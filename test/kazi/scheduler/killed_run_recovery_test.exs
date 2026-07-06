defmodule Kazi.Scheduler.KilledRunRecoveryTest do
  @moduledoc """
  Regression for issue #786: a `kazi apply --parallel` run externally killed
  mid-collective must not permanently poison later applies.

  Root cause: `Kazi.Runtime.run/2`'s t0 vacuous-goal guard (T2.3, R3) rejects a
  goal whose WHOLE predicate vector already passes with `{:error, :vacuous_goal}`
  — correct for a human-authored goal (nothing to converge means it was
  underspecified). But a scheduler PARTITION or `needs`-DAG GROUP's sub-goal is
  authored by kazi itself, and can legitimately already be satisfied: an earlier
  `--parallel` run killed mid-collective can leave its fix landed in the
  workspace before the run recorded convergence. `Kazi.Scheduler.reconcile_partition/2`
  folded EVERY `{:error, _}` (including `:vacuous_goal`) into `:stuck`, so a
  later `apply` re-observing the SAME already-fixed files re-derives the same
  `:stuck` verdict every time — indistinguishable from genuinely poisoned state,
  and unaffected by a new goal id, renamed groups, or a fresh worktree, because
  it is recomputed fresh from the world, not replayed from anything persisted.

  These tests exercise the REAL production reconciler (no injected stub) against
  a real filesystem workspace, so they prove the fix at the same seam the bug
  lived in, not just the surrounding scaffolding.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.Predicate
  alias Kazi.Scheduler
  alias Kazi.Scheduler.PartitionSupervisor

  setup do
    {:ok, sup} = start_supervised(PartitionSupervisor)

    workspace =
      Path.join(System.tmp_dir!(), "kazi-786-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    %{sup: sup, workspace: workspace}
  end

  # A predicate that trivially passes iff `marker` exists under the workspace —
  # standing in for "a killed run's fix already landed in the world".
  defp already_fixed_predicate(id, group, marker) do
    Predicate.new(id, :custom_script,
      group: group,
      config: %{cmd: "sh", args: ["-c", "test -f #{marker}"]}
    )
  end

  test "reconcile_partition/2 treats an already-satisfied partition as converged, not stuck",
       %{workspace: workspace} do
    File.write!(Path.join(workspace, "already_fixed.txt"), "left behind by a killed run\n")

    goal =
      Goal.new("recovering",
        predicates: [already_fixed_predicate(:fixed, nil, "already_fixed.txt")]
      )

    # No :reconciler/:harness injected — the REAL default reconciler, which calls
    # the REAL Kazi.Runtime.run/2 (and its real t0 vacuous-goal observation).
    assert Scheduler.reconcile_partition(%{goal: goal}, workspace: workspace, persist?: false) ==
             :converged
  end

  test "a needs-DAG goal recovering from a killed run's partial progress converges instead of an instant poisoned stuck",
       %{sup: sup, workspace: workspace} do
    # Simulate the exact repro: an earlier --parallel run was killed mid-collective
    # AFTER both waves' fixes had already landed in the workspace but BEFORE the
    # run recorded either as converged.
    File.write!(Path.join(workspace, "wave0_fixed.txt"), "wave0 done\n")
    File.write!(Path.join(workspace, "wave1_fixed.txt"), "wave1 done\n")

    goal = %Goal{
      Goal.new("issue-786-recovery")
      | groups: [
          Group.new("wave0", "wave0", needs: []),
          Group.new("wave1", "wave1", needs: ["wave0"])
        ],
        predicates: [
          already_fixed_predicate(:wave0_check, "wave0", "wave0_fixed.txt"),
          already_fixed_predicate(:wave1_check, "wave1", "wave1_fixed.txt")
        ]
    }

    # No :group_reconciler/:reconciler injected: the REAL `run_goal_dag/2` ->
    # `default_group_reconciler/2` -> `reconcile_partition/2` -> `Kazi.Runtime.run/2`
    # chain, exactly the collapsed-to-:stuck path #786 reported.
    assert {:ok, result} =
             Scheduler.run_goals([goal],
               workspace: workspace,
               supervisor: sup,
               reconcile_timeout: 5_000,
               run_opts: [persist?: false]
             )

    assert result.collective == :converged
    assert Enum.sort(result.groups) == [{"wave0", :converged}, {"wave1", :converged}]
    assert result.blocked == []
  end
end
