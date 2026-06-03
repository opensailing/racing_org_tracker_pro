defmodule NauticNet.Sampling.PhaseTest do
  use ExUnit.Case, async: true

  alias NauticNet.Commands.Assignment
  alias NauticNet.Protobuf.CourseMark
  alias NauticNet.Protobuf.LatLon
  alias NauticNet.Protobuf.RaceAssignment
  alias NauticNet.Protobuf.SamplingRules
  alias NauticNet.Sampling.Phase

  @start ~U[2026-06-03 12:00:00Z]

  defp ts(%DateTime{} = dt), do: NauticNet.Protobuf.to_proto_timestamp(dt)

  defp assignment(opts) do
    rules =
      if Keyword.get(opts, :rules, true) do
        SamplingRules.new(
          default_mode: :SAMPLE_MODE_OUTING_1HZ,
          race_mode: :SAMPLE_MODE_RACE_5HZ,
          event_mode: :SAMPLE_MODE_EVENT_10HZ,
          start_window_seconds: Keyword.get(opts, :sw, 60),
          finish_window_seconds: Keyword.get(opts, :fw, 60),
          mark_proximity_meters: Keyword.get(opts, :mp, 100)
        )
      end

    race =
      RaceAssignment.new(
        official_start_time: opts[:start] && ts(opts[:start]),
        expected_duration_seconds: Keyword.get(opts, :duration, 3600),
        sampling_rules: rules,
        course_marks: Keyword.get(opts, :marks, [])
      )

    %Assignment{
      assignment_id: "a",
      version: 1,
      command_id: "c",
      expires_at: opts[:expires] && ts(opts[:expires]),
      race_assignment: race,
      cancelled: Keyword.get(opts, :cancelled, false)
    }
  end

  defp shift(seconds), do: DateTime.add(@start, seconds, :second)

  test "no assignment is idle at 1 Hz" do
    assert {:idle, :outing_1hz} = Phase.evaluate(nil, @start)
  end

  test "a cancelled assignment is complete at 1 Hz" do
    assert {:complete, :outing_1hz} = Phase.evaluate(assignment(cancelled: true), shift(10))
  end

  test "unreliable (pre-GPS-sync) time stays idle at 1 Hz" do
    assert {:idle, :outing_1hz} = Phase.evaluate(assignment(start: @start), ~U[1970-01-01 00:00:00Z])
  end

  test "an assignment with no start time is idle" do
    assert {:idle, :outing_1hz} = Phase.evaluate(assignment(start: nil), @start)
  end

  test "before the start window is idle at 1 Hz" do
    assert {:idle, :outing_1hz} = Phase.evaluate(assignment(start: @start), shift(-120))
  end

  test "inside the start window is pre_start at 10 Hz" do
    assert {:pre_start, :event_10hz} = Phase.evaluate(assignment(start: @start), shift(-30))
    assert {:pre_start, :event_10hz} = Phase.evaluate(assignment(start: @start), shift(30))
  end

  test "after the start window, mid-race is racing at 5 Hz" do
    assert {:racing, :race_5hz} = Phase.evaluate(assignment(start: @start), shift(120))
  end

  test "within mark proximity while racing is rounding at 10 Hz" do
    marks = [CourseMark.new(code: "1", position: LatLon.new(latitude: 42.0, longitude: -70.0))]
    a = assignment(start: @start, marks: marks, mp: 100)
    # ~50 m away
    assert {:rounding, :event_10hz} = Phase.evaluate(a, shift(120), %{lat: 42.0004, lon: -70.0})
    # far away -> racing
    assert {:racing, :race_5hz} = Phase.evaluate(a, shift(120), %{lat: 41.0, lon: -70.0})
  end

  test "inside the finish window is finish at 10 Hz" do
    assert {:finish, :event_10hz} = Phase.evaluate(assignment(start: @start, duration: 3600), shift(3600 - 30))
  end

  test "past the expected finish is complete at 1 Hz" do
    assert {:complete, :outing_1hz} = Phase.evaluate(assignment(start: @start, duration: 3600), shift(3600))
  end

  test "an expired assignment is complete at 1 Hz" do
    a = assignment(start: @start, expires: shift(-1))
    assert {:complete, :outing_1hz} = Phase.evaluate(a, shift(30))
  end

  test "falls back to the standard modes when sampling rules are absent" do
    assert {:racing, :race_5hz} = Phase.evaluate(assignment(start: @start, rules: false), shift(120))
  end
end
