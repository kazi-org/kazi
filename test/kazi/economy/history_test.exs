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
end
