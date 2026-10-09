defmodule Kazi.Plugin.Manifest do
  alias Kazi.MCP.ClientConfig
  alias Kazi.Teach.InstallSkill

  # The plugin's kebab-case identifier (used for namespacing components). Kept
  # equal to the skill name so `kazi:kazi` never appears -- the skill under
  # `skills/kazi/` carries frontmatter `name: kazi` already.
  @plugin_name "kazi"

  # Static metadata mirrored from mix.exs's package block (Apache-2.0, the
  # public GitHub repo). Genericized/public only -- no internal specifics
  # (ADR-0034). The JSON Schema URL is advisory (Claude Code ignores it at load
  # time) but powers editor validation and `claude plugin validate`.
  @schema_url "https://json.schemastore.org/claude-code-plugin-manifest.json"
  @repository "https://github.com/kazi-org/kazi"
  @license "Apache-2.0"
  @description "Drive kazi -- an outer-loop reconciliation controller that " <>
                 "converges a software goal to machine-checkable acceptance " <>
                 "predicates -- from Claude Code: the kazi skill, the kazi MCP " <>
                 "server in one install."
  @keywords ["kazi", "reconciliation", "predicates", "agent", "mcp"]

  # The plugin subdirectory the skill content is written under. Claude Code's
  # default `skills/` scan discovers `skills/<name>/SKILL.md`, so no `skills`
  # manifest field is needed and the invocation name is the SKILL.md frontmatter
  # `name` (stable across marketplace updates).
  @skill_subdir Path.join("skills", @plugin_name)

  # The manifest lives under `.claude-plugin/` (the reference is explicit: only
  # plugin.json goes there; every component dir is at the plugin root).
  @manifest_path Path.join(".claude-plugin", "plugin.json")

  @doc "The plugin's kebab-case name (`\"kazi\"`)."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc "The manifest's path within the bundle (`.claude-plugin/plugin.json`)."
  @spec manifest_path() :: String.t()
  def manifest_path, do: @manifest_path

  @doc """
  The plugin manifest as an Elixir map (the decoded `plugin.json`).

  Opts:

    * `:version` -- the plugin version string. Defaults to the running kazi
      version (`Application.spec(:kazi, :vsn)`); the release pipeline passes the
      just-built release tag so the plugin version IS the binary version
      (ADR-0077 lockstep). Tests pass a fixed value for determinism.

  The `mcpServers` value is rendered from `ClientConfig`.
  """
  @spec manifest(keyword()) :: map()
  def manifest(opts \\ []) do
    version = Keyword.get(opts, :version) |> normalize_version()

    %{
      "$schema" => @schema_url,
      "name" => @plugin_name,
      "displayName" => "kazi",
      "version" => version,
      "description" => @description,
      "author" => %{"name" => "kazi-org", "url" => @repository},
      "homepage" => @repository,
      "repository" => @repository,
      "license" => @license,
      "keywords" => @keywords,
      "mcpServers" => mcp_servers()
    }
  end

  @doc """
  The manifest as pretty-printed JSON with a trailing newline (the exact bytes
  written to `.claude-plugin/plugin.json`). Deterministic for a fixed version.
  """
  @spec manifest_json(keyword()) :: String.t()
  def manifest_json(opts \\ []) do
    Jason.encode!(manifest(opts), pretty: true) <> "\n"
  end

  @doc """
  The MCP server registration block, identical in shape to what
  `init --with-mcp` writes (`ClientConfig.config/0`'s `mcpServers` value):

      %{"kazi" => %{"command" => "kazi", "args" => ["mcp"]}}
  """
  @spec mcp_servers() :: map()
  def mcp_servers, do: %{ClientConfig.server_name() => ClientConfig.server_entry()}

  @doc """
  The full plugin bundle as an ordered list of `{relative_path, content}` pairs:

      .claude-plugin/plugin.json   -- the manifest
      skills/kazi/SKILL.md         -- the router (InstallSkill.docs/0)
      skills/kazi/AUTHORING.md
      skills/kazi/RECIPES.md

  `LOCAL.md` is deliberately absent (ADR-0077 decision 3): a plugin update
  replaces the skill directory wholesale, so operator customization must live at
  the stable path outside the bundle. Deterministic for a fixed `:version`.
  """
  @spec bundle(keyword()) :: [{String.t(), String.t()}]
  def bundle(opts \\ []) do
    skill_files =
      for {name, content} <- InstallSkill.docs() do
        {Path.join(@skill_subdir, name), content}
      end

    [{@manifest_path, manifest_json(opts)} | skill_files]
  end

  @doc """
  Writes the full `bundle/1` under `dir` (creating parent directories), for
  `mix kazi.plugin` and the release pipeline. Returns `{:ok, dir}` with the
  plugin root, or `{:error, reason}` on the first write that fails.

  Opts are passed through to `bundle/1` (notably `:version`).
  """
  @spec write(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def write(dir, opts \\ []) when is_binary(dir) do
    root = Path.expand(dir)

    Enum.reduce_while(bundle(opts), {:ok, root}, fn {rel, content}, acc ->
      path = Path.join(root, rel)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, content) do
        {:cont, acc}
      else
        {:error, reason} -> {:halt, {:error, {:write_failed, path, reason}}}
      end
    end)
  end

  # A caller-supplied version wins; otherwise read the loaded app spec (set from
  # mix.exs at build time, embedded in the release). "unknown" only if the app
  # is not loaded (never in practice) -- never a clock-derived value, so the
  # bundle stays deterministic.
  defp normalize_version(nil) do
    case Application.spec(:kazi, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp normalize_version(version) when is_binary(version), do: version
end
