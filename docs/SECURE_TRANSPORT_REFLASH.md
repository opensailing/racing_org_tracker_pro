# Secure-Transport Reflash + Enforcement Runbook (one device, end to end)

Operator runbook for the coordinated secure-transport rollout of a SINGLE Nautic Net
device against the SailRoute server, covering: server prep, device provisioning +
reflash, verification, and the coordinated enforcement cutover (with rollback).

This is the operational counterpart to the device wiring landed in P9-job-6
(`NauticNet.SecureTransport.SessionHolder` / `ChannelClient` / `BootProvisioner` in
the supervision tree, and the post-race `BulkUploader` trigger from
`NauticNet.Race.Archive`).

> Terminology: "device" = the Nerves firmware in `nautic_net_device`; "server" =
> SailRoute (`backend`, deployed on Fly). All crypto is Ed25519 + ChaCha20-Poly1305;
> there is no PKI — the device PINS the server's public key and the server records
> the device's claimed public key (a `DeviceKey`).

---

## 0. Invariants and ordering (read first)

- **Single-machine UDP invariant.** SailRoute's UDP telemetry listener binds ONE
  IPv4 socket on the fly-global-services address and command replies egress from
  that same socket. Telemetry ingest, the per-device enforcement gate, and replies
  are all on that single machine. Do not assume multi-machine UDP fan-out.
- **Cutover order (never brick the device).** Always: (1) confirm AEAD telemetry is
  arriving AND the channel session is healthy, (2) turn OFF device plaintext
  (`require_secure_transport=true` on the DEVICE) FIRST, (3) THEN turn ON server
  rejection of plaintext for that device (`requires_secure_transport=true` on the
  SERVER). Reverse order on rollback.
- **Coexistence default.** Every flag defaults OFF. Until you flip them, the device
  sends plaintext and the server accepts it — byte-for-byte unchanged.

---

## 1. Server prep (Fly / SailRoute)

### 1.1 Ensure the server identity seed is set (prod REQUIRES it)

The server signs its handshake HELLO with its Ed25519 identity seed. In prod the seed
MUST be configured (`SailRoute.SecureTransport.ServerIdentity.private_seed/0` raises
otherwise); dev/test falls back to a fixed non-secret seed.

```sh
# 32-byte seed, raw or hex. Generate once, store as a Fly secret.
SEED_HEX=$(openssl rand -hex 32)
fly secrets set SECURE_TRANSPORT_SERVER_SEED="$SEED_HEX" -a <your-app>
```

### 1.2 Obtain the server's pinned PUBLIC key (to pin on the device)

The device authenticates the server against the server's Ed25519 PUBLIC key, derived
from the seed. Derive it ON THE SERVER so it is exactly what the server will sign with:

```sh
fly ssh console -a <your-app> -C \
  "/app/bin/sail_route eval 'IO.puts(Base.encode16(SailRoute.SecureTransport.ServerIdentity.public_key(), case: :lower))'"
```

This prints a 64-char lowercase hex string — the value you set as
`SECURE_TRANSPORT_SERVER_PUBLIC_KEY` on the device (section 2.1). It is the device's
only server-trust anchor; treat a change to it as a firmware re-pin.

> Equivalent low-level form (same result):
> `Base.encode16(SailRoute.SecureTransport.Primitives.ed25519_public_from_secret(SailRoute.SecureTransport.ServerIdentity.private_seed()), case: :lower)`

### 1.3 Create an owner/admin account

The device is claimed BY a user account. Bootstrap one in the release:

```sh
fly ssh console -a <your-app> -C \
  "/app/bin/sail_route eval 'SailRoute.Release.create_admin(\"ops@example.com\", \"a sufficiently long password\")'"
```

Idempotent: re-running with the same email updates the password and re-confirms.

### 1.4 Mint a device claim token (captures BOTH the secret AND the server_nonce)

The owner mints a single-use claim token bound to their account. The device needs BOTH
the returned `claim_token` (secret) AND the `server_nonce` (the device signs a
proof-of-possession over exactly this nonce). A fresh 32-byte `server_nonce` is minted
and stored on the token at mint time; single-use consumption makes a captured signature
non-replayable.

There are two ways to mint; the release-console form is the simplest for an operator.

**Option A — release console (recommended for ops).** Mint directly via
`Devices.generate_claim_token/2`, which returns `{:ok, raw_secret, token}`:

