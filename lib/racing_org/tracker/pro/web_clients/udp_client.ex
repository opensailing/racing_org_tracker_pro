defmodule RacingOrg.Tracker.Pro.WebClients.UDPClient do
  @moduledoc """
  Sends DataSet telemetry over UDP as AEAD-only — there is NO plaintext fallback.

  A DataSet is an encoded protobuf binary (`RacingOrg.Tracker.Protobuf.DataSet`). The device
  ONLY ever puts a sealed AEAD frame on the wire:

    * If a **live** SecureTransport session exists
      (`RacingOrg.Tracker.Pro.SecureTransport.SessionHolder.live?/1`), the DataSet binary is
      sealed into a `RacingOrg.SecureTransport.Frame`-compatible AEAD frame
      (device->server key `k_d2s`, header AAD, nonce `epoch||counter`,
      ChaCha20-Poly1305) and THAT frame is what goes on the wire. The frame
      plaintext is EXACTLY the encoded DataSet — i.e. the same bytes the device
      would otherwise carry — which is precisely what the server's
      `RacingOrg.SecureUDPIngest` recovers and feeds to `DataSetIngest`.
      This is SEND-ONLY: the server does not reply with an AEAD frame on UDP
      (secure command delivery is over the P4 channel).

    * If there is **no** live session, the datagram is DROPPED (logged/audited at a
      low level). Telemetry is never sent in the clear; the device re-sends on the
      next sample once a session is live.

  Counter monotonicity is owned by `SessionHolder` (its `take_send_counter/1`
  reserves a unique `(epoch, counter)` + the out key); the actual sealing is the
  stateless `Frame.seal_with/5`, so concurrent sends can never reuse a `(key,
  nonce)` pair. A crypto/seal error or a session that was just cleared (race) never
  crashes the telemetry pipeline: the one datagram is dropped (UDP is lossy and the
  device re-sends on the next sample).

  The existing UDP RECEIVE handling on the device-initiated socket
  (`RacingOrg.Tracker.Pro.WebClients.UDPClient.Server`) is unchanged for legacy command
  coexistence; secure command delivery is the P4 channel.
  """

  require Logger

  alias RacingOrg.Tracker.Pro.SecureTransport.Frame
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Pro.WebClients.UDPClient.Server

  def child_spec(arg), do: Server.child_spec(arg)

  @doc """
  Seal + send one encoded DataSet (`proto_binary`) over UDP as an AEAD frame, or
  DROP it when no live session exists. Plaintext is never sent.

  Returns `:ok` (the send is fire-and-forget; UDP is lossy). Options (mainly for
  tests):

    * `:session_holder` — the `SessionHolder` server to consult
      (default `SessionHolder`).
    * `:send_fun` — 1-arity fun invoked with the FINAL (sealed) bytes to put on the
      wire (default `&Server.send/1`), so tests can capture the bytes without a
      socket.
  """
  @spec send_data_set(binary(), keyword()) :: :ok
  def send_data_set(proto_binary, opts \\ []) when is_binary(proto_binary) do
    holder = Keyword.get(opts, :session_holder, SessionHolder)
    send_fun = Keyword.get(opts, :send_fun, &Server.send/1)

    case secure_grant(holder) do
      {:ok, grant} -> send_secure(proto_binary, grant, send_fun)
      :no_session -> drop_without_session()
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

  defp drop_without_session do
    # No live session: drop the datagram. Telemetry is AEAD-only — never leak plaintext.
    Logger.debug("Dropping telemetry datagram; no live secure transport session")
    :ok
  end
end
