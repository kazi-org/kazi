defmodule Mix.Tasks.Kazi.Plugin do
  @shortdoc "Render the kazi Claude Code plugin bundle (manifest + skill + hooks + MCP)"

  @moduledoc """
  The CI entry point that renders the `kazi` Claude Code plugin bundle (T61.3,
  ADR-0077):

      mix kazi.plugin --out <dir> [--version <v>]

  It writes a self-contained plugin directory under `<dir>`:

      .claude-plugin/plugin.json   -- the manifest (metadata + inline MCP + hooks)
      skills/kazi/SKILL.md         -- the router
      skills/kazi/AUTHORING.md
      skills/kazi/RECIPES.md

  Every byte is rendered from the SAME single sources of truth the explicit
  installers use (`Kazi.Plugin.Manifest`, which reads `InstallSkill.docs/0`,
  `ClientConfig.server_entry/0`, and `InstallHooks.hook_commands/0`) -- this
  task adds no teaching or config logic of its own.

  With no `--version`, the plugin version is the running kazi version (from the
  app spec / mix.exs), so the plugin version tracks the binary. The release
  pipeline (T61.4) passes the just-built release tag with `--version` so the
  published plugin version IS the binary release version (ADR-0077 lockstep).

  The render is DETERMINISTIC: the same version yields a byte-identical bundle
  (no timestamps, no randomness), so a re-run over an unchanged version is a
  no-op diff.

  ## Flags

    * `--out <dir>` (required) -- the plugin root directory to write.
    * `--version <v>` -- override the plugin version (default: the kazi version).
  """

  use Mix.Task

  alias Kazi.Plugin.Manifest

  @switches [out: :string, version: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
      invalid != [] ->
        Mix.raise("unknown option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")

      is_nil(opts[:out]) ->
        Mix.raise("--out <dir> is required (the plugin root directory to write)")

      true ->
        write(opts)
    end
  end

  defp write(opts) do
    render_opts = if opts[:version], do: [version: opts[:version]], else: []

    case Manifest.write(opts[:out], render_opts) do
      {:ok, root} ->
        version = Manifest.manifest(render_opts)["version"]
        Mix.shell().info("Wrote kazi plugin v#{version} to #{root}")

      {:error, {:write_failed, path, reason}} ->
        Mix.raise("could not write #{path}: #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("could not write the plugin bundle: #{inspect(reason)}")
    end
  end
end
