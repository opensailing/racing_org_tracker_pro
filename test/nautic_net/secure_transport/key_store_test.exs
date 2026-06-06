defmodule NauticNet.SecureTransport.KeyStoreTest do
  @moduledoc """
  The device's long-term Ed25519 identity key store: first-use generation,
  persist-and-reload (stable identity, no regeneration), 0600 file perms, and the
  canonical fingerprint derivation (lowercase hex SHA-256 of the raw 32-byte
  public key) — which MUST equal the server's `DeviceKey.fingerprint/1` rule.
  """
  use ExUnit.Case, async: true

  alias NauticNet.SecureTransport.KeyStore
  alias NauticNet.SecureTransport.Primitives

  setup do
    # Each test gets an isolated, empty base dir so generation/reload is observable.
    base = Path.join(System.tmp_dir!(), "nn_keystore_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  describe "load_or_generate/1" do
    test "generates a keypair on first call", %{base: base} do
      refute File.exists?(Path.join(base, "device_ed25519.key"))

      assert {:ok, identity} = KeyStore.load_or_generate(base_path: base)
      assert byte_size(identity.private_key) == 32
      assert byte_size(identity.public_key) == 32
      assert File.exists?(Path.join(base, "device_ed25519.key"))
    end

    test "persists and reloads the SAME key on the second call (no regeneration)", %{base: base} do
      assert {:ok, first} = KeyStore.load_or_generate(base_path: base)
      assert {:ok, second} = KeyStore.load_or_generate(base_path: base)

      assert second.private_key == first.private_key
      assert second.public_key == first.public_key
      assert second.fingerprint == first.fingerprint
    end

    test "writes the private key file with 0600 perms", %{base: base} do
      assert {:ok, _identity} = KeyStore.load_or_generate(base_path: base)

      key_path = Path.join(base, "device_ed25519.key")
      assert {:ok, stat} = File.stat(key_path)
      # Lowest 9 bits = rwxrwxrwx; 0o600 = owner rw only.
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    test "the persisted file holds exactly the 32-byte private seed", %{base: base} do
      assert {:ok, identity} = KeyStore.load_or_generate(base_path: base)
      raw = File.read!(Path.join(base, "device_ed25519.key"))
      assert raw == identity.private_key
      assert byte_size(raw) == 32
    end

    test "derived public key matches across reload and the stored seed", %{base: base} do
      assert {:ok, first} = KeyStore.load_or_generate(base_path: base)
      assert {:ok, second} = KeyStore.load_or_generate(base_path: base)

      # The public key is DERIVED from the seed, never stored — so it must match
      # both across reload and a fresh derivation from the seed.
      assert second.public_key == first.public_key
      assert Primitives.ed25519_public_from_secret(second.private_key) == second.public_key
    end

    test "a signature made by the loaded key verifies under the derived public key", %{base: base} do
      assert {:ok, identity} = KeyStore.load_or_generate(base_path: base)
      msg = "device-identity-roundtrip"
      sig = Primitives.ed25519_sign(identity.private_key, msg)
      assert Primitives.ed25519_verify(identity.public_key, msg, sig)
    end
  end

  describe "fingerprint" do
    test "is lowercase hex SHA-256 of the raw public key, 64 chars", %{base: base} do
      assert {:ok, identity} = KeyStore.load_or_generate(base_path: base)

      expected = Base.encode16(Primitives.sha256(identity.public_key), case: :lower)
      assert identity.fingerprint == expected
      assert String.length(identity.fingerprint) == 64
      assert identity.fingerprint =~ ~r/^[0-9a-f]{64}$/
    end

    test "matches the server's DeviceKey.fingerprint rule for a known key" do
      # Mirror SailRoute.Devices.DeviceKey.fingerprint/1: lowercase hex SHA-256 of
      # the raw 32-byte Ed25519 public key. Cross-check against a fixed key so the
      # device and server compute byte-identical fingerprints.
      public_key = :binary.copy(<<0x42>>, 32)
      server_rule = Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)

      assert KeyStore.fingerprint(public_key) == server_rule
      assert String.length(server_rule) == 64
    end
  end
end
