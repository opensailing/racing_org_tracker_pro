defmodule RacingOrg.Tracker.ApplicationTest do
  @moduledoc """
  Boot test for the P9-job-6 supervision wiring: on host the application starts
  cleanly with the new secure-transport children present + idle.

  On host (the test target) the gating choice is:

    * `SessionHolder` runs EVERYWHERE (the UDP send path + tests read it). It must
      be present and IDLE (no live session).
    * `ChannelClient`, `BootProvisioner`, and the `BulkUploader` GenServer are gated
      to the real device target AND the pinned server public key being configured
      (`ServerIdentity.configured?`), so on host they are NOT in the tree at all —
      there is no connect attempt, no claim attempt, no crash loop.

  This test asserts the live tree the running application booted (the application is
  started for the suite via `mod: {RacingOrg.Tracker.Application, []}`).
  """
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.SecureTransport.SessionHolder

  @supervisor RacingOrg.Tracker.Supervisor

  defp child_ids do
    @supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
  end

  defp child(id) do
    @supervisor
    |> Supervisor.which_children()
    |> Enum.find(fn {child_id, _pid, _type, _modules} -> child_id == id end)
  end

  test "the application is running and its top supervisor is alive" do
    assert Process.whereis(@supervisor) |> is_pid()
  end

  test "SessionHolder is supervised, alive, and idle (no live session) on host" do
    assert {SessionHolder, pid, :worker, [SessionHolder]} = child(SessionHolder)
    assert is_pid(pid)
    assert Process.alive?(pid)

    # Idle: no session has been published (no ChannelClient on host to publish one).
    refute SessionHolder.live?()
    assert {:error, :no_session} = SessionHolder.get_current_session()
    assert {:error, :no_session} = SessionHolder.take_send_counter()
  end

  test "the WSS ChannelClient is NOT started on host (target + pinned-key gated)" do
    refute ChannelClient in child_ids()
    refute Process.whereis(ChannelClient)
  end

  test "the boot claim provisioner is NOT started on host (target + pinned-key gated)" do
    refute RacingOrg.Tracker.SecureTransport.BootProvisioner in child_ids()
    refute Process.whereis(RacingOrg.Tracker.SecureTransport.BootProvisioner)
  end

  test "the BulkUploader GenServer is NOT started on host (target + pinned-key gated)" do
    refute RacingOrg.Tracker.Race.BulkUploader in child_ids()
  end

  describe "secure_transport_configured?/1 gate predicate" do
    setup do
      prev = Application.get_env(:racing_org_tracker, ServerIdentity)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:racing_org_tracker, ServerIdentity)
          value -> Application.put_env(:racing_org_tracker, ServerIdentity, value)
        end
      end)

      :ok
    end

    test "host target is never configured, even with a pinned key set" do
      Application.put_env(:racing_org_tracker, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      refute RacingOrg.Tracker.Application.secure_transport_configured?(:host)
      refute RacingOrg.Tracker.Application.secure_transport_configured?(:"")
      refute RacingOrg.Tracker.Application.secure_transport_configured?(nil)
    end

    test "a real target with NO pinned key is not configured" do
      Application.delete_env(:racing_org_tracker, ServerIdentity)
      refute RacingOrg.Tracker.Application.secure_transport_configured?(:racing_org_rpi3)
    end

    test "a real target WITH a pinned key is configured" do
      Application.put_env(:racing_org_tracker, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))

      assert RacingOrg.Tracker.Application.secure_transport_configured?(:racing_org_rpi3)
    end
  end

  test "ChannelClient is not connectable on host (so it would stay idle if started)" do
    base = Path.join(System.tmp_dir!(), "app_test_cc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    # Host target + unclaimed + no pinned server key -> not connectable.
    refute ChannelClient.connectable?(keystore_opts: [base_path: base])
  end

  test "a directly-started ChannelClient stays idle on host and does not crash" do
    base = Path.join(System.tmp_dir!(), "app_test_idle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    pid =
      start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: base]})

    assert Process.alive?(pid)
    Process.sleep(50)
    assert Process.alive?(pid)
  end

  test "the secure-transport children carry correct child specs" do
    # SessionHolder spec (the only secure child started on host).
    assert {SessionHolder, _pid, :worker, [SessionHolder]} = child(SessionHolder)

    # ChannelClient exposes a permanent worker spec (used on target).
    cc_spec = ChannelClient.child_spec([])
    assert cc_spec.id == ChannelClient
    assert cc_spec.type == :worker
    assert cc_spec.restart == :permanent
    assert {ChannelClient, :start_link, [[]]} = cc_spec.start

    # BootProvisioner is a transient one-shot worker (runs once then stops).
    bp_spec = RacingOrg.Tracker.SecureTransport.BootProvisioner.child_spec([])
    assert bp_spec.id == RacingOrg.Tracker.SecureTransport.BootProvisioner
    assert bp_spec.restart == :transient
  end
end
