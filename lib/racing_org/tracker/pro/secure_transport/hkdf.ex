defmodule RacingOrg.Tracker.Pro.SecureTransport.HKDF do
  @moduledoc """
  RFC 5869 HKDF (extract-then-expand) over HMAC-SHA256.

  OTP has no `crypto:hkdf`, so this is implemented locally on `:crypto.mac/4`.
  Verified byte-for-byte against RFC 5869 Test Cases 1, 2, and 3 (see the KAT suite
  and `priv/secure_transport/kat_vectors.json`). Portable across OTP 27/28; no native
  dependencies.
  """

  @hash :sha256
  @hash_len 32

  @doc """
  HKDF-Extract: `PRK = HMAC-SHA256(salt, IKM)` (32 bytes).

  An empty `salt` is permitted (RFC 5869 §2.2 substitutes a string of HashLen zeros,
  which HMAC handles equivalently for an empty key — the RFC Test Case 3 confirms
  this implementation matches with empty salt).
  """
  @spec extract(binary(), binary()) :: binary()
  def extract(salt, ikm) when is_binary(salt) and is_binary(ikm) do
    :crypto.mac(:hmac, @hash, salt, ikm)
  end

  @doc """
  HKDF-Expand: derive `length` bytes of output key material from `prk` and `info`.

  Raises `ArgumentError` if `length` exceeds `255 * HashLen` (RFC 5869 limit) or is
  negative.
  """
  @spec expand(binary(), binary(), non_neg_integer()) :: binary()
  def expand(prk, info, length)
      when is_binary(prk) and is_binary(info) and is_integer(length) and length >= 0 do
    max = 255 * @hash_len

    if length > max do
      raise ArgumentError, "HKDF-Expand length #{length} exceeds maximum #{max}"
    end

    n = ceil_div(length, @hash_len)

    {okm, _last} =
      Enum.reduce(1..max(n, 1), {<<>>, <<>>}, fn i, {acc, prev} ->
        block =
          if length == 0 do
            <<>>
          else
            :crypto.mac(:hmac, @hash, prk, <<prev::binary, info::binary, i::8>>)
          end

        {acc <> block, block}
      end)

    binary_part(okm, 0, length)
  end

  @doc """
  Convenience: extract then expand in one call.
  """
  @spec derive(binary(), binary(), binary(), non_neg_integer()) :: binary()
  def derive(salt, ikm, info, length) do
    salt
    |> extract(ikm)
    |> expand(info, length)
  end

  defp ceil_div(_a, 0), do: 0
  defp ceil_div(a, b), do: div(a + b - 1, b)
end
