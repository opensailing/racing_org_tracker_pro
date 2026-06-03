defmodule NauticNet do
  @moduledoc """
  Documentation for NauticNet.
  """

  @doc """
  Returns a unique identifier string for this Nerves device.
  """
  def boat_identifier do
    # :inet.gethostname/0 always succeeds
    {:ok, charlist} = :inet.gethostname()
    to_string(charlist)
  end

  def git_commit do
    Application.get_env(:nautic_net_device, :git_commit)
  end

  @doc """
  Builds an upload `DataSet` for `data_points`, tagged with this device's
  identifier and the latest applied server-command acknowledgement (so SailRoute
  can track which commands the device has applied). `opts` are passed through to
  `NauticNet.Protobuf.new_data_set/2` and override the defaults.
  """
  def data_set(data_points, opts \\ []) do
    base = [boat_identifier: boat_identifier(), ack: NauticNet.Commands.current_ack()]
    NauticNet.Protobuf.new_data_set(data_points, Keyword.merge(base, opts))
  end
end
