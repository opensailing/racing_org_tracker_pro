defmodule NauticNet.SecureTransport.BootProvisioner do
  @moduledoc """
  One-shot, boot-time secure-transport provisioner (Phase AC7 wiring).

  On a real device target, this process performs the bootstrap that turns a freshly
  reflashed device into a registered, identity-provisioned device using TOKENLESS
  self-registration (no claim token, no server-issued nonce):

    1. `KeyStore.load_or_generate/1` — generate + persist the device's long-term
       Ed25519 identity on first boot (idempotent: reloaded unchanged thereafter).
    2. `RegisterClient.register/2` — submit the proof-of-possession-verified
       registration to the server (`POST /api/devices/register`). The device starts
       UNASSIGNED; an admin later associates it to an account (by email) in the web
       panel. On success a small "registered" marker is persisted.

  Once registered + provisioned (and once an admin has associated the device), the
  `ChannelClient`'s gating becomes true, so on the next reconnect tick (or boot) it
  connects the WSS channel and runs the handshake. The handshake/telemetry path is
  owned by `ChannelClient` / `SessionHolder` / `UDPClient`; this module ONLY does the
  initial bootstrap.

  ## Safety / gating

  This is a transient, self-terminating GenServer (`restart: :transient`): it does
  its work in `handle_continue/2` then stops `:normal`, so it never loops. It is
  added to the supervision tree ONLY on the real device target AND when the pinned
  server public key is configured (`ServerIdentity.configured?` — the single
  secure-transport enable). Even when started it is defensive:

    * Server not pinned (`ServerIdentity` unconfigured) -> no-op, stop (there is no
      trusted server to register against yet).
    * Already registered (a register marker exists) -> no-op, stop (re-register would
      be harmless/idempotent, but we avoid the needless round trip).
    * A register REJECTION or transport error is LOGGED, not crashed: the device
      simply stays unregistered (ChannelClient remains idle) until the next boot. We
      deliberately do NOT crash-loop.

  There are no out-of-band provisioning inputs anymore: the only required config is
  the pinned server public key (`ServerIdentity`) and the API endpoint, both already
  read from the build-host environment in `config/config.exs`.
  """

  use GenServer

  require Logger

  alias NauticNet.SecureTransport.KeyStore
  alias NauticNet.SecureTransport.RegisterClient
  alias NauticNet.SecureTransport.ServerIdentity

  @marker_filename "register_marker.json"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Transient child spec — runs once then stops `:normal` (never restarts on normal exit)."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      shutdown: 5_000
    }
  end

  @impl true
  def init(opts) do
    {:ok, opts, {:continue, :provision}}
  end

  @impl true
  def handle_continue(:provision, opts) do
    _ = provision(opts)
    {:stop, :normal, opts}
  end

  @doc """
  Run the boot provisioning once (also callable directly, e.g. from the device CLI).

  Returns:

    * `{:error, :not_configured}` — no pinned server public key; nothing to register
      against (no-op).
    * `{:ok, :already_registered}` — a register marker already exists; nothing to do.
    * `{:ok, register_result}` — a fresh registration succeeded (marker persisted).
    * `{:error, reason}` — identity generation failed or the registration was
      rejected (logged; the device stays unregistered).
  """
  @spec provision(keyword()) ::
          {:ok, :already_registered} | {:ok, map()} | {:error, term()}
  def provision(opts \\ []) do
    keystore_opts = Keyword.get(opts, :keystore_opts, [])

    cond do
      not ServerIdentity.configured?() ->
        Logger.info("[BootProvisioner] server public key not pinned; staying unregistered until provisioned")

        {:error, :not_configured}

      registered?(keystore_opts) ->
        Logger.info("[BootProvisioner] device already registered; nothing to do")
        {:ok, :already_registered}

      true ->
        with {:ok, identity} <- ensure_identity(keystore_opts) do
          do_register(identity, opts, keystore_opts)
        else
          {:error, reason} = err ->
            Logger.error("[BootProvisioner] cannot provision identity: #{inspect(reason)}")
            err
        end
    end
  end

  @doc "Whether a registered marker has been persisted under the base path."
  @spec registered?(keyword()) :: boolean()
  def registered?(opts \\ []), do: File.exists?(marker_path(opts))

  @doc "Reads the persisted registered marker, or `{:error, :not_registered}` if absent."
  @spec read_marker(keyword()) :: {:ok, map()} | {:error, term()}
  def read_marker(opts \\ []) do
    case File.read(marker_path(opts)) do
      {:ok, json} -> Jason.decode(json)
      {:error, :enoent} -> {:error, :not_registered}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  ## --- internal ------------------------------------------------------------

  defp ensure_identity(keystore_opts) do
    case KeyStore.load_or_generate(keystore_opts) do
      {:ok, identity} ->
        Logger.info("[BootProvisioner] device identity ready (fp=#{identity.fingerprint})")
        {:ok, identity}

      {:error, _} = err ->
        err
    end
  end

  # Forward the test-injectable transport/base opts to RegisterClient; keystore_opts
  # carries the base_path the marker is written under.
  defp do_register(identity, opts, keystore_opts) do
    register_opts = Keyword.take(opts, [:adapter, :base_url, :register_path, :timestamp, :boat_identifier])

    case RegisterClient.register(identity, register_opts) do
      {:ok, result} ->
        Logger.info(
          "[BootProvisioner] device registered (device_id=#{inspect(result.device_id)} status=#{inspect(result.status)})"
        )

        _ = persist_marker(result, keystore_opts)
        {:ok, result}

      {:error, reason} = err ->
        # A rejected/failed registration does NOT crash the supervisor: the device
        # stays unregistered (ChannelClient idle) until the next boot.
        Logger.error("[BootProvisioner] device registration failed: #{inspect(reason)}")
        err
    end
  end

  defp persist_marker(result, keystore_opts) do
    marker = %{
      "device_id" => result.device_id,
      "fingerprint" => result.fingerprint,
      "status" => result.status,
      "registered_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    path = marker_path(keystore_opts)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(marker),
         :ok <- File.write(path, json) do
      :ok
    else
      {:error, _} = err -> err
    end
  end

  defp marker_path(opts), do: Path.join(KeyStore.key_path(opts) |> Path.dirname(), @marker_filename)
end