```sh
fly ssh console -a <your-app> -C \
  "/app/bin/sail_route eval '
    user = SailRoute.Accounts.get_user_by_email(\"ops@example.com\")
    {:ok, secret, token} = SailRoute.Devices.generate_claim_token(user)
    IO.puts(\"CLAIM_TOKEN_SECRET=\" <> secret)
    IO.puts(\"CLAIM_TOKEN_SERVER_NONCE=\" <> Base.encode64(token.server_nonce))
  '"
```

Capture both printed values — the secret is shown ONCE (only its hash is stored).
Optionally pass `pinned_fingerprint:` (the device fingerprint from §3.2) to bind the
token to a specific device key and close the key-substitution hole.

**Option B — web endpoint.** `POST /devices/claim-tokens` is mounted on the
BROWSER pipeline behind `:require_authenticated_user` — i.e. it needs the owner's
LOGGED-IN SESSION COOKIE + CSRF token (it is NOT a Bearer/`/api` route). From the
logged-in web UI / a session-cookied client, the JSON response is:

```json
{
  "claim_token":  "<opaque secret string>",   // -> device CLAIM_TOKEN_SECRET
  "server_nonce": "<base64 of 32 raw bytes>",  // -> device CLAIM_TOKEN_SERVER_NONCE
  "expires_at":   "2026-..."
}
```

> If you pinned a fingerprint, the response also echoes `pinned_fingerprint`; the
> device's identity fingerprint (§3.2) must match it or the claim is rejected
> (`:pinned_fingerprint_mismatch`).

---

## 2. Device prep — build-host environment (baked into firmware)

