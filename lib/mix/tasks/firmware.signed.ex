defmodule Mix.Tasks.Firmware.Signed do
  @shortdoc "Build the Nerves firmware and sign it for NervesHub"

  @moduledoc """
  Build the firmware and produce a SIGNED `.fw` ready to upload to NervesHub.

  `mix firmware` always emits an UNSIGNED archive, but NervesHub only accepts signed
  firmware and devices (with `fwup_public_keys` baked in — see `config/target.exs`)
  only apply an OTA whose `.fw` is signed by the matching key. This task does the whole
  release artifact in one step:

    1. `mix firmware`  (skip with `--skip-build` to just re-sign the existing image)
    2. `fwup -S -s <priv key> -i <unsigned.fw> -o <signed.fw>`
    3. verifies the signature against `fwup-key.pub` when that file is present

  ## Usage

      source .envrc            # sets MIX_TARGET + the build env, then:
      mix firmware.signed

  ## Options

    * `--private-key` / `-s` — fwup private signing key
      (default: `fwup-key.priv`, or the `FWUP_PRIV_KEY` env var)
    * `--output` / `-o` — signed firmware path
      (default: `<app>-signed.fw` in the project root)
    * `--skip-build` — don't run `mix firmware`; sign the existing image
  """

  use Mix.Task

  @switches [private_key: :string, output: :string, skip_build: :boolean]
  @aliases [s: :private_key, o: :output]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)

    if Mix.target() == :host do
      Mix.raise(
        "mix firmware.signed must run for a device target. Set MIX_TARGET " <>
          "(e.g. `source .envrc` and pick rpi3) before running."
      )
    end

    ensure_cmake_cross_env()

    priv_key = opts[:private_key] || System.get_env("FWUP_PRIV_KEY") || "fwup-key.priv"

    unless File.exists?(priv_key) do
      Mix.raise("""
      fwup private signing key not found: #{priv_key}

      Generate one with `fwup -g` (keep fwup-key.priv SECRET — back it up in 1Password,
      register fwup-key.pub with the NervesHub org). Or pass --private-key PATH.
      """)
    end

    unless opts[:skip_build], do: Mix.Task.run("firmware", [])

    unsigned = Nerves.Env.firmware_path()

    unless File.exists?(unsigned) do
      Mix.raise("Unsigned firmware not found at #{unsigned}. Run without --skip-build to build it first.")
    end

    signed = opts[:output] || "#{Mix.Project.config()[:app]}-signed.fw"

    Mix.shell().info([:cyan, "==> Signing ", :reset, unsigned])
    fwup!(["-S", "-s", priv_key, "-i", unsigned, "-o", signed])

    if File.exists?("fwup-key.pub") do
      Mix.shell().info([:cyan, "==> Verifying signature against fwup-key.pub", :reset])
      fwup!(["--verify", "-p", "fwup-key.pub", "-i", signed])
    end

    Mix.shell().info([
      :green,
      "\nSigned firmware ready to upload to NervesHub:\n  ",
      :reset,
      Path.expand(signed)
    ])
  end

  # CMake-based NIFs (e.g. :expty / libuv, pulled in by the NervesHub LocalShell
  # extension) don't cross-compile cleanly under Nerves on a macOS host without two
  # nudges, so set them here (without clobbering values the caller already provided):
  #
  #   * CMAKE_POLICY_VERSION_MINIMUM=3.5 — libuv 1.44.2 declares an ancient
  #     `cmake_minimum_required` that CMake 4.x refuses; this re-enables old-policy
  #     compatibility (the escape hatch CMake itself suggests).
  #   * TOOLCHAIN_FILE — expty's Makefile passes `-D CMAKE_TOOLCHAIN_FILE="$(TOOLCHAIN_FILE)"`,
  #     and an empty value CLOBBERS the toolchain file Nerves otherwise provides via the
  #     env, so CMake falls back to the macOS host and emits `-arch arm64` (which the GNU
  #     ARM cross-gcc rejects). Point it at the Nerves cross toolchain file.
  defp ensure_cmake_cross_env do
    unless System.get_env("CMAKE_POLICY_VERSION_MINIMUM"),
      do: System.put_env("CMAKE_POLICY_VERSION_MINIMUM", "3.5")

    toolchain =
      [
        System.get_env("TOOLCHAIN_FILE"),
        System.get_env("CMAKE_TOOLCHAIN_FILE"),
        default_toolchain_file()
      ]
      |> Enum.find(&(is_binary(&1) and &1 != ""))

    if toolchain, do: System.put_env("TOOLCHAIN_FILE", toolchain)
  end

  defp default_toolchain_file do
    candidate = Path.expand("deps/nerves_system_br/nerves-env.cmake")
    if File.exists?(candidate), do: candidate
  end

  defp fwup!(args) do
    case System.cmd("fwup", args, stderr_to_stdout: true) do
      {out, 0} ->
        IO.write(out)

      {out, code} ->
        Mix.raise("fwup #{Enum.join(args, " ")} failed (exit #{code}):\n#{out}")
    end
  end
end
