defmodule RacingOrg.Tracker.Pro.WiFi.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WiFi.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_wifi_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp state do
    %{version: 3, enabled: true, ssid: "boat-net", psk: "hunter2"}
  end

  test "save then load round-trips the desired state", %{dir: dir} do
    assert :ok = Store.save(dir, state())
    assert {:ok, loaded} = Store.load(dir)
    assert loaded.version == 3
    assert loaded.enabled == true
    assert loaded.ssid == "boat-net"
    assert loaded.psk == "hunter2"
  end

  test "load returns :empty when nothing is persisted", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "save uses an atomic rename and leaves no temp file", %{dir: dir} do
    assert :ok = Store.save(dir, state())
    refute File.exists?(Path.join(dir, "current.wifi.tmp"))
    assert File.exists?(Path.join(dir, "current.wifi"))
  end

  test "load recovers from a corrupt file by returning :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.wifi"), <<0, 1, 2, 3, 255>>)
    assert :empty = Store.load(dir)
  end

  test "load ignores an unknown format version", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.wifi"), :erlang.term_to_binary({999, %{}}))
    assert :empty = Store.load(dir)
  end

  test "clear removes the persisted file", %{dir: dir} do
    Store.save(dir, state())
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end
end
