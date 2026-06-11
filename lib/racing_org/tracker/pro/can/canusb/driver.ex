defmodule RacingOrg.Tracker.Pro.CAN.CANUSB.Driver do
  @moduledoc """
  Implementation of a CAN driver for the CANUSB serial device.

  Device info: http://www.can232.com/?page_id=16
  """

  @behaviour RacingOrg.Tracker.Pro.CAN.Driver

  alias RacingOrg.Tracker.Pro.CAN.CANUSB.Server

  @impl RacingOrg.Tracker.Pro.CAN.Driver
  def init(driver_config) do
    case Server.start_link(driver_config) do
      {:ok, _pid} -> :ok
      _ -> :error
    end
  end

  @impl RacingOrg.Tracker.Pro.CAN.Driver
  defdelegate transmit_frame(frame), to: Server
end
