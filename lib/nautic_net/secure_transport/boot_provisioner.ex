defmodule NauticNet.SecureTransport.BootProvisioner do
  @moduledoc """
  One-shot, boot-time secure-transport provisioner (P9-job-6 wiring).

  On a real device target, when an operator has supplied the out-of-band claim
  inputs (a claim-token secret + the server-issued nonce) and the device is not yet
  claimed, this process performs the ONE-TIME bootstrap that turns a freshly
  reflashed device into a claimed, identity-provisioned device:

    1. `KeyStore.load_or_generate/1` — generate + persist the device's long-term
       Ed25519 identity on first boot (idempotent: reloaded unchanged thereafter).
    2. `ClaimClient.claim/2` — submit the proof-of-possession-verified claim to the
       server (`POST /api/devices/claim`) and persist the claimed marker on success.

  Once claimed + provisioned, the `ChannelClient`'s `connectable?/1` becomes true,
  so on the next reconnect tick (or boot) it connects the WSS channel and runs the
  handshake. The handshake/telemetry path is owned by `ChannelClient` /
  `SessionHolder` / `UDPClient`; this module ONLY does the initial bootstrap.

  ## Safety / gating

  This is a transient, self-terminating GenServer (`restart: :transient`): it does
  its work in `handle_continue/2` then stops `:normal`, so it never loops. It is
  added to the supervision tree ONLY on the real device target AND when
  `config :nautic_net_device, :secure_claim_on_boot` is true (job-6 config). Even
  when started it is defensive:

    * Already claimed (a claim marker exists) -> no-op, stop.
    * No claim-token secret / server_nonce configured -> no-op, stop (nothing to do
      until the operator provisions them).
    * A claim REJECTION or transport error is LOGGED, not crashed: the device simply
      stays unclaimed (ChannelClient remains idle) until the inputs are corrected and
      the device reboots. We deliberately do NOT crash-loop on a bad token.

  The claim inputs are read from config (typically wired from env at runtime):

      config :nautic_net_device, NauticNet.SecureTransport.ClaimClient,
        claim_token_secret: System.get_env("CLAIM_TOKEN_SECRET")
      config :nautic_net_device, #{inspect(__MODULE__)},
        server_nonce: System.get_env("CLAIM_TOKEN_SERVER_NONCE")

  `server_nonce` is base64 in the env (matching the mint response) and decoded here;
  the secret is read by `ClaimClient` from its own config key.
  """

  use GenServer

  require Logger

  alias NauticNet.SecureTransport.ClaimClient
  alias NauticNet.SecureTransport.KeyStore

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

    * `{:ok, :already_claimed}` — a claim marker already exists; nothing to do.
    * `{:ok, claim_result}` — a fresh claim succeeded.
    * `{:error, reason}` — identity generation failed, inputs missing, or the claim
      was rejected (logged; the device stays unclaimed).
  """
  @spec provision(keyword()) ::
          {:ok, :already_claimed} | {:ok, map()} | {:error, term()}
  def provision(opts \\ []) do
    keystore_opts = Keyword.get(opts, :keystore_opts, [])

    cond do
      ClaimClient.claimed?(keystore_opts) ->
        Logger.info("[BootProvisioner] device already claimed; nothing to do")
        {:ok, :already_claimed}

      true ->
        with {:ok, identity} <- ensure_identity(keystore_opts),
             {:ok, claim_opts} <- claim_opts(opts, keystore_opts) do
          do_claim(identity, claim_opts)
        else
          {:error, :no_claim_inputs} ->
            Logger.info(
              "[BootProvisioner] no claim token configured; staying unclaimed until provisioned"
            )

            {:error, :no_claim_inputs}

          {:error, reason} = err ->
            Logger.error("[BootProvisioner] cannot provision identity: #{inspect(reason)}")
            err
        end
    end
  end

  defp ensure_identity(keystore_opts) do
    case KeyStore.load_or_generate(keystore_opts) do
      {:ok, identity} ->
        Logger.info("[BootProvisioner] device identity ready (fp=#{identity.fingerprint})")
        {:ok, identity}

      {:error, _} = err ->
        err
    end
  end

  # Build the ClaimClient opts: the secret comes from ClaimClient's own config; the
  # server_nonce is base64 in env/config and decoded to raw bytes here. With no
  # secret OR no nonce there is nothing to claim with -> :no_claim_inputs (no-op).
  # Pass-through opts (`:adapter`, `:base_url`, `:claim_path`, `:base_path`) are
  # forwarded so a test can inject a mock transport and the marker base dir lines up.
  defp claim_opts(opts, keystore_opts) do
    secret = Keyword.get(opts, :claim_token_secret) || configured_secret()

    case {secret, configured_nonce(opts)} do
      {s, {:ok, nonce}} when is_binary(s) and s != "" ->
        passthrough = Keyword.take(opts, [:adapter, :base_url, :claim_path, :base_path])

        merged =
          keystore_opts
          |> Keyword.merge(passthrough)
          |> Keyword.merge(claim_token_secret: s, server_nonce: nonce)

        {:ok, merged}

      _ ->
        {:error, :no_claim_inputs}
    end
  end

  defp configured_secret do
    :nautic_net_device
    |> Application.get_env(ClaimClient, [])
    |> Keyword.get(:claim_token_secret)
  end

  # server_nonce may be supplied raw (32 bytes), as an explicit opt, or base64 from
  # config/env (the mint response encodes it base64).
  defp configured_nonce(opts) do
    raw =
      Keyword.get(opts, :server_nonce) ||
        (:nautic_net_device
         |> Application.get_env(__MODULE__, [])
         |> Keyword.get(:server_nonce))

    decode_nonce(raw)
  end

  defp decode_nonce(<<_::binary-size(32)>> = raw), do: {:ok, raw}

  defp decode_nonce(b64) when is_binary(b64) and b64 != "" do
    case Base.decode64(b64) do
      {:ok, <<_::binary-size(32)>> = raw} -> {:ok, raw}
      _ -> :error
    end
  end

  defp decode_nonce(_), do: :error

  defp do_claim(identity, claim_opts) do
    case ClaimClient.claim(identity, claim_opts) do
      {:ok, result} ->
        Logger.info(
          "[BootProvisioner] device claimed (device_id=#{inspect(result.device_id)} status=#{inspect(result.status)})"
        )

        {:ok, result}

      {:error, reason} = err ->
        # A rejected/failed claim does NOT crash the supervisor: the device stays
        # unclaimed (ChannelClient idle) until the operator fixes the inputs + reboots.
        Logger.error("[BootProvisioner] device claim failed: #{inspect(reason)}")
        err
    end
  end
end
