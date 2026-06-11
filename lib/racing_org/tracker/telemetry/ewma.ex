defmodule RacingOrg.Tracker.Telemetry.Ewma do
  @moduledoc """
  Time-constant EWMA (exponentially-weighted moving average) low-pass filter,
  applied to each signal BEFORE it is sent so the device emits a smoothed value at
  the configured send rate rather than the raw sensor sample.

  ## The filter

  On each incoming sample `x` at time `t` for a signal whose previous sample was at
  `t_prev`, with elapsed `Δt = t - t_prev` (seconds) and time constant `τ` (seconds):

      α = 1 - exp(-Δt / τ)
      y ← y + α · (x - y)

  Because `α` is derived from the ACTUAL elapsed time between samples (from the
  device's monotonic clock), the smoothing is SAMPLE-RATE INDEPENDENT: the same
  wall-clock span of a held input produces the same smoothed output regardless of
  how many samples arrived in between.

  `τ = 0` ⇒ pass-through (α = 1): the latest sample is emitted unsmoothed.

  ## Linear vs circular signals

  Averaging an angle in degrees/radians across the 0 ⇄ 2π wrap is wrong (a naive
  mean of 359° and 1° gives 180°, the exact opposite of the true ~0°). For circular
  quantities (wind angle, heading, course-over-ground, yaw — anything that wraps) the
  filter smooths the unit-vector COMPONENTS (sin θ, cos θ) independently and recovers
  the angle with `atan2`, normalized to `[0, 2π)`.

  Linear quantities (speed, depth, magnitude, lat/lon, pitch/roll) are smoothed
  directly.

  ## State

  Per-signal state is `{value, last_monotonic_ms}` (or `nil` before the first
  sample). For circular signals `value` is the running ANGLE in radians (the
  components are re-derived each step — only the angle needs carrying). `update/5`
  returns `{emitted_value, new_state}`.
  """

  @two_pi 2 * :math.pi()

  @typedoc "Per-signal smoother state, or nil before the first sample."
  @type state :: nil | {number(), integer()}

  @typedoc "Whether the quantity wraps (`:circular`) or not (`:linear`)."
  @type kind :: :linear | :circular

  @doc """
  The EWMA blend factor `α = 1 - exp(-Δt/τ)` for elapsed `dt` (s) and time constant
  `tau` (s). `tau == 0` ⇒ `1.0` (pass-through). Clamped to `[0.0, 1.0]`.
  """
  @spec alpha(number(), number()) :: float()
  def alpha(_dt, tau) when tau <= 0, do: 1.0
  def alpha(dt, _tau) when dt <= 0, do: 0.0

  def alpha(dt, tau) do
    a = 1.0 - :math.exp(-dt / tau)
    min(1.0, max(0.0, a))
  end

  @doc """
  Fold one `sample` (taken at monotonic time `now_ms`) into the smoother `state`
  with time constant `tau` (seconds) for a `:linear` or `:circular` quantity.

  Returns `{emitted_value, new_state}`. With no prior state, or `tau == 0`, the
  sample passes through unsmoothed (but its time/value is recorded for the next Δt).
  """
  @spec update(state(), number(), integer(), number(), kind()) :: {float(), state()}
  def update(state, sample, now_ms, tau, kind)

  def update(nil, sample, now_ms, _tau, :linear) do
    value = sample / 1
    {value, {value, now_ms}}
  end

  def update(nil, sample, now_ms, _tau, :circular) do
    value = normalize_angle(sample / 1)
    {value, {value, now_ms}}
  end

  def update({prev, last_ms}, sample, now_ms, tau, :linear) do
    a = alpha((now_ms - last_ms) / 1000, tau)
    value = prev + a * (sample - prev)
    {value, {value, now_ms}}
  end

  def update({prev, last_ms}, sample, now_ms, tau, :circular) do
    a = alpha((now_ms - last_ms) / 1000, tau)

    # Smooth the unit-vector components toward the new angle's components, then
    # recover the angle. This averages "the short way around" across the wrap.
    sin = :math.sin(prev) + a * (:math.sin(sample) - :math.sin(prev))
    cos = :math.cos(prev) + a * (:math.cos(sample) - :math.cos(prev))
    value = normalize_angle(:math.atan2(sin, cos))
    {value, {value, now_ms}}
  end

  @doc "Normalize an angle in radians to `[0, 2π)`."
  @spec normalize_angle(number()) :: float()
  def normalize_angle(theta) do
    r = :math.fmod(theta, @two_pi)
    if r < 0, do: r + @two_pi, else: r / 1
  end
end
