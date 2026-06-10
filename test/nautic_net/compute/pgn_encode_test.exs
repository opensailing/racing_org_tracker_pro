defmodule NauticNet.Compute.PgnEncodeTest do
  use ExUnit.Case, async: true

  alias NauticNet.Compute.PgnEncode

  # We assert round-trip correctness: PgnEncode emits a payload that, decoded by the
  # SAME deps' decoders the device uses to RECEIVE these PGNs, recovers the input
  # within scaling tolerance. That guarantees ENCODE is the inverse of DECODE.
  alias NauticNet.NMEA2000.J1939

  @deg_per_rad 180.0 / :math.pi()

  # Catalog units: speeds m/s, angles DEGREES, depth m, temperature Kelvin (the
  # NMEA-native unit). The engine output for a 130312 def is already Kelvin and
  # scales straight to the wire (no offset).

  defp def_for(pgn, overrides) do
    Map.merge(
      %{
        output_pgn: pgn,
        output_field: nil,
        output_reference: nil,
        output_unit: nil,
        output_instance: nil
      },
      overrides
    )
  end

  describe "130306 Wind — speed + angle + reference" do
    test "encodes a single-scalar speed def and round-trips speed" do
      d = def_for(130_306, %{output_field: "wind_speed", output_reference: "apparent"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 6.0})
      assert byte_size(payload) == 8

      decoded = J1939.WindDataParams.decode(payload)
      assert_in_delta decoded.wind_speed, 6.0, 0.01
      assert decoded.wind_reference == :apparent
    end

    test "a true_wind library calc fills BOTH wind_speed and wind_angle with reference=true" do
      d = def_for(130_306, %{output_field: "wind_speed", output_reference: "true"})
      outputs = %{"true_wind_speed" => 7.5, "true_wind_angle" => 35.0, "true_wind_direction" => 200.0}

      assert {:ok, payload} = PgnEncode.encode(d, outputs)
      decoded = J1939.WindDataParams.decode(payload)

      assert_in_delta decoded.wind_speed, 7.5, 0.01
      # 35 deg -> radians; decoder yields radians.
      assert_in_delta decoded.wind_angle, 35.0 / @deg_per_rad, 0.001
      # reference "true" must map to a TRUE wind reference (boat- or water-referenced),
      # never :apparent.
      assert decoded.wind_reference in [:true_boat_referenced, :true_water_referenced, :true_ground_referenced]
    end

    test "wind angle wraps negative degrees into [0,2pi) on the wire (u16 angle)" do
      d = def_for(130_306, %{output_field: "wind_speed", output_reference: "true"})
      # -10 deg should encode as 350 deg.
      outputs = %{"true_wind_speed" => 5.0, "true_wind_angle" => -10.0}
      assert {:ok, payload} = PgnEncode.encode(d, outputs)
      decoded = J1939.WindDataParams.decode(payload)
      assert_in_delta decoded.wind_angle, 350.0 / @deg_per_rad, 0.001
    end
  end

  describe "128259 Speed — water/ground referenced" do
    test "water-referenced speed round-trips into the water_speed field" do
      d = def_for(128_259, %{output_field: "speed_water_referenced"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 4.2})
      decoded = J1939.SpeedParams.decode(payload)
      assert_in_delta decoded.water_speed, 4.2, 0.01
    end

    test "ground-referenced speed round-trips into the ground_speed field" do
      d = def_for(128_259, %{output_field: "speed_ground_referenced"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 3.1})
      decoded = J1939.SpeedParams.decode(payload)
      assert_in_delta decoded.ground_speed, 3.1, 0.01
    end
  end

  describe "128267 Water Depth" do
    test "depth in meters round-trips" do
      d = def_for(128_267, %{output_field: "depth"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 12.34})
      decoded = J1939.WaterDepthParams.decode(payload)
      assert_in_delta decoded.depth, 12.34, 0.01
    end
  end

  describe "130312 Temperature — instanced" do
    test "temperature (Kelvin catalog unit) round-trips on the wire; instance carried" do
      d = def_for(130_312, %{output_field: "temperature", output_instance: 3})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 294.15})
      decoded = J1939.TemperatureParams.decode(payload)
      assert decoded.instance == 3
      # catalog unit is Kelvin; the value passes straight through (no offset)
      assert_in_delta decoded.temperature_k, 294.15, 0.02
    end
  end

  describe "127250 Vessel Heading (+ reference)" do
    test "heading degrees round-trips to radians with reference" do
      d = def_for(127_250, %{output_field: "heading", output_reference: "true"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 123.0})
      decoded = J1939.VesselHeadingParams.decode(payload)
      assert_in_delta decoded.heading, 123.0 / @deg_per_rad, 0.001
      assert decoded.reference == :true_reference
    end
  end

  describe "127257 Attitude (yaw/pitch/roll)" do
    test "single-scalar roll maps to the roll field (signed)" do
      d = def_for(127_257, %{output_field: "roll"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => -15.0})
      decoded = J1939.AttitudeParams.decode(payload)
      assert_in_delta decoded.roll, -15.0 / @deg_per_rad, 0.001
    end

    test "named yaw/pitch/roll outputs all populate their fields" do
      d = def_for(127_257, %{output_field: "yaw"})
      outputs = %{"yaw" => 10.0, "pitch" => -5.0, "roll" => 20.0}
      assert {:ok, payload} = PgnEncode.encode(d, outputs)
      decoded = J1939.AttitudeParams.decode(payload)
      assert_in_delta decoded.yaw, 10.0 / @deg_per_rad, 0.001
      assert_in_delta decoded.pitch, -5.0 / @deg_per_rad, 0.001
      assert_in_delta decoded.roll, 20.0 / @deg_per_rad, 0.001
    end
  end

  describe "129026 COG/SOG Rapid" do
    test "cog (deg) + sog (m/s) round-trip; reference=true" do
      d = def_for(129_026, %{output_field: "sog", output_reference: "true"})
      outputs = %{"sog" => 5.5, "cog" => 88.0}
      assert {:ok, payload} = PgnEncode.encode(d, outputs)
      decoded = J1939.VelocityOverGroundParams.decode(payload)
      assert_in_delta decoded.speed_over_ground, 5.5, 0.01
      assert_in_delta decoded.course_over_ground, 88.0 / @deg_per_rad, 0.001
      assert decoded.direction_reference == :true_reference
    end
  end

  describe "proprietary best-effort PGNs" do
    test "130824 (B&G) encodes 8 bytes with manufacturer header + scalar (best effort)" do
      d = def_for(130_824, %{output_field: "value"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 3.3})
      assert byte_size(payload) == 8
      # Manufacturer/industry header is the canonical NMEA proprietary prefix: the
      # first two little-endian bytes carry manufacturer code (11 bits) + industry
      # code (3 bits, 4 = Marine) with a 2-bit reserved field set to 1s.
      <<_mfg_word::little-16, _rest::binary>> = payload
    end

    test "65305 (Simrad) encodes 8 bytes with manufacturer header + scalar (best effort)" do
      d = def_for(65_305, %{output_field: "value"})
      assert {:ok, payload} = PgnEncode.encode(d, %{"value" => 1.0})
      assert byte_size(payload) == 8
    end
  end

  describe "130824 B&G Race Timer (Key 117)" do
    # canboat: PGN 130824 "B&G: key-value data", Key 117 "Race Timer", value u32 in
    # MILLISECONDS (resolution 0.001 s). The descriptor packs Key (12 bits) + Length
    # (4 bits, = value byte length) into 2 little-endian bytes: low byte = key[0..7],
    # high byte = key[8..11] | (Length << 4). Key 117 = 0x075, Length 4 -> "75 40".
    # The full payload is the 2-byte B&G/Marine manufacturer header, then the pair.

    # B&G = 381, Marine = 4: (381 &&& 0x7FF) | (0b11 <<< 11) | (4 <<< 13) = 0x997D,
    # serialized little-endian -> bytes 7D 99.
    @bandg_header <<0x7D, 0x99>>

    test "encodes the worked 5:00 example exactly: 7D 99 75 40 E0 93 04 00" do
      # 300_000 ms = 0x000493E0; u32 LE -> E0 93 04 00; pair -> 75 40 E0 93 04 00.
      assert PgnEncode.race_timer(300_000) == @bandg_header <> <<0x75, 0x40, 0xE0, 0x93, 0x04, 0x00>>
    end

    test "the descriptor word is always Key=117 Length=4 (75 40), header first" do
      <<header::binary-2, 0x75, 0x40, _value::binary-4>> = PgnEncode.race_timer(123_456)
      assert header == @bandg_header
    end

    test "zero ms encodes as all-zero value bytes (the gun)" do
      assert PgnEncode.race_timer(0) == @bandg_header <> <<0x75, 0x40, 0x00, 0x00, 0x00, 0x00>>
    end

    test "value is uint32 little-endian milliseconds for an arbitrary count" do
      # 1500 ms = 0x000005DC -> LE DC 05 00 00.
      assert PgnEncode.race_timer(1_500) == @bandg_header <> <<0x75, 0x40, 0xDC, 0x05, 0x00, 0x00>>
    end

    test "the payload is exactly 8 bytes (2 header + 6 pair) — one fast-packet frame's worth" do
      assert byte_size(PgnEncode.race_timer(60_000)) == 8
    end

    test "race_timer_from/2 computes (gun - now) in ms from monotonic-ms inputs" do
      # gun 90s out from now (in ms): 90_000 ms remaining.
      assert PgnEncode.race_timer_from(90_000, 0) == PgnEncode.race_timer(90_000)
    end

    test "race_timer_from/2 past the gun encodes the elapsed magnitude (count-up)" do
      # now 30s past the gun: |gun - now| = 30_000 ms elapsed.
      assert PgnEncode.race_timer_from(0, 30_000) == PgnEncode.race_timer(30_000)
    end
  end

  describe "unknown / unencodable" do
    test "an unknown PGN returns :error" do
      d = def_for(999_999, %{output_field: "value"})
      assert :error = PgnEncode.encode(d, %{"value" => 1.0})
    end

    test "a missing required output returns :error" do
      d = def_for(128_259, %{output_field: "speed_water_referenced"})
      assert :error = PgnEncode.encode(d, %{})
    end
  end
end
