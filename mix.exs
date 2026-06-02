defmodule NauticNet.Device.MixProject do
  use Mix.Project

  @app :nautic_net_device
  @version "0.2.0"
  @all_device_targets [:nautic_net_rpi3]

  def project do
    [
      app: @app,
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

      # CANUSB serial communication
      {:circuits_uart, "~> 1.5"},

      # Dev tools
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},

      # Telemetry
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 0.6"},

      # Cellular
      {:vintage_net_qmi, "~> 0.4", targets: @all_device_targets},

      # HTTP client
      {:tesla, "~> 1.4"},
      {:hackney, "~> 1.17"},
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
        {:nautic_net_protobuf, git: "git@github.com:opensailing/nautic_net_protobuf.git"},
        nautic_net_system_dep(),
        nautic_net_nmea_dep()
      ]
    end
  end

  # The Nerves system fork is only fetched when building target firmware. Point
  # at a local checkout with NAUTIC_NET_SYSTEM_PATH for system development;
  # otherwise pull the OTP 28 branch from GitHub.
  defp nautic_net_system_dep do
    # `nerves: [compile: true]` forces the system to be built from source (there
    # is no prebuilt artifact published for this fork).
    opts = [runtime: false, targets: :nautic_net_rpi3, nerves: [compile: true]]

    if path = System.get_env("NAUTIC_NET_SYSTEM_PATH") do
      {:nautic_net_system_rpi3, [path: path] ++ opts}
    else
      {:nautic_net_system_rpi3,
       [git: "git@github.com:opensailing/nautic_net_system_rpi3.git", branch: "otp28-upgrade"] ++ opts}
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
