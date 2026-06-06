defmodule NauticNet.SecureTransport.Backoff do
  @moduledoc """
  Pure, jittered exponential backoff schedule for the secure-transport command
  channel (`NauticNet.SecureTransport.ChannelClient`).

  Every disconnect or handshake failure schedules a reconnect after
  `delay/2` milliseconds, computed from the consecutive-failure `attempt` count:

      base * 2^attempt, capped at `:cap`, then ± up to `:jitter` fraction.

  Jitter (full +/- random spread) decorrelates a fleet of devices so they do not
  reconnect in lockstep and stampede the server after a server-side blip. The cap
  bounds the worst case so a long-down device still retries about once a minute.
  The minimum returned delay is always `>= 1` ms (never 0 / never a hot loop):
  even `attempt: 0` with negative jitter is clamped up, so the channel can never
  busy-reconnect.

  This is intentionally separate from Slipstream's built-in
  `reconnect_after_msec` list: the channel client drives its OWN reconnect timer
  (so a HANDSHAKE failure — which happens AFTER a successful socket connect —
  backs off on the same curve as a transport disconnect), and this pure function
  is unit-testable without a socket.
  """

  import Bitwise, only: [bsl: 2]

  @default_base_ms 1_000
  @default_cap_ms 60_000
  @default_jitter 0.25

  @type opts :: [base_ms: pos_integer(), cap_ms: pos_integer(), jitter: number()]

  @doc "Default backoff options (base 1s, cap 60s, +/-25% jitter)."
  @spec defaults() :: opts()
  def defaults, do: [base_ms: @default_base_ms, cap_ms: @default_cap_ms, jitter: @default_jitter]

  @doc """
  Delay in milliseconds before the reconnect for a 0-based `attempt`.

  `attempt: 0` is the first retry. The result is always a positive integer (>= 1),
  bounded above by `cap_ms * (1 + jitter)`.
  """
  @spec delay(non_neg_integer(), opts()) :: pos_integer()
  def delay(attempt, opts \\ []) when is_integer(attempt) and attempt >= 0 do
    base = Keyword.get(opts, :base_ms, @default_base_ms)
    cap = Keyword.get(opts, :cap_ms, @default_cap_ms)
    jitter = Keyword.get(opts, :jitter, @default_jitter)

    base
    |> exp(attempt, cap)
    |> min(cap)
    |> apply_jitter(jitter)
    |> max(1)
  end

  # base * 2^attempt, clamped to the cap. The exponent is itself clamped so a huge
  # `attempt` can't shift into an absurd integer before the `min(cap)` clamp.
  defp exp(base, attempt, cap) do
    # Once 2^attempt would already exceed cap/base, the result is the cap anyway,
    # so cap the shift amount to avoid building a giant intermediate.
    max_shift = 32
    shift = min(attempt, max_shift)

    base
    |> bsl(shift)
    |> min(cap)
  end

  # Symmetric jitter: scale the delay by a random factor in [1 - jitter, 1 + jitter].
  defp apply_jitter(delay, jitter) when jitter <= 0, do: round(delay)

  defp apply_jitter(delay, jitter) do
    factor = 1 + jitter * (2 * :rand.uniform() - 1)
    round(delay * factor)
  end
end
