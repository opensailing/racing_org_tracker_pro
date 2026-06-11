defmodule RacingOrg.Tracker.Serial.Fake.Driver do
  @moduledoc """
  Implementation of a Serial driver for testing.
  """

  @behaviour RacingOrg.Tracker.Serial.Driver

  alias RacingOrg.Tracker.Serial.Fake.Server

  @impl RacingOrg.Tracker.Serial.Driver
  def init(driver_config) do
    case Server.start_link(driver_config) do
      {:ok, _pid} -> :ok
      _ -> :error
    end
  end
end
