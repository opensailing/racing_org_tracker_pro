# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

{git_commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
git_commit = String.trim(git_commit)

config :nautic_net_device,
  target: Mix.target(),
  api_endpoint: System.fetch_env!("API_ENDPOINT"),
  udp_endpoint: System.fetch_env!("UDP_ENDPOINT"),
  product: System.fetch_env!("PRODUCT"),
  replay_log: System.get_env("REPLAY_LOG"),
  git_commit: git_commit

# P9-job-4 AEAD UDP telemetry gate. When a live SecureTransport session exists,
# telemetry DataSets are sealed into AEAD frames; otherwise this flag decides the
# no-session fallback:
#   false (default, coexistence rollout) - send the legacy plaintext DataSet.
#   true  (post per-device enforcement)  - drop the datagram (never send plaintext).
# Mirrors the server's per-device `requires_secure_transport`.
config :nautic_net_device,
       :require_secure_transport,
       System.get_env("REQUIRE_SECURE_TRANSPORT") == "true"

# P9-job-6 secure-transport wiring. The SessionHolder is cheap and starts in EVERY
# environment (the UDP send path + tests read it). The WSS ChannelClient and the
# boot-time claim provisioner are gated to the real device target AND require an
# explicit enabled flag; on host/test they never start. The ChannelClient
# additionally self-gates in `init` (idle unless claimed + identity provisioned +
# server pinned) so even when enabled it is safe to start before provisioning.
#
#   :secure_channel_enabled  - start the WSS ChannelClient (target-only). Default
#                              false; target.exs/runtime sets it true once secure
#                              transport is being rolled out.
#   :secure_claim_on_boot    - run the one-shot boot claim provisioner (target-only)
#                              that generates the device identity and claims it when
#                              a claim token secret + server_nonce are configured and
#                              the device is not yet claimed. Default false.
#   :bulk_upload_enabled     - post-race signed bulk upload of finalized recordings.
#                              Default false; flips on with the rest of the rollout.
# A single switch turns on the secure-transport client surface (channel + boot
# claim + bulk upload) so the rollout flips them together; `require_secure_transport`
# above is the SEPARATE, later cutover that stops emitting plaintext. Unset -> false
# (host/test + un-provisioned firmware stay dormant).
secure_enabled? = System.get_env("SECURE_TRANSPORT_ENABLED") == "true"
config :nautic_net_device, :secure_channel_enabled, secure_enabled?
config :nautic_net_device, :secure_claim_on_boot, secure_enabled?
config :nautic_net_device, :bulk_upload_enabled, secure_enabled?

# Provisioning values read from the BUILD-HOST environment at firmware-compile time
# (same mechanism as API_ENDPOINT above) and baked into the image. Unset (host/test
# or un-provisioned firmware) -> nil, and the secure-transport modules treat
# themselves as unconfigured and stay dormant: ServerIdentity is unpinned (the
# initiator won't connect) and BootProvisioner finds no claim inputs (never claims).
# See docs/SECURE_TRANSPORT_REFLASH.md.
#   SECURE_TRANSPORT_SERVER_PUBLIC_KEY - the server's pinned Ed25519 public key
#       (raw 32 bytes or 64-char hex); the initiator verifies the HELLO signature
#       against it (no PKI).
#   CLAIM_TOKEN_SECRET / CLAIM_TOKEN_SERVER_NONCE - the {secret, base64(nonce)}
#       bundle from the server's claim-token mint, used ONCE at first boot to claim
#       this device to its owner account.
config :nautic_net_device, NauticNet.SecureTransport.ServerIdentity,
  public_key: System.get_env("SECURE_TRANSPORT_SERVER_PUBLIC_KEY")

config :nautic_net_device, NauticNet.SecureTransport.ClaimClient,
  claim_token_secret: System.get_env("CLAIM_TOKEN_SECRET")

config :nautic_net_device, NauticNet.SecureTransport.BootProvisioner,
  server_nonce: System.get_env("CLAIM_TOKEN_SERVER_NONCE")

# Data upload filter modes:
# :permissive - Allow data to be uploaded by any sensor for a data type
# :strict - Only allow data to be uploaded if a sensor is selected -- via a filter -- for the data type
# FUTURETODO: This should probably move to a runtime configuration value
config :nautic_net_device, :data_filtering, filter_mode: :permissive

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1655934717"

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

config :tesla, adapter: Tesla.Adapter.Hackney

if Mix.target() == :host or Mix.target() == :"" do
  import_config "host_#{Mix.env()}.exs"
else
  import_config "target.exs"
end
