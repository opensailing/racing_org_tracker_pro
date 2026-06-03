defmodule NauticNet.Nav.GPX do
  @moduledoc """
  GPX export of a race course/route. This is the fallback for getting route data
  onto a B&G display when its NMEA 2000 route-list (PGN 129285) support is
  limited: the GPX can be imported as a route.

  `waypoints` is a list of `%{code: String.t(), lat: float, lon: float}`.
  """

  @doc "Render the waypoints as a GPX 1.1 route document."
  def route(waypoints, opts \\ []) do
    name = opts[:name] || "Route"

    rtepts =
      Enum.map_join(waypoints, "", fn wp ->
        ~s(    <rtept lat="#{wp.lat}" lon="#{wp.lon}"><name>#{escape(wp.code)}</name></rtept>\n)
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="NauticNet" xmlns="http://www.topografix.com/GPX/1/1">
      <rte>
        <name>#{escape(name)}</name>
    #{rtepts}  </rte>
    </gpx>
    """
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
