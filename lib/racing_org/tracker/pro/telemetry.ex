defmodule RacingOrg.Tracker.Pro.Telemetry do
  @moduledoc """
  Defines metrics and starts the telemetry reporter.

  See `RacingOrg.Tracker.Pro.PacketHandler.EmitTelemetry` for where these metrics are emitted.
  """

  alias RacingOrg.Tracker.Pro.DataSetRecorder
  alias RacingOrg.Tracker.Pro.DeviceInfo
  alias RacingOrg.Tracker.Protobuf

  def child_spec(_opts) do
    %{
      id: RacingOrg.Tracker.Pro.Telemetry,
      start:
        {RacingOrg.Tracker.Pro.Telemetry.Reporter, :start_link,
         [[name: RacingOrg.Tracker.Pro.Telemetry.Reporter, metrics: metrics(), callback: &report_metric/3]]}
    }
  end

  defp metrics do
    import Telemetry.Metrics

    [
      # summary("racing_org.temperature.kelvin", reporter_options: [every_ms: 1_000]),
      summary([:racing_org, :wind, :apparent, :vector], reporter_options: [every_ms: 1_000]),
      last_value([:racing_org, :gps, :position], reporter_options: [asap?: true]),
      last_value([:racing_org, :speed, :water, :speed_m_s], reporter_options: [every_ms: 1_000]),
      last_value([:racing_org, :water_depth, :depth_m], reporter_options: [every_ms: 1_000]),
      last_value([:racing_org, :heading, :rad], reporter_options: [every_ms: 1_000]),
      last_value([:racing_org, :velocity, :ground, :vector], reporter_options: [every_ms: 1_000]),
      last_value([:racing_org, :attitude, :rad], reporter_options: [every_ms: 1_000])
    ]
  end

  @doc """
  Pushes a measurement off the device.

  `metric_name` is a list of atoms for the measurement name, e.g. `[:racing_org, :gps, :position]`.

  `device_id` is the device identifier tuple.

  For `last_value` of a number, the `value` is just that number.
  For `last_value` of a GPS position, the `value` is the map `%{lat: float, lon: float}`.
  For `last_value` of a vector, the `value` is the map `%{angle: float, magnitude: float}` with the angle in radians.
  For the `summary` of a number or vector, the map has the keys: `:min`, `:max`, `:mean`, `:median`, and `:count`.
  """
  @spec report_metric([atom], RacingOrg.Tracker.Pro.DeviceInfo.id(), term) :: term
  def report_metric(metric_name, device_id, value) do
    metric_name
    |> to_proto_data_points(device_id, value)
    |> DataSetRecorder.add_data_points()
  end

  ### Attitude

  defp to_proto_data_points([:racing_org, :attitude, :rad], device_id, %{
         timestamp: timestamp,
         yaw: yaw_rad,
         pitch: pitch_rad,
         roll: roll_rad
       }) do
    [
      proto_data_point(device_id, timestamp,
        sample:
          {:attitude,
           struct(Protobuf.AttitudeSample,
             yaw_mrad: Protobuf.Convert.encode_unit(yaw_rad, :rad, :mrad),
             pitch_mrad: Protobuf.Convert.encode_unit(pitch_rad, :rad, :mrad),
             roll_mrad: Protobuf.Convert.encode_unit(roll_rad, :rad, :mrad)
           )}
      )
    ]
  end

  ### GPS POSITION

  defp to_proto_data_points([:racing_org, :gps, :position], device_id, %{
         timestamp: timestamp,
         lat: lat,
         lon: lon
       }) do
    [
      proto_data_point(device_id, timestamp,
        sample: {:position, struct(Protobuf.PositionSample, latitude: lat, longitude: lon)}
      )
    ]
  end

  ### APPARENT WIND

  defp to_proto_data_points([:racing_org, :wind, :apparent, :vector], device_id, %{
         timestamp: timestamp,
         mean: mean
       }) do
    [
      proto_data_point(device_id, timestamp,
        sample:
          {:wind_velocity,
           struct(Protobuf.WindVelocitySample,
             wind_reference: Protobuf.WindReference.value(:WIND_REFERENCE_APPARENT),
             speed_cm_s: Protobuf.Convert.encode_unit(mean.magnitude, :m_s, :cm_s),
             angle_mrad: Protobuf.Convert.encode_unit(mean.angle, :rad, :mrad)
           )}
      )
    ]
  end

  ### SPEED, WATER REFERENCED

  defp to_proto_data_points([:racing_org, :speed, :water, :speed_m_s], device_id, %{
         timestamp: timestamp,
         value: speed_m_s
       }) do
    [
      proto_data_point(device_id, timestamp,
        sample:
          {:speed,
           struct(Protobuf.SpeedSample,
             speed_reference: Protobuf.SpeedReference.value(:SPEED_REFERENCE_WATER),
             speed_cm_s: Protobuf.Convert.encode_unit(speed_m_s, :m_s, :cm_s)
           )}
      )
    ]
  end

  ### WATER DEPTH

  defp to_proto_data_points([:racing_org, :water_depth, :depth_m], device_id, %{
         timestamp: timestamp,
         value: depth_m
       }) do
    [
      proto_data_point(device_id, timestamp,
        sample:
          {:water_depth, struct(Protobuf.WaterDepthSample, depth_cm: Protobuf.Convert.encode_unit(depth_m, :m, :cm))}
      )
    ]
  end

  defp to_proto_data_points([:racing_org, :heading, :rad], device_id, %{
         timestamp: timestamp,
         value: angle_rad
       }) do
    [
      proto_data_point(device_id, timestamp,
        sample:
          {:heading,
           struct(Protobuf.HeadingSample,
             angle_mrad: Protobuf.Convert.encode_unit(angle_rad, :rad, :mrad),
             # No idea if this is true or magnetic...
             angle_reference: Protobuf.AngleReference.value(:ANGLE_REFERENCE_NONE)
           )}
      )
    ]
  end

  ###  VELOCITY OVER GROUND

  defp to_proto_data_points([:racing_org, :velocity, :ground, :vector], device_id, %{
         timestamp: timestamp,
         angle: angle_rad,
         magnitude: speed_m_s
       }) do
    [
      proto_data_point(device_id, timestamp,
        sample:
          {:velocity,
           struct(Protobuf.VelocitySample,
             # ANGLE_REFERENCE_REFERENCE_TRUE is an educated guess...
             angle_reference: Protobuf.AngleReference.value(:ANGLE_REFERENCE_TRUE_NORTH),
             speed_reference: Protobuf.SpeedReference.value(:SPEED_REFERENCE_GROUND),
             angle_mrad: Protobuf.Convert.encode_unit(angle_rad, :rad, :mrad),
             speed_cm_s: Protobuf.Convert.encode_unit(speed_m_s, :m_s, :cm_s)
           )}
      )
    ]
  end

  defp to_proto_data_points(_metric_name, _device_id, _value), do: []

  defp proto_data_point(device_id, timestamp, fields) do
    [
      timestamp: Protobuf.to_proto_timestamp(timestamp),
      hw_id: DeviceInfo.hw_id(device_id)
    ]
    |> Keyword.merge(fields)
    |> then(&struct(Protobuf.DataSet.DataPoint, &1))
  end
end
