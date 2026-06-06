defmodule NauticNet.SecureTransport.ClaimClient do
  @moduledoc """
  Device-side CLAIM / provisioning client (Phase 2, device half of the claim flow).

  Using the device's long-term Ed25519 identity (`KeyStore`), this builds and
  submits the proof-of-possession-verified claim that the server's
  `SailRoute.Devices.claim_device/1` consumes: the device presents its PUBLIC key
  + the out-of-band claim-token secret + an Ed25519 signature over the
  server-issued nonce, the server records the public key as the device's
  authoritative `DeviceKey`, and the device retains the resulting association.

  ## Provisioning inputs (out-of-band)

    * `claim_token_secret` — minted by the logged-in owner via
      `POST /devices/claim-tokens` and handed to the device OUT OF BAND. On the
      device it is provisioned through config/env
      (`config :nautic_net_device, #{inspect(__MODULE__)}, claim_token_secret: ...`,
      typically from `CLAIM_TOKEN_SECRET`) or supplied explicitly to `claim/2`.
      Wiring it from a writable `/data` setting is a job-6 concern; this module
      reads it from opts/config.
    * `server_nonce` — the SERVER-ISSUED 32-byte nonce bound to the token at mint
      time. The device does NOT choose it; it is obtained out-of-band alongside the
      secret (or, in a later transport-mediated challenge, from the server) and
      passed in. The PoP signature MUST be over exactly this nonce.

  ## Proof-of-possession message (authoritative, mirrors the server)

  The signed bytes are reconstructed verbatim by the server in
  `SailRoute.Devices.claim_device/1` (`claim_pop_message/3`):

      "SailRoute-DeviceClaim-v1"
        || lp(claim_token_secret)   # the UTF-8 secret bytes the owner issued
        || lp(public_key_raw_32)
        || lp(server_nonce_raw)

  where `lp(x) = u16-big-endian(byte_size(x)) || x` (the same length-prefix framing
  as the secure-transport handshake; a field larger than `0xFFFF` is a hard error,
  never silently truncated).

  ## Wire encoding of the request body

  The server verifier (`claim_device/1`) operates on RAW binaries; over JSON the
  device encodes the binary fields with STANDARD base64 — the established
  device↔server convention (cf. the `x-sailroute-signature` header and the
  `proto_base64` data-set body). The request body is:

      {
        "claim_token_secret": "<opaque secret string the owner issued>",
        "public_key":         "<base64(raw 32-byte Ed25519 public key)>",
        "server_nonce":       "<base64(raw 32-byte server nonce)>",
        "signature":          "<base64(64-byte Ed25519 signature)>",
        "fingerprint":        "<lowercase hex SHA-256(public_key)>"
      }

  > NOTE (contract gap, intentionally future-facing): the server currently exposes
  > NO device-facing HTTP claim-submission endpoint — only the owner-authenticated
  > `POST /devices/claim-tokens` (token MINT) is routed, and `claim_device/1` is
  > reachable only via release/console (deferred to P7; see the controller + router
  > moduledocs). This client therefore targets a forward-looking
  > `POST /api/devices/claim` route whose JSON body maps 1:1 onto `claim_device/1`
  > params. The cryptographic contract (PoP message, fingerprint rule, base64
  > encodings) is exact and verified against the server; only the HTTP envelope is
  > pending the server-side P7 endpoint. The route is overridable via `:claim_path`.

  ## Persistence of the claim result

  On success the server returns the device association (`device_id`, the recorded
  `fingerprint`, device `status`). The device retains it in a small JSON "claimed"
  marker under the `KeyStore` base path (`claim_marker.json`) so a subsequent boot
  knows it is already claimed and which device id it is.
  """

  alias NauticNet.SecureTransport.KeyStore
  alias NauticNet.SecureTransport.Primitives

  @claim_pop_domain "SailRoute-DeviceClaim-v1"
  @default_claim_path "/api/devices/claim"
  @marker_filename "claim_marker.json"

  @type identity :: KeyStore.identity()

  @typedoc "The closed set of server-side claim rejection reasons (mirrors `SailRoute.Devices.claim_reason/0`)."
  @type claim_reason :: atom()

  @typedoc "A successful claim association the device retains."
  @type claim_result :: %{
          device_id: String.t() | nil,
          fingerprint: String.t() | nil,
          status: String.t() | nil,
          raw: map()
        }

  ## --- Pure construction ---------------------------------------------------

  @doc """
  Builds the canonical proof-of-possession message the device must sign.

  Reproduces the server's `claim_pop_message/3` byte-for-byte. Pure.
  """
  @spec build_pop_message(binary(), binary(), binary()) :: binary()
  def build_pop_message(claim_token_secret, public_key, server_nonce)
      when is_binary(claim_token_secret) and is_binary(public_key) and is_binary(server_nonce) do
    @claim_pop_domain <>
      lp(claim_token_secret) <> lp(public_key) <> lp(server_nonce)
  end

  @doc """
  Signs the proof-of-possession over the server-issued nonce with the device's
  identity private key. Returns the raw 64-byte Ed25519 signature.
  """
  @spec sign_proof_of_possession(identity(), binary(), binary()) :: binary()
  def sign_proof_of_possession(%{private_key: private_key, public_key: public_key}, secret, server_nonce) do
    message = build_pop_message(secret, public_key, server_nonce)
    Primitives.ed25519_sign(private_key, message)
  end

  @doc """
  Builds the JSON-ready claim request body (a plain map of string keys).

  Encodes the binary fields with standard base64; surfaces the fingerprint for the
  optional pinned-fingerprint flow. Pure.
  """
  @spec build_claim_request(identity(), binary(), binary()) :: map()
  def build_claim_request(%{public_key: public_key} = identity, secret, server_nonce) do
    signature = sign_proof_of_possession(identity, secret, server_nonce)

    %{
      "claim_token_secret" => secret,
      "public_key" => Base.encode64(public_key),
      "server_nonce" => Base.encode64(server_nonce),
      "signature" => Base.encode64(signature),
      "fingerprint" => KeyStore.fingerprint(public_key)
    }
  end

  ## --- Claim flow ----------------------------------------------------------

  @doc """
  Performs the claim against the server.

  Builds the PoP-signed request from `identity`, POSTs it as JSON to the claim
  route, parses the response, and (on success) persists a claimed marker.

  Options:

    * `:claim_token_secret` — the out-of-band secret (defaults to the configured
      `:claim_token_secret`; required).
    * `:server_nonce` — the server-issued 32-byte nonce (required).
    * `:claim_path` — override the POST path (default `#{@default_claim_path}`).
    * `:adapter` — a Tesla adapter (fun or `{module, opts}`) — used to inject a
      mock transport in tests; defaults to the app's configured Tesla adapter.
    * `:base_path` — KeyStore/marker base dir (defaults to the configured base).

  Returns:

    * `{:ok, claim_result}` on a 2xx response (marker persisted).
    * `{:error, {:claim_rejected, reason}}` on a 4xx with a recognised
      `{"error" => reason}` body (e.g. `:invalid_claim_token`,
      `:pinned_fingerprint_mismatch`, `:bad_proof_of_possession`,
      `:server_nonce_mismatch`, `:fingerprint_already_claimed`).
    * `{:error, {:unexpected_status, status, body}}` for an unhandled status.
    * `{:error, {:transport, reason}}` on a transport-level failure.
    * `{:error, {:missing, :claim_token_secret | :server_nonce}}` when an input is
      absent (no request is sent).
  """
  @spec claim(identity(), keyword()) ::
          {:ok, claim_result()}
          | {:error,
             {:claim_rejected, claim_reason()}
             | {:unexpected_status, non_neg_integer(), term()}
             | {:transport, term()}
             | {:missing, atom()}}
  def claim(identity, opts \\ []) do
    with {:ok, secret} <- fetch_secret(opts),
         {:ok, server_nonce} <- require_opt(opts, :server_nonce) do
      body = build_claim_request(identity, secret, server_nonce)
      path = Keyword.get(opts, :claim_path, @default_claim_path)

      case post_claim(path, body, opts) do
        {:ok, %Tesla.Env{status: status} = env} when status in 200..299 ->
          result = parse_success(env.body)
          _ = persist_marker(result, opts)
          {:ok, result}

        {:ok, %Tesla.Env{status: status, body: resp_body}} when status in 400..499 ->
          {:error, {:claim_rejected, reason_from_body(resp_body)}}

        {:ok, %Tesla.Env{status: status, body: resp_body}} ->
          {:error, {:unexpected_status, status, resp_body}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  @doc "Whether a claimed marker has been persisted under the base path."
  @spec claimed?(keyword()) :: boolean()
  def claimed?(opts \\ []), do: File.exists?(marker_path(opts))

  @doc "Reads the persisted claimed marker, or `{:error, :not_claimed}` if absent."
  @spec read_claim_marker(keyword()) :: {:ok, map()} | {:error, term()}
  def read_claim_marker(opts \\ []) do
    case File.read(marker_path(opts)) do
      {:ok, json} -> Jason.decode(json)
      {:error, :enoent} -> {:error, :not_claimed}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  ## --- internal ------------------------------------------------------------

  defp post_claim(path, body, opts) do
    middleware = [Tesla.Middleware.JSON]

    client =
      case Keyword.fetch(opts, :adapter) do
        {:ok, adapter} -> Tesla.client(middleware, adapter)
        :error -> Tesla.client(middleware)
      end

    url = Keyword.get(opts, :base_url, configured_api_endpoint()) <> path
    Tesla.post(client, url, body)
  end

  defp configured_api_endpoint do
    Application.get_env(:nautic_net_device, :api_endpoint, "")
  end

  defp parse_success(body) when is_map(body) do
    %{
      device_id: body["device_id"],
      fingerprint: body["fingerprint"],
      status: body["status"],
      raw: body
    }
  end

  defp parse_success(body), do: %{device_id: nil, fingerprint: nil, status: nil, raw: %{"body" => body}}

  # Map a server error body to a clean atom reason, mirroring claim_reason/0.
  defp reason_from_body(%{"error" => error}) when is_binary(error) do
    safe_to_atom(error)
  end

  defp reason_from_body(_), do: :claim_rejected

  # Only ever map to an ALREADY-EXISTING atom so a hostile/garbage body cannot grow
  # the atom table; unknown strings collapse to a generic reason.
  defp safe_to_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> :claim_rejected
  end

  defp persist_marker(result, opts) do
    marker = %{
      "device_id" => result.device_id,
      "fingerprint" => result.fingerprint,
      "status" => result.status,
      "claimed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    path = marker_path(opts)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(marker),
         :ok <- File.write(path, json) do
      :ok
    else
      {:error, _} = err -> err
    end
  end

  defp fetch_secret(opts) do
    secret = Keyword.get(opts, :claim_token_secret) || configured_secret()

    case secret do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, {:missing, :claim_token_secret}}
    end
  end

  defp configured_secret do
    :nautic_net_device
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:claim_token_secret)
  end

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp marker_path(opts), do: Path.join(KeyStore.key_path(opts) |> Path.dirname(), @marker_filename)

  # Length-prefix framing identical to the server's claim PoP and the
  # secure-transport handshake (u16-big-endian length || bytes), with the same
  # hard guard against a field exceeding what a u16 can encode.
  defp lp(bin) when is_binary(bin) and byte_size(bin) <= 0xFFFF do
    <<byte_size(bin)::unsigned-big-integer-size(16), bin::binary>>
  end

  defp lp(bin) when is_binary(bin) do
    raise ArgumentError,
          "claim proof-of-possession field exceeds u16 length framing (#{byte_size(bin)} bytes)"
  end
end
