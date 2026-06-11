defmodule RacingOrg.Tracker.SecureTransport.KATTest do
  @moduledoc """
  Known-Answer-Test suite proving the device's `:crypto` (OTP 28) reproduces, byte-for-
  byte, the published RFC vectors that the server (OTP 27) also reproduces. The vectors
  are loaded from the SAME `priv/secure_transport/kat_vectors.json` shared with the
  backend, so a single file pins both toolchains.

    * HKDF-SHA256 — RFC 5869 Test Cases 1-3 (PRK + OKM)
    * Ed25519 — RFC 8032 §7.1 TEST 1-3 (derive pub from secret, sign, verify)
    * X25519 — RFC 7748 §5.2 (two scalar/u-coordinate vectors)
    * ChaCha20-Poly1305 — RFC 8439 §2.8.2 (ciphertext + tag 1ae10b59…0691)
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.SecureTransport.{HKDF, Primitives, KATVectors}

  describe "HKDF-SHA256 (RFC 5869 Cases 1-3)" do
    test "reproduces PRK and OKM byte-for-byte" do
      for c <- KATVectors.hkdf_cases() do
        prk = HKDF.extract(c.salt, c.ikm)
        assert prk == c.prk, "PRK mismatch for #{c.name}"

        okm = HKDF.expand(prk, c.info, c.length)
        assert okm == c.okm, "OKM mismatch for #{c.name}"

        assert byte_size(okm) == c.length
      end
    end
  end

  describe "Ed25519 (RFC 8032 §7.1 TEST 1-3)" do
    test "derives public from secret, signs, and verifies" do
      for c <- KATVectors.ed25519_cases() do
        derived_pub = Primitives.ed25519_public_from_secret(c.secret)
        assert derived_pub == c.public, "public-key derivation mismatch for #{c.name}"

        sig = Primitives.ed25519_sign(c.secret, c.message)
        assert sig == c.signature, "signature mismatch for #{c.name}"

        assert Primitives.ed25519_verify(c.public, c.message, c.signature),
               "verify failed for #{c.name}"

        # A tampered message must NOT verify.
        refute Primitives.ed25519_verify(c.public, c.message <> <<0>>, c.signature)
      end
    end
  end

  describe "X25519 (RFC 7748 §5.2)" do
    test "compute_key reproduces the published outputs" do
      for c <- KATVectors.x25519_cases() do
        # compute_key(:ecdh, u_coordinate, scalar, :x25519); OTP clamps the scalar.
        output = :crypto.compute_key(:ecdh, c.u, c.scalar, :x25519)
        assert output == c.output, "X25519 output mismatch for #{c.name}"
      end
    end
  end

  describe "ChaCha20-Poly1305 (RFC 8439 §2.8.2)" do
    test "reproduces ciphertext and the published tag" do
      for c <- KATVectors.chacha20_poly1305_cases() do
        {:ok, ct, tag} = Primitives.aead_seal(c.key, c.nonce, c.plaintext, c.aad)
        assert ct == c.ciphertext, "ciphertext mismatch for #{c.name}"
        assert tag == c.tag, "tag mismatch for #{c.name}"
        assert Base.encode16(tag, case: :lower) == "1ae10b594f09e26a7e902ecbd0600691"

        # And it opens back to the plaintext.
        assert {:ok, pt} = Primitives.aead_open(c.key, c.nonce, ct, c.aad, tag)
        assert pt == c.plaintext
      end
    end
  end
end
