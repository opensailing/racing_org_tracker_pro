defmodule RacingOrg.Tracker.Pro.Serial do
  @moduledoc """
  Entrypoint for reading and writing from a serial port.
  """

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {RacingOrg.Tracker.Pro.Serial.Server, :start_link, [config]}
    }
  end
end
