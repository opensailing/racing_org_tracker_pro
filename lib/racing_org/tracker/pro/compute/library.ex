defmodule RacingOrg.Tracker.Pro.Compute.Library do
  @moduledoc """
  The shipped NATIVE sailing calcs (`true_wind`, `vmg`, `vmc`) evaluated over the
  current raw signals. Unlike `RacingOrg.Tracker.Pro.Compute.Expr` (a generic stack machine over
  a server-compiled token list), these are hand-written formulas — the real sailing
  math — selected by the def's `library_key`.

  `compute/2` takes the library key (an atom) and a `signals` map (canonical name =>
  value in CATALOG UNITS: speeds m/s, angles DEGREES) and returns either
  `{:ok, %{output_name => value}}` (a calc may yield SEVERAL named outputs — e.g.
  `true_wind` yields speed/angle/direction — so Phase 8 can map the def's
  `output_field` onto the right one) or `:invalid` when a required input is missing.

  ## Conventions / coordinate frame

  Boat frame: **x = forward (bow), y = starboard**. Wind angles are "wind FROM"
  bearings off the bow, positive to starboard (the NMEA masthead convention).
  Internally we work in radians and convert results back to degrees.

  ## true_wind  (`true_wind`)

  Flat-water vector triangle plus a heel correction. Inputs:
  `apparent_wind_speed` (AWS), `apparent_wind_angle` (AWA), `boat_speed` (STW),
  `heel`, `pitch` (`heading` optional, only needed for the direction output).

    * The masthead measures AWA in the HEELED mast frame; projecting the apparent
      vector onto the horizontal scales the athwartships component by `cos(heel)`
      (a heeled masthead reads a larger athwartships angle than the true horizontal
      one). So the horizontal apparent-wind components are
      `ax = AWS·cos(AWA)`, `ay = AWS·sin(AWA)·cos(heel)`.
      (`pitch` is accepted/required by the catalog and reserved for a later, fuller
      correction; the in-scope correction here is the heel term. Deep upwash /
      mast-twist corrections are explicitly DEFERRED to a later phase.)
    * Subtract the boat's through-water velocity `(STW, 0)` to get the true-wind
      vector `(tx, ty) = (ax − STW, ay)`.
    * `true_wind_speed = hypot(tx, ty)`,
      `true_wind_angle  = atan2(ty, tx)` (degrees, wrapped to (−180, 180]).
    * `true_wind_direction = wrap360(heading + true_wind_angle)` when `heading` is
      present (compass bearing the true wind blows FROM).

  ## vmg  (`vmg`)

  Velocity made good toward/along the wind axis:
  `vmg = boat_speed · cos(TWA)` where `TWA = wrap(true_wind_direction − heading)`.
  Positive = making ground to windward. Inputs: `boat_speed`,
  `true_wind_direction`, `heading`.

  ## vmc  (`vmc`)

  Velocity made good toward the active mark: `vmc = sog · cos(bearing_to_mark − cog)`.
  Inputs: `sog`, `cog`, `bearing_to_mark`. The bearing to the active mark is NOT yet
  produced on-device, so until a `bearing_to_mark` signal source exists, `vmc` is
  honestly `:invalid` (we do not fabricate a bearing).
  """

  @type signals :: %{optional(String.t()) => number()}
  @type outputs :: %{optional(String.t()) => number()}

  @deg_per_rad 180.0 / :math.pi()
  @rad_per_deg :math.pi() / 180.0

  @doc """
  Evaluate one native library calc over `signals`. Returns `{:ok, named_outputs}` or
  `:invalid` (missing input or a non-finite result).
  """
  @spec compute(atom(), signals()) :: {:ok, outputs()} | :invalid
  def compute(:true_wind, signals), do: true_wind(signals)
  def compute(:vmg, signals), do: vmg(signals)
  def compute(:vmc, signals), do: vmc(signals)
  def compute(_unknown, _signals), do: :invalid

  # --- true_wind ---

  defp true_wind(signals) do
    with {:ok, aws} <- fetch(signals, "apparent_wind_speed"),
         {:ok, awa_deg} <- fetch(signals, "apparent_wind_angle"),
         {:ok, stw} <- fetch(signals, "boat_speed"),
         {:ok, heel_deg} <- fetch(signals, "heel"),
         {:ok, _pitch_deg} <- fetch(signals, "pitch") do
      awa = awa_deg * @rad_per_deg
      heel = heel_deg * @rad_per_deg

      # Horizontal apparent-wind components (boat frame), heel-corrected athwartships.
      ax = aws * :math.cos(awa)
      ay = aws * :math.sin(awa) * :math.cos(heel)

      # Subtract the boat's through-water velocity (bow-ward) to get true wind.
      tx = ax - stw
      ty = ay

      tws = :math.sqrt(tx * tx + ty * ty)
      twa_deg = :math.atan2(ty, tx) * @deg_per_rad

      base = %{"true_wind_speed" => tws, "true_wind_angle" => twa_deg}

      outputs =
        case fetch(signals, "heading") do
          {:ok, heading_deg} -> Map.put(base, "true_wind_direction", wrap360(heading_deg + twa_deg))
          :error -> base
        end

      finite_map(outputs)
    else
      :error -> :invalid
    end
  end

  # --- vmg ---

  defp vmg(signals) do
    with {:ok, stw} <- fetch(signals, "boat_speed"),
         {:ok, twd_deg} <- fetch(signals, "true_wind_direction"),
         {:ok, heading_deg} <- fetch(signals, "heading") do
      twa = wrap180(twd_deg - heading_deg) * @rad_per_deg
      finite_map(%{"vmg" => stw * :math.cos(twa)})
    else
      :error -> :invalid
    end
  end

  # --- vmc ---

  defp vmc(signals) do
    with {:ok, sog} <- fetch(signals, "sog"),
         {:ok, cog_deg} <- fetch(signals, "cog"),
         {:ok, brg_deg} <- fetch(signals, "bearing_to_mark") do
      diff = wrap180(brg_deg - cog_deg) * @rad_per_deg
      finite_map(%{"vmc" => sog * :math.cos(diff)})
    else
      :error -> :invalid
    end
  end

  # --- helpers ---

  defp fetch(signals, name) do
    case Map.fetch(signals, name) do
      {:ok, v} when is_number(v) -> {:ok, v / 1}
      _ -> :error
    end
  end

  # Wrap an angle (degrees) into [0, 360).
  defp wrap360(deg) do
    r = :math.fmod(deg, 360.0)
    if r < 0.0, do: r + 360.0, else: r
  end

  # Wrap an angle (degrees) into (-180, 180].
  defp wrap180(deg) do
    w = wrap360(deg)
    if w > 180.0, do: w - 360.0, else: w
  end

  # Ensure every output is a finite float; otherwise the whole calc is invalid. On
  # BEAM a float cannot be ±Inf (arithmetic overflow raises), so the only non-finite
  # case to guard is NaN, which fails `v == v`.
  defp finite_map(map) do
    if Enum.all?(map, fn {_k, v} -> is_float(v) and v == v end) do
      {:ok, map}
    else
      :invalid
    end
  end
end
