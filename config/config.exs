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

# Secure-transport wiring. The SessionHolder is cheap and starts in EVERY
# environment (the UDP send path + tests read it). The WSS ChannelClient and the
# boot-time self-registration provisioner are gated to the real device target AND
# require an explicit enabled flag; on host/test they never start. The ChannelClient
# additionally self-gates in `init` (idle unless registered + identity provisioned +
# server pinned) so even when enabled it is safe to start before provisioning.
#
#   :secure_channel_enabled   - start the WSS ChannelClient (target-only). Default
#                               false; target.exs/runtime sets it true once secure
#                               transport is being rolled out.
#   :secure_register_on_boot  - run the one-shot boot provisioner (target-only) that
#                               generates the device identity and TOKENLESSLY
#                               self-registers it with the server (proof-of-possession,
#                               no claim token). An admin later associates the device
#                               to an account in the web panel. Default false.
#   :bulk_upload_enabled      - post-race signed bulk upload of finalized recordings.
#                               Default false; flips on with the rest of the rollout.
# A single switch turns on the secure-transport client surface (channel + boot
# register + bulk upload) so the rollout flips them together; `require_secure_transport`
# above is the SEPARATE, later cutover that stops emitting plaintext. Unset -> false
# (host/test + un-provisioned firmware stay dormant).
secure_enabled? = System.get_env("SECURE_TRANSPORT_ENABLED") == "true"
config :nautic_net_device, :secure_channel_enabled, secure_enabled?
config :nautic_net_device, :secure_register_on_boot, secure_enabled?
config :nautic_net_device, :bulk_upload_enabled, secure_enabled?

# Provisioning value read from the BUILD-HOST environment at firmware-compile time
# (same mechanism as API_ENDPOINT above) and baked into the image. Unset (host/test
# or un-provisioned firmware) -> nil, and the secure-transport modules treat
# themselves as unconfigured and stay dormant: ServerIdentity is unpinned, so the
# initiator won't connect AND the BootProvisioner has no trusted server to register
# against (it no-ops). See docs/SECURE_TRANSPORT_REFLASH.md.
#   SECURE_TRANSPORT_SERVER_PUBLIC_KEY - the server's pinned Ed25519 public key
#       (raw 32 bytes or 64-char hex); the initiator verifies the HELLO signature
#       against it (no PKI). It is also the only config the boot self-registration
#       needs (no out-of-band claim token / nonce anymore — registration is tokenless
#       and an admin associates the device to an account after it registers).
config :nautic_net_device, NauticNet.SecureTransport.ServerIdentity,
  public_key: System.get_env("SECURE_TRANSPORT_SERVER_PUBLIC_KEY")

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

# Mint adapter (pure-Elixir, no NIFs). On the device Mint auto-uses castore for
# HTTPS certificate verification (verify_peer by default), resolved at runtime.
# Replaces hackney, whose 4.x line (required by tesla 1.20) drags in an unused
# QUIC/HTTP3 stack.
config :tesla, adapter: Tesla.Adapter.Mint

# Tesla 1.20 soft-deprecates the `use Tesla` builder macro (still fully
# supported) in favor of runtime configuration. We continue to use the builder
# in NauticNet.WebClients.HTTPClient, so silence the per-compile warning.
config :tesla, disable_deprecated_builder_warning: true

if Mix.target() == :host or Mix.target() == :"" do
  import_config "host_#{Mix.env()}.exs"
else
  import_config "target.exs"
end
