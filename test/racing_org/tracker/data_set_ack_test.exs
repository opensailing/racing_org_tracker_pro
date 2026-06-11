defmodule RacingOrg.Tracker.DataSetAckTest do
  # Not async: exercises the application's named RacingOrg.Tracker.Commands process.
  use ExUnit.Case

  alias RacingOrg.Tracker.Commands
  alias RacingOrg.Protobuf.CommandAck
  alias RacingOrg.Protobuf.DeviceCommand
  alias RacingOrg.Protobuf.RaceAssignment
  alias RacingOrg.Protobuf.ServerReply

  test "data_set/2 carries the latest applied command ACK" do
    reply =
      struct(ServerReply, 
        protocol_version: 1,
        # broadcast device_id so it applies regardless of this host's identifier
        device_id: "",
        command:
          struct(DeviceCommand, 
            command_id: "ack-test-1",
            assignment_id: "asg-ack",
            assignment_version: 7,
            payload: {:race_assignment, %RaceAssignment{}}
          )
      )
      |> ServerReply.encode()

    assert :applied = Commands.apply_reply(reply)

    assert %CommandAck{command_id: "ack-test-1", assignment_id: "asg-ack", assignment_version: 7} =
             RacingOrg.Tracker.data_set([]).ack
  end

  test "data_set/2 tags the current sample mode and race phase" do
    # With no race underway the device idles at 1 Hz.
    data_set = RacingOrg.Tracker.data_set([])
    assert data_set.sample_mode == :SAMPLE_MODE_OUTING_1HZ
    assert data_set.race_phase == :RACE_PHASE_IDLE
  end
end
