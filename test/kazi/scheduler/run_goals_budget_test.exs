defmodule Kazi.Scheduler.RunGoalsBudgetTest do
  @moduledoc """
  T21.7 acceptance (ADR-0027 step 3): `Kazi.Scheduler.run_goals/2` SPLITS the goal
  budget across N partitions; a partition exhausting its SHARE reports
  `:over_budget` and ESCALATES without aborting its siblings (each runs its own
  supervised task to its own terminal); the collective verdict + per-partition
  `budget_spent` reflect the per-partition outcomes (the derived rollup sums the
  shares actually spent).

  Hermetic: an injected graph source (per-term file mapping → disjoint partitions),
  an injected 3-arity (budget-aware) inner reconciler that reads its share + reports
  spend, an isolated supervisor instance. No lease/worktree isolation needed for
  the budget acceptance (the split + rollup is the unit under test); no harness, no
  NATS.
  """
  use ExUnit.Case, async: true

  alias Kazi.Budget
  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Scheduler
  alias Kazi.Scheduler.PartitionSupervisor

  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, terms, opts) do
      mapping = Keyword.fetch!(opts, :mapping)

      files =
        terms
        |> Enum.flat_map(&Map.get(mapping, &1, []))
        |> Enum.uniq()
        |> Enum.map(&FileRef.new/1)

      Survey.new(:graph, files: files)
    end

    def new(mapping), do: {__MODULE__, mapping: mapping}
  end

  setup do
    {:ok, sup} = start_supervised(PartitionSupervisor)
    %{sup: sup, workspace: "/ws"}
  end

  defp goal(id, terms), do: Kazi.Goal.new(id, metadata: %{partition_terms: terms})

  test "the goal budget splits across partitions; each partition runs under its SHARE",
       ctx do
    source = TermSource.new(%{"a" => ["lib/a.ex"], "b" => ["lib/b.ex"]})
    goals = [goal("g1", ["a"]), goal("g2", ["b"])]
    test_pid = self()

    # A 3-arity (budget-aware) inner: observe the share handed to each partition,
    # report a spend, converge.
    inner = fn part, _worktree, %{budget: share, report_spent: report_spent} ->
      send(test_pid, {:share, hd(part.goals).id, share.max_iterations})
      report_spent.(%{iterations: share.max_iterations})
      :converged
    end

    assert {:ok, result} =
             Scheduler.run_goals(goals,
               workspace: ctx.workspace,
               graph_source: source,
               reconciler: inner,
               supervisor: ctx.sup,
               reconcile_timeout: 5_000,
               budget: Budget.new(max_iterations: 10)
             )

    # Two partitions ⇒ the budget of 10 splits into 5 + 5 (derived shares).
    shares =
      for _ <- goals do
        assert_receive {:share, _id, iters}
        iters
      end

    assert Enum.sort(shares) == [5, 5]
    assert Enum.sum(shares) == 10

    assert result.collective == :converged
    # The collective derived rollup sums the per-partition spend back to the whole.
    assert result.budget_spent == %{iterations: 10, elapsed_ms: 0, tokens: 0}
  end

  test "a partition exhausting its share reports :over_budget and does NOT abort siblings",
       ctx do
    source =
      TermSource.new(%{
        "a" => ["lib/a.ex"],
        "b" => ["lib/b.ex"],
        "c" => ["lib/c.ex"]
      })

    goals = [goal("g1", ["a"]), goal("g2", ["b"]), goal("g3", ["c"])]
    test_pid = self()

    # g1 is the over-budget partition: it reports it spent its whole share and
    # escalates :over_budget. The siblings converge — and must still FINISH (a
    # sibling abort would mean we never see their :ran message / their status).
    inner = fn part, _worktree, %{budget: share, report_spent: report_spent} ->
      id = hd(part.goals).id
      send(test_pid, {:ran, id})

      case id do
        "g1" ->
          report_spent.(%{iterations: share.max_iterations})
          :over_budget

        _ ->
          report_spent.(%{iterations: 1})
          :converged
      end
    end

    assert {:ok, result} =
             Scheduler.run_goals(goals,
               workspace: ctx.workspace,
               graph_source: source,
               reconciler: inner,
               supervisor: ctx.sup,
               reconcile_timeout: 5_000,
               budget: Budget.new(max_iterations: 9)
             )

    # ALL three partitions ran — the over-budget one did NOT abort its siblings.
    assert_receive {:ran, "g1"}
    assert_receive {:ran, "g2"}
    assert_receive {:ran, "g3"}

    # The collective verdict surfaces the over-budget partition.
    assert result.collective == :over_budget

    # Per-partition outcomes: g1 :over_budget, the rest :converged.
    statuses =
      Map.new(result.partitions, fn {part, status} -> {hd(part.goals).id, status} end)

    assert statuses == %{"g1" => :over_budget, "g2" => :converged, "g3" => :converged}

    # Per-partition budget_spent reflects each share's actual spend: g1 spent its
    # whole share (9 / 3 = 3), the siblings spent 1 each.
    by_goal =
      Map.new(result.partitions_budget, fn {part, status, spent} ->
        {hd(part.goals).id, {status, spent.iterations}}
      end)

    assert by_goal["g1"] == {:over_budget, 3}
    assert by_goal["g2"] == {:converged, 1}
    assert by_goal["g3"] == {:converged, 1}

    # The collective derived rollup sums per-partition spend (3 + 1 + 1).
    assert result.budget_spent == %{iterations: 5, elapsed_ms: 0, tokens: 0}
  end

  test "without a :budget, the result shape is unchanged (backward-compatible)", ctx do
    source = TermSource.new(%{"a" => ["lib/a.ex"]})
    inner = fn _part, _worktree -> :converged end

    assert {:ok, result} =
             Scheduler.run_goals([goal("solo", ["a"])],
               workspace: ctx.workspace,
               graph_source: source,
               reconciler: inner,
               supervisor: ctx.sup,
               reconcile_timeout: 5_000
             )

    assert result.collective == :converged
    refute Map.has_key?(result, :budget_spent)
    refute Map.has_key?(result, :partitions_budget)
  end
end
