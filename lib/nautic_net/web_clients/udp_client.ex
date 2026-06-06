defmodule NauticNet.WebClients.UDPClient do
  @moduledoc """
  Sends DataSet telemetry over UDP, with P9-job-4 AEAD framing + legacy-plaintext
  coexistence.

  A DataSet is an encoded protobuf binary (`NauticNet.Protobuf.DataSet`). Today the
  device sends it as PLAINTEXT over UDP. This module gates that send:

    * If a **live** SecureTransport session exists
      (`NauticNet.SecureTransport.SessionHolder.live?/1`), the DataSet binary is
      sealed into a `SailRoute.SecureTransport.Frame`-compatible AEAD frame
      (device->server key `k_d2s`, header AAD, nonce `epoch||counter`,
      ChaCha20-Poly1305) and THAT frame is what goes on the wire. The frame
      plaintext is EXACTLY the encoded DataSet — i.e. the same bytes the device
      would have sent in the clear — which is precisely what the server's
      `SailRoute.NauticNet.SecureUDPIngest` recovers and feeds to `DataSetIngest`.
      This is SEND-ONLY: the server does not reply with an AEAD frame on UDP
      (secure command delivery is over the P4 channel).

    * If there is **no** live session, behavior is policy-driven by the
      `:require_secure_transport` config (see below):
        - `false` (default, coexistence rollout): send the LEGACY plaintext DataSet
          exactly as before, so an un-handshaken / pre-enforcement device keeps
          working.
        - `true` (post per-device enforcement flip): do NOT send plaintext; drop the
          datagram and log at a low level. Mirrors the server's per-device
          `requires_secure_transport`.

  Counter monotonicity is owned by `SessionHolder` (its `take_send_counter/1`
  reserves a unique `(epoch, counter)` + the out key); the actual sealing is the
  stateless `Frame.seal_with/5`, so concurrent sends can never reuse a `(key,
  nonce)` pair. A crypto/seal error or a session that was just cleared (race) never
  crashes the telemetry pipeline: the one datagram is dropped (UDP is lossy and the
  device re-sends on the next sample).

  The existing UDP RECEIVE handling on the device-initiated socket
  (`NauticNet.WebClients.UDPClient.Server`) is unchanged for legacy command
  coexistence; secure command delivery is the P4 channel.

  ## Config

      config :nautic_net_device, :require_secure_transport, false

  Default `false`. When `true`, plaintext is never sent and a datagram with no live
  session is dropped.
  """

  require Logger

  alias NauticNet.SecureTransport.Frame
  alias NauticNet.SecureTransport.SessionHolder
  alias NauticNet.WebClients.UDPClient.Server

  @config_app :nautic_net_device
  @config_key :require_secure_transport

  def child_spec(arg), do: Server.child_spec(arg)

  @doc """
  Gate + send one encoded DataSet (`proto_binary`) over UDP.

  Returns `:ok` (the send is fire-and-forget; UDP is lossy). Options (mainly for
  tests):

    * `:session_holder` — the `SessionHolder` server to consult
      (default `SessionHolder`).
    * `:send_fun` — 1-arity fun invoked with the FINAL bytes to put on the wire
      (default `&Server.send/1`), so tests can capture the bytes without a socket.
    * `:require_secure_transport` — override the config (default reads the app env).
  """
  @spec send_data_set(binary(), keyword()) :: :ok
  def send_data_set(proto_binary, opts \\ []) when is_binary(proto_binary) do
    holder = Keyword.get(opts, :session_holder, SessionHolder)
    send_fun = Keyword.get(opts, :send_fun, &Server.send/1)

    require_secure? =
      Keyword.get_lazy(opts, @config_key, fn ->
        Application.get_env(@config_app, @config_key, false)
      end)

    case secure_grant(holder) do
      {:ok, grant} -> send_secure(proto_binary, grant, send_fun)
      :no_session -> send_without_session(proto_binary, send_fun, require_secure?)
    end
  end

  # Reserve a counter from the holder iff a session is live. Treat a not-running /
  # crashed holder, or a session cleared between the live? check and the take (race),
  # as "no session" so we never crash the telemetry pipeline.
  defp secure_grant(holder) do
    case SessionHolder.take_send_counter(holder) do
      {:ok, grant} -> {:ok, grant}
      {:error, :no_session} -> :no_session
    end
  catch
    :exit, _ -> :no_session
  end

  defp send_secure(proto_binary, grant, send_fun) do
    case Frame.seal_with(grant.session_id, grant.epoch, grant.counter, grant.out_key, proto_binary) do
      {:ok, frame} ->
        send_fun.(frame)
        :ok

      {:error, reason} ->
        # A seal error (rekey/counter ceiling, AEAD failure) must not crash the
        # pipeline. Drop this datagram; the device re-sends on the next sample. We do
        # NOT silently fall back to plaintext for a sealed-session device.
        Logger.warning("Dropping telemetry datagram; secure seal failed: #{inspect(reason)}")
        :ok
    end
  end

  defp send_without_session(_proto_binary, _send_fun, true) do
    # Enforcement is on for this device but no session is live: do not leak plaintext.
    Logger.debug("Dropping telemetry datagram; secure transport required but no live session")
    :ok
  end

  defp send_without_session(proto_binary, send_fun, false) do
    # Coexistence: legacy plaintext send, exactly as before.
    send_fun.(proto_binary)
    :ok
  end
end
