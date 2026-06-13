defmodule RacingOrg.Tracker.Pro.DiscoveryTest do
  use ExUnit.Case

  alias RacingOrg.Tracker.Pro.Discovery
  alias RacingOrg.Tracker.Protobuf.NetworkDevice
  alias NMEA.NMEA2000.VirtualDevice.NetworkMonitor.DeviceInfo

  # Device discovery itself now happens inside the nmea VirtualDevice's
  # NetworkMonitor. RacingOrg.Tracker.Pro.Discovery polls the virtual device and maps its
  # known devices into protobuf NetworkDevices for upload; that mapping is the
  # device-level logic worth covering here.
  describe "to_network_devices/1" do
    test "maps a known NMEA 2000 network device into a protobuf NetworkDevice" do
      known_devices = %{
        6 => %DeviceInfo{
          nmea_name: <<0, 0, 0, 0, 0, 0, 0, 42>>,
          source_address: 6,
          manufacture_name: "Garmin",
          model_id: "GPS 19x"
        }
      }

      assert [%NetworkDevice{hw_id: 42, name: "Garmin - GPS 19x"}] =
               Discovery.to_network_devices(known_devices)
    end

    test "maps every known device, keyed by source address" do
      known_devices = %{
        1 => %DeviceInfo{nmea_name: <<1::64>>, manufacture_name: "A", model_id: "1"},
        2 => %DeviceInfo{nmea_name: <<2::64>>, manufacture_name: "B", model_id: "2"}
      }

      result = Discovery.to_network_devices(known_devices)

      assert Enum.all?(result, &match?(%NetworkDevice{}, &1))
      assert result |> Enum.map(& &1.name) |> Enum.sort() == ["A - 1", "B - 2"]
      assert result |> Enum.map(& &1.hw_id) |> Enum.sort() == [1, 2]
    end

    test "returns an empty list when no devices are known" do
      assert Discovery.to_network_devices(%{}) == []
    end
  end
end
