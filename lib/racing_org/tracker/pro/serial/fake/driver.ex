defmodule RacingOrg.Tracker.Pro.Serial.Fake.Driver do
  @moduledoc """
  Implementation of a Serial driver for testing.
  """

  @behaviour RacingOrg.Tracker.Pro.Serial.Driver

  alias RacingOrg.Tracker.Pro.Serial.Fake.Server

  @impl RacingOrg.Tracker.Pro.Serial.Driver
  def init(driver_config) do
    case Server.start_link(driver_config) do
      {:ok, _pid} -> :ok
      _ -> :error
    end
  end
end
