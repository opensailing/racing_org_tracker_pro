defmodule NauticNet.WebClients.UDPClient.ServerTest do
  use ExUnit.Case, async: true

  alias NauticNet.Commands
  alias NauticNet.Protobuf.DeviceCommand
  alias NauticNet.Protobuf.RaceAssignment
  alias NauticNet.Protobuf.ServerReply
  alias NauticNet.WebClients.UDPClient.Server

  test "forwards received UDP packets to the commands processor" do
    commands = start_supervised!({Commands, device_id: "dev-1"})
    Commands.subscribe(commands, self())

    server =
      start_supervised!({Server, hostname: "localhost", port: 65_000, commands: commands, name: nil})

    packet =
      struct(ServerReply, 
        protocol_version: 1,
        device_id: "dev-1",
        command:
          struct(DeviceCommand, 
            command_id: "udp-1",
            assignment_id: "asg-1",
            assignment_version: 1,
            payload: {:race_assignment, %RaceAssignment{}}
          )
      )
      |> ServerReply.encode()

    send(server, {:udp, :fake_socket, {127, 0, 0, 1}, 4001, packet})

    assert_receive {:nautic_net_command, %DeviceCommand{command_id: "udp-1"}}
  end

  test "a malformed received packet does not crash the server" do
    commands = start_supervised!({Commands, device_id: "dev-1"})

    server =
      start_supervised!({Server, hostname: "localhost", port: 65_001, commands: commands, name: nil})

    send(server, {:udp, :fake_socket, {127, 0, 0, 1}, 4001, <<0xFF, 0xFF, 0xFF, 0xFF>>})

    # The server is still alive and responsive.
    assert Process.alive?(server)
    assert Commands.current_assignment(commands) == nil
  end
end
