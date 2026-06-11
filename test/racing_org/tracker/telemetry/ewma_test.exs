defmodule RacingOrg.Tracker.Telemetry.EwmaTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Telemetry.Ewma

  describe "alpha/2" do
    test "tau = 0 is pass-through (alpha = 1.0)" do
      assert Ewma.alpha(0.123, 0.0) == 1.0
    end

    test "alpha = 1 - exp(-dt/tau)" do
      dt = 0.5
      tau = 1.0
      assert_in_delta Ewma.alpha(dt, tau), 1.0 - :math.exp(-0.5), 1.0e-12
    end

    test "a larger dt yields a larger alpha (faster catch-up)" do
      assert Ewma.alpha(2.0, 1.0) > Ewma.alpha(0.5, 1.0)
    end
  end

  describe "linear update/4 (tau = 0 pass-through)" do
    test "with no prior state the sample passes through unchanged" do
      {value, state} = Ewma.update(nil, 5.0, 100, 0.0, :linear)
      assert value == 5.0
      assert {sv, _t} = state
      assert sv == 5.0
    end

    test "every sample passes through unchanged when tau = 0" do
      {_v1, s1} = Ewma.update(nil, 1.0, 0, 0.0, :linear)
      {v2, _s2} = Ewma.update(s1, 9.0, 1000, 0.0, :linear)
      assert v2 == 9.0
    end
  end

  describe "linear update/4 step response (time constant)" do
    # Drive a step from 0 -> 1 and check the smoothed output approaches the
    # textbook 1 - e^{-t/tau} curve when sampled at fixed dt.
    test "a unit step converges per the time constant" do
      tau = 1.0
      dt_ms = 100
      # seed at 0.0 at t=0
      {v0, state} = Ewma.update(nil, 0.0, 0, tau, :linear)
      assert v0 == 0.0

      # After one tau (10 samples of 0.1s) the response should be ~1 - e^-1 ≈ 0.632.
      {value, _state} =
        Enum.reduce(1..10, {nil, state}, fn n, {_v, st} ->
          Ewma.update(st, 1.0, n * dt_ms, tau, :linear)
        end)

      assert_in_delta value, 1.0 - :math.exp(-1.0), 0.02
    end

    test "smoothing is sample-rate independent (same elapsed time => same result)" do
      tau = 2.0

      # Path A: one big step of dt = 1.0s.
      {_v0, a0} = Ewma.update(nil, 0.0, 0, tau, :linear)
      {va, _} = Ewma.update(a0, 1.0, 1000, tau, :linear)

      # Path B: ten small steps totalling 1.0s, same input value the whole time.
      {_v0, b0} = Ewma.update(nil, 0.0, 0, tau, :linear)

      {vb, _} =
        Enum.reduce(1..10, {nil, b0}, fn n, {_v, st} ->
          Ewma.update(st, 1.0, n * 100, tau, :linear)
        end)

      # Both represent 1.0s of a held step input -> the same smoothed value.
      assert_in_delta va, vb, 1.0e-9
    end
  end

  describe "circular update/4 (angles in radians)" do
    test "tau = 0 passes the angle through unchanged" do
      {value, _state} = Ewma.update(nil, 3.0, 0, 0.0, :circular)
      assert_in_delta value, 3.0, 1.0e-12
    end

    test "smooths across the 0 / 2π wrap correctly (no 0..2π averaging artifact)" do
      tau = 1.0
      dt_ms = 100
      eps = 0.05

      # Seed just below 2π, then feed samples just above 0 (i.e. just past the wrap).
      # A naive linear mean would swing toward π; the circular smoother must stay
      # near the wrap (≈ 0 / 2π), not the antipode.
      {_v, state} = Ewma.update(nil, 2 * :math.pi() - eps, 0, tau, :circular)

      {value, _state} =
        Enum.reduce(1..50, {nil, state}, fn n, {_v, st} ->
          Ewma.update(st, eps, n * dt_ms, tau, :circular)
        end)

      # Normalize the output to a signed offset from 0 and assert it's tiny.
      offset = :math.atan2(:math.sin(value), :math.cos(value))
      assert abs(offset) < 0.2, "expected angle near the wrap (≈0), got #{value} (offset #{offset})"
    end

    test "the smoothed angle is always normalized to [0, 2π)" do
      {value, _} = Ewma.update(nil, -0.5, 0, 0.0, :circular)
      assert value >= 0.0
      assert value < 2 * :math.pi()
    end
  end
end