`config/config.exs` reads the values below from the **build-host environment at
firmware-compile time** (the same mechanism as the existing `API_ENDPOINT` /
`UDP_ENDPOINT`), so they are baked into the image. You do NOT edit `config/target.exs`
or set anything on the running device — you `export` them in the shell that runs
`mix firmware`. Any value left unset is `nil`/`false`, which leaves the
secure-transport stack dormant (the safe default: `ServerIdentity` unpinned →
`ChannelClient` won't connect; `BootProvisioner` finds no claim inputs).

Provisioning values:

| Env var | Maps to (wired in config.exs) | Purpose |
|---|---|---|
| `SECURE_TRANSPORT_SERVER_PUBLIC_KEY` | `ServerIdentity, public_key:` | The server pubkey from §1.2 (64-char hex or raw 32 bytes). The device's server-trust anchor. |
| `CLAIM_TOKEN_SECRET` | `ClaimClient, claim_token_secret:` | The `claim_token` secret from §1.4. |
| `CLAIM_TOKEN_SERVER_NONCE` | `BootProvisioner, server_nonce:` | The `server_nonce` (base64) from §1.4. |
| `API_ENDPOINT` | `:api_endpoint` | Server HTTPS base (claim + bulk upload, and WS derivation). |
| `UDP_ENDPOINT` | `:udp_endpoint` | Server UDP host:port for telemetry. |
| `SECURE_TRANSPORT_WS_URL` (optional) | read directly by `ChannelClient` | Override the WSS channel URL. Default derives from `API_ENDPOINT` (`https`→`wss`, path `/device_socket/websocket`). |

Rollout switches (also build-host env, read by config.exs; unset = the safe default):

| Env var | Set to (initial) | Effect |
|---|---|---|
| `SECURE_TRANSPORT_ENABLED` | `true` | Single switch that drives `:secure_claim_on_boot` + `:secure_channel_enabled` + `:bulk_upload_enabled`: starts the boot claim, the WSS `ChannelClient`, and the post-race `BulkUploader` (all target-only). |
| `REQUIRE_SECURE_TRANSPORT` | unset / `false` **(initially)** | Device-side plaintext kill switch (`:require_secure_transport`). Leave OFF until the enforcement flip (§4). |

> The `BootProvisioner` / `ChannelClient` / `BulkUploader` start only on a real device
> target (`MIX_TARGET` != `host`) AND when `SECURE_TRANSPORT_ENABLED=true`, matching how
> NervesHubLink / the UDP path are gated. `SessionHolder` starts in every environment
> (cheap, idle). Even when started, `ChannelClient` self-gates idle until claimed +
> identity provisioned + server pinned, so the order of provisioning is forgiving.

### 2.1 Reflash the firmware

Export the environment, then build + flash, all in the same shell:

```sh
export API_ENDPOINT="https://sailroute-backend.fly.dev"      # your server base
export UDP_ENDPOINT="sailroute-backend.fly.dev:4001"
export PRODUCT="logger"
export SECURE_TRANSPORT_SERVER_PUBLIC_KEY="<64-char hex from §1.2>"
export CLAIM_TOKEN_SECRET="<claim_token secret from §1.4>"
export CLAIM_TOKEN_SERVER_NONCE="<base64 server_nonce from §1.4>"
export SECURE_TRANSPORT_ENABLED=true        # turn on claim + channel + bulk
# REQUIRE_SECURE_TRANSPORT stays unset until the §4 cutover

MIX_TARGET=<target> mix firmware
MIX_TARGET=<target> mix burn                # or: fwup / NervesHub OTA push
```

> Because the claim token + nonce are baked into this image and the claim is
> SINGLE-USE, this firmware claims exactly ONE device on first boot (reflashing a
> second device with the same image will fail `:invalid_claim_token`). For a fleet,
> provision per-device out of band — the documented NervesKey / `/data` seam — instead
> of baking a shared token.

### 2.2 What the device does on boot (automatic)

1. `KeyStore.load_or_generate/1` generates the device's long-term Ed25519 identity on
   first boot and persists the 32-byte seed `0600` at `/data/secure_transport/device_ed25519.key`
   (reloaded unchanged on every later boot).
2. `BootProvisioner` claims the device: `POST /api/devices/claim` with the PoP
   signature over `(CLAIM_TOKEN_SECRET, public_key, server_nonce)`. On success it
   persists a claim marker (`/data/secure_transport/claim_marker.json`). A rejected
   token is logged, NOT crash-looped — fix the inputs and reboot.
3. `ChannelClient` connects the WSS channel (`/device_socket`), joins `device:<fp>`,
   runs the initiator handshake, and on `handshake_ok` publishes the live `Session`
   into `SessionHolder`.
4. UDP telemetry is now AEAD-sealed (the `UDPClient` reserves a counter from
   `SessionHolder` and seals each DataSet). With `require_secure_transport=false`,
   any moment without a live session still falls back to plaintext (coexistence).
5. Post-race, `Race.Archive` finalizes the recording and triggers
   `BulkUploader.upload_async` (signed HTTPS bulk plane). Local recordings are kept
   until the server confirms completeness via `manifest_verification_result`.

---

## 3. Verification

### 3.1 Confirm the device claimed (a `device_key` row exists)

```sh
# Find the device key by the device's identity fingerprint (see 3.2 for the fp).
fly ssh console -a <your-app> -C \
  "/app/bin/sail_route eval 'IO.inspect(SailRoute.Devices.get_device_key_by_fingerprint(\"<fingerprint-hex>\"))'"
```

A non-nil `DeviceKey` with the expected `device_id` confirms the claim landed.

### 3.2 Find the device's fingerprint (from the device)

On the device console (`/data` identity), the fingerprint is lowercase hex
`SHA-256(public_key)`:

```elixir
{:ok, id} = NauticNet.SecureTransport.KeyStore.load()
id.fingerprint
```

It is the SAME id used as the WSS connect param and the `device:<fp>` topic, and the
value to use in §3.1 and §4.

### 3.3 Confirm the channel session is live

- Device side: `NauticNet.SecureTransport.SessionHolder.live?()` returns `true`, and
  device logs show `"[ChannelClient] secure session established"`.
- Server side: the session is in the `SessionStore` (routed by `session_id`), and the
  device log line above only prints after the server's `handshake_ok`.

### 3.4 Confirm AEAD telemetry is arriving (not plaintext)

On the server, `SecureUDPIngest` routes AEAD frames through the secure path. Watch the
UDP audit / ingest: AEAD datagrams ingest normally and do NOT show
`:plaintext_rejected`. While `require_secure_transport=false` on both sides you may
still see occasional plaintext (e.g. a brief no-session window) — that is expected
coexistence, not a failure.

### 3.5 Confirm a bulk upload completed

After a race finishes, the device logs `"Bulk upload starting: recording=..."` and
then `"Bulk upload complete: recording=..."`. Server side, check the manifest status:

```sh
curl -sS https://<host>/api/race_recordings/<recording_id>/manifest_status
# -> verification_status: "complete", no missing_chunk_indexes
```

---

## 4. THE ENFORCEMENT FLIP (coordinated cutover for this device)

Goal: require secure transport for THIS device without bricking it. Do NOT proceed
until §3.3 + §3.4 are green for this device.

> **STEP 4 SERVER-ENFORCEMENT FINDING (verified read-only for this runbook):**
> The server's per-device `requires_secure_transport` column IS actually ENFORCED.
> The live UDP listener (`SailRoute.NauticNet.UDPServer.process_datagram/5`) calls
> `SecureUDPIngest.handle_datagram/3` for EVERY datagram; on the legacy plaintext
> branch it resolves the attributable `%Device{}` and
> `plaintext_rejected?/1` rejects (`{:error, {:auth_error, :plaintext_rejected}}`,
> not ingested) when `match?(%Device{requires_secure_transport: true}, device)` — i.e.
> the per-device DB column is read and acted on. Covered by
> `backend/test/sail_route/nautic_net/secure_udp_coexistence_test.exs`
> ("plaintext from a secure-capable device is REJECTED"). So the flip below is REAL,
> not a no-op.

### Step A — Pre-checks
Confirm: device sending AEAD (§3.4), channel session healthy (§3.3), claim row present
(§3.1). Keep both `require_secure_transport` flags OFF at this point.

### Step B — Turn OFF device plaintext (DEVICE first)
Rebuild + reflash the device firmware with the kill switch on. It is compile-time
baked (like the rest of §2), so this is a firmware rebuild — not a live toggle:

```sh
export REQUIRE_SECURE_TRANSPORT=true        # plus the same §2.1 env
MIX_TARGET=<target> mix firmware
MIX_TARGET=<target> mix burn                # or NervesHub OTA push
```

(Equivalently, hardcode `config :nautic_net_device, :require_secure_transport, true`.)
Now the device NEVER emits plaintext: with a live session it sends AEAD; with no live
session it DROPS the datagram (it does not leak plaintext). Re-confirm §3.4 — telemetry
keeps flowing (as AEAD). The server still ACCEPTS plaintext at this point, so there is
no rejection risk during the window.

### Step C — Turn ON server rejection for this device (SERVER second)
Flip the per-device column so the server rejects any (now-impossible) plaintext from it:

```sh
fly ssh console -a <your-app> -C \
  "/app/bin/sail_route eval '
    fp = \"<fingerprint-hex>\"
    %{device_id: id} = SailRoute.Devices.get_device_key_by_fingerprint(fp)
    dev = SailRoute.Devices.get_device(id)
    {:ok, _} = SailRoute.Devices.update_device(dev, %{requires_secure_transport: true})
  '"
```

From now on, a plaintext datagram attributable to this device is rejected
(`:plaintext_rejected`) and only its AEAD frames are accepted.

### Rollback (reverse order)
1. **Server first**: set the device's `requires_secure_transport` back to `false`
   (`SailRoute.Devices.update_device(dev, %{requires_secure_transport: false})`). The
   server again accepts plaintext from it.
2. **Device second**: rebuild + reflash with `REQUIRE_SECURE_TRANSPORT` unset (or
   `config :nautic_net_device, :require_secure_transport, false`). The device resumes
   plaintext fallback when no session is live.

Reversing the order (device-first on rollback) would, for the window in between, leave
a device emitting plaintext while the server still rejects it — telemetry loss. Always
re-open the server before re-opening the device.

---

## 5. The GLOBAL flags (separate, fleet-wide cutovers — NOT this device)

The per-device flip above is one device. Two global flags are independent, fleet-wide
cutovers; do them ONLY after the WHOLE fleet is reflashed + verified:

- **`require_authenticated_device` (UDP telemetry kill switch).**
  `config :sail_route, :device_auth, require_authenticated_device: true`. When ON, the
  server rejects ALL plaintext telemetry from ANY device (even unknown), regardless of
  the per-device column — same `:plaintext_rejected` path
  (`SecureUDPIngest.plaintext_rejected?/1`). This bricks any not-yet-reflashed device,
  so it is the LAST step after the entire fleet is on AEAD.

- **`WEB_AUTH_ENFORCE` (web/API user-principal auth — P7).**
  `WEB_AUTH_ENFORCE=true` sets `config :sail_route, :web_auth, enforce: true`, read by
  `SailRouteWeb.UserAuth.enforce?/0` and acted on by the `RequireApiUser` plug to
  reject unauthenticated web/API requests. This governs the WEB/API plane (the iOS app
  bearer auth), NOT device telemetry. Flip it ON only AFTER the iOS client ships bearer
  auth, or you lock out the app. It is entirely separate from the device transport
  flags above.

These three (`require_secure_transport` per device, `require_authenticated_device`
global UDP, `WEB_AUTH_ENFORCE` global web) are independent switches — flip each in its
own coordinated window.
