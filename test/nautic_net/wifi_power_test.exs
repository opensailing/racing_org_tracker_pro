defmodule NauticNet.WiFiPowerTest do
  use ExUnit.Case, async: true

  alias NauticNet.WiFiPower

  describe "disable/1" do
    test "runs the radio power-down steps (injectable, best-effort)" do
      parent = self()

      assert :ok =
               WiFiPower.disable(
                 rfkill_fun: fn -> send(parent, :rfkill) end,
                 linkdown_fun: fn -> send(parent, :linkdown) end
               )

      assert_received :rfkill
      assert_received :linkdown
    end

    test "still returns :ok if a step raises (best-effort, never crashes boot)" do
      assert :ok =
               WiFiPower.disable(
                 rfkill_fun: fn -> raise "no sysfs" end,
                 linkdown_fun: fn -> :ok end
               )
    end
  end

  describe "GenServer lifecycle" do
    test "init/1 schedules the power-down via handle_continue" do
      assert {:ok, _opts, {:continue, :disable}} = WiFiPower.init([])
    end

    test "handle_continue/2 disables the radio then stops :normal" do
      parent = self()
      opts = [rfkill_fun: fn -> send(parent, :rfkill) end, linkdown_fun: fn -> :ok end]

      assert {:stop, :normal, ^opts} = WiFiPower.handle_continue(:disable, opts)
      assert_received :rfkill
    end
  end
end
