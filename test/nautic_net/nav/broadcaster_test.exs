defmodule NauticNet.Nav.BroadcasterTest do
  use ExUnit.Case, async: true

  alias NauticNet.Commands
  alias NauticNet.Nav.Broadcaster
  alias NauticNet.Protobuf.CourseMark
  alias NauticNet.Protobuf.DeviceCommand
  alias NauticNet.Protobuf.LatLon
  alias NauticNet.Protobuf.RaceAssignment
  alias NauticNet.Protobuf.ServerReply

  defp start_broadcaster do
    test_pid = self()
    commands = start_supervised!({Commands, device_id: "dev"})

    broadcaster =
      start_supervised!(
        {Broadcaster,
         commands: commands,
         interval_ms: 60_000,
         transmit_fn: fn priority, pgn, payload -> send(test_pid, {:tx, priority, pgn, payload}) end,
         name: nil}
      )

    %{commands: commands, broadcaster: broadcaster}
  end

  defp assign_course(commands) do
    marks = [
      CourseMark.new(code: "1", sequence: 1, position: LatLon.new(latitude: 42.0, longitude: -70.0)),
      CourseMark.new(code: "2", sequence: 2, position: LatLon.new(latitude: 42.1, longitude: -70.0))
    ]

    race = RaceAssignment.new(course_marks: marks, active_mark_code: "2", route_hash: "rh")

    command =
      DeviceCommand.new(
        command_id: "c1",
        assignment_id: "a1",
        assignment_version: 1,
        payload: {:race_assignment, race}
      )

    reply = ServerReply.new(protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
    :applied = Commands.apply_reply(commands, reply)
  end

  test "broadcasts nav-data, XTE, and route PGNs while navigating" do
    %{commands: c, broadcaster: b} = start_broadcaster()
    assign_course(c)
    send(b, {:nav_position, {42.05, -70.001}})

    assert {%{active?: true}, 3} = Broadcaster.broadcast_now(b)

    assert_receive {:tx, 3, 129_284, nav_data}
    assert byte_size(nav_data) == 34
    assert_receive {:tx, 3, 129_283, _xte}
    assert_receive {:tx, 6, 129_285, _route}
  end

  test "broadcasts nothing when there is no active waypoint" do
    %{broadcaster: b} = start_broadcaster()
    assert {%{active?: false}, 0} = Broadcaster.broadcast_now(b)
    refute_receive {:tx, _, _, _}, 50
  end

  test "never transmits an autopilot heading/track-control PGN" do
    %{commands: c, broadcaster: b} = start_broadcaster()
    assign_course(c)
    send(b, {:nav_position, {42.05, -70.0}})
    Broadcaster.broadcast_now(b)

    pgns =
      for _ <- 1..3, do: (receive do {:tx, _p, pgn, _} -> pgn after 50 -> nil end)

    refute 127_237 in pgns
    assert Enum.sort(pgns) == [129_283, 129_284, 129_285]
  end
end
