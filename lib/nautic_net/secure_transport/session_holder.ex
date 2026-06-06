defmodule NauticNet.SecureTransport.SessionHolder do
  @moduledoc """
  Shared, supervised holder for the CURRENT live secure-transport `Session`.

  The `NauticNet.SecureTransport.ChannelClient` runs the device→server handshake
  over the WSS command channel and, once the server confirms it
  (`"handshake_ok"`), PUBLISHES the established `Session` here. Other subsystems —
  most importantly the P9-job-4 AEAD UDP telemetry path — read the session from
  this single owner rather than reaching into the channel client process.

  ## Why a GenServer owns the send counter

  The secure-transport AEAD nonce is `epoch || send_counter` (see
  `NauticNet.SecureTransport.Frame`). Reusing a `(key, counter)` pair under one
  epoch is catastrophic (nonce reuse breaks ChaCha20-Poly1305 confidentiality and
  integrity). The counter MUST therefore advance monotonically with no gaps or
  reuse even when MANY processes seal frames concurrently.

  To make that safe by construction, this holder OWNS counter monotonicity: it is
  the single writer of the send counter. A sealer never mutates a `Session`'s
  `send_counter` itself; instead it calls `take_send_counter/1` (or
  `take_send_counters/2` for a batch), which atomically returns the next
  counter value(s) and advances the stored counter. Because the GenServer
  serializes these calls, two concurrent sealers can never receive the same
  counter.

  ## API contract (job-4)

  Job-4 seals a UDP telemetry frame like this:

      {:ok, %{session_id: sid, out_key: key, epoch: epoch, counter: ctr}} =
        SessionHolder.take_send_counter()
      frame = Frame.seal_with(key, epoch, ctr, plaintext)  # job-4 helper

  i.e. `take_send_counter/1` hands back everything needed to seal exactly ONE
  frame: the sealing key (`out_key` = device→server `k_d2s`), the `epoch`, the
  cleartext `session_id` (for routing/the frame header), and a UNIQUE, never-reused
  `counter`. The counter is reserved the instant it is returned, so even if the
  caller crashes before sealing, that counter is simply skipped (gaps are safe;
  reuse is not).

  When there is no live session, the take/get functions return
  `{:error, :no_session}` — callers must not seal.

  ## Lifecycle

    * `put/1`        — ChannelClient publishes a freshly-established session
                       (resets the counter base to the session's `send_counter`).
    * `take_send_counter/1`, `take_send_counters/2` — reserve counter(s) to seal.
    * `get_current_session/0` — read-only snapshot (counter NOT advanced); for
                       inspection/telemetry. Sealers MUST use the take functions.
    * `clear/0`      — ChannelClient drops the session on disconnect/eviction.

  The holder is a plain `GenServer` (no ETS/`:persistent_term`): a single writer
  is the simplest correct way to guarantee counter monotonicity, and the session
  is small + read-rarely-relative-to-writes. It is safe to start with NO session
  (idle) and never crashes on a missing session.
  """

  use GenServer

  alias NauticNet.SecureTransport.Session

  @type counter_grant :: %{
          session_id: binary(),
          out_key: binary(),
          epoch: non_neg_integer(),
          counter: non_neg_integer(),
          role: Session.role()
        }

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Publish the current live session, replacing any previous one. The counter base
  is taken from the session's own `send_counter` (normally 0 for a fresh
  handshake).
  """
  @spec put(GenServer.server(), Session.t()) :: :ok
  def put(server \\ __MODULE__, %Session{} = session) do
    GenServer.call(server, {:put, session})
  end

  @doc "Drop the current session (no live session afterwards). Idempotent."
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  @doc """
  Read-only snapshot of the current session, or `{:error, :no_session}`.

  The returned `Session`'s `send_counter` reflects the NEXT counter that would be
  handed out, but reading it here does NOT reserve it. Sealers MUST use
  `take_send_counter/1` instead so the counter is reserved atomically.
  """
  @spec get_current_session(GenServer.server()) :: {:ok, Session.t()} | {:error, :no_session}
  def get_current_session(server \\ __MODULE__) do
    GenServer.call(server, :get_current_session)
  end

  @doc "Whether a live session is currently held."
  @spec live?(GenServer.server()) :: boolean()
  def live?(server \\ __MODULE__) do
    GenServer.call(server, :live?)
  end

  @doc """
  Atomically reserve the next send counter and return everything needed to seal
  ONE outbound (device→server) frame.

  Returns `{:ok, grant}` where `grant` is a `t:counter_grant/0`, or
  `{:error, :no_session}` when no session is live. The reserved counter is never
  handed out again for this session.
  """
  @spec take_send_counter(GenServer.server()) ::
          {:ok, counter_grant()} | {:error, :no_session}
  def take_send_counter(server \\ __MODULE__) do
    case take_send_counters(server, 1) do
      {:ok, [grant]} -> {:ok, grant}
      {:error, _} = err -> err
    end
  end

  @doc """
  Atomically reserve `count` consecutive send counters, returning a grant for
  each (ascending). Useful for sealing a batch without N round-trips.
  """
  @spec take_send_counters(GenServer.server(), pos_integer()) ::
          {:ok, [counter_grant()]} | {:error, :no_session}
  def take_send_counters(server \\ __MODULE__, count) when is_integer(count) and count > 0 do
    GenServer.call(server, {:take_send_counters, count})
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    {:ok, %{session: nil}}
  end

  @impl true
  def handle_call({:put, session}, _from, state) do
    {:reply, :ok, %{state | session: session}}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | session: nil}}
  end

  def handle_call(:get_current_session, _from, %{session: nil} = state) do
    {:reply, {:error, :no_session}, state}
  end

  def handle_call(:get_current_session, _from, %{session: session} = state) do
    {:reply, {:ok, session}, state}
  end

  def handle_call(:live?, _from, state) do
    {:reply, not is_nil(state.session), state}
  end

  def handle_call({:take_send_counters, _count}, _from, %{session: nil} = state) do
    {:reply, {:error, :no_session}, state}
  end

  def handle_call({:take_send_counters, count}, _from, %{session: %Session{} = session} = state) do
    start = session.send_counter

    grants =
      for counter <- start..(start + count - 1)//1 do
        %{
          session_id: session.session_id,
          out_key: session.out_key,
          epoch: session.epoch,
          counter: counter,
          role: session.role
        }
      end

    session = %{session | send_counter: start + count}
    {:reply, {:ok, grants}, %{state | session: session}}
  end
end
