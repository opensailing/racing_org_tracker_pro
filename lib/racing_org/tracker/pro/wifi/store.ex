defmodule RacingOrg.Tracker.Pro.WiFi.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the device's DESIRED Wi-Fi
  state so a runtime change (set credentials / enable / disable) survives reboots
  WITHOUT reflashing.

  Mirrors `RacingOrg.Tracker.Pro.Commands.Store`: the state is written to a temp file and
  atomically renamed into place, so a crash mid-write can never leave a partially
  written current file. Loading a missing, unreadable, corrupt, or unknown-version
  file returns `:empty` rather than raising, so a bad on-disk state can never take
  down the Wi-Fi manager (it falls back to the compile-time default).

  The persisted state is a plain map:

      %{version: integer(), enabled: boolean(), ssid: String.t() | nil, psk: String.t() | nil}

  The PSK lives on `/data` here. This is unavoidable — the device needs the
  pre-shared key to associate, and VintageNet persists it to `/data` itself. It is
  never logged.
  """

  require Logger

  @type state :: %{
          required(:version) => integer(),
          required(:enabled) => boolean(),
          required(:ssid) => String.t() | nil,
          required(:psk) => String.t() | nil
        }

  @filename "current.wifi"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load.
  @format_version 1

  @doc "Atomically persist the desired Wi-Fi `state` under `dir`. Best-effort; never raises."
  @spec save(Path.t(), state()) :: :ok | {:error, term()}
  def save(dir, %{} = state) do
    File.mkdir_p!(dir)
    path = path(dir)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary({@format_version, state}))
    File.rename!(tmp, path)
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist Wi-Fi state to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the persisted Wi-Fi state from `dir`, or `:empty` if absent/unusable."
  @spec load(Path.t()) :: {:ok, state()} | :empty
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode(binary, dir)
      {:error, :enoent} -> :empty
      {:error, reason} -> warn_empty(dir, "could not read", reason)
    end
  end

  @doc "Remove any persisted Wi-Fi state under `dir`."
  @spec clear(Path.t()) :: :ok
  def clear(dir) do
    _ = File.rm(path(dir))
    :ok
  end

  defp decode(binary, dir) do
    case safe_binary_to_term(binary) do
      {@format_version, %{enabled: _, version: _} = state} -> {:ok, state}
      _other -> warn_empty(dir, "unrecognized/incompatible", :format)
    end
  rescue
    error -> warn_empty(dir, "corrupt", error)
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted Wi-Fi state in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
end
