defmodule NauticNet.SecureTransport.ClaimClientTest do
  @moduledoc """
  Device-side claim/provisioning client.

  Verifies that, given the device identity keypair + the out-of-band claim-token
  secret + the server-issued nonce, the client:

    * builds the EXACT proof-of-possession message the server reconstructs in
      `SailRoute.Devices.claim_device/1` (domain string + length-prefixed
      secret/public_key/server_nonce), signs it, and the signature verifies
      against the presented public key over that message;
    * emits a request body whose field names + encodings match what the server
      verifier expects (public key / signature / server_nonce as base64, the
      secret as the opaque string the owner issued);
    * handles a success response (persisting the claimed marker) and clear
      failure responses (token expired/consumed, fingerprint pin mismatch,
      signature rejected).

  Pure construction + a MOCKED Tesla transport — no live server.
  """
  use ExUnit.Case, async: true

  alias NauticNet.SecureTransport.ClaimClient
  alias NauticNet.SecureTransport.KeyStore
  alias NauticNet.SecureTransport.Primitives

  # Mirror of the server's PoP message (SailRoute.Devices.claim_pop_message/3):
  #   "SailRoute-DeviceClaim-v1" || lp(secret) || lp(public_key) || lp(server_nonce)
  # where lp(x) = u16-big-endian(byte_size(x)) || x. This is the authoritative
  # signing input; the device MUST reproduce it byte-for-byte.
  @claim_pop_domain "SailRoute-DeviceClaim-v1"

  defp server_pop_message(secret, public_key, server_nonce) do
    @claim_pop_domain <> lp(secret) <> lp(public_key) <> lp(server_nonce)
  end

  defp lp(bin) when byte_size(bin) <= 0xFFFF do
    <<byte_size(bin)::unsigned-big-integer-size(16), bin::binary>>
  end

  setup do
    base = Path.join(System.tmp_dir!(), "nn_claim_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, identity} = KeyStore.load_or_generate(base_path: base)

    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    server_nonce = :crypto.strong_rand_bytes(32)

    {:ok, base: base, identity: identity, secret: secret, server_nonce: server_nonce}
  end

  describe "build_pop_message/3 + sign_proof_of_possession/3" do
    test "reproduces the server's PoP message byte-for-byte", ctx do
      built = ClaimClient.build_pop_message(ctx.secret, ctx.identity.public_key, ctx.server_nonce)
      expected = server_pop_message(ctx.secret, ctx.identity.public_key, ctx.server_nonce)
      assert built == expected
    end

    test "produced signature verifies against the presented public key over that message", ctx do
      sig = ClaimClient.sign_proof_of_possession(ctx.identity, ctx.secret, ctx.server_nonce)
      message = server_pop_message(ctx.secret, ctx.identity.public_key, ctx.server_nonce)

      assert byte_size(sig) == 64
      assert Primitives.ed25519_verify(ctx.identity.public_key, message, sig)
      # Sanity: the server WOULD accept this (same verify primitive, same message).
      refute Primitives.ed25519_verify(ctx.identity.public_key, "wrong-message", sig)
    end
  end

  describe "build_claim_request/3" do
    test "request body has the exact fields + encodings the server expects", ctx do
      body = ClaimClient.build_claim_request(ctx.identity, ctx.secret, ctx.server_nonce)

      assert body["claim_token_secret"] == ctx.secret
      assert body["public_key"] == Base.encode64(ctx.identity.public_key)
      assert body["server_nonce"] == Base.encode64(ctx.server_nonce)

      # The signature field must decode to a 64-byte Ed25519 signature that the
      # server verifies against the decoded public key over the PoP message.
      assert {:ok, sig} = Base.decode64(body["signature"])
      assert {:ok, pub} = Base.decode64(body["public_key"])
      message = server_pop_message(ctx.secret, pub, ctx.server_nonce)
      assert Primitives.ed25519_verify(pub, message, sig)

      # Convenience: fingerprint surfaced for the optional pinned-fingerprint flow.
      assert body["fingerprint"] == KeyStore.fingerprint(ctx.identity.public_key)
    end
  end

  describe "claim/2 over a mocked transport" do
    test "success response persists a claimed marker and returns the device association", ctx do
      device_id = "11111111-2222-3333-4444-555555555555"

      adapter = fn %Tesla.Env{} = env ->
        # The client POSTs JSON to the claim path with the expected body.
        assert env.method == :post
        decoded = decode_body(env.body)
        assert decoded["public_key"] == Base.encode64(ctx.identity.public_key)
        assert decoded["claim_token_secret"] == ctx.secret

        {:ok,
         %Tesla.Env{
           env
           | status: 201,
             body: %{
               "device_id" => device_id,
               "fingerprint" => KeyStore.fingerprint(ctx.identity.public_key),
               "status" => "provisioned"
             }
         }}
      end

      assert {:ok, claim} =
               ClaimClient.claim(ctx.identity,
                 claim_token_secret: ctx.secret,
                 server_nonce: ctx.server_nonce,
                 adapter: adapter,
                 base_path: ctx.base
               )

      assert claim.device_id == device_id
      assert claim.fingerprint == KeyStore.fingerprint(ctx.identity.public_key)

      # A claimed marker is persisted under the base path so a reboot knows it is done.
      assert ClaimClient.claimed?(base_path: ctx.base)
      assert {:ok, marker} = ClaimClient.read_claim_marker(base_path: ctx.base)
      assert marker["device_id"] == device_id
    end

    test "expired/consumed token failure is a clear error", ctx do
      adapter = fn %Tesla.Env{} = env ->
        {:ok, %Tesla.Env{env | status: 422, body: %{"error" => "invalid_claim_token"}}}
      end

      assert {:error, {:claim_rejected, :invalid_claim_token}} =
               ClaimClient.claim(ctx.identity,
                 claim_token_secret: ctx.secret,
                 server_nonce: ctx.server_nonce,
                 adapter: adapter,
                 base_path: ctx.base
               )

      refute ClaimClient.claimed?(base_path: ctx.base)
    end

    test "pinned-fingerprint mismatch failure is a clear error", ctx do
      adapter = fn %Tesla.Env{} = env ->
        {:ok, %Tesla.Env{env | status: 422, body: %{"error" => "pinned_fingerprint_mismatch"}}}
      end

      assert {:error, {:claim_rejected, :pinned_fingerprint_mismatch}} =
               ClaimClient.claim(ctx.identity,
                 claim_token_secret: ctx.secret,
                 server_nonce: ctx.server_nonce,
                 adapter: adapter,
                 base_path: ctx.base
               )
    end

    test "signature-rejected failure is a clear error", ctx do
      adapter = fn %Tesla.Env{} = env ->
        {:ok, %Tesla.Env{env | status: 422, body: %{"error" => "bad_proof_of_possession"}}}
      end

      assert {:error, {:claim_rejected, :bad_proof_of_possession}} =
               ClaimClient.claim(ctx.identity,
                 claim_token_secret: ctx.secret,
                 server_nonce: ctx.server_nonce,
                 adapter: adapter,
                 base_path: ctx.base
               )
    end

    test "a transport error surfaces clearly", ctx do
      adapter = fn %Tesla.Env{} -> {:error, :econnrefused} end

      assert {:error, {:transport, :econnrefused}} =
               ClaimClient.claim(ctx.identity,
                 claim_token_secret: ctx.secret,
                 server_nonce: ctx.server_nonce,
                 adapter: adapter,
                 base_path: ctx.base
               )
    end

    test "a missing claim-token secret is rejected before any request", ctx do
      adapter = fn %Tesla.Env{} -> flunk("should not hit the transport") end

      assert {:error, {:missing, :claim_token_secret}} =
               ClaimClient.claim(ctx.identity,
                 claim_token_secret: nil,
                 server_nonce: ctx.server_nonce,
                 adapter: adapter,
                 base_path: ctx.base
               )
    end
  end

  # Tesla.Middleware.JSON has not run on the mock env's body (the mock receives the
  # already-encoded body), so decode defensively for the assertion.
  defp decode_body(body) when is_binary(body), do: Jason.decode!(body)
  defp decode_body(body) when is_map(body), do: body
end
