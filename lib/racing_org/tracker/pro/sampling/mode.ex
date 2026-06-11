defmodule RacingOrg.Tracker.Pro.Sampling.Mode do
  @moduledoc """
  Telemetry output sample modes and their flush intervals.

      outing_1hz -> 1 Hz  (1000 ms) — default / non-race
      race_5hz   -> 5 Hz  (200 ms)  — active race
      event_10hz -> 10 Hz (100 ms)  — start / mark-rounding / finish windows
  """

  @intervals %{outing_1hz: 1000, race_5hz: 200, event_10hz: 100}

  @type t :: :outing_1hz | :race_5hz | :event_10hz

  @doc "The flush interval, in milliseconds, for `mode`."
  def interval_ms(mode), do: Map.fetch!(@intervals, mode)

  @doc "All known modes."
  def modes, do: Map.keys(@intervals)

  @doc """
  Convert a protobuf `SampleMode` (atom or integer) into a mode, or `nil` if
  unspecified/unknown.
  """
  def from_proto(mode) when mode in [:SAMPLE_MODE_OUTING_1HZ, 1], do: :outing_1hz
  def from_proto(mode) when mode in [:SAMPLE_MODE_RACE_5HZ, 2], do: :race_5hz
  def from_proto(mode) when mode in [:SAMPLE_MODE_EVENT_10HZ, 3], do: :event_10hz
  def from_proto(_unspecified), do: nil

  @doc "Convert a mode into its protobuf `SampleMode` atom."
  def to_proto(:outing_1hz), do: :SAMPLE_MODE_OUTING_1HZ
  def to_proto(:race_5hz), do: :SAMPLE_MODE_RACE_5HZ
  def to_proto(:event_10hz), do: :SAMPLE_MODE_EVENT_10HZ
end
