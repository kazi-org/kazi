defmodule Kazi.Economy.HistoryTest do
  @moduledoc """
  Tier 2 — real SQLite boundary (T48.8, ADR-0058 decision 2 precursor).
  `Kazi.Economy.History` aggregates the run-end economics `RunRegistry.finish/3`
  (T48.7) persists onto `Kazi.ReadModel.Run` into p50/p95 percentile groups by
  `{goal_shape_bucket, model, harness}`. Seeded rows via the real registry (not
  hand-built structs), so this pins the aggregate against the SAME write path
  production uses.
  """
  use ExUnit.Case, async: false

  alias Kazi.Economy.History
  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp seed_run(overrides) do
    run_id = "hist-#{System.unique_integer([:positive])}"

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

    # Backdate started_at so wall-clock is observably non-zero and deterministic
    # under the fixture's :wall_clock_s override.
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
      overrides
      |> Map.take([
        :budget_tokens,
        :budget_cached_input_tokens,
        :budget_cost_usd,
        :dispatch_count,
        :context_tier,
        :predicate_count,
        :predicate_kind_histogram
      ])

    {:ok, finished} =
      RunRegistry.finish(run_id, Map.get(overrides, :status, "converged"), economics)

    finished
  end

  # T49.9 (ADR-0046/0058): role attribution. Iterations carry no run id — they are
  # correlated to a run by (goal_ref, [started_at, finished_at]) — so these seed
  # the iterations INSIDE the run's window explicitly rather than relying on "now".
  defp record_dispatch(goal_ref, index, kind, observed_at) do
    {:ok, _} =
      Kazi.ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: index,
        action: %Kazi.Action{kind: kind, params: %{}},
        observed_at: observed_at
      })
  end

  defp set_window(run, started_at, finished_at) do
    run
    |> Kazi.ReadModel.Run.changeset(%{"started_at" => started_at, "finished_at" => finished_at})
    |> Repo.update!()
  end

  describe "aggregate/1 — dispatch_by_role (T49.9)" do
    test "a run with one fixer and one demonstrator dispatch reports the per-role split" do
      goal_ref = "goal-roles-#{System.unique_integer([:positive])}"

      run =
        seed_run(%{
          goal_ref: goal_ref,
          predicate_count: 2,
          dispatch_count: 2,
          wall_clock_s: 60
        })

      inside = DateTime.add(run.started_at, 1, :second)
      record_dispatch(goal_ref, 0, :dispatch_agent, inside)
      record_dispatch(goal_ref, 1, :dispatch_demonstrator, inside)

      assert %{groups: [group]} = History.aggregate(goal_ref: goal_ref)

      # The acc's invariant: two rows, distinct kinds, and the run's own
      # loop-tracked total is 2 — the split must ADD UP to it, not drift from it.
      assert group.dispatch_count.p50 == 2
      assert group.dispatch_by_role.dispatch_agent.p50 == 1
      assert group.dispatch_by_role.dispatch_demonstrator.p50 == 1

      assert group.dispatch_by_role.dispatch_agent.p50 +
               group.dispatch_by_role.dispatch_demonstrator.p50 == group.dispatch_count.p50
    end

    test "a role the run never dispatched reports an honest 0, not nil" do
      goal_ref = "goal-fixer-only-#{System.unique_integer([:positive])}"

      run =
        seed_run(%{goal_ref: goal_ref, predicate_count: 2, dispatch_count: 1, wall_clock_s: 60})

      record_dispatch(goal_ref, 0, :dispatch_agent, DateTime.add(run.started_at, 1, :second))

      assert %{groups: [group]} = History.aggregate(goal_ref: goal_ref)

      # A run that HAPPENED and used no demonstrator genuinely spent 0 there. That
      # is a real measurement, unlike tokens/cost where nil means "never reported"
      # (ADR-0046) — so 0 here, never nil.
      assert group.dispatch_by_role.dispatch_agent.p50 == 1
      assert group.dispatch_by_role.dispatch_demonstrator.p50 == 0
    end

    test "non-dispatch iterations are excluded from the split" do
      goal_ref = "goal-mixed-#{System.unique_integer([:positive])}"

      run =
        seed_run(%{goal_ref: goal_ref, predicate_count: 2, dispatch_count: 1, wall_clock_s: 60})

      inside = DateTime.add(run.started_at, 1, :second)
      record_dispatch(goal_ref, 0, :dispatch_agent, inside)
      record_dispatch(goal_ref, 1, :integrate, inside)
      record_dispatch(goal_ref, 2, :deploy, inside)

      assert %{groups: [group]} = History.aggregate(goal_ref: goal_ref)
      assert group.dispatch_by_role.dispatch_agent.p50 == 1
      assert group.dispatch_by_role.dispatch_demonstrator.p50 == 0
    end

    test "an earlier run's dispatches are not attributed to a later run of the same goal" do
      goal_ref = "goal-two-runs-#{System.unique_integer([:positive])}"
      base = DateTime.utc_now()

      # goal_ref is stable ACROSS runs, so a goal_ref-only join would pool these two
      # runs into each other. The run's time window is what keeps them apart — so
      # pin DISJOINT windows explicitly rather than letting the fixture's default
      # backdating overlap them.
      first = seed_run(%{goal_ref: goal_ref, predicate_count: 2, dispatch_count: 1})
      set_window(first, DateTime.add(base, -100, :second), DateTime.add(base, -90, :second))
      record_dispatch(goal_ref, 0, :dispatch_agent, DateTime.add(base, -95, :second))

      second = seed_run(%{goal_ref: goal_ref, predicate_count: 2, dispatch_count: 1})
      set_window(second, DateTime.add(base, -10, :second), base)
      record_dispatch(goal_ref, 1, :dispatch_demonstrator, DateTime.add(base, -5, :second))

      assert %{groups: [group]} = History.aggregate(goal_ref: goal_ref)

      # Two runs, ONE dispatch each — not two each. Each role appears in exactly one
      # of the two runs, so per role the counts are [1, 0]: p95 sees the run that
      # used it, p50 the run that did not.
      assert group.n == 2
      assert group.dispatch_count.p50 == 1
      assert group.dispatch_by_role.dispatch_agent.p95 == 1
      assert group.dispatch_by_role.dispatch_agent.p50 == 0
      assert group.dispatch_by_role.dispatch_demonstrator.p95 == 1
      assert group.dispatch_by_role.dispatch_demonstrator.p50 == 0
    end

    test "a group with no iteration history at all reports 0s, and existing metrics are untouched" do
      goal_ref = "goal-no-iters-#{System.unique_integer([:positive])}"
      seed_run(%{goal_ref: goal_ref, predicate_count: 2, dispatch_count: 0, wall_clock_s: 60})

      assert %{groups: [group]} = History.aggregate(goal_ref: goal_ref)
      assert group.dispatch_by_role.dispatch_agent.p50 == 0
      assert group.dispatch_by_role.dispatch_demonstrator.p50 == 0
    end
  end

  describe "aggregate/1 — percentile grouping" do
    test "aggregates seeded runs into correct p50/p95 per group" do
      goal_ref = "goal-shared"

      for tokens <- [1000, 2000, 3000, 4000] do
        seed_run(%{
          goal_ref: goal_ref,
          harness: "claude",
          model: "claude-sonnet-5",
          predicate_count: 2,
          budget_tokens: tokens,
          budget_cost_usd: tokens / 100_000,
          dispatch_count: 2
        })
      end

      %{groups: groups} = History.aggregate(goal_ref: goal_ref)

      assert [group] = groups
      assert group.goal_shape_bucket == "1-3"
      assert group.model == "claude-sonnet-5"
      assert group.harness == "claude"
      assert group.n == 4
      assert group.n_with_usage == 4

      # Nearest-rank over [1000, 2000, 3000, 4000]: p50 rank = ceil(0.5*4) = 2 -> 2000;
      # p95 rank = ceil(0.95*4) = 4 -> 4000.
      assert group.tokens == %{p50: 2000, p95: 4000}
      assert group.cost_usd == %{p50: 0.02, p95: 0.04}
      assert group.dispatch_count == %{p50: 2, p95: 2}
    end

    test "separates groups by goal_shape_bucket, model, and harness" do
      small = seed_run(%{predicate_count: 2, budget_tokens: 100, harness: "claude", model: "m1"})

      large =
        seed_run(%{predicate_count: 10, budget_tokens: 900, harness: "opencode", model: "m2"})

      %{groups: groups} = History.aggregate(goal_ref: nil)

      by_bucket = Map.new(groups, &{&1.goal_shape_bucket, &1})

      assert small.goal_ref != large.goal_ref
      assert Map.has_key?(by_bucket, "1-3")
      assert Map.has_key?(by_bucket, "9+")
      assert by_bucket["1-3"].model == "m1"
      assert by_bucket["1-3"].harness == "claude"
      assert by_bucket["9+"].model == "m2"
      assert by_bucket["9+"].harness == "opencode"
    end

    test "the optional goal_ref filter restricts the aggregate to one goal" do
      target = "goal-filter-target"
      seed_run(%{goal_ref: target, budget_tokens: 500, predicate_count: 1})
      seed_run(%{goal_ref: "goal-other", budget_tokens: 999, predicate_count: 1})

      %{groups: [group]} = History.aggregate(goal_ref: target)

      assert group.n == 1
      assert group.tokens == %{p50: 500, p95: 500}
    end
  end

  describe "aggregate/1 — honest-unknown nil-safety (ADR-0046)" do
    test "a group where every run left tokens/cost unreported yields nil, never 0" do
      goal_ref = "goal-unreported"

      # No :budget_tokens / :budget_cost_usd key at all -- mirrors a harness
      # that never reported usage this run (T48.7's honest-unknown contract).
      seed_run(%{goal_ref: goal_ref, predicate_count: 1, dispatch_count: 1})
      seed_run(%{goal_ref: goal_ref, predicate_count: 1, dispatch_count: 3})

      %{groups: [group]} = History.aggregate(goal_ref: goal_ref)

      assert group.n == 2
      assert group.n_with_usage == 0
      assert group.tokens == %{p50: nil, p95: nil}
      assert group.cost_usd == %{p50: nil, p95: nil}
      # dispatch_count is loop-tracked (never nil, default 0) -- reports real values.
      assert group.dispatch_count == %{p50: 1, p95: 3}
    end

    test "a mixed group excludes unreported runs from the metric's percentile input" do
      goal_ref = "goal-mixed"

      seed_run(%{goal_ref: goal_ref, predicate_count: 1, budget_tokens: 100})
      seed_run(%{goal_ref: goal_ref, predicate_count: 1})

      %{groups: [group]} = History.aggregate(goal_ref: goal_ref)

      assert group.n == 2
      assert group.n_with_usage == 1
      # Only the one reported value feeds the percentile -- not averaged with a
      # phantom 0 for the unreported run.
      assert group.tokens == %{p50: 100, p95: 100}
    end

    test "a nil predicate_count (pre-T48.7 shape) buckets as unknown, not a crash" do
      seed_run(%{goal_ref: "goal-unknown-shape", budget_tokens: 42})

      %{groups: [group]} = History.aggregate(goal_ref: "goal-unknown-shape")

      assert group.goal_shape_bucket == "unknown"
    end
  end

  describe "aggregate/1 — wall-clock derived from timestamps" do
    test "wall_clock_s percentiles derive from finished_at - started_at" do
      goal_ref = "goal-wallclock"
      seed_run(%{goal_ref: goal_ref, predicate_count: 1, wall_clock_s: 30})
      seed_run(%{goal_ref: goal_ref, predicate_count: 1, wall_clock_s: 90})

      %{groups: [group]} = History.aggregate(goal_ref: goal_ref)

      assert_in_delta group.wall_clock_s.p50, 30.0, 1.0
      assert_in_delta group.wall_clock_s.p95, 90.0, 1.0
    end
  end

  describe "aggregate/1 — honest empty" do
    test "a fresh read-model with no finished runs returns an empty groups list" do
      assert History.aggregate(goal_ref: "goal-never-seen") == %{groups: []}
    end
  end

  describe "aggregate_by_shape_bucket/2 — pooled across model/harness (T48.9)" do
    test "pools every run in the bucket regardless of model/harness" do
      goal_ref = "goal-pooled"

      seed_run(%{
        goal_ref: goal_ref,
        predicate_count: 2,
        harness: "claude",
        model: "claude-sonnet-5",
        budget_tokens: 1000,
        dispatch_count: 2
      })

      seed_run(%{
        goal_ref: goal_ref,
        predicate_count: 3,
        harness: "opencode",
        model: "local-model",
        budget_tokens: 3000,
        dispatch_count: 6
      })

      group = History.aggregate_by_shape_bucket("1-3", goal_ref: goal_ref)

      assert group.goal_shape_bucket == "1-3"
      assert group.model == nil
      assert group.harness == nil
      assert group.n == 2
      # Pooled percentiles over [1000, 3000] regardless of the differing
      # model/harness identities on each run.
      assert group.tokens == %{p50: 1000, p95: 3000}
      assert group.dispatch_count == %{p50: 2, p95: 6}
    end

    test "a run outside the requested bucket is excluded" do
      goal_ref = "goal-pooled-exclude"
      seed_run(%{goal_ref: goal_ref, predicate_count: 2, budget_tokens: 100})
      seed_run(%{goal_ref: goal_ref, predicate_count: 10, budget_tokens: 900})

      group = History.aggregate_by_shape_bucket("1-3", goal_ref: goal_ref)

      assert group.n == 1
      assert group.tokens == %{p50: 100, p95: 100}
    end

    test "an empty bucket returns nil (honest no-history), never an empty group" do
      assert History.aggregate_by_shape_bucket("1-3", goal_ref: "goal-never-seen") == nil
    end
  end

  describe "goal_shape_bucket/1" do
    test "bands 1-3, 4-8, 9+ and unknown for nil/non-positive" do
      assert History.goal_shape_bucket(1) == "1-3"
      assert History.goal_shape_bucket(3) == "1-3"
      assert History.goal_shape_bucket(4) == "4-8"
      assert History.goal_shape_bucket(8) == "4-8"
      assert History.goal_shape_bucket(9) == "9+"
      assert History.goal_shape_bucket(100) == "9+"
      assert History.goal_shape_bucket(0) == "unknown"
      assert History.goal_shape_bucket(-1) == "unknown"
      assert History.goal_shape_bucket(nil) == "unknown"
    end
  end

  describe "aggregate/1 — model ID normalization" do
    test "normalizes model IDs so variants group together" do
      goal_ref = "goal-model-norm"

      # Same semantic model, different case and version suffix.
      seed_run(%{
        goal_ref: goal_ref,
        harness: "claude",
        model: "claude-opus-4-8",
        predicate_count: 2,
        budget_tokens: 1000,
        dispatch_count: 1
      })

      seed_run(%{
        goal_ref: goal_ref,
        harness: "claude",
        model: "CLAUDE-OPUS-4-8-20260101",
        predicate_count: 2,
        budget_tokens: 2000,
        dispatch_count: 2
      })

      %{groups: groups} = History.aggregate(goal_ref: goal_ref)

      # Both runs should group together under the normalized model ID.
      assert [group] = groups
      assert group.model == "claude-opus-4-8"
      assert group.n == 2
      assert group.tokens == %{p50: 1000, p95: 2000}
    end

    test "nil model remains nil after normalization" do
      goal_ref = "goal-nil-model"

      seed_run(%{
        goal_ref: goal_ref,
        harness: "claude",
        model: nil,
        predicate_count: 2,
        budget_tokens: 500,
        dispatch_count: 1
      })

      %{groups: [group]} = History.aggregate(goal_ref: goal_ref)

      assert group.model == nil
    end
  end
end
