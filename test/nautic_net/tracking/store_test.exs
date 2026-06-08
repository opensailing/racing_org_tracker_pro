defmodule NauticNet.Tracking.StoreTest do
  use ExUnit.Case, async: true

  alias NauticNet.Tracking.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_tracking_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  @config %{
    version: 0,
    states: %{
      pre_race: %{damping_seconds: 2.0, send_rate_hz: 1.0},
      starting: %{damping_seconds: 1.0, send_rate_hz: 5.0},
      race: %{damping_seconds: 0.5, send_rate_hz: 10.0}
    }
  }

  test "save/2 then load/1 round-trips the full 3-state config + version", %{dir: dir} do
    assert :ok = Store.save(dir, @config)
    assert {:ok, loaded} = Store.load(dir)
    assert loaded.version == 0
    assert loaded.states.pre_race == %{damping_seconds: 2.0, send_rate_hz: 1.0}
    assert loaded.states.starting == %{damping_seconds: 1.0, send_rate_hz: 5.0}
    assert loaded.states.race == %{damping_seconds: 0.5, send_rate_hz: 10.0}
  end

  test "load/1 on a missing dir returns :empty", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "load/1 on corrupt data returns :empty (never raises)", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.tracking"), "not a term")
    assert :empty = Store.load(dir)
  end

  test "clear/1 removes the persisted config", %{dir: dir} do
    Store.save(dir, @config)
    assert {:ok, _} = Store.load(dir)
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end
end
