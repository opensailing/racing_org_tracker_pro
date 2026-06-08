defmodule NauticNet.Tracking.ConfigTest do
  use ExUnit.Case, async: true

  alias NauticNet.Tracking.Config
  alias NauticNet.Tracking.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_tracking_cfg_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # Wire-shape payload (string keys, as it arrives over the Slipstream channel).
  defp payload(version) do
    %{
      "version" => version,
      "states" => %{
        "pre_race" => %{"damping_seconds" => 2.0, "send_rate_hz" => 1.0},
        "starting" => %{"damping_seconds" => 1.0, "send_rate_hz" => 5.0},
        "race" => %{"damping_seconds" => 0.5, "send_rate_hz" => 10.0}
      }
    }
  end

  defp start(opts) do
    parent = self()

    base =
      [
        name: nil,
        store_dir: opts[:dir],
        on_apply: fn applied -> send(parent, {:on_apply, applied}) end
      ]

    start_supervised!({Config, Keyword.merge(base, Keyword.delete(opts, :dir))})
  end

  describe "apply_config/2 — version 0 is a real config applied on first receipt" do
    test "applies version 0 on first receipt (applied_version starts below 0)", %{dir: dir} do
      pid = start(dir: dir)

      assert {:ok, applied} = Config.apply_config(pid, payload(0))
      assert applied.version == 0
      assert applied.states.race == %{damping_seconds: 0.5, send_rate_hz: 10.0}

      # The applied version is now 0 and reflected in status.
      assert Config.applied_version(pid) == 0
      assert Config.get_state(pid, :race) == %{damping_seconds: 0.5, send_rate_hz: 10.0}
    end

    test "invokes the injected on_apply side-effect with the applied config", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(0))
      assert_receive {:on_apply, applied}
      assert applied.version == 0
    end

    test "persists the applied config to the store", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(0))

      assert {:ok, persisted} = Store.load(dir)
      assert persisted.version == 0
      assert persisted.states.starting == %{damping_seconds: 1.0, send_rate_hz: 5.0}
    end
  end

  describe "idempotency on version" do
    test "re-applying the same version is a no-op", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(0))
      assert_receive {:on_apply, _}

      assert {:ok, :unchanged} = Config.apply_config(pid, payload(0))
      refute_receive {:on_apply, _}, 50
    end

    test "applying an older version is a no-op", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(3))
      assert_receive {:on_apply, _}

      assert {:ok, :unchanged} = Config.apply_config(pid, payload(2))
      refute_receive {:on_apply, _}, 50
      assert Config.applied_version(pid) == 3
    end

    test "applying a newer version is applied", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(0))
      assert_receive {:on_apply, _}

      assert {:ok, applied} = Config.apply_config(pid, payload(1))
      assert applied.version == 1
      assert_receive {:on_apply, %{version: 1}}
      assert Config.applied_version(pid) == 1
    end
  end

  describe "boot reconciliation" do
    test "loads a persisted config on boot and treats it as applied", %{dir: dir} do
      Store.save(dir, %{
        version: 7,
        states: %{
          pre_race: %{damping_seconds: 3.0, send_rate_hz: 2.0},
          starting: %{damping_seconds: 1.5, send_rate_hz: 4.0},
          race: %{damping_seconds: 0.25, send_rate_hz: 8.0}
        }
      })

      pid = start(dir: dir)

      assert Config.applied_version(pid) == 7
      assert Config.get_state(pid, :pre_race) == %{damping_seconds: 3.0, send_rate_hz: 2.0}

      # A re-push of the same version is then a no-op.
      assert {:ok, :unchanged} = Config.apply_config(pid, payload(7))
    end

    test "with no persisted config, applied_version is nil and states use safe defaults", %{dir: dir} do
      pid = start(dir: dir)
      assert Config.applied_version(pid) == nil
      # A get_state before any config returns a sane default (1 Hz, no damping).
      assert %{damping_seconds: _, send_rate_hz: hz} = Config.get_state(pid, :race)
      assert hz > 0
    end
  end

  describe "status/1" do
    test "reports the applied version + all three states", %{dir: dir} do
      pid = start(dir: dir)
      assert {:ok, _} = Config.apply_config(pid, payload(0))

      status = Config.status(pid)
      assert status.applied_version == 0
      assert status.states.race == %{damping_seconds: 0.5, send_rate_hz: 10.0}
    end
  end
end
