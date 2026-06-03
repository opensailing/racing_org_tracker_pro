defmodule NauticNet.Sampling.Phase do
  @moduledoc """
  Pure determination of the current race phase and telemetry sample mode from the
  active assignment, the current (GPS/network) time, and the latest boat position.

  Phases and the rate they imply (rates come from the assignment's sampling
  rules, falling back to the standard 1/5/10 Hz modes):

      idle      -> default mode (1 Hz)  — no race, before the start window, or unreliable time
      pre_start -> event mode  (10 Hz)  — within the start window around the official start
      racing    -> race mode   (5 Hz)   — race underway, outside event windows
      rounding  -> event mode  (10 Hz)  — within mark-proximity of a course mark
      finish    -> event mode  (10 Hz)  — within the finish window before the expected finish
      complete  -> default mode (1 Hz)  — race finished, expired, or cancelled

  The device switches rates autonomously here with no server involvement.
  """

  alias NauticNet.Commands.Assignment
  alias NauticNet.Sampling.Mode

  @type phase :: :idle | :pre_start | :racing | :rounding | :finish | :complete

  @doc "Returns `{phase, mode}` for the given assignment, time, and position."
  def evaluate(assignment, now, position \\ nil)

  def evaluate(nil, _now, _position), do: {:idle, :outing_1hz}

  def evaluate(%Assignment{cancelled: true}, _now, _position), do: {:complete, :outing_1hz}

  def evaluate(%Assignment{} = assignment, now, position) do
    rules = assignment.race_assignment && assignment.race_assignment.sampling_rules
    default = mode_or(rules, :default_mode, :outing_1hz)
    race = mode_or(rules, :race_mode, :race_5hz)
    event = mode_or(rules, :event_mode, :event_10hz)

    start = proto_dt(assignment.race_assignment && assignment.race_assignment.official_start_time)
    duration = int(assignment.race_assignment && assignment.race_assignment.expected_duration_seconds)
    sw = rule_int(rules, :start_window_seconds)
    fw = rule_int(rules, :finish_window_seconds)
    mp = rule_int(rules, :mark_proximity_meters)

    cond do
      expired?(assignment, now) -> {:complete, default}
      not reliable_time?(now) -> {:idle, default}
      is_nil(start) -> {:idle, default}
      before?(now, shift(start, -sw)) -> {:idle, default}
      not after?(now, shift(start, sw)) -> {:pre_start, event}
      finished?(start, duration, now) -> {:complete, default}
      in_finish_window?(start, duration, fw, now) -> {:finish, event}
      near_mark?(assignment, position, mp) -> {:rounding, event}
      true -> {:racing, race}
    end
  end

  @doc "Convert a phase atom into its protobuf `RacePhase` atom."
  def to_proto(:idle), do: :RACE_PHASE_IDLE
  def to_proto(:pre_start), do: :RACE_PHASE_PRE_START
  def to_proto(:racing), do: :RACE_PHASE_RACING
  def to_proto(:rounding), do: :RACE_PHASE_ROUNDING
  def to_proto(:finish), do: :RACE_PHASE_FINISH
  def to_proto(:complete), do: :RACE_PHASE_COMPLETE

  # --- helpers ---

  defp mode_or(nil, _field, fallback), do: fallback
  defp mode_or(rules, field, fallback), do: Mode.from_proto(Map.get(rules, field)) || fallback

  defp rule_int(nil, _field), do: 0
  defp rule_int(rules, field), do: int(Map.get(rules, field))

  defp int(n) when is_integer(n) and n > 0, do: n
  defp int(_), do: 0

  defp proto_dt(nil), do: nil
  defp proto_dt(%{seconds: seconds}), do: DateTime.from_unix!(seconds)

  defp reliable_time?(%DateTime{} = now), do: now.year >= 2020
  defp reliable_time?(_), do: false

  defp shift(%DateTime{} = dt, seconds), do: DateTime.add(dt, seconds, :second)

  defp before?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :lt
  defp after?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :gt

  defp expired?(%Assignment{expires_at: nil}, _now), do: false
  defp expired?(%Assignment{expires_at: expires}, now), do: reliable_time?(now) and after?(now, proto_dt(expires))

  defp finished?(_start, 0, _now), do: false
  defp finished?(start, duration, now), do: not before?(now, shift(start, duration))

  defp in_finish_window?(_start, 0, _fw, _now), do: false
  defp in_finish_window?(_start, _duration, 0, _now), do: false

  defp in_finish_window?(start, duration, fw, now) do
    not before?(now, shift(start, duration - fw))
  end

  defp near_mark?(_assignment, nil, _mp), do: false
  defp near_mark?(_assignment, _position, 0), do: false

  defp near_mark?(%Assignment{race_assignment: race}, position, mp) when not is_nil(race) do
    {lat, lon} = latlon(position)

    Enum.any?(race.course_marks || [], fn mark ->
      case mark.position do
        %{latitude: mlat, longitude: mlon} -> distance_m({lat, lon}, {mlat, mlon}) <= mp
        _ -> false
      end
    end)
  end

  defp near_mark?(_assignment, _position, _mp), do: false

  defp latlon(%{lat: lat, lon: lon}), do: {lat, lon}
  defp latlon({lat, lon}), do: {lat, lon}

  # Great-circle (haversine) distance in meters.
  defp distance_m({lat1, lon1}, {lat2, lon2}) do
    radius = 6_371_000.0
    rad = &(&1 * :math.pi() / 180.0)
    dlat = rad.(lat2 - lat1)
    dlon = rad.(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(rad.(lat1)) * :math.cos(rad.(lat2)) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    radius * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end
end
