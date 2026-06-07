defmodule NauticNet.SamplingTest do
  use ExUnit.Case, async: true

  alias NauticNet.Commands
  alias NauticNet.Protobuf.CourseMark
  alias NauticNet.Protobuf.DeviceCommand
  alias NauticNet.Protobuf.LatLon
  alias NauticNet.Protobuf.RaceAssignment
  alias NauticNet.Protobuf.SamplingRules
  alias NauticNet.Protobuf.ServerReply
  alias NauticNet.Sampling

  # A stand-in reporter that records the flush intervals the controller requests.
  defmodule StubReporter do
    use GenServer
    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:set_flush_interval, ms}, _from, test_pid) do
      send(test_pid, {:flush_interval, ms})
      {:reply, :ok, test_pid}
    end
  end

  @start ~U[2026-06-03 12:00:00Z]

  defp ts(dt), do: NauticNet.Protobuf.to_proto_timestamp(dt)

  defp start_sampling(now) do
    commands = start_supervised!({Commands, device_id: "dev"})
    reporter = start_supervised!({StubReporter, self()})

    sampling =
      start_supervised!(
        {Sampling,
         commands: commands, reporter: reporter, now_fn: fn -> now end, reevaluate_interval_ms: 60_000}
      )

    %{commands: commands, sampling: sampling}
  end

  defp apply_race_assignment(commands, opts) do
    rules =
      struct(SamplingRules, 
        default_mode: :SAMPLE_MODE_OUTING_1HZ,
        race_mode: :SAMPLE_MODE_RACE_5HZ,
        event_mode: :SAMPLE_MODE_EVENT_10HZ,
        start_window_seconds: 60,
        finish_window_seconds: 60,
        mark_proximity_meters: 100
      )

    race =
      struct(RaceAssignment, 
        official_start_time: ts(@start),
        expected_duration_seconds: 3600,
        sampling_rules: rules,
        course_marks: Keyword.get(opts, :marks, [])
      )

    command =
      struct(DeviceCommand, 
        command_id: "c1",
        assignment_id: "a1",
        assignment_version: 1,
        payload: {:race_assignment, race}
      )

    reply = struct(ServerReply, protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
    :applied = Commands.apply_reply(commands, reply)
  end

  test "boots at idle / 1 Hz and sets the reporter to 1000 ms" do
    %{sampling: s} = start_sampling(@start)
    assert Sampling.current_phase(s) == :idle
    assert Sampling.current_mode(s) == :outing_1hz
    assert_receive {:flush_interval, 1000}
  end

  test "switches to 5 Hz racing when a race is underway" do
    %{commands: c, sampling: s} = start_sampling(DateTime.add(@start, 120, :second))
    apply_race_assignment(c, [])
    assert {:racing, :race_5hz} = Sampling.reevaluate(s)
    assert Sampling.current_mode(s) == :race_5hz
    assert_receive {:flush_interval, 200}
  end

  test "switches to 10 Hz during the start window" do
    %{commands: c, sampling: s} = start_sampling(DateTime.add(@start, -30, :second))
    apply_race_assignment(c, [])
    assert {:pre_start, :event_10hz} = Sampling.reevaluate(s)
    assert_receive {:flush_interval, 100}
  end

  test "goes to 10 Hz rounding when near a mark" do
    %{commands: c, sampling: s} = start_sampling(DateTime.add(@start, 120, :second))
    marks = [struct(CourseMark, code: "1", position: struct(LatLon, latitude: 42.0, longitude: -70.0))]
    apply_race_assignment(c, marks: marks)
    send(s, {:sampling_position, {42.0, -70.0}})
    assert {:rounding, :event_10hz} = Sampling.reevaluate(s)
  end

  test "returns to 1 Hz after the expected finish" do
    %{commands: c, sampling: s} = start_sampling(DateTime.add(@start, 3600, :second))
    apply_race_assignment(c, [])
    assert {:complete, :outing_1hz} = Sampling.reevaluate(s)
  end
end
