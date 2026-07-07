defmodule Kazi.Economy.History do
  @moduledoc """
  T48.8 (ADR-0058 decision 2 precursor): aggregates the run-end economics
  T48.7 persists onto `Kazi.ReadModel.Run` (tokens, cached-input tokens, cost
  USD, dispatch count, wall-clock) into p50/p95 percentile groups an operator
  inspects via `kazi economy --json`, and that T48.9's learned budget
  proposals will consume by the SAME grouping.

  ## Grouping

  Runs group by `{goal_shape_bucket, model, harness}` — `model`/`harness` are
  the run's recorded harness identity; `goal_shape_bucket` is `predicate_count`
  banded via `goal_shape_bucket/1` (public, reusable — see its doc for the
  banding rationale). A `nil` `model`/`harness` groups together as its own
  bucket (a pre-T46 row or a run whose harness never reported an identity) —
  it is a real, distinct group, never silently dropped or merged into a
  "known" one.

  ## Honest-unknown (ADR-0046)

  `budget_tokens`/`budget_cached_input_tokens`/`budget_cost_usd` are nullable
  columns (a harness that never reported usage persists NULL, T48.7). Here,
  nil values are EXCLUDED from a metric's percentile input, never coerced to
  0 — a group where every run left a metric unreported yields `nil` for BOTH
  its `p50` and `p95`, not a fabricated zero. `dispatch_count` is loop-tracked
  and never nil (schema default 0), so its percentiles are only nil for an
  (impossible) empty group. `wall_clock_s` is derived from
  `finished_at - started_at`; both timestamps are required at `RunRegistry`
  write time, so it is nil only for a row from before those columns existed.

  ## Percentile method

  Nearest-rank over the ascending-sorted, non-nil values: `rank = ceil(p/100 *
  n)`, clamped to `[1, n]`. Simple and deterministic — kazi's local run
  history is small enough that interpolation would not change the operator's
  decision, and nearest-rank is trivial to hand-verify against a seeded
  fixture.

  This module is a pure read over `Kazi.Repo` (via `Kazi.ReadModel.Run`) — it
  never writes, and it makes no scheduling/budget decision itself; that
  belongs to the human at `kazi plan`/`kazi adopt` (T48.9) which merely READS
  this aggregate as a suggestion input.
  """

  import Ecto.Query, only: [from: 2]

  alias Kazi.ReadModel.Run
  alias Kazi.Repo

  @typedoc "p50/p95 for one metric; either or both are nil when unreported (ADR-0046)."
  @type percentile_pair :: %{p50: number() | nil, p95: number() | nil}

  @typedoc "One `{goal_shape_bucket, model, harness}` group's aggregate."
  @type group :: %{
          goal_shape_bucket: String.t(),
          model: String.t() | nil,
          harness: String.t() | nil,
          n: non_neg_integer(),
          n_with_usage: non_neg_integer(),
          tokens: percentile_pair(),
          cost_usd: percentile_pair(),
          dispatch_count: percentile_pair(),
          wall_clock_s: percentile_pair()
        }

  @doc """
  Aggregates every FINISHED run (a recorded `finished_at`) into percentile
  groups. `opts[:goal_ref]` optionally restricts the aggregate to one goal's
  own run history; absent, it aggregates across every goal on this read-model
  (the cross-goal view `kazi economy --json` reports by default, and the one
  T48.9's cross-goal learned-budget lookup uses).

  Returns `%{groups: []}` on a fresh/empty read-model — an empty history is a
  legitimate, honestly-reported answer, never an error.
  """
  @spec aggregate(keyword()) :: %{groups: [group()]}
  def aggregate(opts \\ []) do
    groups =
      opts
      |> finished_runs()
      |> Enum.group_by(&group_key/1)
      |> Enum.map(fn {key, runs} -> build_group(key, runs) end)
      |> Enum.sort_by(&{&1.goal_shape_bucket, &1.model || "", &1.harness || ""})

    %{groups: groups}
  end

  @doc """
  Buckets a goal's `predicate_count` into a coarse workload-size band —
  `"1-3"`, `"4-8"`, `"9+"`, or `"unknown"` for `nil`/non-positive (a pre-T48.7
  row, or a goal shape that was never recorded). Bands rather than the exact
  count: at kazi's local run volumes, grouping by exact predicate count leaves
  most groups with a sample of one, which cannot support a meaningful
  percentile. Three bands trade some precision for groups that actually fill
  up, while still separating a small fixture goal's economics from a large
  multi-predicate goal's.

  Public and reusable BY DESIGN: T48.9 (learned budget proposals) computes a
  drafted goal's OWN bucket through this same function before looking up its
  matching history group, so the bucket a proposal is scored against is
  guaranteed to be the same one this module would have aggregated it into.
  """
  @spec goal_shape_bucket(non_neg_integer() | nil) :: String.t()
  def goal_shape_bucket(count) when is_integer(count) and count in 1..3, do: "1-3"
  def goal_shape_bucket(count) when is_integer(count) and count in 4..8, do: "4-8"
  def goal_shape_bucket(count) when is_integer(count) and count >= 9, do: "9+"
  def goal_shape_bucket(_count), do: "unknown"

  @doc """
  Pools every finished run within one goal-shape `bucket` (as returned by
  `goal_shape_bucket/1`), collapsing the `model`/`harness` dimensions `aggregate/1`
  groups by (T48.9, ADR-0058 decision 2): `Kazi.Economy.BudgetSuggestion` calls
  this when a drafted/adopted goal's target model or harness is not yet known
  (the common case at `kazi plan`/`kazi adopt` time), so the suggestion draws on
  the FULL bucket's run history instead of a single, possibly sample-of-one
  model/harness slice.

  `opts[:goal_ref]` restricts to one goal's own history, exactly as in
  `aggregate/1`.

  Returns `nil` on an empty bucket (no finished run of that shape anywhere in
  history) — an honest "nothing to learn from" the caller treats as no
  suggestion, never a fabricated number — or a single `group()`-shaped map
  computed with the SAME percentile method as `aggregate/1`. Its `model` and
  `harness` fields are both `nil`, marking the pooled fallback; that is the same
  representation `aggregate/1` uses for a group whose runs genuinely never
  reported a harness identity, so a caller that must tell the two apart should
  use `aggregate/1` directly instead of this pooled view.
  """
  @spec aggregate_by_shape_bucket(String.t(), keyword()) :: group() | nil
  def aggregate_by_shape_bucket(bucket, opts \\ []) when is_binary(bucket) do
    opts
    |> finished_runs()
    |> Enum.filter(&(goal_shape_bucket(&1.predicate_count) == bucket))
    |> case do
      [] -> nil
      runs -> build_group({bucket, nil, nil}, runs)
    end
  end

  defp finished_runs(opts) do
    query = from(r in Run, where: not is_nil(r.finished_at))

    query =
      case Keyword.get(opts, :goal_ref) do
        nil -> query
        goal_ref -> from(r in query, where: r.goal_ref == ^goal_ref)
      end

    Repo.all(query)
  end

  defp group_key(%Run{predicate_count: predicate_count, model: model, harness: harness}) do
    {goal_shape_bucket(predicate_count), model, harness}
  end

  defp build_group({bucket, model, harness}, runs) do
    %{
      goal_shape_bucket: bucket,
      model: model,
      harness: harness,
      n: length(runs),
      n_with_usage: Enum.count(runs, &(&1.budget_tokens != nil)),
      tokens: percentiles(Enum.map(runs, & &1.budget_tokens)),
      cost_usd: percentiles(Enum.map(runs, & &1.budget_cost_usd)),
      dispatch_count: percentiles(Enum.map(runs, & &1.dispatch_count)),
      wall_clock_s: percentiles(Enum.map(runs, &wall_clock_seconds/1))
    }
  end

  defp wall_clock_seconds(%Run{
         started_at: %DateTime{} = started,
         finished_at: %DateTime{} = finished
       }) do
    DateTime.diff(finished, started, :microsecond) / 1_000_000
  end

  defp wall_clock_seconds(_run), do: nil

  # Nil-safe (ADR-0046 honest-unknown): unreported values are EXCLUDED from the
  # percentile input, never coerced to 0. A group with zero non-nil values for
  # a metric reports nil for BOTH p50 and p95.
  defp percentiles(values) do
    present = Enum.reject(values, &is_nil/1)
    %{p50: percentile(present, 50), p95: percentile(present, 95)}
  end

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    n = length(sorted)
    rank = (p / 100 * n) |> Float.ceil() |> trunc() |> max(1) |> min(n)
    Enum.at(sorted, rank - 1)
  end
end
