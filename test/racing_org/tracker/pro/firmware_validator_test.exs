defmodule RacingOrg.Tracker.Pro.FirmwareValidatorTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidator

  test "validates when the firmware is not yet valid" do
    parent = self()

    assert :validated =
             FirmwareValidator.validate_on_connect(
               firmware_valid?: fn -> false end,
               validate: fn -> send(parent, :validated) end
             )

    assert_received :validated
  end

  test "no-op (does not re-validate) when already valid" do
    assert :already_valid =
             FirmwareValidator.validate_on_connect(
               firmware_valid?: fn -> true end,
               validate: fn -> raise "must not be called" end
             )
  end

  test "best-effort: a failure is caught and returns :error (never raises)" do
    assert :error =
             FirmwareValidator.validate_on_connect(
               firmware_valid?: fn -> false end,
               validate: fn -> raise "no nerves runtime" end
             )
  end

  test "no-op on host where Nerves.Runtime is unavailable and nothing injected" do
    assert :unavailable = FirmwareValidator.validate_on_connect()
  end
end
