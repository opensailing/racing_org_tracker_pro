defmodule RacingOrg.Tracker.Pro.Telemetry.Reporter do
  @moduledoc """
  Telemetry reporter

  Based heavily on the source of `Telemetry.Metrics.ConsoleReporter`.

  ## Supported metric types

      [
        # Report every single measurement as soon as it happens
        last_value("some.metric.value", reporter_options: [asap?: true]),

        # Report the latest measurement at a minimum time interval; if there are no
        # measurements, nothing is reported
        last_value("some.metric.value", reporter_options: [every_ms: 10]),

        # Report a measurement summary at a minimum time interval; if there are no
        # measurements, nothing is reported
        summary("some.metric.value", reporter_options: [every_ms: 10])
      ]
  """

  use GenServer
  require Logger

  alias RacingOrg.Tracker.Pro.Telemetry.Ewma
  alias Telemetry.Metrics.LastValue
  alias Telemetry.Metrics.Summary

  # Per-signal EWMA smoothing spec, keyed by the metric NAME. Declares, for each
  # numeric field of the measurement map, whether it is a :linear or :circular
  # (wrapping, radians) quantity. Circular signals are smoothed via sin/cos so the
  # 0 ⇄ 2π wrap is handled correctly; everything else is smoothed directly. Fields
  # not listed here (e.g. :timestamp) are passed through untouched (last sample).
  #
  # Circular fields here: wind/COG/velocity angle, heading, attitude yaw — all
  # headings/bearings in radians. Linear fields: speeds, magnitudes, depth, lat/lon,
  # and attitude pitch/roll (bounded oscillations about 0, not wrapping).
  @smoothing_specs %{
    [:racing_org, :heading, :rad] => %{value: :circular},
    [:racing_org, :speed, :water, :speed_m_s] => %{value: :linear},
    [:racing_org, :water_depth, :depth_m] => %{value: :linear},
    [:racing_org, :velocity, :ground, :vector] => %{angle: :circular, magnitude: :linear},
    [:racing_org, :attitude, :rad] => %{yaw: :circular, pitch: :linear, roll: :linear},
    [:racing_org, :gps, :position] => %{lat: :linear, lon: :linear}
  }

  @doc """
  Starts the reporter.

  ## Options

  - `:metrics` - required; a list of telemetry metrics
  - `:callback` - required; 3-arity function to invoke when a metric is ready to report (metric_name, device_id, and value)
  - `:flush_interval_ms` - optional; how often non-`asap?` metrics are flushed (default 1000 ms / 1 Hz)
  """
  def start_link(opts) do
    server_opts = Keyword.take(opts, [:name])

    metrics =
      opts[:metrics] ||
        raise ArgumentError, "the :metrics option is required by #{inspect(__MODULE__)}"

    callback =
      opts[:callback] ||
        raise ArgumentError, "the :callback option is required by #{inspect(__MODULE__)}"

    init_args = %{
      metrics: metrics,
      callback: callback,
      flush_interval_ms: opts[:flush_interval_ms] || 1000,
      damping_seconds: opts[:damping_seconds] || 0.0
    }

    GenServer.start_link(__MODULE__, init_args, server_opts)
  end

  @doc false
  def report(pid, metric) do
    GenServer.call(pid, {:report, metric})
  end

  @doc """
  Change how often interval metrics are flushed (the device output sample rate),
  in milliseconds. Used by `RacingOrg.Tracker.Pro.Sampling` to drive 1/5/10 Hz output.
  """
  def set_flush_interval(server, ms) when is_integer(ms) and ms > 0 do
    GenServer.call(server, {:set_flush_interval, ms})
  end

  @doc """
  Set the EWMA damping time constant `τ` (seconds, ≥ 0) applied to each signal
  before it is flushed. `0` ⇒ pass-through (no smoothing). Used by
  `RacingOrg.Tracker.Pro.Sampling` to apply the active tracking state's `damping_seconds`.
  """
  def set_damping(server, tau) when is_number(tau) and tau >= 0 do
    GenServer.call(server, {:set_damping, tau})
  end

  @impl true
  @doc false
  def init(%{metrics: metrics, callback: callback, flush_interval_ms: flush_interval_ms} = init_args) do
    Process.flag(:trap_exit, true)
    groups = Enum.group_by(metrics, & &1.event_name)

    # Tables need to be public because handle_event/4 is invoked from a different process
    tables = %{
      LastValue => :ets.new(__MODULE__.LastValue, [:public, :duplicate_bag]),
      Summary => :ets.new(__MODULE__.Summary, [:public, :duplicate_bag])
    }

    # Persistent per-signal EWMA smoother state, keyed by {metric_name, device_id}.
    # Unlike the duplicate_bag buffers above (drained every flush), this carries the
    # smoothed value + last-sample monotonic time ACROSS flushes so the time-constant
    # low-pass is continuous. Owned by the GenServer; only read/written at flush.
    smooth_table = :ets.new(__MODULE__.SmoothState, [:set, :private])

    # Attach Telemetry event handlers
    for {event, event_metrics} <- groups do
      id = {__MODULE__, event, self()}

      # The fourth arg passed to handle_event/4
      config = %{
        tables: tables,
        callback: callback,
        metrics: event_metrics,
        reporter_pid: self()
      }

      # Capture the public handle_event/4 API for Telemetry performance reasons
      :telemetry.attach(id, event, &__MODULE__.handle_event/4, config)
    end

    # Non-`asap?` metrics are flushed together on a single, runtime-adjustable
    # timer (the device output sample rate). `asap?` metrics report on each event
    # (see handle_event/4).
    interval_metrics = Enum.reject(metrics, & &1.reporter_options[:asap?])
    {:ok, timer_ref} = :timer.send_interval(flush_interval_ms, :flush_all)

    state = %{
      tables: tables,
      smooth_table: smooth_table,
      events: Map.keys(groups),
      callback: callback,
      interval_metrics: interval_metrics,
      flush_interval_ms: flush_interval_ms,
      # EWMA time constant (seconds) applied at flush; 0 = pass-through. Driven by
      # RacingOrg.Tracker.Pro.Sampling via set_damping/2 from the active tracking state.
      damping_seconds: opts_damping(init_args),
      timer_ref: timer_ref
    }

    {:ok, state}
  end

  defp opts_damping(%{damping_seconds: tau}) when is_number(tau) and tau >= 0, do: tau
  defp opts_damping(_), do: 0.0

  @impl true
  def handle_call({:report, metric}, _, state) do
    do_report(metric, state)
    {:reply, :ok, state}
  end

  def handle_call({:set_flush_interval, ms}, _, %{flush_interval_ms: ms} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:set_flush_interval, ms}, _, state) do
    {:ok, :cancel} = :timer.cancel(state.timer_ref)
    {:ok, timer_ref} = :timer.send_interval(ms, :flush_all)
    {:reply, :ok, %{state | flush_interval_ms: ms, timer_ref: timer_ref}}
  end

  def handle_call({:set_damping, tau}, _, %{damping_seconds: tau} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:set_damping, tau}, _, state) do
    {:reply, :ok, %{state | damping_seconds: tau / 1}}
  end

  @impl true
  def handle_info(:flush_all, state) do
    for metric <- state.interval_metrics, do: do_report(metric, state)
    {:noreply, state}
  end

  defp do_report(metric, state) do
    table = state.tables[metric.__struct__]
    rows = :ets.lookup(table, metric.name)
    :ets.delete(table, metric.name)

    device_ids =
      rows
      |> Enum.map(fn {_metric_name, _measurement, metadata} -> metadata.device_id end)
      |> Enum.uniq()

    for device_id <- device_ids do
      device_rows = Enum.filter(rows, fn {_, _, %{device_id: id}} -> id == device_id end)

      case smoothing_spec(metric) do
        nil ->
          # No EWMA spec (e.g. Summary metrics, or τ has no effect): existing path.
          measurements = Enum.map(device_rows, fn {_, m, _} -> m end)
          report_on(metric, device_id, measurements, state.callback)

        spec ->
          smooth_and_report(metric, device_id, device_rows, spec, state)
      end
    end
  end

  # A LastValue metric with a registered smoothing spec is EWMA low-passed: the
  # buffered raw samples are folded (in monotonic-timestamp order) into the carried
  # smoother state and the resulting smoothed measurement map is emitted. With τ = 0
  # this collapses to pass-through (the last sample), matching the old last_value.
  defp smoothing_spec(%LastValue{name: name}), do: Map.get(@smoothing_specs, name)
  defp smoothing_spec(_metric), do: nil

  defp smooth_and_report(_metric, _device_id, [], _spec, _state), do: :noop

  defp smooth_and_report(metric, device_id, rows, spec, state) do
    key = {metric.name, device_id}
    tau = state.damping_seconds

    # Samples in time order: prefer the monotonic timestamp from metadata, falling
    # back to insertion order (rows come back in insertion order from the bag).
    samples =
      rows
      |> Enum.map(fn {_, measurement, metadata} -> {mono_ms(metadata), measurement} end)
      |> Enum.sort_by(&elem(&1, 0))

    prior = lookup_smooth(state.smooth_table, key)
    {smoothed, last_measurement, next_state} = fold_samples(samples, spec, tau, prior)

    :ets.insert(state.smooth_table, {key, next_state})

    # Emit the smoothed numeric fields, but keep the non-numeric fields (e.g.
    # :timestamp) from the most recent raw sample.
    value = Map.merge(last_measurement, smoothed)
    state.callback.(metric.name, device_id, value)
  end

  # Fold each sample's numeric fields through their per-field EWMA, carrying the
  # per-field smoother state forward. Returns {smoothed_fields, last_raw_measurement,
  # next_field_states}.
  defp fold_samples(samples, spec, tau, prior) do
    Enum.reduce(samples, {%{}, %{}, prior}, fn {now_ms, measurement}, {_acc, _last, states} ->
      {smoothed, next_states} =
        Enum.reduce(spec, {%{}, states}, fn {field, kind}, {sm, st} ->
          case Map.fetch(measurement, field) do
            {:ok, x} when is_number(x) ->
              field_state = Map.get(st, field)
              {value, new_field_state} = Ewma.update(field_state, x, now_ms, tau, kind)
              {Map.put(sm, field, value), Map.put(st, field, new_field_state)}

            _ ->
              {sm, st}
          end
        end)

      {smoothed, measurement, next_states}
    end)
  end

  defp lookup_smooth(table, key) do
    case :ets.lookup(table, key) do
      [{^key, states}] -> states
      [] -> %{}
    end
  end

  defp mono_ms(%{timestamp_monotonic_ms: ms}) when is_integer(ms), do: ms
  defp mono_ms(_metadata), do: System.monotonic_time(:millisecond)

  @impl true
  def terminate(_, state) do
    for event <- state.events do
      :telemetry.detach({__MODULE__, event, self()})
    end

    :timer.cancel(state.timer_ref)

    :ok
  end

  # Telemetry callback (not run in the GenServer)
  def handle_event(event_name, measurements, metadata, config) do
    for metric <- config.metrics do
      measurement = extract_measurement(metric, measurements, metadata)
      tags = extract_tags(metric, metadata)

      if keep?(metric, metadata) do
        aggregate(metric, event_name, measurement, metadata, tags, config)

        # `asap?` metrics report on every event; interval metrics are flushed by
        # the periodic timer started in init/1.
        if metric.reporter_options[:asap?] do
          report(config.reporter_pid, metric)
        end
      end
    end
  end

  # Telemetry boilerplate
  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      fun when is_function(fun, 1) -> fun.(measurements)
      key -> measurements[key]
    end
  end

  # Telemetry boilerplate
  defp extract_tags(metric, metadata) do
    tag_values = metric.tag_values.(metadata)
    Map.take(tag_values, metric.tags)
  end

  # Telemetry boilerplate
  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(metric, metadata), do: metric.keep.(metadata)

  # Time to record something to ETS
  defp aggregate(%LastValue{} = metric, _event_name, measurement, metadata, _tags, config) do
    :ets.insert(config.tables[LastValue], {metric.name, measurement, metadata})
  end

  defp aggregate(%Summary{} = metric, _event_name, measurement, metadata, _tags, config) do
    :ets.insert(config.tables[Summary], {metric.name, measurement, metadata})
  end

  # Time to report it to the world
  defp report_on(%LastValue{} = _metric, _device_id, [], _callback), do: :noop

  defp report_on(%LastValue{} = metric, device_id, measurements, callback) do
    callback.(metric.name, device_id, List.last(measurements))
  end

  defp report_on(%Summary{} = _metric, _device_id, [], _callback), do: :noop

  # Compute vector (angle & magnitude) summaries for wind, etc.
  defp report_on(
         %Summary{} = metric,
         device_id,
         [%{angle: _, magnitude: _} | _] = measurements,
         callback
       ) do
    # The summary periods will be very short, so this timestamp is close enough
    timestamp = Map.get(hd(measurements), :timestamp)

    count = length(measurements)

    # Pick the min and max vectors based purely on magnitude
    {min, max} = Enum.min_max_by(measurements, & &1.magnitude)

    # Pick the median vector based purely on magnitude... I have no idea if this makes any sense or
    # is meaningful in any way.
    median = Enum.sort_by(measurements, & &1.magnitude) |> Enum.at(trunc(count / 2))

    # To find the mean, first add up all the vectors in Cartesian coordinates
    {x_sum, y_sum} =
      Enum.reduce(
        measurements,
        {0, 0},
        fn %{angle: angle_rad, magnitude: magnitude}, {x_sum, y_sum} ->
          {x_sum + magnitude * :math.cos(angle_rad), y_sum + magnitude * :math.sin(angle_rad)}
        end
      )

    # Then calculate the mean vector in Cartesian coordinates
    {x_mean, y_mean} = {x_sum / count, y_sum / count}

    # Finally, convert back to polar coordinates
    mean = %{
      magnitude: :math.sqrt(x_mean * x_mean + y_mean * y_mean),
      angle: if(x_mean == 0, do: 0, else: :math.atan(y_mean / x_mean))
    }

    callback.(metric.name, device_id, %{
      timestamp: timestamp,
      min: min,
      max: max,
      mean: mean,
      median: median,
      count: count
    })
  end

  defp report_on(%Summary{} = metric, device_id, [measurement | _] = measurements, callback)
       when is_number(measurement) do
    # TODO: Make this more efficient
    count = length(measurements)
    {min, max} = Enum.min_max(measurements)
    median = Enum.sort(measurements) |> Enum.at(trunc(count / 2))
    sum = Enum.sum(measurements)

    callback.(metric.name, device_id, %{
      min: min,
      max: max,
      mean: sum / count,
      median: median,
      count: count
    })
  end
end
