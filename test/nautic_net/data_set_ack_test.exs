defmodule NauticNet.DataSetAckTest do
  # Not async: exercises the application's named NauticNet.Commands process.
  use ExUnit.Case

  alias NauticNet.Commands
  alias NauticNet.Protobuf.CommandAck
  alias NauticNet.Protobuf.DeviceCommand
  alias NauticNet.Protobuf.RaceAssignment
  alias NauticNet.Protobuf.ServerReply

  test "data_set/2 carries the latest applied command ACK" do
    reply =
      ServerReply.new(
        protocol_version: 1,
        # broadcast device_id so it applies regardless of this host's identifier
        device_id: "",
        command:
          DeviceCommand.new(
            command_id: "ack-test-1",
            assignment_id: "asg-ack",
            assignment_version: 7,
            payload: {:race_assignment, RaceAssignment.new()}
          )
      )
      |> ServerReply.encode()

    assert :applied = Commands.apply_reply(reply)

    assert %CommandAck{command_id: "ack-test-1", assignment_id: "asg-ack", assignment_version: 7} =
             NauticNet.data_set([]).ack
  end
end
