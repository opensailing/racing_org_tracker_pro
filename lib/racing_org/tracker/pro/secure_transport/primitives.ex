defmodule RacingOrg.Tracker.Pro.SecureTransport.Primitives do
  @moduledoc """
  Low-level cryptographic primitives for RacingOrg Secure Transport.

  Thin, auditable wrappers over Erlang/OTP `:crypto` (OpenSSL-backed). **No native
  dependencies.** Every function here is portable across OTP 27 (server) and OTP 28
  (device).

  ## The pinned AEAD and its mandatory structural checks

  The only AEAD is ChaCha20-Poly1305 (IETF): 32-byte key, **12-byte** nonce,
  **16-byte** tag. OpenSSL/OTP `crypto_one_time_aead` verifies only the bytes you
  pass as the tag, so a *truncated* tag is silently accepted (empirically confirmed
  on OTP 27: a 12-byte tag opened successfully). To close this fail-open, every
  `aead_open/5` here **structurally validates** the tag is exactly 16 bytes and the
  nonce exactly 12 bytes *before* calling `:crypto`, and returns `:error` otherwise.
  `aead_seal/4` likewise enforces sizes so a malformed nonce can never be used.

  AES-GCM and XChaCha20 are deliberately unreachable: there is exactly one cipher
  constant and no negotiation path.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport, as: ST

  @aead_cipher :chacha20_poly1305

  # Canonical curve25519 small-order / blocklisted X25519 public points (RFC 7748
  # context). Any of these as a peer public key yields a predictable/zero shared
  # secret regardless of our private key, so they are rejected before compute_key.
  @low_order_points [
    "0000000000000000000000000000000000000000000000000000000000000000",
    "0100000000000000000000000000000000000000000000000000000000000000",
    "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
    "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
    "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b87f",
    "4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7",
    "d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"
  ]
  @low_order_points_bin Enum.map(@low_order_points, &Base.decode16!(&1, case: :lower))

  @zero_shared :binary.copy(<<0>>, 32)

  # --- Hashing ---

  @doc "SHA-256 of `data` (32 bytes)."
  @spec sha256(binary()) :: binary()
  def sha256(data) when is_binary(data), do: :crypto.hash(:sha256, data)

  @doc """
  Constant-time equality of two binaries (`:crypto.hash_equals/2`).

  Returns `false` for differing lengths. Use for any secret/identity comparison.
  """
  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  # --- Ed25519 identity (long-term) ---

  @doc "Generate a long-term Ed25519 identity keypair `{public32, private32}`."
  @spec generate_identity_keypair() :: {binary(), binary()}
  def generate_identity_keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  @doc "Derive the Ed25519 public key from a known 32-byte seed (for KAT/testing)."
  @spec ed25519_public_from_secret(binary()) :: binary()
  def ed25519_public_from_secret(<<secret::binary-size(32)>>) do
    {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519, secret)
    pub
  end

  @doc "Ed25519 signature (64 bytes) over `message` with `private` (32-byte seed)."
  @spec ed25519_sign(binary(), binary()) :: binary()
  def ed25519_sign(private, message)
      when is_binary(private) and is_binary(message) do
    :crypto.sign(:eddsa, :none, message, [private, :ed25519])
  end

  @doc """
  Verify an Ed25519 `signature` over `message` against `public`.

  Returns `false` (never raises) on wrong sizes or bad signature.
  """
  @spec ed25519_verify(binary(), binary(), binary()) :: boolean()
  def ed25519_verify(public, message, signature)
      when is_binary(public) and is_binary(message) and is_binary(signature) do
    cond do
      byte_size(public) != ST.ed25519_pub_size() -> false
      byte_size(signature) != ST.ed25519_sig_size() -> false
      true -> safe_verify(message, signature, public)
    end
  end

  defp safe_verify(message, signature, public) do
    :crypto.verify(:eddsa, :none, message, signature, [public, :ed25519])
  rescue
    _ -> false
  end

  # --- X25519 ephemeral key agreement ---

  @doc "Generate a fresh ephemeral X25519 keypair `{public32, private32}`."
  @spec generate_ephemeral_keypair() :: {binary(), binary()}
  def generate_ephemeral_keypair, do: :crypto.generate_key(:ecdh, :x25519)

  @doc """
  Validate a peer X25519 public key before key agreement.

  Rejects wrong length and the canonical small-order / blocklisted points.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_x25519_public(binary()) :: :ok | {:error, atom()}
  def validate_x25519_public(pub) when is_binary(pub) do
    cond do
      byte_size(pub) != ST.x25519_key_size() -> {:error, :bad_x25519_length}
      low_order_point?(pub) -> {:error, :low_order_x25519_point}
      true -> :ok
    end
  end

  def validate_x25519_public(_), do: {:error, :bad_x25519_length}

  defp low_order_point?(pub) do
    Enum.any?(@low_order_points_bin, fn p -> secure_compare(pub, p) end)
  end

  @doc """
  Compute the X25519 shared secret from a validated `peer_public` and `our_private`.

  Validates the peer point first; also rejects an all-zero shared secret as defence
  in depth. Returns `{:ok, shared32}` or `{:error, reason}`.

  The caller MUST drop `our_private` immediately after this call (the ephemeral
  private key is never stored in any session struct or logged). See the spec on
  BEAM zeroization limits.
  """
  @spec x25519_shared(binary(), binary()) :: {:ok, binary()} | {:error, atom()}
  def x25519_shared(peer_public, our_private) do
    with :ok <- validate_x25519_public(peer_public),
         shared when is_binary(shared) <-
           safe_compute_key(peer_public, our_private) do
      if secure_compare(shared, @zero_shared) do
        {:error, :zero_shared_secret}
      else
        {:ok, shared}
      end
    else
      {:error, _} = err -> err
      _ -> {:error, :x25519_compute_failed}
    end
  end

  defp safe_compute_key(peer_public, our_private) do
    :crypto.compute_key(:ecdh, peer_public, our_private, :x25519)
  rescue
    _ -> {:error, :x25519_compute_failed}
  end

  # --- AEAD: ChaCha20-Poly1305 (the only cipher) ---

  @doc """
  AEAD seal. Returns `{:ok, ciphertext, tag16}` or `{:error, reason}`.

  Enforces 32-byte key and 12-byte nonce; the produced tag is always 16 bytes.
  """
  @spec aead_seal(binary(), binary(), binary(), binary()) ::
          {:ok, binary(), binary()} | {:error, atom()}
  def aead_seal(key, nonce, plaintext, aad)
      when is_binary(key) and is_binary(nonce) and is_binary(plaintext) and
             is_binary(aad) do
    cond do
      byte_size(key) != ST.key_size() -> {:error, :bad_key_length}
      byte_size(nonce) != ST.nonce_size() -> {:error, :bad_nonce_length}
      true -> do_seal(key, nonce, plaintext, aad)
    end
  end

  defp do_seal(key, nonce, plaintext, aad) do
    {ct, tag} =
      :crypto.crypto_one_time_aead(@aead_cipher, key, nonce, plaintext, aad, true)

    {:ok, ct, tag}
  rescue
    _ -> {:error, :aead_seal_failed}
  end

  @doc """
  AEAD open. Returns `{:ok, plaintext}` or `{:error, reason}`.

  CRITICAL: structurally validates `byte_size(tag) == 16` and
  `byte_size(nonce) == 12` BEFORE calling `:crypto`. OTP verifies only the tag bytes
  passed to it, so without this check a truncated tag would be silently accepted
  (fail-open). A failed authentication returns `{:error, :aead_open_failed}`.
  """
  @spec aead_open(binary(), binary(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, atom()}
  def aead_open(key, nonce, ciphertext, aad, tag)
      when is_binary(key) and is_binary(nonce) and is_binary(ciphertext) and
             is_binary(aad) and is_binary(tag) do
    cond do
      byte_size(key) != ST.key_size() -> {:error, :bad_key_length}
      byte_size(nonce) != ST.nonce_size() -> {:error, :bad_nonce_length}
      byte_size(tag) != ST.tag_size() -> {:error, :bad_tag_length}
      true -> do_open(key, nonce, ciphertext, aad, tag)
    end
  end

  defp do_open(key, nonce, ciphertext, aad, tag) do
    case :crypto.crypto_one_time_aead(@aead_cipher, key, nonce, ciphertext, aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :aead_open_failed}
    end
  rescue
    _ -> {:error, :aead_open_failed}
  end
end
