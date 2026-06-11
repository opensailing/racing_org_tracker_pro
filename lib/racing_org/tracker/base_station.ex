defmodule RacingOrg.Tracker.BaseStation do
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {RacingOrg.Tracker.BaseStation.Server, :start_link, []},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end
end
