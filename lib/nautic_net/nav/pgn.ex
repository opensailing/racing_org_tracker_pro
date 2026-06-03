defmodule NauticNet.Nav.PGN do
  @moduledoc """
  Encodes outbound NMEA 2000 navigation *display* PGNs from a `NauticNet.Nav.State`:

    * 129283 — Cross Track Error
    * 129284 — Navigation Data (active waypoint, bearing/range, active leg, destination)
    * 129285 — Navigation Route / WP Information (the route list)

  These are information PGNs that chartplotters broadcast; they do not command an
  autopilot. No heading/track-control PGNs are produced here. All multi-byte
  fields are little-endian per NMEA 2000, with the standard "unknown" sentinels
  where a value is unavailable.
  """

  alias NauticNet.Nav.State

  @pgn_xte 129_283
  @pgn_nav_data 129_284
  @pgn_route 129_285

  @u16_unknown 0xFFFF
  @u32_unknown 0xFFFFFFFF
  @s16_unknown 0x7FFF
  @s32_unknown 0x7FFFFFFF

  @doc """
  The `{priority, pgn, payload}` messages to broadcast for the given nav state.
  Empty when not navigating.
  """
  def nav_messages(state, waypoints \\ [], route_name \\ "")

  def nav_messages(%State{active?: false}, _waypoints, _route_name), do: []

  def nav_messages(%State{} = state, waypoints, route_name) do
    [
      {3, @pgn_nav_data, navigation_data_129284(state)},
      {3, @pgn_xte, xte_129283(state)}
    ] ++ route_messages(waypoints, route_name)
  end

  defp route_messages([], _route_name), do: []
  defp route_messages(waypoints, route_name), do: [{6, @pgn_route, route_129285(waypoints, route_name)}]

  @doc "PGN 129283 Cross Track Error (8 bytes)."
  def xte_129283(%State{cross_track_m: xte}, sid \\ 0) do
    xte_value = if is_number(xte), do: round(xte * 100), else: @s32_unknown
    # XTE mode = 0 (Autonomous), reserved bits set, navigation terminated = No.
    mode_byte = 0x30
    <<sid::8, mode_byte::8, xte_value::little-signed-32, @u16_unknown::little-16>>
  end

  @doc "PGN 129284 Navigation Data (34-byte fast packet payload)."
  def navigation_data_129284(%State{} = state, sid \\ 0) do
    {dest_lat, dest_lon} = encode_latlon(state.destination)

    # Course/Bearing Reference = True (0); Perpendicular not crossed; arrival not
    # entered; Calculation Type = Great Circle (0); reserved bit set.
    flags = 0x80

    <<sid::8, encode_u32(state.distance_to_dest_m, 100)::little-32, flags::8,
      @u32_unknown::little-32, @u16_unknown::little-16, encode_rad(state.bearing_origin_to_dest_rad)::little-16,
      encode_rad(state.bearing_position_to_dest_rad)::little-16, encode_wp(state.origin_wp_number)::little-32,
      encode_wp(state.destination_wp_number)::little-32, dest_lat::little-signed-32,
      dest_lon::little-signed-32, @s16_unknown::little-signed-16>>
  end

  @doc """
  PGN 129285 Navigation Route/WP Information (variable-length fast packet).

  `waypoints` is a list of `%{code: String.t(), lat: float, lon: float}`.

  Note: the route-list PGN's exact field layout and B&G support vary; this is a
  best-effort encoding. Prefer the GPX export (`NauticNet.Nav.GPX`) when route
  PGN support is limited.
  """
  def route_129285(waypoints, route_name \\ "") do
    count = length(waypoints)

    header =
      <<1::little-16, count::little-16, 0::little-16, 0::little-16, 0::8>> <>
        string_lau(route_name) <> <<@u16_unknown::little-16>>

    body =
      for {wp, index} <- Enum.with_index(waypoints, 1), into: <<>> do
        {lat, lon} = encode_latlon({wp.lat, wp.lon})
        <<index::little-16>> <> string_lau(wp.code || "") <> <<lat::little-signed-32, lon::little-signed-32>>
      end

    header <> body
  end

  def pgns, do: %{xte: @pgn_xte, navigation_data: @pgn_nav_data, route: @pgn_route}

  # --- field encoders ---

  defp encode_u32(nil, _scale), do: @u32_unknown
  defp encode_u32(value, scale), do: min(round(value * scale), @u32_unknown - 1)

  defp encode_rad(nil), do: @u16_unknown
  defp encode_rad(rad), do: min(round(rad / 0.0001), @u16_unknown - 1)

  defp encode_wp(nil), do: @u32_unknown
  defp encode_wp(n), do: n

  defp encode_latlon(nil), do: {@s32_unknown, @s32_unknown}
  defp encode_latlon({lat, lon}), do: {round(lat * 1.0e7), round(lon * 1.0e7)}

  # NMEA 2000 variable string: <<total_len::8, control::8, chars::binary>> where
  # total_len includes the length and control bytes, and control 1 = ASCII.
  defp string_lau(str) do
    bytes = to_string(str)
    <<byte_size(bytes) + 2::8, 1::8, bytes::binary>>
  end
end
