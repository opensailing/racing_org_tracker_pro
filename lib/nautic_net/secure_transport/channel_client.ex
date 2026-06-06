defmodule NauticNet.SecureTransport.ChannelClient do
  @moduledoc """
  Device side of the SailRoute authenticated command channel (P9): an OUTBOUND,
  CGNAT-friendly WSS Slipstream client that runs the SecureTransport INITIATOR
  handshake over channel messages, receives server→device commands, applies them
  through the SAME command path as the UDP transport, and acks them.

  ## Transport

  Mirrors `NervesHubLink.Socket`: a single outbound `wss://` connection (so a
  device behind CGNAT/NAT reaches the server without an inbound route), TLS via
  the system/`castore` CA bundle, `http1` only. It connects to the server's
  `SailRouteWeb.DeviceSocket` mount (`/device_socket`) presenting the device key
  `fingerprint` as the connect param, then joins `device:<fingerprint>`.

  ## Handshake (driven over channel pushes — see `SailRouteWeb.DeviceChannel`)

      join "device:<fp>"               ==>
                                       <== "handshake_hello" %{hello: b64}
      "handshake_init" %{init: b64}    ==>
                                       <== "handshake_ok"    %{session_id: b64}
                                           (or "handshake_error" %{reason})

  On `"handshake_hello"` the client runs
  `NauticNet.SecureTransport.Handshake.initiator_init/2` (via the pure
  `ChannelHandler`) with its identity (`KeyStore`), the pinned server public key
  (`ServerIdentity`), and its fingerprint as the `device_id`. It pushes the INIT
  and holds the derived `Session`. On `"handshake_ok"` it sanity-checks the
  `session_id`, marks the session LIVE, and PUBLISHES it to
  `NauticNet.SecureTransport.SessionHolder` (the shared holder job-4 reads for
  AEAD UDP telemetry).

  ## Commands

  On a `"command"` push the client decodes the `ServerReply` protobuf and applies
  it through `NauticNet.Commands` (the existing, idempotent command handler), then
  pushes the `"ack"` event the server expects. Duplicate commands are de-duped by
  `NauticNet.Commands` and still acked (idempotent).

  ## Eviction / reconnect

  `"session_evicted"` (or `"handshake_error"`, or any disconnect) clears the
  session holder and schedules a reconnect on a JITTERED exponential backoff
  (`NauticNet.SecureTransport.Backoff`) — never a hot loop. A fresh handshake runs
  on every reconnect.

  ## Gating (job-6 wires this into the supervision tree)

  `start_link/1` always succeeds and the process is safe to run "not configured":
  if the device is not on a real target, is unclaimed, has no identity, or has no
  pinned server key, the client stays IDLE (it never attempts to connect and never
  crash-loops). It only connects when `connectable?/1` is true. The child spec is
  exposed but NOT added to `application.ex` here.
  """

  use Slipstream

  require Logger

  alias NauticNet.SecureTransport.Backoff
  alias NauticNet.SecureTransport.ChannelHandler
  alias NauticNet.SecureTransport.KeyStore
  alias NauticNet.SecureTransport.ServerIdentity
  alias NauticNet.SecureTransport.SessionHolder

  @device_socket_path "/device_socket"
  @handshake_epoch 0

  # --- Public API / child spec ---

  @doc """
  Start the channel client. Always returns `{:ok, pid}` (or a standard GenServer
  start result); the process self-gates and stays idle when not configured.

  Options (all optional; sensible production defaults):

    * `:name` — registered name (default `__MODULE__`).
    * `:commands` — the `NauticNet.Commands` server (default `NauticNet.Commands`).
    * `:session_holder` — the `SessionHolder` server (default `SessionHolder`).
    * `:url` — full `wss://host/device_socket` URL override (else derived from
      `SECURE_TRANSPORT_WS_URL`, then the configured `:api_endpoint` host).
    * `:keystore_opts` — opts forwarded to `KeyStore.load/1` (tests use a temp dir).
    * `:auto_connect?` — force connect/idle for tests (defaults to `connectable?/0`).
    * `:backoff` — `NauticNet.SecureTransport.Backoff` opts.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Slipstream.start_link(__MODULE__, opts, name: name)
  end

  @doc "Standard supervisor child spec (job-6 adds this to the tree)."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Whether the device is currently configured to connect: a real device target AND
  claimed AND a provisioned identity AND a pinned server public key. Host/test and
  unclaimed/unprovisioned devices return `false` (the client stays idle).
  """
  @spec connectable?(keyword()) :: boolean()
  def connectable?(opts \\ []) do
    device_target?() and claimed?(opts) and has_identity?(opts) and ServerIdentity.configured?()
  end

  # --- Slipstream callbacks ---

  @impl Slipstream
  def init(opts) do
    state = %{
      opts: opts,
      commands: Keyword.get(opts, :commands, NauticNet.Commands),
      session_holder: Keyword.get(opts, :session_holder, SessionHolder),
      backoff_opts: Keyword.get(opts, :backoff, Backoff.defaults()),
      attempt: 0,
      session: nil,
      topic: nil
    }

    socket = new_socket() |> assign(state)

    if auto_connect?(opts) do
      {:ok, socket, {:continue, :connect}}
    else
      Logger.info(
        "[ChannelClient] not yet provisioned (unclaimed / no identity / no pinned " <>
          "server key); will re-check until ready"
      )

      {:ok, schedule_recheck(socket)}
    end
  end

  @impl Slipstream
  def handle_continue(:connect, socket) do
    case connect_opts(socket.assigns.opts) do
      {:ok, opts, topic} ->
        Logger.info("[ChannelClient] connecting to #{inspect(opts[:uri])}")
        {:noreply, socket |> assign(:topic, topic) |> connect!(opts)}

      {:error, reason} ->
        Logger.warning("[ChannelClient] cannot build connect opts: #{inspect(reason)}; backing off")
        {:noreply, schedule_reconnect(socket)}
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info("[ChannelClient] socket connected; joining #{socket.assigns.topic}")
    {:ok, join(socket, socket.assigns.topic)}
  end

  @impl Slipstream
  def handle_join(_topic, _reply, socket) do
    # Reset the failure counter only once the server actually completes the
    # handshake (handshake_ok); a successful socket+join but failed handshake must
    # still back off. So we do NOT reset attempt here.
    Logger.debug("[ChannelClient] joined #{socket.assigns.topic}; awaiting handshake_hello")
    {:ok, socket}
  end

  # Server pushes "handshake_hello" -> produce + push INIT, hold the session.
  @impl Slipstream
  def handle_message(_topic, "handshake_hello", payload, socket) do
    case ChannelHandler.handshake_init(payload, handshake_inputs(socket.assigns.opts)) do
      {:ok, init_payload, session} ->
        socket = assign(socket, :session, session)
        push(socket, socket.assigns.topic, "handshake_init", init_payload)
        {:ok, socket}

      {:error, reason} ->
        Logger.error("[ChannelClient] handshake_init failed: #{inspect(reason)}")
        {:ok, fail_handshake(socket)}
    end
  end

  # Server confirms with "handshake_ok" -> verify, publish the live session.
  def handle_message(_topic, "handshake_ok", payload, socket) do
    case socket.assigns.session do
      nil ->
        Logger.error("[ChannelClient] handshake_ok before a derived session")
        {:ok, fail_handshake(socket)}

      session ->
        case ChannelHandler.verify_handshake_ok(payload, session) do
          :ok ->
            :ok = SessionHolder.put(socket.assigns.session_holder, session)
            Logger.info("[ChannelClient] secure session established")
            {:ok, assign(socket, :attempt, 0)}

          {:error, reason} ->
            Logger.error("[ChannelClient] handshake_ok mismatch: #{inspect(reason)}")
            {:ok, fail_handshake(socket)}
        end
    end
  end

  def handle_message(_topic, "handshake_error", payload, socket) do
    Logger.error("[ChannelClient] server handshake_error: #{inspect(payload)}")
    {:ok, fail_handshake(socket)}
  end

  # Server pushes a command -> decode + apply + ack (idempotent).
  def handle_message(topic, "command", payload, socket) do
    command_id = command_id(payload)

    case ChannelHandler.handle_command(payload, command_id, socket.assigns.commands) do
      {:ack, ack_payload} ->
        push(socket, topic, "ack", ack_payload)
        {:ok, socket}

      {:noack, reason} ->
        Logger.debug("[ChannelClient] command #{inspect(command_id)} not acked: #{inspect(reason)}")
        {:ok, socket}
    end
  end

  # Server killed the session (key revoke / device revoke / transfer).
  def handle_message(_topic, "session_evicted", payload, socket) do
    Logger.warning("[ChannelClient] session evicted: #{inspect(payload)}")
    clear_session(socket)
    {:stop, :normal, socket}
  end

  def handle_message(_topic, event, _payload, socket) do
    Logger.debug("[ChannelClient] ignoring unhandled event #{inspect(event)}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("[ChannelClient] disconnected: #{inspect(reason)}")
    clear_session(socket)
    {:ok, schedule_reconnect(socket)}
  end

  @impl Slipstream
  def handle_topic_close(_topic, reason, socket) do
    Logger.warning("[ChannelClient] topic closed: #{inspect(reason)}")
    clear_session(socket)
    {:ok, schedule_reconnect(disconnect(socket))}
  end

  # Our own jittered-backoff reconnect timer.
  @impl Slipstream
  def handle_info(:reconnect, socket) do
    {:noreply, socket, {:continue, :connect}}
  end

  # Provisioning can complete AFTER boot: BootProvisioner generates the device
  # identity + claims asynchronously, and an operator may provision later. When we
  # started idle, poll connectable?/1 and connect the moment the device is claimed +
  # identity-provisioned + server-pinned, so a fresh device needs no reboot to come
  # online.
  def handle_info(:recheck, socket) do
    if auto_connect?(socket.assigns.opts) do
      Logger.info("[ChannelClient] now provisioned; connecting")
      {:noreply, socket, {:continue, :connect}}
    else
      {:noreply, schedule_recheck(socket)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- internal ---

  # A handshake failure (bad signature, mismatch, server error) is NOT a clean
  # session: clear the holder and reconnect on backoff (which re-runs the
  # handshake fresh). We disconnect the socket so a full reconnect happens.
  defp fail_handshake(socket) do
    clear_session(socket)
    schedule_reconnect(disconnect(socket))
  end

  defp clear_session(socket) do
    _ = SessionHolder.clear(socket.assigns.session_holder)
    assign(socket, :session, nil)
  end

  defp schedule_reconnect(socket) do
    attempt = socket.assigns.attempt
    delay = Backoff.delay(attempt, socket.assigns.backoff_opts)
    Logger.info("[ChannelClient] reconnect ##{attempt + 1} in #{delay}ms")
    Process.send_after(self(), :reconnect, delay)
    assign(socket, :attempt, attempt + 1)
  end

  # Fixed-interval poll used only while idle-waiting for provisioning to complete
  # (distinct from the jittered reconnect backoff above). Configurable for tests.
  defp schedule_recheck(socket) do
    ms = Keyword.get(socket.assigns.opts, :recheck_ms, 15_000)
    Process.send_after(self(), :recheck, ms)
    socket
  end

  defp command_id(payload) do
    case payload do
      %{"command_id" => id} -> id
      _ -> nil
    end
  end

  # --- connect option construction ---

  defp connect_opts(opts) do
    with {:ok, fingerprint} <- fingerprint(opts),
         {:ok, uri} <- ws_uri(opts, fingerprint) do
      base = [
        uri: uri,
        mint_opts: mint_opts(uri),
        reconnect_after_msec: [5_000]
      ]

      # Threaded through so Slipstream.SocketTest can drive the socket layer
      # without a real server (default false in production).
      connect = Keyword.put(base, :test_mode?, Keyword.get(opts, :test_mode?, false))

      {:ok, connect, "device:" <> fingerprint}
    end
  end

  # Append the fingerprint connect param to the /device_socket websocket URL.
  defp ws_uri(opts, fingerprint) do
    case base_ws_url(opts) do
      {:ok, base} ->
        uri = URI.parse(base)
        query = URI.encode_query(%{"fingerprint" => fingerprint})
        {:ok, %{uri | query: query} |> URI.to_string()}

      {:error, _} = err ->
        err
    end
  end

  # URL precedence: explicit :url opt, then SECURE_TRANSPORT_WS_URL env, then
  # derived from the configured HTTP :api_endpoint (http->ws, https->wss) with the
  # /device_socket/websocket path.
  defp base_ws_url(opts) do
    cond do
      url = Keyword.get(opts, :url) -> {:ok, url}
      url = System.get_env("SECURE_TRANSPORT_WS_URL") -> {:ok, url}
      true -> derive_from_api_endpoint()
    end
  end

  defp derive_from_api_endpoint do
    case Application.get_env(:nautic_net_device, :api_endpoint) do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        uri = URI.parse(endpoint)
        scheme = if uri.scheme in ["https", "wss"], do: "wss", else: "ws"
        path = @device_socket_path <> "/websocket"
        {:ok, %URI{scheme: scheme, host: uri.host, port: uri.port, path: path} |> URI.to_string()}

      _ ->
        {:error, :no_api_endpoint}
    end
  end

  # Mirror NervesHubLink: http1 only; for wss, TLS with verify_peer against the
  # castore CA bundle (the device already depends on castore).
  defp mint_opts(uri) do
    if String.starts_with?(uri, "wss") do
      [
        protocols: [:http1],
        transport_opts: [
          verify: :verify_peer,
          cacertfile: castore_path(),
          versions: [:"tlsv1.2", :"tlsv1.3"]
        ]
      ]
    else
      [protocols: [:http1]]
    end
  end

  # CAStore is a target-only dep (it is not present on host/test); resolve it at
  # runtime so the host build compiles cleanly without a missing-module warning.
  defp castore_path do
    castore = Module.concat(["CAStore"])

    if Code.ensure_loaded?(castore) and function_exported?(castore, :file_path, 0) do
      castore.file_path()
    else
      :undefined
    end
  end

  defp handshake_inputs(opts) do
    {:ok, identity} = KeyStore.load(keystore_opts(opts))
    server_pub = ServerIdentity.public_key()

    %{
      device_identity_private: identity.private_key,
      device_identity_public: identity.public_key,
      server_identity_public: server_pub,
      # The server does not validate device_id; it binds whatever we send into the
      # transcript. We send the fingerprint (the routing id) — deterministic, the
      # same id used at connect + as the topic.
      device_id: identity.fingerprint,
      epoch: @handshake_epoch
    }
  end

  defp fingerprint(opts) do
    case KeyStore.load(keystore_opts(opts)) do
      {:ok, %{fingerprint: fp}} -> {:ok, fp}
      {:error, _} = err -> err
    end
  end

  # --- gating helpers ---

  defp auto_connect?(opts), do: Keyword.get_lazy(opts, :auto_connect?, fn -> connectable?(opts) end)

  defp device_target? do
    case Application.get_env(:nautic_net_device, :target) do
      nil -> false
      :host -> false
      :"" -> false
      _ -> true
    end
  end

  defp claimed?(opts) do
    NauticNet.SecureTransport.ClaimClient.claimed?(keystore_opts(opts))
  end

  defp has_identity?(opts) do
    match?({:ok, _}, KeyStore.load(keystore_opts(opts)))
  end

  defp keystore_opts(opts), do: Keyword.get(opts, :keystore_opts, [])
end
