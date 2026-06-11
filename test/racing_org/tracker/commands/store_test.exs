defmodule RacingOrg.Tracker.Commands.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Commands.Assignment
  alias RacingOrg.Tracker.Commands.Store
  alias RacingOrg.Protobuf.RaceAssignment

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp assignment do
    %Assignment{
      assignment_id: "a1",
      version: 3,
      command_id: "c1",
      hash: "h",
      race_assignment: struct(RaceAssignment, race_session_id: "2026-06-03-1", active_mark_code: "1"),
      active_mark_code: "1"
    }
  end

  test "save then load round-trips the assignment", %{dir: dir} do
    assert :ok = Store.save(dir, assignment())
    assert {:ok, loaded} = Store.load(dir)
    assert loaded.assignment_id == "a1"
    assert loaded.version == 3
    assert loaded.race_assignment.race_session_id == "2026-06-03-1"
  end

  test "load returns :empty when nothing is persisted", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "save uses an atomic rename and leaves no temp file", %{dir: dir} do
    assert :ok = Store.save(dir, assignment())
    refute File.exists?(Path.join(dir, "current.assignment.tmp"))
    assert File.exists?(Path.join(dir, "current.assignment"))
  end

  test "load recovers from a corrupt file by returning :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.assignment"), <<0, 1, 2, 3, 255>>)
    assert :empty = Store.load(dir)
  end

  test "load ignores an unknown format version", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.assignment"), :erlang.term_to_binary({999, %{}}))
    assert :empty = Store.load(dir)
  end

  test "clear removes the persisted file", %{dir: dir} do
    Store.save(dir, assignment())
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end
end
