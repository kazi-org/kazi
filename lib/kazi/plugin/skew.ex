defmodule Kazi.Plugin.Skew do
  @moduledoc """
  T61.5 (ADR-0077 decision 2): detect version skew between the two independently
  upgradable kazi distribution channels -- the binary (brew/direct install) and
  the Claude Code plugin (marketplace, T61.3/T61.4) -- and surface it as a single
  advisory line at `SessionStart`.

  Because the two channels can be upgraded separately (an operator `brew upgrade
  kazi`s the binary but does not refresh the marketplace plugin, or vice versa),
  the teaching surface a session sees can silently lag the binary it actually
  drives. This check compares the locally-resolved `kazi version`
  (`Application.spec(:kazi, :vsn)`, the SAME source `kazi version` prints) against
  the installed plugin manifest's declared `version` (the `.claude-plugin/plugin.json`
  T61.3 generates, whose version IS the release version by lockstep) and returns:

    * `{:emit, line}` -- ONE line naming both versions and which channel to update,
      when the two disagree;
    * `:silent` -- when they match, when no kazi plugin is installed, or when the
      comparison source is unreachable/unreadable (fail-silent, never blocks).

  This rides the EXISTING `Kazi.Bus.Hook` `session-start` machinery (T55.9/ADR-0076):
  `Kazi.Bus.Hook.session_start/1` calls `check/1` inside the same bounded
  `Task`, so the file read here is already under the hook's hard wall-clock bound
  and its fail-silent-on-timeout contract. This module adds NO new hook type and
  starts NO process of its own -- it is a pure, best-effort read.

  ## Where an installed plugin lives on disk (Claude Code layout)

  Claude Code records installed plugins under `~/.claude/plugins/`:

    * `installed_plugins.json` maps `<name>@<marketplace>` to an `installPath`
      (a cached checkout, e.g. `~/.claude/plugins/cache/<marketplace>/<name>/<ver>/`);
    * each plugin's manifest is `<installPath>/.claude-plugin/plugin.json`, whose
      `version` field is the authoritative declared version (a marketplace entry
      may key on a git SHA, so we read the manifest, not the index's version).

  Discovery is two-tier and best-effort: consult `installed_plugins.json` for a
  `kazi@*` entry first, then fall back to scanning the plugin tree for a manifest
  whose `name` is `kazi`. Either tier missing (no file, no entry, malformed JSON)
  degrades to `:silent` -- a plugin that is simply not installed must never warn.
  """

  @plugin_name Kazi.Plugin.Manifest.plugin_name()

  @typedoc "The skew check either emits a one-line warning or stays silent."
  @type result :: {:emit, String.t()} | :silent

  @doc """
  The skew result for the current session.

  Opts (all optional; the unset ones resolve from the real environment):

    * `:local_version` -- the local binary version (test seam; defaults to the
      loaded app spec, the same value `kazi version` prints);
    * `:plugin_version` -- the installed plugin's declared version (test seam;
      short-circuits all on-disk discovery);
    * `:plugin_manifest_path` -- a direct path to a `plugin.json` to read (test
      seam; bypasses `installed_plugins.json` discovery);
    * `:claude_home` -- the Claude Code home dir (defaults to `~/.claude`); used
      to locate `plugins/installed_plugins.json` and the plugin tree.

  Returns `{:emit, line}` on mismatch, `:silent` otherwise. Any error anywhere in
  the read path collapses to `:silent`: a diagnostic must never break a session.
  """
  @spec check(keyword()) :: result()
  def check(opts \\ []) when is_list(opts) do
    with local when is_binary(local) <- local_version(opts),
         plugin when is_binary(plugin) <- plugin_version(opts),
         true <- local != plugin do
      {:emit, warning_line(local, plugin)}
    else
      _match_absent_or_equal -> :silent
    end
  rescue
    _ -> :silent
  catch
    _kind, _reason -> :silent
  end

  @doc """
  The exact one-line warning for a `local` binary vs `plugin` manifest mismatch:
  names BOTH versions and which channel to update. The direction is chosen by
  semver comparison -- the channel that is BEHIND is the one to update -- with a
  neutral "reconcile" fallback when either string is not valid semver.
  """
  @spec warning_line(String.t(), String.t()) :: String.t()
  def warning_line(local, plugin) when is_binary(local) and is_binary(plugin) do
    "kazi version skew: local binary #{local} vs installed Claude Code plugin " <>
      "#{plugin} -- #{channel_hint(local, plugin)}."
  end

  # Which channel is behind -> update that one. `:gt` means the binary is ahead,
  # so the plugin (marketplace) is stale; `:lt` means the plugin is ahead, so the
  # binary is stale. A non-semver string on either side yields a neutral hint.
  defp channel_hint(local, plugin) do
    case safe_compare(local, plugin) do
      :gt -> "update the plugin to match (`claude plugin update #{@plugin_name}`)"
      :lt -> "upgrade the kazi binary to match (`brew upgrade kazi`)"
      _ -> "reconcile the two channels so they match"
    end
  end

  defp safe_compare(a, b) do
    Version.compare(a, b)
  rescue
    _ -> :error
  end

  # The local binary version -- the same source `kazi version` prints. A test
  # seam wins; otherwise the loaded app spec (nil only if the app is not loaded,
  # which never happens in a running session -> :silent).
  defp local_version(opts) do
    case Keyword.get(opts, :local_version) do
      v when is_binary(v) ->
        v

      _absent ->
        case Application.spec(:kazi, :vsn) do
          nil -> nil
          vsn -> to_string(vsn)
        end
    end
  end

  # The installed plugin's declared version, resolved by (in order): the
  # `:plugin_version` seam, then a direct `:plugin_manifest_path`, then on-disk
  # discovery under the Claude Code plugin tree. Any miss -> nil (plugin absent
  # or unreadable -> the caller stays silent).
  defp plugin_version(opts) do
    cond do
      is_binary(opts[:plugin_version]) ->
        opts[:plugin_version]

      is_binary(opts[:plugin_manifest_path]) ->
        read_manifest_version(opts[:plugin_manifest_path])

      true ->
        case discover_manifest_path(opts) do
          path when is_binary(path) -> read_manifest_version(path)
          _none -> nil
        end
    end
  end

  # Read a `plugin.json` and return its `version` string, or nil on any failure
  # (missing file, unreadable, invalid JSON, missing/blank version field).
  defp read_manifest_version(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"version" => version}} <- Jason.decode(body),
         true <- is_binary(version) and version != "" do
      version
    else
      _unreadable_or_absent -> nil
    end
  end

  # Locate the installed kazi plugin's `plugin.json`. Tier 1: the authoritative
  # `installed_plugins.json` index (a `kazi@<marketplace>` key -> `installPath`).
  # Tier 2 (fallback): scan the plugin tree for a manifest whose `name` is kazi.
  defp discover_manifest_path(opts) do
    plugins_dir = Path.join(claude_home(opts), "plugins")

    from_index(plugins_dir) || from_scan(plugins_dir)
  end

  defp claude_home(opts) do
    case Keyword.get(opts, :claude_home) do
      dir when is_binary(dir) -> Path.expand(dir)
      _absent -> Path.expand("~/.claude")
    end
  end

  # Tier 1: read `installed_plugins.json`, find the first `kazi@...` key, and map
  # its `installPath` to `<installPath>/.claude-plugin/plugin.json` if it exists.
  defp from_index(plugins_dir) do
    index_path = Path.join(plugins_dir, "installed_plugins.json")

    with {:ok, body} <- File.read(index_path),
         {:ok, %{"plugins" => plugins}} when is_map(plugins) <- Jason.decode(body),
         {_key, entries} <- Enum.find(plugins, &kazi_entry?/1),
         install_path when is_binary(install_path) <- install_path(entries) do
      manifest = Path.join([install_path, ".claude-plugin", "plugin.json"])
      if File.exists?(manifest), do: manifest, else: nil
    else
      _no_index_or_entry -> nil
    end
  end

  # A `kazi@<marketplace>` key identifies our plugin regardless of marketplace.
  defp kazi_entry?({key, _entries}) when is_binary(key),
    do: key == @plugin_name or String.starts_with?(key, @plugin_name <> "@")

  defp kazi_entry?(_other), do: false

  # An entry's value is a list of install records (scopes); take the first with a
  # string `installPath`.
  defp install_path(entries) when is_list(entries) do
    Enum.find_value(entries, fn
      %{"installPath" => p} when is_binary(p) -> p
      _ -> nil
    end)
  end

  defp install_path(_other), do: nil

  # Tier 2: scan for any `.claude-plugin/plugin.json` under the plugin tree whose
  # manifest `name` is `kazi`. Bounded by the plugin tree's size; best-effort.
  defp from_scan(plugins_dir) do
    # `match_dot: true` is REQUIRED: the manifest lives under the dot-prefixed
    # `.claude-plugin/` directory, which `Path.wildcard` skips by default.
    plugins_dir
    |> Path.join("**/.claude-plugin/plugin.json")
    |> Path.wildcard(match_dot: true)
    |> Enum.find(&kazi_manifest?/1)
  end

  defp kazi_manifest?(path) do
    case File.read(path) do
      {:ok, body} ->
        match?({:ok, %{"name" => @plugin_name}}, Jason.decode(body))

      _unreadable ->
        false
    end
  end
end
