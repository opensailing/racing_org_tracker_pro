defmodule RacingOrg.Tracker.Pro.Nav.State do
  @moduledoc """
  Derives the navigation display state (active waypoint, active leg, bearing and
  range to the waypoint, and cross-track error) from the active race assignment
  and the latest boat position. This is the source data for the outbound
  NMEA 2000 navigation PGNs.
  """

  alias RacingOrg.Tracker.Pro.Commands.Assignment
  alias RacingOrg.Tracker.Pro.Nav.Geo

  @type t :: %__MODULE__{}

  defstruct active?: false,
            position: nil,
            destination: nil,
            destination_mark_code: nil,
            destination_wp_number: nil,
            origin: nil,
            origin_mark_code: nil,
            origin_wp_number: nil,
            total_waypoints: 0,
            bearing_origin_to_dest_rad: nil,
            bearing_position_to_dest_rad: nil,
            distance_to_dest_m: nil,
            cross_track_m: nil

  @doc "Derive the nav state. `position` is `{lat, lon}` or `nil`."
  def derive(assignment, position \\ nil)

  def derive(nil, _position), do: %__MODULE__{}
  def derive(%Assignment{cancelled: true}, _position), do: %__MODULE__{}
  def derive(%Assignment{race_assignment: nil}, _position), do: %__MODULE__{}

  def derive(%Assignment{race_assignment: race, active_mark_code: code}, position) do
    marks = sort_marks(race.course_marks || [])

    with dest_idx when is_integer(dest_idx) <- Enum.find_index(marks, &(&1.code == code)),
         dest_mark = Enum.at(marks, dest_idx),
         dest when not is_nil(dest) <- latlon(dest_mark.position) do
      build(marks, dest_idx, dest_mark, dest, position)
    else
      _ -> %__MODULE__{active?: false, total_waypoints: length(marks)}
    end
  end

  defp build(marks, dest_idx, dest_mark, dest, position) do
    {origin, origin_code, origin_wp} = origin_for(marks, dest_idx)

    %__MODULE__{
      active?: true,
      position: position,
      destination: dest,
      destination_mark_code: dest_mark.code,
      destination_wp_number: dest_idx + 1,
      origin: origin,
      origin_mark_code: origin_code,
      origin_wp_number: origin_wp,
      total_waypoints: length(marks),
      bearing_origin_to_dest_rad: origin && Geo.bearing_rad(origin, dest),
      bearing_position_to_dest_rad: position && Geo.bearing_rad(position, dest),
      distance_to_dest_m: position && Geo.distance_m(position, dest),
      cross_track_m: origin && position && Geo.cross_track_m(origin, dest, position)
    }
  end

  defp origin_for(_marks, 0), do: {nil, nil, nil}

  defp origin_for(marks, dest_idx) do
    mark = Enum.at(marks, dest_idx - 1)

    case latlon(mark.position) do
      nil -> {nil, nil, nil}
      origin -> {origin, mark.code, dest_idx}
    end
  end

  defp sort_marks(marks), do: Enum.sort_by(marks, &(&1.sequence || 0))

  defp latlon(%{latitude: lat, longitude: lon}) when is_number(lat) and is_number(lon), do: {lat, lon}
  defp latlon(_), do: nil
end
