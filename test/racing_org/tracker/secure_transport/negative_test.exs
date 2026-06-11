defmodule RacingOrg.Tracker.SecureTransport.NegativeTest do
  @moduledoc """
  Negative / fail-closed obligations (the functional subset of spec §14):

    * truncated 12-byte tag rejected; over-long 17-byte tag rejected
    * wrong nonce length rejected on seal/open
    * each header byte flipped (magic/version/type/aead/session_id/epoch/counter) → open fails
    * replayed counter rejected; stale/foreign epoch rejected
    * low-order / malformed X25519 point rejected before compute
    * bad Ed25519 handshake signature rejected (both roles)
    * server_nonce != 32 rejected
    * epoch_mismatch on both roles
    * derive_purpose_key reserved (<0x80) rejected; external (>=0x80) accepted & != session_id
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.SecureTransport, as: ST
  alias RacingOrg.Tracker.SecureTransport.{Frame, Handshake, Primitives}

  setup do
    {dev_pub, dev_priv} = identity(<<0xC3>>)
    {srv_pub, srv_priv} = identity(<<0xD4>>)

    ctx = %{
      dev_pub: dev_pub,
      dev_priv: dev_priv,
      srv_pub: srv_pub,
      srv_priv: srv_priv,
      device_id: "device-negative"
    }

    {d, s} = full_handshake(ctx, epoch: 2)
    Map.merge(ctx, %{dsession: d, ssession: s})
  end

  defp identity(byte) do
    seed = :binary.copy(byte, 32)
    {Primitives.ed25519_public_from_secret(seed), seed}
  end

  defp full_handshake(ctx, opts) do
    epoch = Keyword.get(opts, :epoch, 0)

    {:ok, hello, rstate} =
      Handshake.responder_hello(
        server_identity_private: ctx.srv_priv,
        server_identity_public: ctx.srv_pub,
        device_identity_public: ctx.dev_pub,
        epoch: epoch
      )

    {:ok, init, dsession} =
      Handshake.initiator_init(hello,
        device_identity_private: ctx.dev_priv,
        device_identity_public: ctx.dev_pub,
        server_identity_public: ctx.srv_pub,
        device_id: ctx.device_id,
        epoch: epoch
      )

    {:ok, ssession} = Handshake.responder_finalize(rstate, init)
    {dsession, ssession}
  end

  # ---- AEAD structural tag/nonce checks (close the OTP fail-open) ----

  describe "AEAD structural checks" do
    test "truncated 12-byte tag is rejected before :crypto" do
      key = :binary.copy(<<1>>, 32)
      nonce = :binary.copy(<<2>>, 12)
      {:ok, ct, tag} = Primitives.aead_seal(key, nonce, "data", "aad")
      truncated = binary_part(tag, 0, 12)
      assert {:error, :bad_tag_length} = Primitives.aead_open(key, nonce, ct, "aad", truncated)
    end

    test "over-long 17-byte tag is rejected" do
      key = :binary.copy(<<1>>, 32)
      nonce = :binary.copy(<<2>>, 12)
      {:ok, ct, tag} = Primitives.aead_seal(key, nonce, "data", "aad")
      overlong = tag <> <<0>>
      assert {:error, :bad_tag_length} = Primitives.aead_open(key, nonce, ct, "aad", overlong)
    end

    test "wrong nonce length rejected on seal and open" do
      key = :binary.copy(<<1>>, 32)
      assert {:error, :bad_nonce_length} = Primitives.aead_seal(key, :binary.copy(<<2>>, 11), "x", "")
      assert {:error, :bad_nonce_length} = Primitives.aead_seal(key, :binary.copy(<<2>>, 13), "x", "")

      {:ok, ct, tag} = Primitives.aead_seal(key, :binary.copy(<<2>>, 12), "x", "")
      assert {:error, :bad_nonce_length} = Primitives.aead_open(key, :binary.copy(<<2>>, 11), ct, "", tag)
    end
  end

  # ---- Frame header tamper (AAD) ----

  describe "header tamper → open fails" do
    setup ctx do
      {:ok, frame, _} = Frame.seal(ctx.dsession, "tamper-target")
      %{frame: frame}
    end

    # offsets of each header field per spec §12.1
    test "flipping each header byte fails the open", ctx do
      offsets = [
        {0, :magic},
        {4, :version},
        {5, :type},
        {6, :aead_alg_id},
        {7, :session_id},
        {23, :epoch},
        {27, :counter}
      ]

      for {offset, _field} <- offsets do
        tampered = flip_byte(ctx.frame, offset)
        assert {:error, _reason} = Frame.open(ctx.ssession, tampered)
      end
    end
  end

  defp flip_byte(bin, offset) do
    <<head::binary-size(offset), b, tail::binary>> = bin
    <<head::binary, Bitwise.bxor(b, 0xFF), tail::binary>>
  end

  # ---- Replay + epoch enforcement ----

  describe "replay and epoch enforcement" do
    test "replayed counter is rejected", ctx do
      {:ok, frame, _d2} = Frame.seal(ctx.dsession, "once")
      assert {:ok, "once", s2} = Frame.open(ctx.ssession, frame)
      # Re-open the exact same frame → replay.
      assert {:error, :replayed} = Frame.open(s2, frame)
    end

    test "stale / foreign epoch is rejected", ctx do
      {:ok, frame, _} = Frame.seal(ctx.dsession, "wrong-epoch")
      # The opener's session is at a different epoch.
      foreign = %{ctx.ssession | epoch: ctx.ssession.epoch + 1}
      assert {:error, :stale_epoch} = Frame.open(foreign, frame)
    end
  end

  # ---- X25519 point validation ----

  describe "X25519 point validation (before compute)" do
    test "all-zero (low-order) point rejected" do
      assert {:error, :low_order_x25519_point} =
               Primitives.validate_x25519_public(:binary.copy(<<0>>, 32))
    end

    test "malformed (wrong-length) point rejected" do
      assert {:error, :bad_x25519_length} = Primitives.validate_x25519_public(<<1, 2, 3>>)
    end

    test "responder rejects a low-order device ephemeral in INIT", ctx do
      {:ok, hello, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.dev_pub
        )

      {:ok, init, _} =
        Handshake.initiator_init(hello,
          device_identity_private: ctx.dev_priv,
          device_identity_public: ctx.dev_pub,
          server_identity_public: ctx.srv_pub,
          device_id: ctx.device_id,
          ephemeral: {:binary.copy(<<0>>, 32), :crypto.strong_rand_bytes(32)}
        )

      assert {:error, :low_order_x25519_point} = Handshake.responder_finalize(rstate, init)
    end

    test "initiator rejects a low-order server ephemeral in HELLO before key agreement", ctx do
      {:ok, hello, _rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.dev_pub,
          ephemeral: {:binary.copy(<<0>>, 32), :crypto.strong_rand_bytes(32)}
        )

      assert {:error, :low_order_x25519_point} =
               Handshake.initiator_init(hello,
                 device_identity_private: ctx.dev_priv,
                 device_identity_public: ctx.dev_pub,
                 server_identity_public: ctx.srv_pub,
                 device_id: ctx.device_id
               )
    end
  end

  # ---- Handshake signature verification (both roles) ----

  describe "bad Ed25519 handshake signature rejected" do
    test "initiator rejects a HELLO signed by a different server key", ctx do
      {wrong_pub, wrong_priv} = identity(<<0xEE>>)

      # Server signs with wrong_priv but the device pins ctx.srv_pub.
      {:ok, hello, _} =
        Handshake.responder_hello(
          server_identity_private: wrong_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.dev_pub
        )

      refute wrong_pub == ctx.srv_pub

      assert {:error, :bad_server_signature} =
               Handshake.initiator_init(hello,
                 device_identity_private: ctx.dev_priv,
                 device_identity_public: ctx.dev_pub,
                 server_identity_public: ctx.srv_pub,
                 device_id: ctx.device_id
               )
    end

    test "responder rejects an INIT signed by the wrong device key", ctx do
      {wrong_pub, wrong_priv} = identity(<<0xEF>>)

      {:ok, hello, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.dev_pub
        )

      # Device init signs with wrong_priv; the server stored ctx.dev_pub.
      {:ok, init, _} =
        Handshake.initiator_init(hello,
          device_identity_private: wrong_priv,
          device_identity_public: wrong_pub,
          server_identity_public: ctx.srv_pub,
          device_id: ctx.device_id
        )

      assert {:error, :bad_device_signature} = Handshake.responder_finalize(rstate, init)
    end
  end

  # ---- server_nonce length ----

  describe "server_nonce length enforcement" do
    for {label, bad} <- [empty: <<>>, short: :binary.copy(<<0>>, 16), long: :binary.copy(<<0>>, 33)] do
      test "responder rejects a #{label} server_nonce", ctx do
        assert {:error, :bad_server_nonce_length} =
                 Handshake.responder_hello(
                   server_identity_private: ctx.srv_priv,
                   server_identity_public: ctx.srv_pub,
                   device_identity_public: ctx.dev_pub,
                   server_nonce: unquote(bad)
                 )
      end
    end
  end

  # ---- epoch mismatch on both roles ----

  describe "epoch mismatch" do
    test "initiator rejects a HELLO epoch != its configured epoch", ctx do
      {:ok, hello, _} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.dev_pub,
          epoch: 5
        )

      assert {:error, :epoch_mismatch} =
               Handshake.initiator_init(hello,
                 device_identity_private: ctx.dev_priv,
                 device_identity_public: ctx.dev_pub,
                 server_identity_public: ctx.srv_pub,
                 device_id: ctx.device_id,
                 epoch: 0
               )
    end

    test "responder rejects an INIT epoch != its state epoch", ctx do
      {:ok, hello, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.dev_pub,
          epoch: 5
        )

      {:ok, init, _} =
        Handshake.initiator_init(hello,
          device_identity_private: ctx.dev_priv,
          device_identity_public: ctx.dev_pub,
          server_identity_public: ctx.srv_pub,
          device_id: ctx.device_id,
          epoch: 5
        )

      # The responder's state epoch is surgically changed to disagree.
      forged_state = %{rstate | epoch: 9}
      assert {:error, reason} = Handshake.responder_finalize(forged_state, init)
      assert reason in [:epoch_mismatch, :bad_device_signature]
    end
  end

  # ---- role confusion ----

  describe "role confusion" do
    test "a HELLO fed to responder_finalize is rejected (bad_type)", ctx do
      {:ok, hello, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.dev_pub
        )

      assert {:error, :bad_type} = Handshake.responder_finalize(rstate, hello)
    end

    test "an INIT fed to initiator_init is rejected (bad_type)", ctx do
      {:ok, hello, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.dev_pub
        )

      {:ok, init, _} =
        Handshake.initiator_init(hello,
          device_identity_private: ctx.dev_priv,
          device_identity_public: ctx.dev_pub,
          server_identity_public: ctx.srv_pub,
          device_id: ctx.device_id
        )

      _ = rstate

      assert {:error, :bad_type} =
               Handshake.initiator_init(init,
                 device_identity_private: ctx.dev_priv,
                 device_identity_public: ctx.dev_pub,
                 server_identity_public: ctx.srv_pub,
                 device_id: ctx.device_id
               )
    end
  end

  # ---- derive_purpose_key registry ----

  describe "derive_purpose_key registry" do
    test "reserved purposes (< 0x80, incl. 0x01 and 0x03) are rejected", ctx do
      for p <- [0x00, 0x01, 0x03, 0x7F] do
        assert {:error, :purpose_reserved} = Handshake.derive_purpose_key(ctx.dsession, p, 0x00)
      end
    end

    test "out-of-range purpose (> 0xFF) is rejected", ctx do
      assert {:error, :purpose_out_of_range} = Handshake.derive_purpose_key(ctx.dsession, 0x100, 0x00)
    end

    test "external purpose (>= 0x80) is accepted and is not the session_id", ctx do
      assert {:ok, key} = Handshake.derive_purpose_key(ctx.dsession, ST.purpose_external_min(), 0x00)
      assert byte_size(key) == 32
      assert binary_part(key, 0, 16) != ctx.dsession.session_id
    end
  end

  # ---- epoch overflow guards ----

  describe "epoch u32 overflow guard" do
    test "responder_hello refuses an out-of-range epoch", ctx do
      assert {:error, :epoch_exhausted} =
               Handshake.responder_hello(
                 server_identity_private: ctx.srv_priv,
                 server_identity_public: ctx.srv_pub,
                 device_identity_public: ctx.dev_pub,
                 epoch: 0x1_0000_0000
               )
    end

    test "seal refuses an out-of-range epoch", ctx do
      bad = %{ctx.dsession | epoch: 0x1_0000_0000}
      assert {:error, :epoch_exhausted} = Frame.seal(bad, "x")
    end
  end

  # P9-job-4: the stateless seal (explicit session_id/epoch/counter/key, no Session
  # and no counter state). It is what the SessionHolder grant feeds the UDP path.
  describe "stateless seal_with/5" do
    test "round-trips byte-identically with the stateful seal/2", ctx do
      {:ok, stateful, _} = Frame.seal(ctx.dsession, "round-trip")

      {:ok, stateless} =
        Frame.seal_with(
          ctx.dsession.session_id,
          ctx.dsession.epoch,
          ctx.dsession.send_counter,
          ctx.dsession.out_key,
          "round-trip"
        )

      assert stateless == stateful
      assert {:ok, "round-trip", _} = Frame.open(ctx.ssession, stateless)
    end

    test "mirrors the seal/2 ceiling + rekey guards", ctx do
      sid = ctx.dsession.session_id
      key = ctx.dsession.out_key

      assert {:error, :epoch_exhausted} =
               Frame.seal_with(sid, 0x1_0000_0000, 0, key, "x")

      assert {:error, :counter_exhausted} =
               Frame.seal_with(sid, ctx.dsession.epoch, ST.counter_max(), key, "x")

      assert {:error, :rekey_required} =
               Frame.seal_with(sid, ctx.dsession.epoch, ST.rekey_after(), key, "x")
    end

    test "an invalid out_key surfaces an AEAD error (no crash)", ctx do
      assert {:error, :bad_key_length} =
               Frame.seal_with(ctx.dsession.session_id, ctx.dsession.epoch, 0, <<0::8>>, "x")
    end
  end
end
