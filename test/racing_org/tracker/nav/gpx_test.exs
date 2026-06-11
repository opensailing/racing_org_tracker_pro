defmodule RacingOrg.Tracker.Nav.GPXTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Nav.GPX

  test "renders a GPX route with a waypoint per mark" do
    gpx =
      GPX.route(
        [
          %{code: "1", lat: 42.0, lon: -70.0},
          %{code: "WL", lat: 42.1, lon: -70.05}
        ],
        name: "Course A"
      )

    assert gpx =~ ~s(<gpx version="1.1")
    assert gpx =~ "<name>Course A</name>"
    assert gpx =~ ~s(<rtept lat="42.0" lon="-70.0"><name>1</name></rtept>)
    assert gpx =~ ~s(<rtept lat="42.1" lon="-70.05"><name>WL</name></rtept>)
  end

  test "escapes XML-special characters in names" do
    gpx = GPX.route([%{code: "A&B", lat: 1.0, lon: 2.0}], name: "R<1>")
    assert gpx =~ "<name>R&lt;1&gt;</name>"
    assert gpx =~ "<name>A&amp;B</name>"
  end
end
