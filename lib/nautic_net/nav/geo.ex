defmodule NauticNet.Nav.Geo do
  @moduledoc """
  Great-circle geometry for navigation display: distance, initial bearing, and
  cross-track error between `{latitude, longitude}` points in decimal degrees.
  """

  @earth_radius_m 6_371_000.0

  @doc "Great-circle distance in meters."
  def distance_m({lat1, lon1}, {lat2, lon2}) do
    phi1 = rad(lat1)
    phi2 = rad(lat2)
    dphi = rad(lat2 - lat1)
    dlambda = rad(lon2 - lon1)

    a = sq(:math.sin(dphi / 2)) + :math.cos(phi1) * :math.cos(phi2) * sq(:math.sin(dlambda / 2))
    @earth_radius_m * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end

  @doc "Initial great-circle bearing in radians, normalized to `[0, 2π)`."
  def bearing_rad({lat1, lon1}, {lat2, lon2}) do
    phi1 = rad(lat1)
    phi2 = rad(lat2)
    dlambda = rad(lon2 - lon1)

    y = :math.sin(dlambda) * :math.cos(phi2)
    x = :math.cos(phi1) * :math.sin(phi2) - :math.sin(phi1) * :math.cos(phi2) * :math.cos(dlambda)

    :math.fmod(:math.atan2(y, x) + 2 * :math.pi(), 2 * :math.pi())
  end

  @doc """
  Signed cross-track distance in meters of `pos` relative to the great-circle
  path from `origin` to `dest`. Positive means right of track.
  """
  def cross_track_m(origin, dest, pos) do
    angular_13 = distance_m(origin, pos) / @earth_radius_m
    bearing_13 = bearing_rad(origin, pos)
    bearing_12 = bearing_rad(origin, dest)

    :math.asin(:math.sin(angular_13) * :math.sin(bearing_13 - bearing_12)) * @earth_radius_m
  end

  defp rad(deg), do: deg * :math.pi() / 180.0
  defp sq(x), do: x * x
end
