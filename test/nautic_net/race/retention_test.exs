defmodule NauticNet.Race.RetentionTest do
  use ExUnit.Case, async: true

  alias NauticNet.Race.Recording
  alias NauticNet.Race.Retention

  setup do
    base = Path.join(System.tmp_dir!(), "nn_ret_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  test "keeps the most recent 10 recordings and prunes the rest, with numeric N ordering", %{base: base} do
    for n <- 1..12, do: Recording.open(base, %{recording_id: "2026-06-03-#{n}"})

    dropped = Retention.prune(base, 10)

    assert Enum.sort(dropped) == ["2026-06-03-1", "2026-06-03-2"]
    remaining = Recording.list(base)
    assert length(remaining) == 10
    assert "2026-06-03-12" in remaining
    assert "2026-06-03-3" in remaining
    refute "2026-06-03-1" in remaining
  end

  test "prunes across dates by recency", %{base: base} do
    Recording.open(base, %{recording_id: "2026-06-01-1"})
    Recording.open(base, %{recording_id: "2026-06-02-1"})
    Recording.open(base, %{recording_id: "2026-06-03-1"})

    assert ["2026-06-01-1"] = Retention.prune(base, 2)
    remaining = Recording.list(base)
    assert "2026-06-03-1" in remaining
    assert "2026-06-02-1" in remaining
    refute "2026-06-01-1" in remaining
  end

  test "is a no-op when under the limit", %{base: base} do
    Recording.open(base, %{recording_id: "2026-06-03-1"})
    assert [] = Retention.prune(base, 10)
    assert Recording.list(base) == ["2026-06-03-1"]
  end
end
