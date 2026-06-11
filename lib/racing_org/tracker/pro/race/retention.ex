defmodule RacingOrg.Tracker.Pro.Race.Retention do
  @moduledoc """
  Deterministic local retention for race recordings: keep only the most recent
  `keep` recordings (default 10) and delete the rest.

  Recordings are ordered by their `YYYY-MM-DD-N` id, treating `N` numerically so
  that `2026-06-03-10` sorts after `2026-06-03-2`.
  """

  alias RacingOrg.Tracker.Pro.Race.Recording

  @default_keep 10

  @doc "Prune recordings under `base_dir` to the most recent `keep`. Returns the deleted ids."
  def prune(base_dir, keep \\ @default_keep) do
    {_kept, dropped} =
      base_dir
      |> Recording.list()
      |> Enum.sort_by(&sort_key/1, :desc)
      |> Enum.split(keep)

    for id <- dropped, do: Recording.delete(base_dir, id)
    dropped
  end

  # Sort most-recent first by (date, race number). Malformed ids sort oldest so
  # they are the first to be pruned.
  defp sort_key(id) do
    case String.split(id, "-") do
      [year, month, day, n] ->
        {year, month, day, String.to_integer(n)}

      _ ->
        {"", "", "", 0}
    end
  rescue
    ArgumentError -> {"", "", "", 0}
  end
end
