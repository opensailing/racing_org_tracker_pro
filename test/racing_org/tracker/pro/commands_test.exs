defmodule RacingOrg.Tracker.Pro.CommandsTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Protobuf.CommandAck
  alias RacingOrg.Protobuf.DeviceCommand
  alias RacingOrg.Protobuf.RaceAssignment
  alias RacingOrg.Protobuf.ServerReply

  setup do
    # A fixed "now" so expiry is deterministic.
    now = ~U[2026-06-03 12:00:00Z]
    pid = start_supervised!({Commands, device_id: "dev-1", now_fn: fn -> now end})
    %{commands: pid, now: now}
  end

  defp encode(opts) do
    payload = Keyword.get(opts, :payload, {:race_assignment, struct(RaceAssignment, race_session_id: "2026-06-03-1")})

    command =
      struct(DeviceCommand,
        command_id: Keyword.get(opts, :command_id, "cmd-1"),
        assignment_id: Keyword.get(opts, :assignment_id, "asg-1"),
        assignment_version: Keyword.get(opts, :assignment_version, 1),
        assignment_hash: Keyword.get(opts, :assignment_hash, "hash-1"),
        expires_at: opts[:expires_at],
        payload: payload
      )

    struct(ServerReply,
      protocol_version: Keyword.get(opts, :protocol_version, 1),
      device_id: Keyword.get(opts, :device_id, "dev-1"),
      command: command
    )
    |> ServerReply.encode()
  end

  defp ts(%DateTime{} = dt), do: RacingOrg.Protobuf.to_proto_timestamp(dt)

  test "applies a valid command and exposes the assignment + ACK", %{commands: c} do
    assert :applied = Commands.apply_reply(c, encode(command_id: "cmd-1", assignment_version: 2))

    assignment = Commands.current_assignment(c)
    assert assignment.assignment_id == "asg-1"
    assert assignment.version == 2

    assert %CommandAck{command_id: "cmd-1", assignment_id: "asg-1", assignment_version: 2} =
             Commands.current_ack(c)
  end

  test "notifies subscribers when a command is applied", %{commands: c} do
    Commands.subscribe(c, self())
    assert :applied = Commands.apply_reply(c, encode(command_id: "cmd-9"))
    assert_receive {:racing_org_command, %DeviceCommand{command_id: "cmd-9"}}
  end

  test "ignores a duplicate command_id (idempotent)", %{commands: c} do
    assert :applied = Commands.apply_reply(c, encode(command_id: "dup", assignment_version: 1))
    assert {:ignored, :duplicate} = Commands.apply_reply(c, encode(command_id: "dup", assignment_version: 1))
  end

  test "ignores a stale assignment version for the same assignment", %{commands: c} do
    assert :applied = Commands.apply_reply(c, encode(command_id: "v2", assignment_version: 2))
    assert {:ignored, :stale_version} = Commands.apply_reply(c, encode(command_id: "v1", assignment_version: 1))
    assert Commands.current_assignment(c).version == 2
  end

  test "accepts a newer assignment version for the same assignment", %{commands: c} do
    assert :applied = Commands.apply_reply(c, encode(command_id: "v1", assignment_version: 1))
    assert :applied = Commands.apply_reply(c, encode(command_id: "v2", assignment_version: 2))
    assert Commands.current_assignment(c).version == 2
  end

  test "ignores an expired command", %{commands: c, now: now} do
    past = DateTime.add(now, -10, :second)
    assert {:ignored, :expired} = Commands.apply_reply(c, encode(command_id: "old", expires_at: ts(past)))
  end

  test "applies a not-yet-expired command", %{commands: c, now: now} do
    future = DateTime.add(now, 60, :second)
    assert :applied = Commands.apply_reply(c, encode(command_id: "fresh", expires_at: ts(future)))
  end

  test "ignores a command addressed to a different device", %{commands: c} do
    assert {:ignored, :device_mismatch} = Commands.apply_reply(c, encode(device_id: "other-device"))
  end

  test "accepts a broadcast command with an empty device_id", %{commands: c} do
    assert :applied = Commands.apply_reply(c, encode(device_id: ""))
  end

  test "ignores an unsupported protocol version", %{commands: c} do
    assert {:ignored, :protocol_mismatch} = Commands.apply_reply(c, encode(protocol_version: 99))
  end

  test "ignores a malformed packet safely", %{commands: c} do
    assert {:ignored, :malformed} = Commands.apply_reply(c, <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>)
    # still functional afterward
    assert :applied = Commands.apply_reply(c, encode(command_id: "after-bad"))
  end

  test "decode/1 returns an error tuple for garbage instead of raising" do
    assert {:error, _} = Commands.decode(<<0xFF, 0xFF, 0xFF>>)
  end
end
