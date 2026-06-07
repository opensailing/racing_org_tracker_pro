defmodule NauticNet.SecureTransport.BootProvisionerTest do
  @moduledoc """
  The boot provisioner is safe to run repeatedly: it generates the device identity
  and TOKENLESSLY self-registers it with the server (no claim token / nonce). It
  no-ops when the server is not yet pinned (nothing to register against), and a
  second run is harmless because the server's register endpoint is idempotent. A
  "registered" marker is persisted so a later boot can skip re-registering.
  """
  use ExUnit.Case, async: true

  alias NauticNet.SecureTransport.BootProvisioner
  alias NauticNet.SecureTransport.KeyStore
  alias NauticNet.SecureTransport.ServerIdentity

  setup do
    base = Path.join(System.tmp_dir!(), "bp_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    # Pin a server public key so the provisioner has something to register against.
    srv_pub = NauticNet.SecureTransport.Primitives.ed25519_public_from_secret(:binary.copy(<<0xB2>>, 32))
    prev = Application.get_env(:nautic_net_device, ServerIdentity)
    Application.put_env(:nautic_net_device, ServerIdentity, public_key: srv_pub)
    on_exit(fn -> restore_env(ServerIdentity, prev) end)

    %{base: base}
  end

  defp restore_env(key, nil), do: Application.delete_env(:nautic_net_device, key)
  defp restore_env(key, prev), do: Application.put_env(:nautic_net_device, key, prev)

  defp ok_adapter(device_id \\ "dev-9") do
    fn %Tesla.Env{} = env ->
      assert env.method == :post
      assert String.ends_with?(env.url, "/api/devices/register")
      {:ok,
       %Tesla.Env{
         env
         | status: 201,
           body: %{"device_id" => device_id, "status" => "unassigned", "assigned" => false}
       }}
    end
  end

  test "no-op (no crash) when the server is not pinned", %{base: base} do
    Application.delete_env(:nautic_net_device, ServerIdentity)

    adapter = fn %Tesla.Env{} -> flunk("should not hit the transport when unpinned") end

    assert {:error, :not_configured} =
             BootProvisioner.provision(keystore_opts: [base_path: base], adapter: adapter)

    refute BootProvisioner.registered?(base_path: base)
  end

  test "generates identity + registers (no token needed) and persists a marker", %{base: base} do
    assert {:ok, result} =
             BootProvisioner.provision(
               keystore_opts: [base_path: base],
               adapter: ok_adapter("dev-9"),
               base_path: base
             )

    assert result.device_id == "dev-9"
    assert BootProvisioner.registered?(base_path: base)
    # The identity was generated + persisted.
    assert {:ok, _identity} = KeyStore.load(base_path: base)
  end

  test "already registered -> no-op (does not re-hit the transport)", %{base: base} do
    # First run registers + writes the marker.
    assert {:ok, _} =
             BootProvisioner.provision(
               keystore_opts: [base_path: base],
               adapter: ok_adapter(),
               base_path: base
             )

    assert BootProvisioner.registered?(base_path: base)

    # Second run sees the marker and short-circuits without hitting the network.
    no_hit = fn %Tesla.Env{} -> flunk("should not re-register once marked") end

    assert {:ok, :already_registered} =
             BootProvisioner.provision(
               keystore_opts: [base_path: base],
               adapter: no_hit,
               base_path: base
             )
  end

  test "re-registering is safe even without a marker (server is idempotent)", %{base: base} do
    # Even if the marker is absent, registering again just succeeds (idempotent server);
    # the provisioner never crashes / never carries single-use state.
    assert {:ok, _} =
             BootProvisioner.provision(
               keystore_opts: [base_path: base],
               adapter: ok_adapter("dev-1"),
               base_path: base
             )

    File.rm!(Path.join(base, "register_marker.json"))

    assert {:ok, %{device_id: "dev-2"}} =
             BootProvisioner.provision(
               keystore_opts: [base_path: base],
               adapter: ok_adapter("dev-2"),
               base_path: base
             )
  end

  test "a register rejection is reported, not crashed, and leaves the device unregistered", %{base: base} do
    adapter = fn %Tesla.Env{} = env ->
      {:ok, %Tesla.Env{env | status: 401, body: %{"error" => "bad_proof_of_possession"}}}
    end

    assert {:error, {:register_rejected, 401, _}} =
             BootProvisioner.provision(
               keystore_opts: [base_path: base],
               adapter: adapter,
               base_path: base
             )

    refute BootProvisioner.registered?(base_path: base)
  end

  test "the GenServer runs once then stops :normal", %{base: base} do
    {:ok, pid} =
      BootProvisioner.start_link(
        name: nil,
        keystore_opts: [base_path: base],
        adapter: ok_adapter(),
        base_path: base
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end
end
