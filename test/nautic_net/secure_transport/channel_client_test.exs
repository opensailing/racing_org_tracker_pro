defmodule NauticNet.SecureTransport.ChannelClientTest do
  @moduledoc """
  Tests for the gating logic (safe-to-start-idle) and a socket-layer smoke test
  using `Slipstream.SocketTest` (a conceptual server, no real websocket): the
  client connects, joins `device:<fp>`, and on a server `handshake_hello` push
  pushes a `handshake_init` back.
  """
  use Slipstream.SocketTest

  alias NauticNet.SecureTransport.ChannelClient
  alias NauticNet.SecureTransport.Handshake
  alias NauticNet.SecureTransport.KeyStore
  alias NauticNet.SecureTransport.Primitives
  alias NauticNet.SecureTransport.ServerIdentity
  alias NauticNet.SecureTransport.SessionHolder

  # A per-test KeyStore in a temp dir + a pinned server keypair.
  setup do
    base = Path.join(System.tmp_dir!(), "cc_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, identity} = KeyStore.load_or_generate(base_path: base)

    {srv_pub, srv_priv} = identity(<<0xB2>>)
    prev = Application.get_env(:nautic_net_device, ServerIdentity)
    Application.put_env(:nautic_net_device, ServerIdentity, public_key: srv_pub)
    on_exit(fn -> restore_env(ServerIdentity, prev) end)

    %{base: base, identity: identity, srv_pub: srv_pub, srv_priv: srv_priv}
  end

  defp identity(byte) do
    seed = :binary.copy(byte, 32)
    {Primitives.ed25519_public_from_secret(seed), seed}
  end

  defp restore_env(key, nil), do: Application.delete_env(:nautic_net_device, key)
  defp restore_env(key, prev), do: Application.put_env(:nautic_net_device, key, prev)

  # --- gating: safe to start idle, never connects when not configured ---

  describe "gating / connectable?" do
    test "host/unclaimed device is NOT connectable (stays idle)", %{base: base} do
      # On host the :target is :host and there is no claim marker -> not connectable.
      refute ChannelClient.connectable?(keystore_opts: [base_path: base])
    end

    test "starts and stays idle when not auto-connecting (no crash loop)", %{base: base} do
      pid =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: base]})

      assert Process.alive?(pid)
      # Give it a beat; it must NOT crash or busy-loop.
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  # --- socket-layer smoke test (conceptual server) ---

  describe "handshake over the channel (SocketTest)" do
    test "connects, joins device:<fp>, and answers handshake_hello with handshake_init", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           keystore_opts: [base_path: ctx.base]}
        )

      # Connect + join (the conceptual server accepts).
      connect_and_assert_join(client, ^topic, %{}, :ok)

      # Server (us) builds a real HELLO and pushes it.
      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})

      # The client must push back a valid handshake_init.
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)

      # And the INIT finalizes server-side into a matching session.
      assert {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)

      # When the server confirms with handshake_ok, the client publishes the live
      # session to the holder.
      push(client, topic, "handshake_ok", %{
        "session_id" => Base.encode64(server_session.session_id)
      })

      # Wait for the holder to be populated.
      assert eventually(fn -> SessionHolder.live?(holder) end)
      {:ok, device_session} = SessionHolder.get_current_session(holder)
      assert device_session.session_id == server_session.session_id
      assert device_session.out_key == server_session.in_key
    end
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, retries - 1)
    end
  end
end
