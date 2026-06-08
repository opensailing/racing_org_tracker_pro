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

  defp fwup!(args) do
    case System.cmd("fwup", args, stderr_to_stdout: true) do
      {out, 0} ->
        IO.write(out)

      {out, code} ->
        Mix.raise("fwup #{Enum.join(args, " ")} failed (exit #{code}):\n#{out}")
    end
  end
end
