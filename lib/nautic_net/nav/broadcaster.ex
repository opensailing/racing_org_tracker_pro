defmodule NauticNet.Nav.Broadcaster do
  @moduledoc """
  Periodically broadcasts NMEA 2000 navigation *display* PGNs (active waypoint,
  bearing/range, active leg, cross-track error, and the route list) onto the bus
  so B&G displays can show route/navigation state during a race.

  It derives the nav state from the active assignment (`NauticNet.Commands`) and
  the latest boat position (from the telemetry stream), and transmits via an
  injectable function (the NMEA 2000 VirtualDevice on the device; captured in
  tests). It only emits information PGNs — never autopilot heading/track-control
  PGNs — and emits nothing when there is no active waypoint.
  """
  use GenServer

  require Logger

  alias NauticNet.Commands
  alias NauticNet.Nav.PGN
  alias NauticNet.Nav.State

  @position_event [:nautic_net, :gps]

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Derive and broadcast now; returns `{nav_state, message_count}`."
  def broadcast_now(server \\ __MODULE__), do: GenServer.call(server, :broadcast)

  @doc false
  def handle_position(_event, %{position: %{lat: lat, lon: lon}}, _meta, %{pid: pid}),
    do: send(pid, {:nav_position, {lat, lon}})

  def handle_position(_event, _measurements, _meta, _config), do: :ok

  @impl true
  def init(opts) do
    :telemetry.attach({__MODULE__, self()}, @position_event, &__MODULE__.handle_position/4, %{pid: self()})

    interval = opts[:interval_ms] || 1_000
    Process.send_after(self(), :tick, interval)

    state = %{
      commands: opts[:commands] || Commands,
      transmit: opts[:transmit_fn] || (&default_transmit/3),
      interval: interval,
      route_name: opts[:route_name] || "Course",
      position: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    do_broadcast(state)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info({:nav_position, position}, state), do: {:noreply, %{state | position: position}}

  @impl true
  def handle_call(:broadcast, _from, state), do: {:reply, do_broadcast(state), state}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach({__MODULE__, self()})
    :ok
  end

  defp do_broadcast(state) do
    assignment = safe_assignment(state.commands)
    nav = State.derive(assignment, state.position)
    messages = PGN.nav_messages(nav, waypoints(assignment), state.route_name)

    for {priority, pgn, payload} <- messages, do: safe_transmit(state.transmit, priority, pgn, payload)

    {nav, length(messages)}
  end

  defp waypoints(nil), do: []
  defp waypoints(%{race_assignment: nil}), do: []

  defp waypoints(%{race_assignment: race}) do
    for mark <- race.course_marks || [], pos = mark.position, is_map(pos) do
      %{code: mark.code, lat: pos.latitude, lon: pos.longitude}
    end
  end

  defp safe_transmit(fun, priority, pgn, payload) do
    fun.(priority, pgn, payload)
  rescue
    error -> Logger.warning("Nav PGN #{pgn} transmit failed: #{inspect(error)}")
  catch
    :exit, _ -> :ok
  end

  # On the device, transmit through the NMEA 2000 VirtualDevice as a broadcast
  # (destination address 0xFF). No-op if the VirtualDevice isn't available.
  defp default_transmit(priority, pgn, payload) do
    case NauticNet.virtual_device() do
      nil -> :ok
      vd -> NMEA.NMEA2000.VirtualDevice.send_data(vd, priority, pgn, payload, 0xFF)
    end
  end

  defp safe_assignment(commands) do
    Commands.current_assignment(commands)
  catch
    :exit, _ -> nil
  end
end
