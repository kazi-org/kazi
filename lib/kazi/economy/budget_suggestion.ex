defmodule Kazi.Economy.BudgetSuggestion do
  @moduledoc """
  Learned `[budget]` proposals for `kazi plan`/`kazi adopt` (T48.9, ADR-0058
  decision 2): derives SUGGESTED budget ceilings from `Kazi.Economy.History`
  (T48.8) for a goal of a given shape, with explicit provenance -- never a
  silent write. Both authoring surfaces render `suggest/2`'s result as
  ADVISORY output only (a JSON `suggested_budget` field, or a COMMENTED TOML
  block); neither ever puts a learned value into the goal a human approves.

  ## Derivation

  `p95 * 1.5` headroom over the matching history group, rounded UP to a sane
  granularity so the suggestion reads as a round number a human would
  actually type: `max_tokens` to the nearest 10k, `max_wall_clock_ms` to the
  nearest minute, `max_dispatches` to the next whole dispatch (no further
  granularity -- dispatch counts are already small integers). A metric with
  no reported history in the matching group contributes NO suggested key
  (honest-unknown, ADR-0046) -- never a fabricated number filling the gap.

  `max_iterations` and `cached_read_weight` are NOT suggested: neither has a
  direct 1:1 recorded metric (`dispatch_count` counts agent dispatches, not
  observe-tick iterations; `cached_read_weight` is a discount rate, not a
  ceiling), so guessing one from adjacent data would not be a learned value,
  it would be a fabricated one.

  ## Grouping / fallback

  A goal's `predicate_count` buckets via `Kazi.Economy.History.goal_shape_bucket/1`
  (the SAME banding `kazi economy` groups by, so a suggestion is scored
  against exactly the bucket that goal's own run would land in later). When
  `opts[:model]` AND `opts[:harness]` are BOTH known (e.g. re-planning a goal
  whose target harness is already pinned) and an EXACT `{bucket, model,
  harness}` group exists, that group is used. Otherwise -- the common case at
  `plan`/`adopt` time, before a harness is chosen -- every run in the bucket is
  POOLED regardless of model/harness (`History.aggregate_by_shape_bucket/2`),
  and the provenance line says so explicitly ("any model/harness").

  Returns `nil` (no suggestion at all) when the matching group has nothing
  usable: no runs in the bucket, or every dimension unreported. `nil` is a
  legitimate, honestly-reported answer -- callers render nothing for it, so
  `kazi plan`/`kazi adopt` output is BYTE-IDENTICAL to before this feature
  existed when local history has nothing to learn from.

  ## Best-effort over the read-model

  `kazi adopt`/`kazi init` has never required the SQLite read-model (ADR-0013:
  detection is pure filesystem inspection, no DB, no network) and must not
  start needing it now just because a suggestion is nice to have when
  available. Any failure reaching the read-model (an unchecked-out Ecto
  Sandbox connection in a hermetic test, a Repo that never started) is
  treated exactly like "no usable history": `suggest/2` returns `nil` rather
  than raising. `kazi plan` already requires the read-model for persistence
  (`Kazi.Authoring.propose/2`), so in practice this path only ever degrades
  gracefully for the adopt surface.
  """

  alias Kazi.Economy.History

  @headroom 1.5
  @token_granularity 10_000
  @wall_clock_granularity_ms 60_000

  @typedoc """
  A suggestion: zero or more ceiling keys (each present only when its metric
  has reported history) plus a REQUIRED human-readable `:provenance` line
  naming the sample size, goal shape, and derivation rule.
  """
  @type t :: %{
          optional(:max_tokens) => pos_integer(),
          optional(:max_dispatches) => pos_integer(),
          optional(:max_wall_clock_ms) => pos_integer(),
          provenance: String.t()
        }

  @doc """
  Suggests budget ceilings for a goal with `predicate_count` acceptance/guard
  predicates (`nil`/non-positive buckets as `"unknown"`, same as
  `Kazi.Economy.History.goal_shape_bucket/1`).

  ## Options

    * `:model` / `:harness` -- when BOTH are given and an exact-match history
      group exists, narrows the lookup to it; otherwise (the default) pools
      every run in the goal-shape bucket regardless of model/harness.

  Returns `nil` when there is nothing usable to learn from -- an empty bucket,
  or a matching group where every budget-relevant metric is unreported.
  """
  @spec suggest(non_neg_integer() | nil, keyword()) :: t() | nil
  def suggest(predicate_count, opts \\ []) do
    bucket = History.goal_shape_bucket(predicate_count)
    model = Keyword.get(opts, :model)
    harness = Keyword.get(opts, :harness)

    case pick_group(bucket, model, harness) do
      nil -> nil
      {group, scope} -> build(group, bucket, scope)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp pick_group(bucket, model, harness)
       when is_binary(model) and is_binary(harness) do
    %{groups: groups} = History.aggregate()

    groups
    |> Enum.find(
      &(&1.goal_shape_bucket == bucket and &1.model == model and &1.harness == harness)
    )
    |> case do
      nil -> pick_pooled(bucket)
      group -> {group, {:exact, model, harness}}
    end
  end

  defp pick_group(bucket, _model, _harness), do: pick_pooled(bucket)

  defp pick_pooled(bucket) do
    case History.aggregate_by_shape_bucket(bucket) do
      nil -> nil
      group -> {group, :pooled}
    end
  end

  defp build(group, bucket, scope) do
    fields =
      %{
        max_tokens: ceil_to(group.tokens.p95, @headroom, @token_granularity),
        max_dispatches: ceil_count(group.dispatch_count.p95, @headroom),
        max_wall_clock_ms: ceil_wall_clock_ms(group.wall_clock_s.p95, @headroom)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case map_size(fields) do
      0 -> nil
      _ -> Map.put(fields, :provenance, provenance(group.n, bucket, scope))
    end
  end

  defp ceil_to(nil, _headroom, _granularity), do: nil

  defp ceil_to(p95, headroom, granularity) do
    target = p95 * headroom
    rounded = (Float.ceil(target / granularity) * granularity) |> trunc()
    max(rounded, granularity)
  end

  defp ceil_count(nil, _headroom), do: nil

  defp ceil_count(p95, headroom) do
    (p95 * headroom) |> Float.ceil() |> trunc() |> max(1)
  end

  defp ceil_wall_clock_ms(nil, _headroom), do: nil

  defp ceil_wall_clock_ms(p95_seconds, headroom) do
    ceil_to(p95_seconds * 1000, headroom, @wall_clock_granularity_ms)
  end

  defp provenance(n, bucket, {:exact, model, harness}) do
    "learned from #{n} #{run_word(n)} (shape #{bucket}, model #{model}, harness #{harness}), p95 x 1.5"
  end

  defp provenance(n, bucket, :pooled) do
    "learned from #{n} #{run_word(n)} (shape #{bucket}, any model/harness), p95 x 1.5"
  end

  defp run_word(1), do: "run"
  defp run_word(_n), do: "runs"
end
