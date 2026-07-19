defmodule Kazi.Providers.DocsUpdated do
  @moduledoc """
  The `:docs_updated` predicate provider (T44.8, ADR-0034): productizes the
  "**docs land with the code**" discipline as a gate — a surface-change heuristic
  ported verbatim from the T29.1 `docs_with_code_guard.sh` CI check.

  When the goal's diff-vs-base touches a USER-FACING SURFACE — a CLI command/flag
  (`lib/kazi/cli.ex`, `lib/kazi/cli/`), a predicate provider
  (`lib/kazi/providers/`), a public behaviour (`predicate_provider.ex`,
  `harness_adapter.ex`), or the MCP surface (`lib/kazi/mcp/`) — the SAME diff must
  EITHER also touch docs (`docs/`, `README.md`, `AGENTS.md`) OR carry an explicit
  `[no-docs] <reason>` marker in a commit message. Missing BOTH is `:fail`, naming
  the surface files that triggered the requirement.

  A diff that touches NO surface passes VACUOUSLY — the gate simply does not apply
  (an internal/private refactor is not a docs violation, so it is never a false
  positive). A `:pass` records WHY (docs present, or the captured `[no-docs]`
  reason); a `:fail` names the surface files.

  Like the other diff-scanning gates (`:cve`, `:no_stubs`) the verdict is read
  from PARSED git output, not an exit code. It examines the COMMITTED range
  `base..HEAD` (surface files + commit messages), since the `[no-docs]` escape
  lives in a commit message and landing commits its work.

  ## Config

    * `:base` — the base ref to diff against. Default: `Kazi.ScopeDiff.base_ref/1`
      (merge-base with `origin/main`, else the repo root commit, else the empty
      tree).
    * `:surface_patterns` — override the surface-defining path regexes (anchored
      strings). Default the six surface paths above.
    * `:doc_patterns` — override the doc path regexes. Default `docs/`, `README.md`,
      `AGENTS.md`.

  ## Context

  `context[:workspace]` is the git repo to scan (`git -C`). Defaults to the current
  directory. A non-git workspace is an `:error`, never a false `:pass`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult, ScopeDiff}

  # The T29.1 guard's surface-defining code paths (kept deliberately narrow so a
  # pure internal refactor elsewhere in lib/ does not trip the gate).
  @default_surface_patterns [
    "^lib/kazi/cli\\.ex$",
    "^lib/kazi/cli/",
    "^lib/kazi/providers/",
    "^lib/kazi/predicate_provider\\.ex$",
    "^lib/kazi/harness_adapter\\.ex$",
    "^lib/kazi/mcp/"
  ]

  # Paths that count as a documentation update.
  @default_doc_patterns [
    "^docs/",
    "^README\\.md$",
    "^AGENTS\\.md$"
  ]

  @no_docs_marker "[no-docs]"
  @surface_sample_limit 50

  @doc "The default surface-defining path patterns (the T29.1 guard's set)."
  @spec default_surface_patterns() :: [String.t()]
  def default_surface_patterns, do: @default_surface_patterns

  @impl true
  def evaluate(%Predicate{kind: :docs_updated, config: config}, context) do
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
    case changed_files(workspace, base) do
      {:error, reason} ->
        PredicateResult.error(%{reason: {:git_diff_failed, reason}, base: base})

      {:ok, files} ->
        surface = compile(surface_patterns(config))
        docs = compile(doc_patterns(config))
        decide(files, surface, docs, workspace, base)
    end
  end

  defp decide(files, surface_re, doc_re, workspace, base) do
    surface_files = Enum.filter(files, &matches_any?(&1, surface_re))

    cond do
      # No user-facing surface changed — the gate does not apply. Vacuous pass.
      surface_files == [] ->
        PredicateResult.pass(%{applicable: false, reason: :no_surface_change, base: base})

      # A docs change rides in the same diff.
      Enum.any?(files, &matches_any?(&1, doc_re)) ->
        PredicateResult.pass(%{
          applicable: true,
          reason: :docs_present,
          surface_files: Enum.take(Enum.sort(surface_files), @surface_sample_limit),
          base: base
        })

      # No docs — a justified [no-docs] marker in a commit message is the escape.
      true ->
        case no_docs_justification(workspace, base) do
          {:ok, justification} ->
            PredicateResult.pass(%{
              applicable: true,
              reason: :no_docs_marker,
              justification: justification,
              surface_files: Enum.take(Enum.sort(surface_files), @surface_sample_limit),
              base: base
            })

          :none ->
            fail(surface_files, base)
        end
    end
  end

  defp fail(surface_files, base) do
    ordered = Enum.sort(surface_files)

    evidence = %{
      applicable: true,
      reason: :missing_docs,
      surface_files: Enum.take(ordered, @surface_sample_limit),
      count: length(ordered),
      base: base
    }

    PredicateResult.new(:fail, evidence,
      score: length(ordered) * 1.0,
      direction: :lower_better,
      diagnostics: Enum.map(Enum.take(ordered, @surface_sample_limit), &diagnostic/1)
    )
  end

  defp diagnostic(file) do
    Kazi.Evidence.new(
      rule: "docs_updated",
      level: :error,
      file: file,
      message:
        "user-facing surface changed but no docs updated and no [no-docs] justification: #{file}"
    )
  end

  # --- git plumbing ------------------------------------------------------------

  # The committed range's changed paths (base..HEAD), mirroring the T29.1 guard's
  # `git diff --name-only <base>...HEAD`.
  defp changed_files(workspace, base) do
    case git(workspace, ["diff", "--name-only", base, "HEAD"]) do
      {:ok, out} -> {:ok, String.split(out, "\n", trim: true)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The FIRST `[no-docs] <reason>` marker across the branch's commit messages
  # (base..HEAD). Returns `{:ok, reason}` (the text after the marker, trimmed) or
  # `:none`. An empty reason is still an accepted marker (mirrors the guard, which
  # only checks presence) — reported as `""`.
  defp no_docs_justification(workspace, base) do
    case git(workspace, ["log", "--format=%B", base <> "..HEAD"]) do
      {:ok, log} ->
        log
        |> String.split("\n")
        |> Enum.find_value(:none, fn line ->
          case String.split(line, @no_docs_marker, parts: 2) do
            [_before, after_marker] -> {:ok, String.trim(after_marker)}
            _ -> nil
          end
        end)

      {:error, _} ->
        :none
    end
  end

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

  # --- config ------------------------------------------------------------------

  defp base_ref(config, workspace) do
    case Map.get(config, :base) do
      base when is_binary(base) and base != "" -> base
      _ -> ScopeDiff.base_ref(workspace)
    end
  end

  defp surface_patterns(config),
    do: patterns(config, :surface_patterns, @default_surface_patterns)

  defp doc_patterns(config), do: patterns(config, :doc_patterns, @default_doc_patterns)

  defp patterns(config, key, default) do
    case Map.get(config, key) do
      [_ | _] = list -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      _ -> default
    end
  end

  defp compile(patterns), do: Enum.map(patterns, &Regex.compile!/1)

  defp matches_any?(path, regexes), do: Enum.any?(regexes, &Regex.match?(&1, path))
end
