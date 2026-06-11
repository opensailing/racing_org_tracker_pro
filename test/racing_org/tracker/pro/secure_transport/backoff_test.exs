defmodule RacingOrg.Tracker.Pro.SecureTransport.BackoffTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.Backoff

  @no_jitter [base_ms: 1_000, cap_ms: 60_000, jitter: 0.0]

  test "without jitter, doubles each attempt from the base" do
    assert Backoff.delay(0, @no_jitter) == 1_000
    assert Backoff.delay(1, @no_jitter) == 2_000
    assert Backoff.delay(2, @no_jitter) == 4_000
    assert Backoff.delay(3, @no_jitter) == 8_000
  end

  test "is bounded above by the cap (never grows without limit)" do
    for attempt <- 0..100 do
      assert Backoff.delay(attempt, @no_jitter) <= 60_000
    end

    # A very large attempt still returns the cap, not an overflow.
    assert Backoff.delay(1_000, @no_jitter) == 60_000
    assert Backoff.delay(1_000_000, @no_jitter) == 60_000
  end

  test "monotonically increases (non-decreasing) up to the cap, without jitter" do
    delays = Enum.map(0..20, &Backoff.delay(&1, @no_jitter))

    Enum.zip(delays, tl(delays))
    |> Enum.each(fn {a, b} -> assert b >= a end)

    assert List.last(delays) == 60_000
  end

  test "is never zero / never a hot loop, even with maximal negative jitter" do
    opts = [base_ms: 1, cap_ms: 60_000, jitter: 1.0]

    for attempt <- 0..50, _ <- 1..20 do
      assert Backoff.delay(attempt, opts) >= 1
    end
  end

  test "jitter keeps the delay within +/- the jitter fraction of the un-jittered value" do
    base = 1_000
    jitter = 0.25
    opts = [base_ms: base, cap_ms: 60_000, jitter: jitter]

    # attempt 2 -> un-jittered 4000; jittered in [3000, 5000].
    for _ <- 1..200 do
      d = Backoff.delay(2, opts)
      assert d >= round(4_000 * (1 - jitter))
      assert d <= round(4_000 * (1 + jitter))
    end
  end

  test "jitter actually varies the delay (decorrelates a fleet)" do
    opts = [base_ms: 1_000, cap_ms: 60_000, jitter: 0.5]
    samples = for _ <- 1..50, do: Backoff.delay(3, opts)
    assert length(Enum.uniq(samples)) > 1
  end

  test "defaults are base 1s / cap 60s / 25% jitter" do
    assert Backoff.defaults() == [base_ms: 1_000, cap_ms: 60_000, jitter: 0.25]
  end
end
