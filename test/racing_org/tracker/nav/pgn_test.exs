defmodule RacingOrg.Tracker.Nav.PGNTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Nav.PGN
  alias RacingOrg.Tracker.Nav.State

  defp active_state do
    %State{
      active?: true,
      destination: {42.0, -70.0},
      destination_wp_number: 2,
      origin_wp_number: 1,
      distance_to_dest_m: 1000.0,
      bearing_origin_to_dest_rad: 0.0,
      bearing_position_to_dest_rad: :math.pi() / 2,
      cross_track_m: 12.34
    }
  end

  test "129283 XTE encodes the cross-track error at 0.01 m resolution" do
    payload = PGN.xte_129283(active_state())
    assert byte_size(payload) == 8
    <<_sid::8, _mode::8, xte::little-signed-32, _reserved::little-16>> = payload
    assert xte == 1234
  end

  test "129283 XTE uses the unknown sentinel when there is no cross-track" do
    <<_::binary-2, xte::little-signed-32, _::binary>> = PGN.xte_129283(%State{active?: true})
    assert xte == 0x7FFFFFFF
  end

  test "129284 Navigation Data encodes destination, waypoints, and distance" do
    payload = PGN.navigation_data_129284(active_state())
    assert byte_size(payload) == 34

    <<_sid::8, distance::little-32, _flags::8, _eta_time::little-32, _eta_date::little-16,
      _brg_od::little-16, _brg_pd::little-16, origin_wp::little-32, dest_wp::little-32,
      dest_lat::little-signed-32, dest_lon::little-signed-32, _closing::little-signed-16>> = payload

    assert distance == 100_000
    assert origin_wp == 1
    assert dest_wp == 2
    assert dest_lat == 420_000_000
    assert dest_lon == -700_000_000
  end

  test "129284 uses unknown sentinels when origin/position are unavailable" do
    state = %State{active?: true, destination: {1.0, 2.0}, destination_wp_number: 1}
    payload = PGN.navigation_data_129284(state)

    <<_sid::8, distance::little-32, _flags::8, _::binary-8, origin_wp::little-32, _::binary>> = payload
    assert distance == 0xFFFFFFFF
    assert origin_wp == 0xFFFFFFFF
  end

  test "nav_messages is empty when not navigating" do
    assert PGN.nav_messages(%State{active?: false}) == []
  end

  test "nav_messages broadcasts nav-data + XTE, plus the route when waypoints are given" do
    state = active_state()
    assert [{3, 129_284, _}, {3, 129_283, _}] = PGN.nav_messages(state)

    waypoints = [%{code: "1", lat: 42.0, lon: -70.0}, %{code: "2", lat: 42.1, lon: -70.0}]
    messages = PGN.nav_messages(state, waypoints, "Course A")
    assert length(messages) == 3
    assert {6, 129_285, route_payload} = List.last(messages)
    assert is_binary(route_payload) and byte_size(route_payload) > 0
  end

  test "produces only information PGNs, never autopilot heading/track-control PGNs" do
    pgns = PGN.nav_messages(active_state(), [%{code: "1", lat: 1.0, lon: 2.0}], "r") |> Enum.map(&elem(&1, 1))
    assert pgns == [129_284, 129_283, 129_285]
    # 127237 (Heading/Track Control) and similar autopilot command PGNs are never produced.
    refute 127_237 in pgns
  end
end
