defmodule RacingOrg.Tracker.PacketHandler.Callbacks do
  @moduledoc """
  A generic `RacingOrg.Tracker.PacketHandler` that forwards events to caller-supplied
  callback functions. Useful for tests and ad-hoc inspection of the CAN stream.
  """
  @behaviour RacingOrg.Tracker.PacketHandler

  @impl RacingOrg.Tracker.PacketHandler
  def init(opts) do
    opts
    |> Keyword.take([:handle_packet, :handle_closed])
    |> Map.new()
  end

  @impl RacingOrg.Tracker.PacketHandler
  def handle_packet(packet, config) do
    apply_callback(config[:handle_packet], [packet])
  end

  @impl RacingOrg.Tracker.PacketHandler
  def handle_data(data, config) do
    apply_callback(config[:handle_packet], [data])
  end

  @impl RacingOrg.Tracker.PacketHandler
  def handle_closed(config) do
    apply_callback(config[:handle_closed], [])
  end

  defp apply_callback(nil, _args), do: nil

  defp apply_callback(callback, args) when is_function(callback) do
    apply(callback, args)
  end

  defp apply_callback({module, fun}, args) do
    apply(module, fun, args)
  end
end
