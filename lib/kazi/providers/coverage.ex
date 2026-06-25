defmodule Kazi.Providers.Coverage do
  @moduledoc """
  The `:coverage` predicate provider (T32.8, ADR-0043): patch coverage meets a
  target AND the project's coverage does not regress.

  Coverage is named in the `Kazi.Ratchet` docstring as the headline ratchet
  instance, and that is exactly what this provider is — it does NOT re-derive the
  baseline machinery. It runs TWO ratchet comparisons on `Kazi.Ratchet`:

    * **patch** — the coverage of the lines this change TOUCHED, against a fixed
      `target` (a literal baseline, `direction: :higher_better`,
      `allowed_regression: 0`). New code must be covered: a patch that drops below
      `target` fails. This is the dimension a passing test suite still misses —
      project coverage can stay flat while a new, untested function lands.
    * **project** (optional) — total project coverage, against a `project_baseline`
      (`"stored"`/`"prior"`, a git ref, or a number) so the WHOLE codebase's
      coverage may only improve (a `Kazi.Ratchet`-as-ADR-0042-guard). Absent, only
      the patch dimension gates.

  The predicate passes iff BOTH dimensions pass (or `project` is omitted). Either
  dimension erroring (a broken coverage tool, an unresolved baseline ref) makes the
  whole predicate `:error`, never a silent pass. The headline `score` is the patch
  coverage, `direction: :higher_better`, so the loop reads "is new code getting
  more covered?" without coverage-specific knowledge (envelope v2, ADR-0041). The
  convergence gate is unchanged: a coverage predicate contributes only its `:pass`.

  ## Config

    * `:patch` — a metric table (`Kazi.Metric`: `cmd` required, `args`, `env`,
      `path`, `timeout_ms`) emitting the PATCH coverage percentage. Required.
    * `:target` — the patch-coverage floor (a number, e.g. `80.0`). Required.
    * `:project` — an OPTIONAL metric table emitting TOTAL project coverage. When
      present the project dimension gates too.
    * `:project_baseline` — the project bar: `"stored"`/`"prior"` (default — the
      last passing value, tightened on a pass), a git ref, or a number.
    * `:project_allowed_regression` — the tolerated project-coverage drop (number,
      default `0` — "may only improve").
    * `:store_dir` — overrides the stored-baseline directory (defaults to the
      workspace `.kazi`).

  The loader validates these at load time (a missing `patch.cmd`, a missing
  `target`), so a mis-declared coverage gate fails loudly at load, not at dispatch.
  See `kazi schema coverage`.

  ## Context

  `context[:workspace]` is where the coverage tools run and a git-ref baseline
  resolves; `context[:ratchet_store_dir]` overrides the stored-baseline directory.

  ## Evidence

  The result carries the proof a fixer needs: the `:patch_coverage`, the `:target`,
  and — when the project dimension is present — the `:project_coverage`, the
  resolved `:project_baseline`, and the project `:regression`. An `:error` carries
  the failing dimension and its `:reason`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult, Ratchet}

  # The metric sub-table keys we lift from string to atom — a goal file's inline
  # table arrives string-keyed (the loader only atomizes top-level predicate keys).
  # A fixed set so we never unbounded-atomize goal-file input (mirrors
  # Kazi.Providers.Ratchet).
  @metric_keys ~w(cmd args env path timeout_ms)

  @impl true
  def evaluate(%Predicate{kind: :coverage, id: id, config: config}, context) do
    patch_result =
      Ratchet.evaluate(
        %{
          id: "#{id}:patch",
          metric: normalize_metric(Map.get(config, :patch)),
          baseline: Map.get(config, :target),
          direction: :higher_better,
          allowed_regression: 0.0
        }
        |> maybe_put_store_dir(config),
        context
      )

    case Map.get(config, :project) do
      nil -> result(patch_result, nil, context)
      project -> result(patch_result, project_result(id, project, config, context), context)
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  defp project_result(id, project, config, context) do
    Ratchet.evaluate(
      %{
        id: "#{id}:project",
        metric: normalize_metric(project),
        baseline: Map.get(config, :project_baseline, "stored"),
        direction: :higher_better,
        allowed_regression: Map.get(config, :project_allowed_regression, 0.0)
      }
      |> maybe_put_store_dir(config),
      context
    )
  end

  # Combine the patch (and optional project) ratchet outcomes into one envelope-v2
  # result. An error in EITHER dimension is an :error (never a silent pass); the
  # predicate passes iff every present dimension passes. The headline score is the
  # patch coverage so the loop reads new-code coverage as the gradient.
  defp result(%Ratchet.Result{status: :error} = patch, _project, _context) do
    PredicateResult.error(%{dimension: :patch, reason: patch.reason})
  end

  defp result(_patch, %Ratchet.Result{status: :error} = project, _context) do
    PredicateResult.error(%{dimension: :project, reason: project.reason})
  end

  defp result(%Ratchet.Result{} = patch, project, _context) do
    evidence =
      %{
        patch_coverage: patch.signal,
        target: patch.baseline,
        patch_status: patch.status
      }
      |> with_project(project)

    status = combined_status(patch, project)

    PredicateResult.new(status, evidence,
      score: numeric(patch.signal),
      direction: :higher_better
    )
  end

  defp combined_status(%Ratchet.Result{status: :pass}, nil), do: :pass
  defp combined_status(%Ratchet.Result{status: status}, nil), do: status

  defp combined_status(%Ratchet.Result{status: :pass}, %Ratchet.Result{status: :pass}), do: :pass
  defp combined_status(_patch, _project), do: :fail

  defp with_project(evidence, nil), do: evidence

  defp with_project(evidence, %Ratchet.Result{} = project) do
    Map.merge(evidence, %{
      project_coverage: project.signal,
      project_baseline: project.baseline,
      project_baseline_source: project.baseline_source,
      project_regression: project.regression,
      project_status: project.status
    })
  end

  # =============================================================================
  # Config normalization (goal-file shapes -> Kazi.Metric config)
  # =============================================================================

  defp normalize_metric(metric) when is_map(metric) do
    Map.new(metric, fn {key, value} -> {metric_key(key), value} end)
  end

  defp normalize_metric(_), do: %{}

  defp metric_key(key) when is_atom(key), do: key

  defp metric_key(key) when is_binary(key) do
    if key in @metric_keys, do: String.to_atom(key), else: key
  end

  defp maybe_put_store_dir(ratchet_config, config) do
    case Map.get(config, :store_dir) do
      dir when is_binary(dir) and dir != "" -> Map.put(ratchet_config, :store_dir, dir)
      _ -> ratchet_config
    end
  end

  defp numeric(n) when is_integer(n), do: n * 1.0
  defp numeric(n) when is_float(n), do: n
  defp numeric(_), do: nil
end
