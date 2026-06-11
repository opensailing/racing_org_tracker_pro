defmodule RacingOrg.Tracker.Pro.Commands.PersistenceTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Protobuf.ActiveWaypointUpdate
  alias RacingOrg.Protobuf.CancelAssignment
  alias RacingOrg.Protobuf.DeviceCommand
  alias RacingOrg.Protobuf.LatLon
  alias RacingOrg.Protobuf.NoopCommand
  alias RacingOrg.Protobuf.RaceAssignment
  alias RacingOrg.Protobuf.RouteUpdate
  alias RacingOrg.Protobuf.ServerReply

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_persist_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp start(dir), do: start_supervised!({Commands, device_id: "dev", store_dir: dir})

  defp encode(opts) do
    payload =
      Keyword.get(
        opts,
        :payload,
        {:race_assignment, struct(RaceAssignment, race_session_id: "2026-06-03-1", active_mark_code: "1")}
      )

    command =
      struct(DeviceCommand,
        command_id: Keyword.get(opts, :command_id, "cmd-1"),
        assignment_id: Keyword.get(opts, :assignment_id, "asg-1"),
        assignment_version: Keyword.get(opts, :assignment_version, 1),
        assignment_hash: Keyword.get(opts, :assignment_hash, "h1"),
        payload: payload
      )

    struct(ServerReply, protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
  end

  test "an applied assignment survives a restart, and stale commands are rejected after reboot", %{dir: dir} do
    c1 = start(dir)
    assert :applied = Commands.apply_reply(c1, encode(command_id: "v3", assignment_version: 3))
    :ok = stop_supervised(RacingOrg.Tracker.Pro.Commands)

    c2 = start(dir)
    assert Commands.current_assignment(c2).version == 3
    assert Commands.current_assignment(c2).race_assignment.race_session_id == "2026-06-03-1"
    # ACK is restored so RacingOrg learns the device already applied this command.
    assert Commands.current_ack(c2).assignment_version == 3
    # A re-sent same/older version is still rejected after reboot.
    assert {:ignored, :stale_version} =
             Commands.apply_reply(c2, encode(command_id: "v3-again", assignment_version: 3))
  end

  test "route_update overlays route + active mark while preserving the course", %{dir: dir} do
    c = start(dir)
    assert :applied = Commands.apply_reply(c, encode(command_id: "ra", assignment_version: 1))

    route =
      {:route_update,
       struct(RouteUpdate,
         route_hash: "rh",
         active_mark_code: "2",
         route_geometry: [struct(LatLon, latitude: 1.0, longitude: 2.0)]
       )}

    assert :applied = Commands.apply_reply(c, encode(command_id: "ru", assignment_version: 2, payload: route))

    a = Commands.current_assignment(c)
    assert a.active_mark_code == "2"
    assert a.route_hash == "rh"
    assert a.version == 2
    assert a.race_assignment.race_session_id == "2026-06-03-1"
  end

  test "active_waypoint_update changes the active mark", %{dir: dir} do
    c = start(dir)
    assert :applied = Commands.apply_reply(c, encode(command_id: "ra", assignment_version: 1))

    waypoint = {:active_waypoint_update, struct(ActiveWaypointUpdate, active_mark_code: "3")}
    assert :applied = Commands.apply_reply(c, encode(command_id: "awu", assignment_version: 2, payload: waypoint))
    assert Commands.current_assignment(c).active_mark_code == "3"
  end

  test "cancel_assignment marks the assignment cancelled", %{dir: dir} do
    c = start(dir)
    assert :applied = Commands.apply_reply(c, encode(command_id: "ra", assignment_version: 1))

    cancel = {:cancel_assignment, struct(CancelAssignment, reason: "abandoned")}
    assert :applied = Commands.apply_reply(c, encode(command_id: "cx", assignment_version: 2, payload: cancel))
    assert Commands.current_assignment(c).cancelled == true
  end

  test "a non-assignment command updates the ACK without touching the assignment", %{dir: dir} do
    c = start(dir)
    assert :applied = Commands.apply_reply(c, encode(command_id: "ra", assignment_version: 1))

    noop = {:noop, %NoopCommand{}}

    assert :applied =
             Commands.apply_reply(
               c,
               encode(command_id: "noop", assignment_id: "", assignment_version: 0, payload: noop)
             )

    assert Commands.current_assignment(c).assignment_id == "asg-1"
    assert Commands.current_ack(c).command_id == "noop"
  end

  test "a corrupt persisted file at boot is ignored without crashing", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.assignment"), "garbage")

    c = start(dir)
    assert Commands.current_assignment(c) == nil
    assert :applied = Commands.apply_reply(c, encode(command_id: "fresh"))
  end

  test "without a store_dir, persistence is disabled and the process still works" do
    c = start_supervised!({Commands, device_id: "dev"})
    assert :applied = Commands.apply_reply(c, encode(command_id: "mem-only"))
    assert Commands.current_assignment(c).version == 1
  end
end
