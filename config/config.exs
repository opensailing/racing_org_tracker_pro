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

# A build-host environment flag is "on" only for the canonical truthy spellings
# `1 / true / yes / on` (case-insensitive, trimmed); everything else — including
# unset — is OFF. Used by the race-broadcast validation gates below so a validation
# firmware can be built by adding an env var to `.envrc` with NO code edit, while the
# production DEFAULT stays OFF. See docs/N2K_RACE_BROADCAST_VALIDATION.md.
env_flag = fn name ->
  (System.get_env(name) || "")
  |> String.trim()
  |> String.downcase()
  |> Kernel.in(["1", "true", "yes", "on"])
end

config :nautic_net_device,
  target: Mix.target(),
  api_endpoint: System.fetch_env!("API_ENDPOINT"),
  udp_endpoint: System.fetch_env!("UDP_ENDPOINT"),
  product: System.fetch_env!("PRODUCT"),
  replay_log: System.get_env("REPLAY_LOG"),
  git_commit: git_commit

# Secure-transport wiring. The SessionHolder is cheap and starts in EVERY
# environment (the UDP send path + tests read it). The WSS ChannelClient, the
# boot-time self-registration provisioner, and the post-race BulkUploader are gated
# to the real device target AND the PINNED SERVER PUBLIC KEY being configured (see
# below); on host/test they never start. Each also self-gates at runtime (the
# ChannelClient idles unless registered + identity provisioned + server pinned; the
# BootProvisioner no-ops when not pinned), so this is belt-and-suspenders.
#
# There is NO separate build-time enable flag: the single "secure transport is
# configured" signal IS the pinned server public key below. Setting
# SECURE_TRANSPORT_SERVER_PUBLIC_KEY enables secure transport; unset leaves the
# secure-transport children dormant.
#
# UDP telemetry is AEAD-only: when a live session exists each DataSet is sealed and
# sent, and with no live session the datagram is dropped (never plaintext). There is
# no device-side plaintext kill switch / fallback flag.
#
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
#       and an admin associates the device to an account after it registers). It is
#       the SINGLE enable for the secure-transport children.
config :nautic_net_device, NauticNet.SecureTransport.ServerIdentity,
  public_key: System.get_env("SECURE_TRANSPORT_SERVER_PUBLIC_KEY")

# Race-start countdown broadcast (PGN 130824 Key 117 "Race Timer", B&G). When the
# device holds a race assignment with a gun time it can broadcast a ~1 Hz countdown so
# the boat's B&G/Zeus display ticks the same timer. This is a PROPRIETARY message and
# ships OFF until the on-hardware sniff confirms the wire format (manufacturer-header
# reserved bits, the through-gun representation, any companion start-line keys, the
# device NAME). Flip to `true` per-device after that validation. See
# NauticNet.Compute.RaceTimerBroadcaster.
#
# DEFAULT OFF (production-safe). Override at BUILD time without a code edit by exporting
# `RACE_TIMER_BROADCAST_ENABLED=true` (or 1/yes/on) in `.envrc` before the burn — see
# docs/N2K_RACE_BROADCAST_VALIDATION.md. Host tests still drive the broadcaster ENABLED
# via the `:enabled` start_link opt, independent of this build-time gate.
config :nautic_net_device, :race_timer_broadcast_enabled, env_flag.("RACE_TIMER_BROADCAST_ENABLED")

# Next-waypoint NMEA 2000 broadcast (PGN 129284 Navigation Data + PGN 129285 Route/WP
# Information). When the device holds a race assignment whose active mark carries a
# position AND the device has a recent GPS fix, it broadcasts the bearing + distance to
# that next mark at ~1 Hz so the boat's B&G/Zeus plotter shows the steer-to numbers (and,
# where the plotter accepts it, the active waypoint). These are STANDARD nav PGNs, but
# whether a given Navico/Zeus plotter ADOPTS an externally-sourced active waypoint onto
# the chart (vs only rendering the data-box) is an on-hardware validation item, so this
# ships OFF until that sniff. Flip to `true` per-device after validation. See
# NauticNet.Compute.WaypointBroadcaster.
#
# DEFAULT OFF (production-safe). Override at BUILD time without a code edit by exporting
# `WAYPOINT_BROADCAST_ENABLED=true` (or 1/yes/on) in `.envrc` before the burn — see
# docs/N2K_RACE_BROADCAST_VALIDATION.md. Host tests still drive the broadcaster ENABLED
# via the `:enabled` start_link opt, independent of this build-time gate.
config :nautic_net_device, :waypoint_broadcast_enabled, env_flag.("WAYPOINT_BROADCAST_ENABLED")

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
