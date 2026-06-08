defmodule NauticNet.WiFiManager do
  @moduledoc """
  Owns `wlan0` at runtime: applies Wi-Fi configuration (set credentials / enable /
  disable→radio-off), persists the DESIRED state to `/data` so it survives reboots
  WITHOUT reflashing, and reconciles on boot so a runtime change takes precedence
  over the compile-time default baked into `config/target.exs`.

  ## Authority / boot precedence

  The persisted state in `NauticNet.WiFi.Store` is the AUTHORITY. On boot:

    * If a state is PRESENT, it is applied verbatim — this is what fixes the
      conflict where a runtime "enable" would otherwise be re-blocked at boot by
      the compile-time `:wifi_enabled` flag. The store wins.
    * If the store is `:empty` (never set at runtime), the COMPILE DEFAULT is
      applied: `compile_default == false` → rfkill block (mirroring the old
      `NauticNet.WiFiPower` boot behaviour); `compile_default == true` → leave the
      `target.exs`-configured `wlan0` as-is (radio unblocked, no reconfigure).

  Because this module re-applies its desired state from its own store on every
  boot, it configures VintageNet with `persist: false` — it is the single source
  of truth, not VintageNet's own persistence.

  ## Lifecycle

  Started ONLY on a real device target (see `NauticNet.Application`); it decides
  the rest internally. Never started on host/test.

  All side effects are injectable via `start_link/1` opts (defaulting to the real
  VintageNet / `NauticNet.WiFiPower` implementations) so the reconcile and
  apply logic is fully unit-testable on host without VintageNet present.
  """

  use GenServer
  require Logger

  alias NauticNet.WiFi.Store
  alias NauticNet.WiFiPower

  @type desired_state :: %{
          version: integer(),
          enabled: boolean(),
          ssid: String.t() | nil,
          psk: String.t() | nil
        }

  # The /data directory the desired Wi-Fi state is persisted under by default.
  @default_store_dir "/data/wifi"

  @connection_property ["interface", "wlan0", "connection"]

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc """
  Apply a desired Wi-Fi config (public API, called by J5's WSS channel handler).

  Accepts a map with string OR atom keys: `ssid`, `psk`, `enabled`, `version`.

  Idempotent on `version`: if `version <= last-applied version`, this is a no-op
  and returns `{:ok, :unchanged}` (so re-pushing the same config on every
  reconnect does not churn the radio). Otherwise:

    * `enabled: true`  → reconfigure `wlan0` as a WPA-PSK client + rfkill UNBLOCK.
      `ssid` is required; without it returns `{:error, :ssid_required}` and applies
      nothing.
    * `enabled: false` → deconfigure `wlan0` + rfkill BLOCK + link down (radio off,
      battery save).

  Persists the new desired state (including `version`) and returns
  `{:ok, applied_state}`.
  """
  @spec apply_config(GenServer.server(), map()) ::
          {:ok, desired_state()} | {:ok, :unchanged} | {:error, atom()}
  def apply_config(server \\ __MODULE__, config) when is_map(config) do
    GenServer.call(server, {:apply_config, config})
  end

  @doc "Best-effort current `wlan0` status, read via the injected `status_fun`."
  @spec current_status(GenServer.server()) :: map()
  def current_status(server \\ __MODULE__) do
    GenServer.call(server, :current_status)
  end

  # --- Server ---

  @impl true
  def init(opts) do
    state = %{
      store_dir: Keyword.get(opts, :store_dir, @default_store_dir),
      configure_fun: Keyword.get(opts, :configure_fun, &default_configure/3),
      deconfigure_fun: Keyword.get(opts, :deconfigure_fun, &default_deconfigure/1),
      rfkill_block_fun: Keyword.get(opts, :rfkill_block_fun, &default_rfkill_block/0),
      rfkill_unblock_fun: Keyword.get(opts, :rfkill_unblock_fun, &default_rfkill_unblock/0),
      status_fun: Keyword.get(opts, :status_fun, &default_status/0),
      subscribe_fun: Keyword.get(opts, :subscribe_fun, &default_subscribe/1),
      compile_default: Keyword.get(opts, :compile_default, false),
      status_subscriber: Keyword.get(opts, :status_subscriber),
      # The version of the desired state currently applied; -1 means "nothing
      # applied yet", so any incoming version (>= 0) is newer.
      applied_version: -1
    }

    {:ok, state, {:continue, :reconcile}}
  end

  # Boot reconciliation: persisted state wins; otherwise the compile default.
  @impl true
  def handle_continue(:reconcile, state) do
    _ = state.subscribe_fun.(@connection_property)
    {:noreply, reconcile(state)}
  end

  @impl true
  def handle_call({:apply_config, config}, _from, state) do
    {result, state} = do_apply(normalize(config), state)
    {:reply, result, state}
  end

  def handle_call(:current_status, _from, state) do
    {:reply, read_status(state), state}
  end

  # VintageNet property-change notifications (subscribed in handle_continue). For
  # J4 we just forward a status push to an optional registered subscriber; J5 will
  # use this to push status over the WSS channel.
  @impl true
  def handle_info({VintageNet, _property, _old, _new, _meta}, state) do
    notify_status(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Reconcile / apply pipeline ---

  defp reconcile(state) do
    case Store.load(state.store_dir) do
      {:ok, desired} ->
        Logger.info("[WiFiManager] reconciling persisted desired state (enabled=#{desired.enabled})")
        {_result, state} = apply_desired(desired, state)
        state

      :empty ->
        reconcile_compile_default(state)
    end
  end

  # No runtime state has ever been set: honor the compile-time default.
  #   false → power the radio down at boot (mirrors the old WiFiPower behaviour).
  #   true  → leave the target.exs-configured wlan0 as-is; do not reconfigure.
  defp reconcile_compile_default(%{compile_default: false} = state) do
    Logger.info("[WiFiManager] no persisted state, compile default disabled → rfkill block")
    run(state.rfkill_block_fun, "rfkill-block")
    state
  end

  defp reconcile_compile_default(%{compile_default: true} = state) do
    Logger.info("[WiFiManager] no persisted state, compile default enabled → leaving wlan0 as configured")
    state
  end

  # Idempotency: ignore stale/replayed versions.
  defp do_apply(%{version: version}, %{applied_version: applied} = state)
       when is_integer(version) and version <= applied do
    {{:ok, :unchanged}, state}
  end

  # Enabling requires an SSID; do not half-apply.
  defp do_apply(%{enabled: true, ssid: ssid}, state) when ssid in [nil, ""] do
    {{:error, :ssid_required}, state}
  end

  defp do_apply(%{} = desired, state) do
    {result, state} = apply_desired(desired, state)

    case result do
      :ok ->
        _ = Store.save(state.store_dir, persistable(desired))
        {{:ok, persistable(desired)}, %{state | applied_version: desired.version}}

      {:error, _} = error ->
        {error, state}
    end
  end

  # Perform the side effects for a desired state. Returns {:ok | {:error, reason}, state}.
  defp apply_desired(%{enabled: true, ssid: ssid} = desired, state) when ssid not in [nil, ""] do
    config = wifi_client_config(ssid, desired.psk)
    state.configure_fun.("wlan0", config, persist: false)
    run(state.rfkill_unblock_fun, "rfkill-unblock")
    {:ok, %{state | applied_version: desired.version}}
  end

  defp apply_desired(%{enabled: true}, state) do
    {{:error, :ssid_required}, state}
  end

  defp apply_desired(%{enabled: false} = desired, state) do
    state.deconfigure_fun.("wlan0")
    run(state.rfkill_block_fun, "rfkill-block")
    {:ok, %{state | applied_version: desired.version}}
  end

  # --- Status ---

  defp read_status(state) do
    state.status_fun.()
  rescue
    error ->
      Logger.warning("[WiFiManager] status read failed: #{inspect(error)}")
      %{enabled: false, ssid: nil, connection: :disconnected, signal: nil}
  end

  defp notify_status(%{status_subscriber: nil}), do: :ok

  defp notify_status(%{status_subscriber: pid} = state) do
    send(pid, {:wifi_status, read_status(state)})
    :ok
  end

  # --- Normalization ---

  # Accept string OR atom keys; coerce to a canonical map with the keys we use.
  defp normalize(config) do
    %{
      version: fetch(config, :version, "version") |> to_version(),
      enabled: fetch(config, :enabled, "enabled") |> to_bool(),
      ssid: fetch(config, :ssid, "ssid"),
      psk: fetch(config, :psk, "psk")
    }
  end

  defp persistable(%{version: v, enabled: e, ssid: ssid, psk: psk}) do
    %{version: v, enabled: e, ssid: ssid, psk: psk}
  end

  defp fetch(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end

  defp to_version(v) when is_integer(v), do: v
  defp to_version(v) when is_binary(v), do: String.to_integer(v)
  defp to_version(nil), do: 0

  defp to_bool(true), do: true
  defp to_bool(false), do: false
  defp to_bool("true"), do: true
  defp to_bool("false"), do: false
  defp to_bool(nil), do: false

  # --- VintageNet config shape ---

  @doc """
  The `wlan0` VintageNet client config for a WPA-PSK network — same shape as
  `config/target.exs` builds for a baked-in network.
  """
  @spec wifi_client_config(String.t(), String.t() | nil) :: map()
  def wifi_client_config(ssid, psk) do
    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [%{key_mgmt: :wpa_psk, ssid: ssid, psk: psk}]
      },
      ipv4: %{method: :dhcp}
    }
  end

  # --- Best-effort wrapper ---

  defp run(fun, label) do
    fun.()
  rescue
    e -> Logger.warning("[WiFiManager] #{label} step failed: #{inspect(e)}")
  end

  # --- Real-target defaults (never invoked on host/test) ---
  #
  # `VintageNet` is a target-only dependency (not compiled on host/test), so these
  # defaults reach it via `apply/3`: the compiler never resolves the module on host
  # (no "undefined" warnings), and they only ever run on a real device where
  # VintageNet is present. The WiFiManager itself is never started on host/test.

  defp default_configure(iface, config, opts),
    do: apply(VintageNet, :configure, [iface, config, opts])

  defp default_deconfigure(iface), do: apply(VintageNet, :deconfigure, [iface])
  defp default_rfkill_block, do: WiFiPower.block()
  defp default_rfkill_unblock, do: WiFiPower.unblock()
  defp default_subscribe(property), do: apply(VintageNet, :subscribe, [property])

  defp default_status do
    enabled = match?({:ok, _}, apply(VintageNet, :get_configuration, ["wlan0"]))
    connection = apply(VintageNet, :get, [@connection_property, :disconnected])
    ssid = apply(VintageNet, :get, [["interface", "wlan0", "wifi", "current_ap", :ssid]])
    signal = apply(VintageNet, :get, [["interface", "wlan0", "wifi", "current_ap", :signal_dbm]])

    %{enabled: enabled, ssid: ssid, connection: connection, signal: signal}
  end
end
