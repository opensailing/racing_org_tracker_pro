defmodule NauticNet.Sampling do
  @moduledoc """
  Drives the device's telemetry output sample rate (1/5/10 Hz) autonomously,
  with no server involvement.

  Boots at 1 Hz (`outing_1hz` / `idle`) and re-evaluates the race phase from the
  active assignment (`NauticNet.Commands`), the current GPS/network time, and the
  latest boat position (observed from the telemetry stream). On a phase/mode
  change it adjusts `NauticNet.Telemetry.Reporter`'s flush interval and exposes
  the current mode/phase so uploads can be tagged.
  """
  use GenServer

  require Logger

  alias NauticNet.Commands
  alias NauticNet.Sampling.Mode
  alias NauticNet.Sampling.Phase
  alias NauticNet.Telemetry.Reporter

  @position_event [:nautic_net, :gps]

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "The current sample mode (`:outing_1hz` / `:race_5hz` / `:event_10hz`)."
  def current_mode(server \\ __MODULE__), do: GenServer.call(server, :current_mode)

  @doc "The current race phase."
  def current_phase(server \\ __MODULE__), do: GenServer.call(server, :current_phase)

  @doc "Force a re-evaluation now; returns `{phase, mode}`."
  def reevaluate(server \\ __MODULE__), do: GenServer.call(server, :reevaluate)

  @doc "Subscribe `pid` to `{:sampling_phase, old_phase, new_phase}` notifications."
  def subscribe(server \\ __MODULE__, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  # Telemetry handler (runs in the emitting process): forward the latest position.
  @doc false
  def handle_position(_event, %{position: %{lat: lat, lon: lon}}, _meta, %{pid: pid}) do
    send(pid, {:sampling_position, {lat, lon}})
  end

  def handle_position(_event, _measurements, _meta, _config), do: :ok

  @impl true
  def init(opts) do
    commands = opts[:commands] || Commands
    reporter = opts[:reporter] || Reporter
    interval_ms = opts[:reevaluate_interval_ms] || 1_000

    Commands.subscribe(commands, self())

    :telemetry.attach(
      {__MODULE__, self()},
      @position_event,
      &__MODULE__.handle_position/4,
      %{pid: self()}
    )

    state = %{
      commands: commands,
      reporter: reporter,
      now_fn: opts[:now_fn] || (&DateTime.utc_now/0),
      reevaluate_interval_ms: interval_ms,
      phase: :idle,
      mode: :outing_1hz,
      position: nil,
      phase_subscribers: MapSet.new()
    }

    # Boot at 1 Hz, then converge to the correct phase.
    set_interval(state, :outing_1hz)
    Process.send_after(self(), :reevaluate_tick, interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:current_mode, _from, state), do: {:reply, state.mode, state}
  def handle_call(:current_phase, _from, state), do: {:reply, state.phase, state}

  def handle_call(:reevaluate, _from, state) do
    state = do_reevaluate(state)
    {:reply, {state.phase, state.mode}, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | phase_subscribers: MapSet.put(state.phase_subscribers, pid)}}
  end

  @impl true
  def handle_info(:reevaluate_tick, state) do
    state = do_reevaluate(state)
    Process.send_after(self(), :reevaluate_tick, state.reevaluate_interval_ms)
    {:noreply, state}
  end

  def handle_info({:nautic_net_command, _command}, state), do: {:noreply, do_reevaluate(state)}
  def handle_info({:sampling_position, position}, state), do: {:noreply, %{state | position: position}}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach({__MODULE__, self()})
    :ok
  end

  defp do_reevaluate(state) do
    assignment = safe_current_assignment(state.commands)
    {phase, mode} = Phase.evaluate(assignment, state.now_fn.(), state.position)

    if mode != state.mode do
      Logger.info("Sampling mode #{state.mode} -> #{mode} (phase #{phase})")
      set_interval(state, mode)
    end

    if phase != state.phase do
      for pid <- state.phase_subscribers, do: send(pid, {:sampling_phase, state.phase, phase})
    end

    %{state | phase: phase, mode: mode}
  end

  defp set_interval(state, mode) do
    Reporter.set_flush_interval(state.reporter, Mode.interval_ms(mode))
  catch
    :exit, _ -> :ok
  end

  defp safe_current_assignment(commands) do
    Commands.current_assignment(commands)
  catch
    :exit, _ -> nil
  end
end
