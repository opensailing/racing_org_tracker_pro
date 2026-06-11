defmodule RacingOrg.Tracker.Pro.PacketHandler.EmitTelemetryTest do
  # Not async: attaches global :telemetry handlers and asserts on emitted events.
  use ExUnit.Case

  alias RacingOrg.Tracker.Pro.PacketHandler.EmitTelemetry

  test "attitude data is emitted on the :attitude event path, not :heading" do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      handler_id,
      [[:racing_org, :attitude], [:racing_org, :heading]],
      fn event, measurements, _meta, _config -> send(test_pid, {:telemetry, event, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, pid} = EmitTelemetry.start_link(filter_mode: :permissive)

    data = %NMEA.Data{
      values: %{NMEA.AttitudeParams => %NMEA.AttitudeParams{yaw: 0.1, pitch: 0.2, roll: 0.3}},
      source_info: %NMEA.NMEA2000.Frame{timestamp: ~U[2026-06-03 12:00:00Z], timestamp_monotonic_ms: 1},
      metadata: %{source_nmea_name: <<1, 2, 3, 4, 5, 6, 7, 8>>}
    }

    send(pid, {:data, data})

    assert_receive {:telemetry, [:racing_org, :attitude], %{rad: %{yaw: 0.1, pitch: 0.2, roll: 0.3}}}
    refute_receive {:telemetry, [:racing_org, :heading], _}, 50
  end
end
