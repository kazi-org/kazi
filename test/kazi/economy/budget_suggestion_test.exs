defmodule Kazi.Economy.BudgetSuggestionTest do
  @moduledoc """
  Tier 2 — real SQLite boundary (T48.9, ADR-0058 decision 2). Seeds run
  economics via the real `RunRegistry` write path (T48.7), then pins the
  learned `[budget]` suggestion `kazi plan`/`kazi adopt` render: derivation
  (p95 x 1.5 headroom, rounded to a sane granularity), provenance, the
  any-model/harness pooled fallback, an exact-match lookup when both are
  known, and the honest-empty (`nil`) case a fresh read-model reports.
  """
  use ExUnit.Case, async: false

  alias Kazi.Economy.BudgetSuggestion
  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp seed_run(overrides) do
    run_id = "budsug-#{System.unique_integer([:positive])}"

    base = %{
      run_id: run_id,
      pid: "#PID<0.1.0>",
      workspace: "/tmp/ws",
      goal_ref: "goal-#{run_id}",
      harness: "claude",
      model: "claude-sonnet-5"
    }

    attrs = Map.merge(base, Map.take(overrides, [:goal_ref, :harness, :model]))
    {:ok, run} = RunRegistry.start(attrs)

    started_at =
      case overrides[:wall_clock_s] do
        seconds when is_number(seconds) ->
          DateTime.add(run.heartbeat_at, -trunc(seconds), :second)

        _ ->
          run.started_at
      end

    run
    |> Kazi.ReadModel.Run.changeset(%{"started_at" => started_at})
    |> Repo.update!()

    economics =
      Map.take(overrides, [
        :budget_tokens,
        :budget_cost_usd,
        :dispatch_count,
        :predicate_count
      ])

    {:ok, finished} =
      RunRegistry.finish(run_id, Map.get(overrides, :status, "converged"), economics)

    finished
  end

  describe "suggest/2 — honest empty" do
    test "a fresh read-model with no finished runs returns nil, never a fabricated number" do
      assert BudgetSuggestion.suggest(2, model: "no-such-model", harness: "no-such-harness") ==
               nil
    end

    test "a bucket with zero runs (unrelated goal shapes exist) returns nil" do
      seed_run(%{goal_ref: "goal-elsewhere", predicate_count: 10, budget_tokens: 500})

      assert BudgetSuggestion.suggest(2) == nil
    end
  end

  describe "suggest/2 — pooled fallback (model/harness unknown, the plan/adopt default)" do
    test "derives max_tokens/max_dispatches/max_wall_clock_ms at p95 x 1.5, rounded" do
      goal_ref = "goal-pooled-suggest"

      for {tokens, dispatches, wall_clock, harness, model} <- [
            {1000, 2, 30, "claude", "claude-sonnet-5"},
            {2000, 4, 60, "claude", "claude-sonnet-5"},
            {3000, 6, 90, "opencode", "local-model"}
          ] do
        seed_run(%{
          goal_ref: goal_ref,
          predicate_count: 2,
          harness: harness,
          model: model,
          budget_tokens: tokens,
          dispatch_count: dispatches,
          wall_clock_s: wall_clock
        })
      end

      # p95 rank = ceil(0.95*3) = 3 -> the largest value in each metric.
      # tokens: ceil(3000*1.5 / 10_000) * 10_000 = 10_000
      # dispatches: ceil(6*1.5) = 9
      # wall_clock: ceil(90*1.5*1000 / 60_000) * 60_000 = 180_000 (3 minutes)
      assert %{
               max_tokens: 10_000,
               max_dispatches: 9,
               max_wall_clock_ms: 180_000,
               provenance: provenance
             } = BudgetSuggestion.suggest(2)

      assert provenance == "learned from 3 runs (shape 1-3, any model/harness), p95 x 1.5"
    end

    test "a metric with no reported history contributes no key (honest-unknown)" do
      goal_ref = "goal-partial"
      # No budget_tokens/dispatch_count/wall_clock overrides at all.
      seed_run(%{goal_ref: goal_ref, predicate_count: 1})

      assert %{provenance: provenance} = suggestion = BudgetSuggestion.suggest(1)
      refute Map.has_key?(suggestion, :max_tokens)
      # dispatch_count is loop-tracked (defaults 0), so it IS reported, but a
      # 0 p95 still rounds up to a minimum floor of 1.
      assert suggestion[:max_dispatches] == 1
      assert provenance =~ "shape 1-3"
    end

    test "a group where every metric is unreported yields nil overall" do
      # dispatch_count always defaults to a real 0 via RunRegistry, so a
      # group can't naturally hit "every metric unreported" -- confirm the
      # only-dispatch-count-present case still yields a real suggestion
      # rather than nil (dispatch_count alone is enough to suggest from).
      seed_run(%{goal_ref: "goal-dispatch-only", predicate_count: 1})

      refute BudgetSuggestion.suggest(1) == nil
    end
  end

  describe "suggest/2 — exact-match group (model + harness both known)" do
    test "prefers the exact group over the pooled bucket when both match" do
      goal_ref = "goal-exact"

      seed_run(%{
        goal_ref: goal_ref,
        predicate_count: 2,
        harness: "claude",
        model: "claude-sonnet-5",
        budget_tokens: 1000,
        dispatch_count: 2
      })

      # A different model/harness in the SAME bucket -- must not pollute the
      # exact-match lookup.
      seed_run(%{
        goal_ref: goal_ref,
        predicate_count: 2,
        harness: "opencode",
        model: "local-model",
        budget_tokens: 9_000_000,
        dispatch_count: 900
      })

      assert %{max_tokens: max_tokens, provenance: provenance} =
               BudgetSuggestion.suggest(2, model: "claude-sonnet-5", harness: "claude")

      # ceil(1000*1.5/10_000)*10_000 = 10_000 -- proves the opencode/local-model
      # run's huge token count was excluded from this exact-match lookup.
      assert max_tokens == 10_000
      assert provenance =~ "model claude-sonnet-5"
      assert provenance =~ "harness claude"
    end

    test "falls back to the pooled bucket when no exact model/harness match exists" do
      goal_ref = "goal-no-exact"

      seed_run(%{
        goal_ref: goal_ref,
        predicate_count: 2,
        harness: "opencode",
        model: "local-model",
        budget_tokens: 4000,
        dispatch_count: 4
      })

      assert %{provenance: provenance} =
               BudgetSuggestion.suggest(2, model: "claude-sonnet-5", harness: "claude")

      assert provenance =~ "any model/harness"
    end
  end

  describe "suggest/2 — a single-run sample" do
    test "provenance pluralizes 'run' correctly for n=1" do
      seed_run(%{goal_ref: "goal-singular", predicate_count: 1, budget_tokens: 100})

      assert %{provenance: provenance} = BudgetSuggestion.suggest(1)
      assert provenance =~ "learned from 1 run "
      refute provenance =~ "1 runs"
    end
  end
end
