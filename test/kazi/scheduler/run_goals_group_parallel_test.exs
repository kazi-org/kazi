defmodule Kazi.Scheduler.RunGoalsGroupParallelTest do
  @moduledoc """
  Regression: a SINGLE goal whose predicates are organized into 2+ INDEPENDENT
  groups (no `needs` edges) must run its disjoint groups IN PARALLEL, not collapse
  into one serial partition.

  The partition unit for a single bare goal is the whole goal, so the flat path
  yields exactly one partition — which silently serialized a multi-group goal even
  though its groups were independent (the "disjoint groups collapse into one
  partition" bug a parallel-run dogfood exposed). `Kazi.Scheduler.run_goals/2` now
  routes a fully-grouped multi-group goal through the group scheduler, which with no
  `needs` dispatches every group in one frontier (fully parallel, the ADR-0027
  default). A goal with any UNGROUPED acceptance predicate stays flat so those
  predicates are never dropped by the per-group split.

  Hermetic: an injected group reconciler (no harness/loop/git/NATS), gated on a
  release message so dispatch concurrency is observable.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.Predicate
  alias Kazi.Scheduler
  alias Kazi.Scheduler.PartitionSupervisor

  setup do
    {:ok, sup} = start_supervised(PartitionSupervisor)
    %{sup: sup}
  end

  defp pred(id, group),
    do: %Predicate{id: id, kind: :file_exists, group: group, config: %{path: "#{id}.txt"}}

  defp grouped_goal(group_ids) do
    %Goal{
      Goal.new("multi")
      | groups: Enum.map(group_ids, fn id -> %Group{id: id, name: id, needs: []} end),
        predicates: Enum.map(group_ids, fn id -> pred(id, id) end)
    }
  end

  test "a single goal with 2 disjoint no-needs groups dispatches them CONCURRENTLY", %{sup: sup} do
    test_pid = self()
    goal = grouped_goal(["alpha", "beta"])

    # Each group announces its dispatch (with its own pid) then blocks until the
    # test releases it. Both must announce before either is released ⇒ they were
    # dispatched concurrently in ONE frontier (not serialized).
    gated = fn group_id ->
      send(test_pid, {:dispatched, group_id, self()})

      receive do
        {:release, ^group_id} -> :converged
      end
    end

    runner =
      Task.async(fn ->
        Scheduler.run_goals([goal],
          workspace: File.cwd!(),
          supervisor: sup,
          group_reconciler: gated,
          reconcile_timeout: 5_000
        )
      end)

    assert_receive {:dispatched, "alpha", alpha_pid}, 1_000
    assert_receive {:dispatched, "beta", beta_pid}, 1_000

    # Both in flight at once: release them and collect the collective verdict.
    send(alpha_pid, {:release, "alpha"})
    send(beta_pid, {:release, "beta"})

    assert {:ok, result} = Task.await(runner, 5_000)
    assert result.collective == :converged
    # The group-parallel result carries a per-GROUP view (not a single partition).
    assert Map.has_key?(result, :groups)
    assert Enum.sort(Enum.map(result.groups, &elem(&1, 0))) == ["alpha", "beta"]
  end

  test "a goal with an UNGROUPED acceptance predicate stays flat (predicates not dropped)",
       %{sup: sup} do
    test_pid = self()

    goal = %Goal{
      Goal.new("mixed")
      | groups: [
          %Group{id: "alpha", name: "alpha", needs: []},
          %Group{id: "beta", name: "beta", needs: []}
        ],
        predicates: [pred("a", "alpha"), pred("u", nil)]
    }

    # The flat path hands the inner reconciler the WHOLE goal (all predicates),
    # proving nothing was split away by a per-group route.
    inner = fn partition, _worktree ->
      ids = partition.goals |> Enum.flat_map(& &1.predicates) |> Enum.map(& &1.id) |> Enum.sort()
      send(test_pid, {:flat_partition, ids})
      :converged
    end

    assert {:ok, result} =
             Scheduler.run_goals([goal],
               workspace: File.cwd!(),
               supervisor: sup,
               reconciler: inner,
               reconcile_timeout: 5_000
             )

    # Flat result shape (one partition over the whole goal), not the group view.
    assert Map.has_key?(result, :partitions)
    assert length(result.partitions) == 1
    refute Map.has_key?(result, :groups)
    assert_received {:flat_partition, ["a", "u"]}
  end
end
