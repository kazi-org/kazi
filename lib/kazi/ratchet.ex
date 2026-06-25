defmodule Kazi.Ratchet do
  @moduledoc """
  The baseline-comparison machinery built ONCE so coverage, perf, and binary/bundle
  size are CONFIGS of one mode, not three bespoke providers (T32.3, ADR-0041
  decision 4).

  A ratchet asserts a metric stays within an allowed regression of a baseline:

  > it passes iff the metric moved no more than `allowed_regression` in the
  > WORSENING direction.

  The direction makes the single rule serve both shapes — coverage and mutation
  score are `:higher_better` (down is worse); binary size, p95 latency, and a
  lint-finding count are `:lower_better` (up is worse). With
  `allowed_regression = 0` the metric "may only improve," which is exactly the
  anti-gaming guard substrate ADR-0042 builds on (coverage/test-count may not
  drop).

  This module owns the whole cycle ADR-0041 names — resolve the baseline, compare,
  store the new value — so a future first-class provider (`:coverage`, `:static`,
  T32.7/T32.8) reuses it by handing in its own metric config rather than
  re-deriving the comparison. `Kazi.Providers.Ratchet` is the thin config-only
  realization.

  ## Baseline sources

  The `baseline` config selects how the bar is resolved:

    * a NUMBER (`baseline = 80.0`) — a fixed literal threshold; never persisted.
    * `"stored"` (or `"prior"`) — the metric's own last passing value, persisted
      in `Kazi.Ratchet.Store`. The FIRST run has no stored value: it SEEDS the
      baseline (passes, records the signal) so the next run has a bar. On a pass
      the stored baseline TIGHTENS toward the improving side (`max` for
      higher-better, `min` for lower-better); a fail leaves it untouched so the
      agent must climb back.
    * any other string — a git ref (`"HEAD~1"`, `"main"`, `"origin/main"`): the
      metric is recomputed against that ref in a throwaway detached worktree, so
      "no regression vs main" is a real, recomputed comparison; never persisted.

  ## Result

  `evaluate/2` returns a `Kazi.Ratchet.Result` carrying `status`
  (`:pass | :fail | :error`), the `signal`, the resolved `baseline`, the
  direction-interpreted `regression`, the `allowed_regression`, the `direction`,
  the `baseline_source` (`:literal | :stored | :git_ref | :seed`), whether a new
  baseline was `stored?`, and a `reason` on `:error`.
  """

  alias Kazi.Ratchet.Store

  defmodule Result do
    @moduledoc "The outcome of a ratchet comparison — see `Kazi.Ratchet`."

    @type t :: %__MODULE__{
            status: :pass | :fail | :error,
            signal: number() | nil,
            baseline: number() | nil,
            regression: number() | nil,
            allowed_regression: number(),
            direction: :higher_better | :lower_better,
            baseline_source: :literal | :stored | :git_ref | :seed | nil,
            stored?: boolean(),
            reason: term()
          }

    @enforce_keys [:status]
    defstruct status: nil,
              signal: nil,
              baseline: nil,
              regression: nil,
              allowed_regression: 0.0,
              direction: :higher_better,
              baseline_source: nil,
              stored?: false,
              reason: nil
  end

  @stored_keywords ~w(stored prior)

  @doc """
  The amount the metric moved in the WORSENING direction relative to `baseline`,
  interpreted through `direction`. Positive is a regression (worse); negative is
  an improvement; zero is unchanged.

    * `:higher_better` — worsening is DOWN, so `baseline - signal`.
    * `:lower_better`  — worsening is UP, so `signal - baseline`.

  ## Examples

      iex> Kazi.Ratchet.regression(82.0, 80.0, :higher_better)
      -2.0

      iex> Kazi.Ratchet.regression(120.0, 100.0, :lower_better)
      20.0
  """
  @spec regression(number(), number(), :higher_better | :lower_better) :: number()
  def regression(signal, baseline, :higher_better), do: baseline - signal
  def regression(signal, baseline, :lower_better), do: signal - baseline

  @doc """
  `:pass` iff the regression is within `allowed_regression`, else `:fail`. Pure.

  ## Examples

      iex> Kazi.Ratchet.verdict(82.0, 80.0, 0.0, :higher_better)
      :pass

      iex> Kazi.Ratchet.verdict(78.0, 80.0, 1.0, :higher_better)
      :fail
  """
  @spec verdict(number(), number(), number(), :higher_better | :lower_better) :: :pass | :fail
  def verdict(signal, baseline, allowed_regression, direction) do
    if regression(signal, baseline, direction) <= allowed_regression, do: :pass, else: :fail
  end

  @doc """
  The baseline tightened toward the improving side — `max` for `:higher_better`,
  `min` for `:lower_better`. Storing this (not the raw signal) makes the bar a
  true RATCHET: once a better value is reached it cannot silently slip back.

  ## Examples

      iex> Kazi.Ratchet.tighten(80.0, 85.0, :higher_better)
      85.0

      iex> Kazi.Ratchet.tighten(80.0, 85.0, :lower_better)
      80.0
  """
  @spec tighten(number(), number(), :higher_better | :lower_better) :: number()
  def tighten(baseline, signal, :higher_better), do: max(baseline, signal)
  def tighten(baseline, signal, :lower_better), do: min(baseline, signal)

  @doc """
  Runs one full ratchet comparison: compute the signal (`Kazi.Metric`), resolve
  the baseline, compare, and persist the new baseline when the bar moves forward.

  `config` keys:

    * `:metric` — the `Kazi.Metric` config (required) producing the signal.
    * `:baseline` — a number, `"stored"`/`"prior"`, or a git ref (required).
    * `:allowed_regression` — the tolerated worsening (number, default `0.0`).
    * `:direction` — `:higher_better | :lower_better` (required).
    * `:id` — the predicate id, the store key (required for the stored baseline).
    * `:store_dir` — overrides the baseline-store directory.

  `context` keys: `:workspace` (where the metric runs and the git ref is resolved)
  and optionally `:ratchet_store_dir`.

  Returns a `Kazi.Ratchet.Result`.
  """
  @spec evaluate(map(), map()) :: Result.t()
  def evaluate(config, context) when is_map(config) and is_map(context) do
    workspace = context[:workspace] || File.cwd!()
    direction = config[:direction]
    allowed = config[:allowed_regression] || 0.0

    with {:ok, direction} <- validate_direction(direction),
         {:ok, signal, _output} <- Kazi.Metric.signal(config[:metric] || %{}, workspace) do
      resolve_and_compare(signal, config, context, workspace, direction, allowed)
    else
      {:error, {:invalid_direction, _} = reason} -> error(reason, direction, allowed)
      {:error, reason} -> error(reason, direction, allowed)
    end
  end

  # Resolve the baseline per its source, then compare. A first stored run with no
  # baseline yet SEEDS it (a pass with nothing to regress from). A git-ref or
  # literal baseline never persists; a stored baseline tightens on a pass.
  defp resolve_and_compare(signal, config, context, workspace, direction, allowed) do
    case resolve_baseline(config[:baseline], config, context, workspace, direction) do
      {:seed, _} ->
        store_dir = store_dir(config, context, workspace)
        stored? = Store.write(store_dir, config[:id], signal) == :ok

        %Result{
          status: :pass,
          signal: signal,
          baseline: nil,
          regression: nil,
          allowed_regression: allowed,
          direction: direction,
          baseline_source: :seed,
          stored?: stored?
        }

      {:ok, source, baseline} ->
        compare_and_store(
          signal,
          baseline,
          source,
          config,
          context,
          workspace,
          direction,
          allowed
        )

      {:error, reason} ->
        error(reason, direction, allowed)
    end
  end

  defp compare_and_store(signal, baseline, source, config, context, workspace, direction, allowed) do
    status = verdict(signal, baseline, allowed, direction)
    reg = regression(signal, baseline, direction)

    stored? =
      if status == :pass and source == :stored do
        new_baseline = tighten(baseline, signal, direction)
        Store.write(store_dir(config, context, workspace), config[:id], new_baseline) == :ok
      else
        false
      end

    %Result{
      status: status,
      signal: signal,
      baseline: baseline,
      regression: reg,
      allowed_regression: allowed,
      direction: direction,
      baseline_source: source,
      stored?: stored?
    }
  end

  # =============================================================================
  # Baseline resolution
  # =============================================================================

  defp resolve_baseline(baseline, _config, _context, _workspace, _direction)
       when is_number(baseline),
       do: {:ok, :literal, baseline}

  defp resolve_baseline(baseline, config, context, workspace, _direction)
       when is_binary(baseline) do
    if String.downcase(baseline) in @stored_keywords do
      resolve_stored(config, context, workspace)
    else
      resolve_git_ref(baseline, config, workspace)
    end
  end

  defp resolve_baseline(nil, _config, _context, _workspace, _direction),
    do: {:error, :missing_baseline}

  defp resolve_baseline(other, _config, _context, _workspace, _direction),
    do: {:error, {:invalid_baseline, other}}

  defp resolve_stored(config, context, workspace) do
    case Store.read(store_dir(config, context, workspace), config[:id]) do
      {:ok, value} -> {:ok, :stored, value}
      :none -> {:seed, nil}
    end
  end

  # Recompute the metric against a git ref in a throwaway DETACHED worktree, so
  # "no regression vs <ref>" compares against the metric as it really was at that
  # ref. The worktree is always removed, even on a metric error.
  defp resolve_git_ref(ref, config, workspace) do
    tmp = Path.join(System.tmp_dir!(), "kazi-ratchet-#{System.unique_integer([:positive])}")

    case git(workspace, ["worktree", "add", "--detach", tmp, ref]) do
      {:ok, _} ->
        try do
          case Kazi.Metric.signal(config[:metric] || %{}, tmp) do
            {:ok, value, _output} -> {:ok, :git_ref, value}
            {:error, reason} -> {:error, {:baseline_metric, reason}}
          end
        after
          git(workspace, ["worktree", "remove", "--force", tmp])
        end

      {:error, output} ->
        {:error, {:baseline_ref_unresolved, ref, String.trim(output)}}
    end
  end

  defp git(workspace, args) do
    {output, exit_code} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
    if exit_code == 0, do: {:ok, output}, else: {:error, output}
  rescue
    error in [ErlangError, File.Error] -> {:error, Exception.message(error)}
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  defp store_dir(config, context, workspace) do
    config[:store_dir] || context[:ratchet_store_dir] || Path.join(workspace, ".kazi")
  end

  defp validate_direction(:higher_better), do: {:ok, :higher_better}
  defp validate_direction(:lower_better), do: {:ok, :lower_better}
  defp validate_direction(other), do: {:error, {:invalid_direction, other}}

  defp error(reason, direction, allowed) do
    %Result{
      status: :error,
      allowed_regression: allowed || 0.0,
      direction: (direction in [:higher_better, :lower_better] && direction) || :higher_better,
      reason: reason
    }
  end
end
