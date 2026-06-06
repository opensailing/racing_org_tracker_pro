defmodule NauticNet.SecureTransport.BootProvisionerTest do
  @moduledoc """
  The boot provisioner is safe to run before provisioning: with no claim inputs it
  no-ops, and when already claimed it no-ops. A successful claim generates the
  identity and submits the PoP claim via a mocked transport.
  """
  use ExUnit.Case, async: true

  alias NauticNet.SecureTransport.BootProvisioner
  alias NauticNet.SecureTransport.ClaimClient
  alias NauticNet.SecureTransport.KeyStore

  setup do
    base = Path.join(System.tmp_dir!(), "bp_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  test "no-op (no crash) when no claim inputs are configured", %{base: base} do
    assert {:error, :no_claim_inputs} = BootProvisioner.provision(keystore_opts: [base_path: base])
    # No identity is forced into existence by a no-input boot... actually identity is
    # generated first; but the point is it does not claim and does not crash.
    refute ClaimClient.claimed?(base_path: base)
  end

  test "no-op when already claimed", %{base: base} do
    # Plant a claim marker by hand (the same path ClaimClient writes to).
    {:ok, _identity} = KeyStore.load_or_generate(base_path: base)
    marker = Path.join(base, "claim_marker.json")
    File.write!(marker, Jason.encode!(%{"device_id" => "dev-1"}))

    assert {:ok, :already_claimed} = BootProvisioner.provision(keystore_opts: [base_path: base])
  end

  test "generates identity + claims when inputs are present (mock transport)", %{base: base} do
    server_nonce = :binary.copy(<<7>>, 32)

    adapter = fn %Tesla.Env{} = env ->
      assert env.method == :post
      assert String.ends_with?(env.url, "/api/devices/claim")
      {:ok, %Tesla.Env{env | status: 200, body: %{"device_id" => "dev-9", "status" => "active"}}}
    end

    assert {:ok, result} =
             BootProvisioner.provision(
               keystore_opts: [base_path: base],
               claim_token_secret: "the-secret",
               server_nonce: Base.encode64(server_nonce),
               adapter: adapter,
               base_path: base
             )

    assert result.device_id == "dev-9"
    assert ClaimClient.claimed?(base_path: base)
    assert {:ok, _identity} = KeyStore.load(base_path: base)
  end

  test "a claim rejection is reported, not crashed, and leaves the device unclaimed", %{base: base} do
    adapter = fn %Tesla.Env{} = env ->
      {:ok, %Tesla.Env{env | status: 422, body: %{"error" => "invalid_claim_token"}}}
    end

    assert {:error, {:claim_rejected, :invalid_claim_token}} =
             BootProvisioner.provision(
               keystore_opts: [base_path: base],
               claim_token_secret: "bad",
               server_nonce: Base.encode64(:binary.copy(<<1>>, 32)),
               adapter: adapter,
               base_path: base
             )

    refute ClaimClient.claimed?(base_path: base)
  end

  test "the GenServer runs once then stops :normal", %{base: base} do
    {:ok, pid} = BootProvisioner.start_link(name: nil, keystore_opts: [base_path: base])
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end
end
