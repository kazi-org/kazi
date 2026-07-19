defmodule Kazi.Providers.Ratchet do
  @moduledoc """
  The `:ratchet` predicate provider (T32.3, ADR-0041 decision 4): the config-only
  realization of the first-class RATCHET mode.

  A ratchet predicate asserts a metric stays within an allowed regression of a
  baseline — `signal` no more than `allowed_regression` worse than `baseline`,
  interpreted through `direction`. Coverage, perf, and binary/bundle size are the
  SAME predicate (`signal vs baseline within an allowed regression`); this
  provider makes each a goal-file config, not a kazi release, by handing its
  declared `metric` + `baseline` to the shared `Kazi.Ratchet` machinery.

  It reports `score = signal` and a `direction` (envelope v2, ADR-0041), so the
  loop's progress classifier and stuck-detector read the gradient WITHOUT
  per-provider knowledge. The convergence gate is unchanged: a ratchet still
  contributes only its `:pass`.

  ## Config

    * `:metric` — an inline table declaring how to produce the signal
      (`Kazi.Metric`): `cmd` (required), `args`, `env`, `path` (a `Kazi.JSONPath`
      subset over JSON stdout; absent means stdout IS the number), `timeout_ms`.
    * `:baseline` — the bar: a NUMBER (a fixed threshold), `"stored"`/`"prior"`
      (the metric's own last passing value, persisted between runs and tightened
      on a pass — first run seeds it), or a GIT REF (`"HEAD~1"`, `"main"`: the
      metric recomputed at that ref in a throwaway worktree).
    * `:direction` — `"higher_better"` (coverage, mutation score: down is worse)
      or `"lower_better"` (size, latency, lint count: up is worse). Required.
    * `:allowed_regression` — the tolerated worsening (number, default `0`). `0`
      means "may only improve" (the ADR-0042 guard substrate).

  The loader validates these at load time, so a missing `metric.cmd`, an unknown
  `direction`, or a missing `baseline` fails loudly at load, not at dispatch. See
  `kazi schema ratchet`.

  ## Context

  `context[:workspace]` is where the metric runs and a git-ref baseline resolves;
  `context[:ratchet_store_dir]` overrides the stored-baseline directory.

  ## Evidence

  The result carries the proof a fixer needs: the `:signal`, the resolved
  `:baseline`, the direction-interpreted `:regression`, the `:allowed_regression`,
  the `:direction`, the `:baseline_source`, and whether a new baseline was
  `:stored`. An `:error` (a broken metric, an unresolved ref) carries a `:reason`
  and is never read as a pass.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult, Ratchet}

  # The metric sub-table keys we lift from string to atom (a goal file's inline
  # table arrives string-keyed; the loader only atomizes top-level predicate
  # keys). A fixed set so we never unbounded-atomize goal-file input.
  @metric_keys ~w(cmd args env path timeout_ms)

  @directions %{"higher_better" => :higher_better, "lower_better" => :lower_better}

  @impl true
  def evaluate(%Predicate{kind: :ratchet, id: id, config: config}, context) do
    ratchet_config = %{
      id: id,
      metric: normalize_metric(Map.get(config, :metric)),
      baseline: Map.get(config, :baseline),
      direction: direction_atom(Map.get(config, :direction)),
      allowed_regression: Map.get(config, :allowed_regression, 0.0)
    }

    ratchet_config
    |> maybe_put_store_dir(config)
    |> Ratchet.evaluate(context)
    |> to_predicate_result()
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  # Map a Kazi.Ratchet.Result onto the envelope-v2 PredicateResult: score = signal,
  # the direction so the loop reads progress, and the comparison as evidence.
  defp to_predicate_result(%Ratchet.Result{status: :error} = r) do
    PredicateResult.error(%{
      reason: r.reason,
      direction: r.direction,
      allowed_regression: r.allowed_regression
    })
  end

  defp to_predicate_result(%Ratchet.Result{} = r) do
    evidence = %{
      signal: r.signal,
      baseline: r.baseline,
      regression: r.regression,
      allowed_regression: r.allowed_regression,
      direction: r.direction,
      baseline_source: r.baseline_source,
      stored: r.stored?
    }

    PredicateResult.new(r.status, evidence,
      score: numeric(r.signal),
      direction: r.direction
    )
  end

  # =============================================================================
  # Config normalization (goal-file shapes -> Kazi.Ratchet config)
  # =============================================================================

  defp normalize_metric(metric) when is_map(metric) do
    Map.new(metric, fn {key, value} -> {metric_key(key), value} end)
  end

  defp normalize_metric(_), do: %{}

  defp metric_key(key) when is_atom(key), do: key

  defp metric_key(key) when is_binary(key) do
    if key in @metric_keys, do: String.to_atom(key), else: key
  end

  defp direction_atom(direction) when is_atom(direction) and not is_nil(direction), do: direction
  defp direction_atom(direction) when is_binary(direction), do: Map.get(@directions, direction)
  defp direction_atom(_), do: nil

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
