defmodule RacingOrg.Tracker.Pro.WiFiManagerTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WiFi.Store
  alias RacingOrg.Tracker.Pro.WiFiManager

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_wifi_mgr_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # Build an injectable-side-effects opts list that forwards every effect to the
  # test process as a tagged message, so we can assert exactly what was applied.
  defp recording_opts(dir, extra) do
    parent = self()

    [
      name: nil,
      store_dir: dir,
      configure_fun: fn iface, config, opts -> send(parent, {:configure, iface, config, opts}) end,
      deconfigure_fun: fn iface -> send(parent, {:deconfigure, iface}) end,
      rfkill_block_fun: fn -> send(parent, :rfkill_block) end,
      rfkill_unblock_fun: fn -> send(parent, :rfkill_unblock) end,
      status_fun: fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end,
      subscribe_fun: fn _property -> :ok end,
      compile_default: false
    ]
    |> Keyword.merge(extra)
  end

  defp start(opts) do
    pid = start_supervised!({WiFiManager, opts})
    pid
  end

  describe "boot reconciliation" do
    test "persisted state PRESENT takes precedence over the compile default", %{dir: dir} do
      # Persist a runtime "enable" while compile default is false: it must be applied,
      # NOT re-blocked at boot.
      Store.save(dir, %{version: 5, enabled: true, ssid: "boat-net", psk: "pw"})

      start(recording_opts(dir, compile_default: false))

      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock
      refute_received :rfkill_block
    end

    test "persisted :empty + compile_default=false → rfkill block (mirror WiFiPower)", %{dir: dir} do
      start(recording_opts(dir, compile_default: false))

      assert_receive :rfkill_block
      refute_received {:configure, _, _, _}
    end

    test "persisted :empty + compile_default=true → no rfkill block", %{dir: dir} do
      start(recording_opts(dir, compile_default: true))

      refute_received :rfkill_block
      refute_received {:deconfigure, _}
    end
  end

  describe "apply_config/2 enable" do
    test "configures wlan0, unblocks rfkill, and persists state + version", %{dir: dir} do
      pid = start(recording_opts(dir, compile_default: false))
      # drain boot effects
      assert_receive :rfkill_block

      assert {:ok, applied} =
               WiFiManager.apply_config(pid, %{
                 "version" => 1,
                 "enabled" => true,
                 "ssid" => "boat-net",
                 "psk" => "secret"
               })

      assert applied.enabled == true
      assert applied.ssid == "boat-net"
      assert applied.version == 1

      assert_receive {:configure, "wlan0", config, opts}
      assert config.type == VintageNetWiFi
      assert [%{ssid: "boat-net", psk: "secret", key_mgmt: :wpa_psk}] = config.vintage_net_wifi.networks
      assert Keyword.get(opts, :persist) == false
      assert_receive :rfkill_unblock

      assert {:ok, persisted} = Store.load(dir)
      assert persisted.enabled == true
      assert persisted.ssid == "boat-net"
      assert persisted.psk == "secret"
      assert persisted.version == 1
    end

    test "atom keys are accepted and normalized", %{dir: dir} do
      pid = start(recording_opts(dir, compile_default: true))

      assert {:ok, applied} =
               WiFiManager.apply_config(pid, %{version: 2, enabled: true, ssid: "s", psk: "p"})

      assert applied.ssid == "s"
      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock
    end

    test "enable without ssid returns {:error, :ssid_required} and applies nothing", %{dir: dir} do
      pid = start(recording_opts(dir, compile_default: true))

      assert {:error, :ssid_required} =
               WiFiManager.apply_config(pid, %{"version" => 1, "enabled" => true, "psk" => "p"})

      refute_received {:configure, _, _, _}
      refute_received :rfkill_unblock
      assert :empty = Store.load(dir)
    end
  end

  describe "apply_config/2 disable" do
    test "deconfigures wlan0, blocks rfkill, and persists disabled state", %{dir: dir} do
      pid = start(recording_opts(dir, compile_default: true))

      assert {:ok, applied} =
               WiFiManager.apply_config(pid, %{"version" => 1, "enabled" => false})

      assert applied.enabled == false
      assert applied.version == 1

      assert_receive {:deconfigure, "wlan0"}
      assert_receive :rfkill_block

      assert {:ok, persisted} = Store.load(dir)
      assert persisted.enabled == false
      assert persisted.version == 1
    end
  end

  describe "idempotency on version" do
    test "apply_config with version <= last-applied is a no-op", %{dir: dir} do
      Store.save(dir, %{version: 10, enabled: true, ssid: "boat-net", psk: "pw"})
      pid = start(recording_opts(dir, compile_default: false))
      assert_receive {:configure, "wlan0", _, _}
      assert_receive :rfkill_unblock

      # Equal version → no-op
      assert {:ok, :unchanged} =
               WiFiManager.apply_config(pid, %{"version" => 10, "enabled" => false})

      # Lower version → no-op
      assert {:ok, :unchanged} =
               WiFiManager.apply_config(pid, %{"version" => 9, "enabled" => false})

      refute_received {:configure, _, _, _}
      refute_received {:deconfigure, _}
      refute_received :rfkill_block
      refute_received :rfkill_unblock
    end
  end

  describe "current_status/1" do
    test "reads the injected status_fun", %{dir: dir} do
      status = %{enabled: true, ssid: "boat-net", connection: :internet, signal: -55}
      pid = start(recording_opts(dir, compile_default: true, status_fun: fn -> status end))

      assert ^status = WiFiManager.current_status(pid)
    end
  end
end
