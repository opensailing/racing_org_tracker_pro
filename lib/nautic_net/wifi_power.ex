defmodule NauticNet.WiFiPower do
  @moduledoc """
  Powers down the onboard Wi-Fi radio at boot on cellular-only firmware, to save
  battery.

  A configured-but-unassociated `wlan0` keeps the radio SCANNING (which draws power) —
  "not connected" is not "off". When the firmware was built WITHOUT Wi-Fi credentials,
  `config/target.exs` leaves `wlan0` unconfigured (so `wpa_supplicant` never runs — no
  scanning, the bulk of the draw) AND sets `:wifi_enabled` false. This transient
  GenServer — started ONLY on a real device target when `:wifi_enabled` is false (see
  `NauticNet.Application`) — then cuts the residual radio power:

    1. rfkill **soft-block** every `wlan`-type radio via `/sys/class/rfkill/*/soft`.
    2. bring the `wlan0` link **down**.

  It deliberately does NOT unload the `brcmfmac` driver: the rfkill block persists only
  while the driver is loaded, and a hot-reload after `rmmod` could silently clear it —
  rfkill-while-loaded is the robust choice. (For absolute zero Wi-Fi power — chip never
  clocked — use `dtoverlay=disable-wifi` in the system, a separate build profile.)

  Each step is best-effort and logged; the device runs on cellular regardless. Work
  happens in `handle_continue/2`, then it stops `:normal` (`restart: :transient`), so it
  never loops. On a bench build (Wi-Fi creds present) it is never started.
  """

  use GenServer, restart: :transient
  require Logger

  @rfkill_dir "/sys/class/rfkill"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, opts, {:continue, :disable}}

  @impl true
  def handle_continue(:disable, opts) do
    disable(opts)
    {:stop, :normal, opts}
  end

  @doc """
  Power down the Wi-Fi radio. Best-effort: a failing step is logged and never raises.

  Side effects are injectable for tests:
    * `:rfkill_fun`   — 0-arity, soft-blocks the wlan radios (default: sysfs writes)
    * `:linkdown_fun` — 0-arity, brings `wlan0` down (default: `ip link set wlan0 down`)
  """
  @spec disable(keyword()) :: :ok
  def disable(opts \\ []) do
    run(Keyword.get(opts, :rfkill_fun, &rfkill_block_wlan/0), "rfkill")
    run(Keyword.get(opts, :linkdown_fun, &link_down/0), "link-down")
    :ok
  end

  @doc """
  rfkill SOFT-BLOCK the Wi-Fi radio (radio off, battery save) and bring `wlan0`
  down. Same effect as `disable/1`, named for the `NauticNet.WiFiManager`
  reconcile path. Best-effort: a failing step is logged and never raises.

  Side effects are injectable for tests (same opts as `disable/1`).
  """
  @spec block(keyword()) :: :ok
  def block(opts \\ []), do: disable(opts)

  @doc """
  rfkill UN-block the Wi-Fi radio so it can associate again (the inverse of
  `block/1`). Writes "0" to every `wlan`-type radio's `/sys/class/rfkill/*/soft`.
  Bringing the link back up / associating is left to VintageNet's reconfigure.
  Best-effort: a failing step is logged and never raises.

  Side effects are injectable for tests:
    * `:rfkill_unblock_fun` — 0-arity, un-soft-blocks the wlan radios (default: sysfs writes)
  """
  @spec unblock(keyword()) :: :ok
  def unblock(opts \\ []) do
    run(Keyword.get(opts, :rfkill_unblock_fun, &rfkill_unblock_wlan/0), "rfkill-unblock")
    :ok
  end

  defp run(fun, label) do
    fun.()
  rescue
    e -> Logger.warning("[WiFiPower] #{label} step failed: #{inspect(e)}")
  end

  defp rfkill_block_wlan, do: rfkill_set_wlan("1", "soft-blocked", "(wlan radio off)")
  defp rfkill_unblock_wlan, do: rfkill_set_wlan("0", "un-soft-blocked", "(wlan radio on)")

  defp rfkill_set_wlan(value, verb, suffix) do
    case File.ls(@rfkill_dir) do
      {:ok, nodes} ->
        for node <- nodes, wlan_radio?(node) do
          path = Path.join([@rfkill_dir, node, "soft"])

          case File.write(path, value) do
            :ok -> Logger.info("[WiFiPower] rfkill #{verb} #{node} #{suffix}")
            {:error, reason} -> Logger.warning("[WiFiPower] rfkill #{node} failed: #{inspect(reason)}")
          end
        end

        :ok

      {:error, reason} ->
        Logger.warning("[WiFiPower] #{@rfkill_dir} unavailable: #{inspect(reason)}")
        :ok
    end
  end

  defp wlan_radio?(node) do
    case File.read(Path.join([@rfkill_dir, node, "type"])) do
      {:ok, type} -> String.trim(type) == "wlan"
      _ -> false
    end
  end

  defp link_down do
    case System.find_executable("ip") do
      nil ->
        :ok

      ip ->
        _ = System.cmd(ip, ["link", "set", "wlan0", "down"], stderr_to_stdout: true)
        Logger.info("[WiFiPower] wlan0 link down")
        :ok
    end
  end
end
