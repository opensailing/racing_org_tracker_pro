defmodule NauticNet.Compute.StoreTest do
  use ExUnit.Case, async: true

  alias NauticNet.Compute.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_compute_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp config do
    %{
      version: 3,
      values: [
        %{
          id: "abc",
          name: "AWS x2",
          definition_type: :expression,
          library_key: nil,
          input_bindings: %{},
          rpn: [%{"signal" => "apparent_wind_speed"}, %{"const" => 2.0}, %{"op" => "*"}],
          signals: ["apparent_wind_speed"],
          output_pgn: 128_259,
          output_field: "speed_water_referenced",
          output_reference: nil,
          output_unit: "m/s",
          output_instance: nil,
          damping_seconds: 0.5,
          broadcast_rate_hz: 2.0,
          broadcast_enabled: true,
          stream_to_backend: true
        }
      ]
    }
  end

  test "save + load round-trips the config", %{dir: dir} do
    assert :ok = Store.save(dir, config())
    assert {:ok, loaded} = Store.load(dir)
    assert loaded.version == 3
    assert [value] = loaded.values
    assert value.id == "abc"
    assert value.rpn == [%{"signal" => "apparent_wind_speed"}, %{"const" => 2.0}, %{"op" => "*"}]
  end

  test "loading a missing dir is :empty", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "loading a corrupt file is :empty (never raises)", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.computed_values"), "not a term")
    assert :empty = Store.load(dir)
  end

  test "an empty values list round-trips (a CLEAR config)", %{dir: dir} do
    assert :ok = Store.save(dir, %{version: 0, values: []})
    assert {:ok, loaded} = Store.load(dir)
    assert loaded.version == 0
    assert loaded.values == []
  end

  test "clear removes the persisted config", %{dir: dir} do
    assert :ok = Store.save(dir, config())
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end
end
