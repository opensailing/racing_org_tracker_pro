defmodule NauticNet.Device.MixProject do
  use Mix.Project

  @app :nautic_net_device
  @version "0.3.0"
  @all_device_targets [:nautic_net_rpi3]

  def project do
    [
      app: @app,
      # NervesHub product name. Nerves bakes `:name || :app` into the firmware's
      # `meta-product`, and NervesHub matches uploads against a Product of that exact
      # name. The OTP app stays `:nautic_net_device`; only the firmware product label
      # changes. Must match the NervesHub Product name exactly.
      name: "racing-org",
      version: @version,
      elixir: "~> 1.17",
      archives: [nerves_bootstrap: "~> 1.13"],
      start_permanent: Mix.env() == :prod,
      build_embedded: true,
      deps: deps(),
      releases: [{@app, release()}],
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {NauticNet.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.14", runtime: false},
      {:shoehorn, "~> 0.9"},
      {:ring_logger, "~> 0.11"},
      {:toolshed, "~> 0.4"},
      {:ssh_subsystem_fwup, "~> 0.6.1"},
      {:nerves_time, "~> 0.4.5", targets: @all_device_targets},

      # Dependencies for all targets except :host
      {:nerves_runtime, "~> 0.13", targets: @all_device_targets},
      {:nerves_pack, "~> 0.7", targets: @all_device_targets},

      # Remote management: OTA firmware updates + remote console via NervesHub.
      # castore provides the CA bundle nerves_hub_link uses for its TLS
      # connection (it's an optional dep there, so depend on it explicitly).
      {:nerves_hub_link, "~> 2.12", targets: @all_device_targets},
      {:castore, "~> 1.0", targets: @all_device_targets},

      # Slipstream powers the device's outbound, CGNAT-friendly WSS command
      # channel to SailRoute (NauticNet.SecureTransport.ChannelClient). It is
      # already resolved transitively via :nerves_hub_link (1.2.2 in mix.lock);
      # depend on it explicitly (and on all targets, so host tests can drive the
      # channel logic) and pin it to the resolved minor.
      {:slipstream, "~> 1.2"},

      # CANUSB serial communication
      {:circuits_uart, "~> 1.5"},

      # Dev tools
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},

      # Telemetry
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.1"},

      # Cellular
      {:vintage_net_qmi, "~> 0.4", targets: @all_device_targets},

      # HTTP client. Mint is the Tesla adapter: pure-Elixir, no NIFs, and on the
      # device it auto-uses castore for HTTPS cert verification (verify_peer) at
      # runtime. We do NOT use hackney: tesla 1.20 requires hackney >= 4.0.2, whose
      # 4.x line bundles a full QUIC/HTTP3 stack this device never uses.
      {:tesla, "~> 1.4"},
      {:mint, "~> 1.0"},
      {:jason, ">= 1.0.0"},

      # :nmea pulls in ng_can, a Linux/SocketCAN NIF (needs <linux/can.h>) that
      # only builds on the Nerves target. Override it to target-only so host
      # builds — which use the Fake CAN driver — don't try to compile the NIF.
      # :nmea references NgCan only at runtime, so host compilation is unaffected.
      {:ng_can, github: "rosepointnav/ng_can", override: true, targets: @all_device_targets}
    ] ++ nautic_net_deps()
  end

  defp nautic_net_deps do
    if deps_path = System.get_env("NAUTIC_NET_DEPS_PATH") do
      # Local development
      [
        {:nautic_net_nmea2000, path: Path.join(deps_path, "nautic_net_nmea2000")},
        {:nautic_net_protobuf, path: Path.join(deps_path, "nautic_net_protobuf")},
        {:nautic_net_system_rpi3,
         path: Path.join(deps_path, "nautic_net_system_rpi3"), runtime: false, targets: :nautic_net_rpi3},
        {:nmea, path: Path.join(deps_path, "nmea")}
      ]
    else
      # Pull from GitHub
      [
        {:nautic_net_nmea2000, git: "git@github.com:opensailing/nautic_net_nmea2000.git"},
        nautic_net_protobuf_dep(),
        nautic_net_system_dep(),
        nautic_net_nmea_dep()
      ]
    end
  end

  # Point at a local nautic_net_protobuf checkout with NAUTIC_NET_PROTOBUF_PATH
  # while developing the wire contract; otherwise pull main from GitHub.
  defp nautic_net_protobuf_dep do
    if path = System.get_env("NAUTIC_NET_PROTOBUF_PATH") do
      {:nautic_net_protobuf, path: path}
    else
      {:nautic_net_protobuf,
       git: "git@github.com:opensailing/nautic_net_protobuf.git", branch: "main"}
    end
  end

  # The Nerves system fork is only fetched when building target firmware. Point
  # at a local checkout with NAUTIC_NET_SYSTEM_PATH for system development;
  # otherwise pull the OTP 28 branch from GitHub.
  defp nautic_net_system_dep do
    base = [runtime: false, targets: :nautic_net_rpi3]

    if path = System.get_env("NAUTIC_NET_SYSTEM_PATH") do
      # Local system development: build the local source from scratch.
      {:nautic_net_system_rpi3, [path: path, nerves: [compile: true]] ++ base}
    else
      # Normal build: download the PREBUILT artifact from the fork's GitHub
      # releases (artifact_sites {:github_releases, ...} -> the v<version> release).
      # No local Buildroot build and no case-sensitive volume needed.
      {:nautic_net_system_rpi3,
       [git: "git@github.com:opensailing/nautic_net_system_rpi3.git", branch: "otp28-upgrade"] ++ base}
    end
  end

  # Point at a local nmea checkout with NAUTIC_NET_NMEA_PATH while developing the
  # library; otherwise pull from GitHub.
  defp nautic_net_nmea_dep do
    if path = System.get_env("NAUTIC_NET_NMEA_PATH") do
      {:nmea, path: path}
    else
      {:nmea, git: "git@github.com:opensailing/nmea", branch: "ng-can-optional"}
    end
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  def aliases do
    [
      "firmware.upload": ["firmware", "upload"]
    ]
  end
end
