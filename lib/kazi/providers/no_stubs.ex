defmodule Kazi.Providers.NoStubs do
  @moduledoc """
  The `:no_stubs` predicate provider (T44.6, ADR-0043 shape): a deterministic
  DIFF SCANNER that fails when the goal's diff-vs-base introduces a
  stub/placeholder/hardcoded-return marker into a NON-TEST (production) file.

  This productizes the ZERO-STUB POLICY — "no stub/mock/fake/hardcoded-return in
  production code" — from a manual self-check into an ACTUAL predicate a goal-file
  can declare, so the loop gates on it objectively instead of trusting the agent.

  Like `:cve`, the verdict is read from PARSED output, not an exit code: the
  "tool" is `git diff <base>`, and the finding is a stub marker on an ADDED line
  (a `+` line, tracked to its new-file line number) in a production file. It reuses
  the tested unified-diff parser (`Kazi.Enforcement.DiffGuard.file_changes/1`) and
  the shared base-ref detection (`Kazi.ScopeDiff.base_ref/1`) rather than
  re-implementing either.

  ## What counts

    * **Only ADDED lines** — a pure deletion or a context line carries no marker,
      so the scan never fails on pre-existing stubs the diff did not introduce.
    * **Only NON-TEST files** — stubs/mocks/fakes are legitimate in tests. A path
      under a `test/` directory or ending `_test.exs`/`_test.ex` is exempt (plus
      any `:exclude` prefixes the goal declares).
    * **The markers** (default, case-insensitive, left-word-boundary so `MockServer`
      / `stub_line` match): `stub`, `mock`, `fake`, `dummy`, `placeholder`, `todo`,
      `fixme`, `notimplemented`. Override with `:patterns`.

  Any production-reachable hit is `:fail` with `file:line` evidence (the marker +
  the offending snippet); a clean diff is `:pass`. `score` is the hit count
  (`direction: :lower_better`).

  ## Config

    * `:patterns` — the marker list (strings, matched case-insensitively). Default
      the eight above.
    * `:base` — the base ref to diff against. Default: `Kazi.ScopeDiff.base_ref/1`
      (merge-base with `origin/main`, else the root commit, else the empty tree).
    * `:exclude` — extra path PREFIXES to exempt beyond the built-in test-file rule
      (e.g. `["priv/examples/"]`). Default `[]`.

  ## Context

  `context[:workspace]` is the git repo to scan (`git -C`). Defaults to the current
  directory. A non-git workspace is an `:error` (the scan could not run), never a
  false `:pass`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.Enforcement.DiffGuard
  alias Kazi.{Predicate, PredicateResult, ScopeDiff}

  @default_patterns ~w(stub mock fake dummy placeholder todo fixme notimplemented)
  @finding_sample_limit 50
  @snippet_cap 200

  @doc "The default stub/placeholder markers scanned for."
  @spec default_patterns() :: [String.t()]
  def default_patterns, do: @default_patterns

  @impl true
  def evaluate(%Predicate{kind: :no_stubs, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()

    cond do
      not is_binary(workspace) ->
        PredicateResult.error(%{reason: :no_workspace})

      not git_repo?(workspace) ->
        PredicateResult.error(%{reason: :not_a_git_repo, workspace: workspace})

      true ->
        base = base_ref(config, workspace)
        scan(workspace, base, config)
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  defp scan(workspace, base, config) do
    case git(workspace, ["diff", base]) do
      {:error, reason} ->
        PredicateResult.error(%{reason: {:git_diff_failed, reason}, base: base})

      {:ok, diff} ->
        regex = pattern_regex(patterns(config))
        excludes = excludes(config)

        {hits, scanned} =
          diff
          |> DiffGuard.file_changes()
          |> Enum.reject(&exempt?(&1.file, excludes))
          |> collect_hits(regex)

        decide(hits, scanned, base)
    end
  end

  # Walk each production file's ADDED lines for a marker; accumulate {file, line,
  # pattern, snippet} hits and the count of production files scanned.
  defp collect_hits(file_changes, regex) do
    Enum.reduce(file_changes, {[], 0}, fn %{file: file, added: added}, {hits, scanned} ->
      file_hits =
        for {line, content} <- added, match = match_marker(content, regex), match != nil do
          %{file: file, line: line, pattern: match, snippet: snippet(content)}
        end

      {file_hits ++ hits, scanned + 1}
    end)
  end

  defp match_marker(content, regex) do
    case Regex.run(regex, content) do
      [matched | _] -> String.downcase(matched)
      nil -> nil
    end
  end

  defp decide([], scanned, base) do
    PredicateResult.pass(%{hits: 0, scanned_files: scanned, base: base})
  end

  defp decide(hits, scanned, base) do
    ordered = Enum.sort_by(hits, &{&1.file, &1.line})
    count = length(ordered)

    evidence = %{
      hits: Enum.take(ordered, @finding_sample_limit),
      count: count,
      scanned_files: scanned,
      base: base
    }

    PredicateResult.new(:fail, evidence,
      score: count * 1.0,
      direction: :lower_better,
      diagnostics: Enum.map(Enum.take(ordered, @finding_sample_limit), &diagnostic/1)
    )
  end

  defp diagnostic(hit) do
    Kazi.Evidence.new(
      rule: "no_stubs:#{hit.pattern}",
      level: :error,
      file: hit.file,
      line: hit.line,
      message:
        "stub/placeholder marker '#{hit.pattern}' added in a production file: #{hit.snippet}"
    )
  end

  # --- classification + config -------------------------------------------------

  # A production file is anything NOT a test file and not under a declared exclude
  # prefix. Test files (stubs/mocks legitimate there) are a path under a `test/`
  # directory or a `_test.ex(s)` file.
  defp exempt?(path, excludes) do
    test_file?(path) or Enum.any?(excludes, &String.starts_with?(path, &1))
  end

  defp test_file?(path) do
    String.starts_with?(path, "test/") or
      String.contains?(path, "/test/") or
      String.ends_with?(path, "_test.exs") or
      String.ends_with?(path, "_test.ex")
  end

  defp patterns(config) do
    case Map.get(config, :patterns) do
      [_ | _] = list -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      _ -> @default_patterns
    end
  end

  defp excludes(config) do
    case Map.get(config, :exclude) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp base_ref(config, workspace) do
    case Map.get(config, :base) do
      base when is_binary(base) and base != "" -> base
      _ -> ScopeDiff.base_ref(workspace)
    end
  end

  # Case-insensitive, left-word-boundary alternation so `MockServer` / `stub_line`
  # match but `stubborn`-style prose is minimized to a deliberate design trade-off
  # (the marker list is configurable when a repo needs to tune it).
  defp pattern_regex(patterns) do
    alternation = patterns |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    Regex.compile!("\\b(?:#{alternation})", "i")
  end

  defp snippet(content) do
    trimmed = String.trim(content)

    if String.length(trimmed) > @snippet_cap do
      String.slice(trimmed, 0, @snippet_cap) <> "…"
    else
      trimmed
    end
  end

  # --- git plumbing ------------------------------------------------------------

  defp git_repo?(workspace) do
    match?({:ok, _}, git(workspace, ["rev-parse", "--is-inside-work-tree"]))
  end

  defp git(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    _, _ -> {:error, :git_crashed}
  end
end
