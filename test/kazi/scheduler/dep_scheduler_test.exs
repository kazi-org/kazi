defmodule Kazi.Scheduler.DepSchedulerTest do
  @moduledoc """
  T23.3 acceptance (ADR-0028): the topological, PIPELINED scheduler over a goal's
  `needs`-DAG. The scheduler dispatches only the READY SET, runs ready groups
  concurrently under the `DynamicSupervisor`, RE-EVALUATES the ready set as each
  group converges (newly-eligible groups dispatch immediately, NO barrier), and
  surfaces BLOCKED sub-DAGs naming the blocking dep without hanging.

  Every case is hermetic: the reconciler is an injected STUB (no real harness,
  loop, git, or NATS). Convergence is driven by controlling the stub's return per
  group; PIPELINING is asserted by gating stubs on a `release` message so a group
  cannot finish until the test lets it, exposing the dispatch ORDER and the
  overlap of disjoint groups.

  Each test starts its OWN isolated `Kazi.Scheduler.PartitionSupervisor` instance
  so cases never contend and can run `async`.
  """
  use ExUnit.Case, async: true

  alias Kazi.Context.Survey
  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.Scheduler.DepScheduler
  alias Kazi.Scheduler.PartitionSupervisor

  defmodule StaticEmptySource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, _terms, _opts), do: Survey.new(:graph, files: [])
  end

  setup do
    {:ok, sup} = start_supervised(PartitionSupervisor)
    %{sup: sup}
  end

  # A goal whose groups carry the given `needs` edges. `edges` is a keyword list
  # `group_id => [dep_id]`; declared order is the keyword order.
  defp dag_goal(edges) do
    groups =
      Enum.map(edges, fn {id, needs} ->
        Group.new(to_string(id), to_string(id), needs: Enum.map(needs, &to_string/1))
      end)

    Goal.new("dag", groups: groups)
  end

  # A reconciler stub that ANNOUNCES its dispatch (with its own pid so the test can
  # release it) and then blocks until the test sends `{:release, id}`, returning a
  # chosen terminal status. This exposes dispatch ORDER and lets us prove a group
  # is in-flight (not yet converged) at a chosen instant — the basis for the
  # pipelining assertions.
  defp gated_reconciler(test_pid, status \\ :converged) do
    fn group_id ->
      send(test_pid, {:dispatched, group_id, self()})

      receive do
        {:release, ^group_id} -> status
      end
    end
  end

  describe "ready-set dispatch (only eligible groups start)" do
    test "a group with an unconverged needs dep does NOT dispatch until the dep converges",
         %{sup: sup} do
      # b needs a. a is gated on a release; while a is in-flight, b must NOT start.
      test_pid = self()
      goal = dag_goal(a: [], b: [:a])
      reconciler = gated_reconciler(test_pid)

      task =
        Task.async(fn ->
          DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)
        end)

      # a dispatches immediately (no needs); b does NOT (its dep a is pending).
      assert_receive {:dispatched, "a", a_pid}
      refute_receive {:dispatched, "b", _}, 50

      # Release a → it converges → b becomes ready and dispatches.
      send(a_pid, {:release, "a"})
      assert_receive {:dispatched, "b", b_pid}
      send(b_pid, {:release, "b"})

      assert {:ok, result} = Task.await(task)
      assert result.collective == :converged
      assert result.groups == [{"a", :converged}, {"b", :converged}]
      assert result.blocked == []
    end
  end

  describe "pipelining (no global barrier)" do
    test "diamond A;B←A;C←A;D←B,C: B and C start the moment A converges; D the moment BOTH do",
         %{sup: sup} do
      # Disjoint B and C overlap; D waits for BOTH; nothing waits on an unrelated
      # group. Every group is gated so we observe the exact frontier transitions.
      test_pid = self()
      goal = dag_goal(a: [], b: [:a], c: [:a], d: [:b, :c])
      reconciler = gated_reconciler(test_pid)

      task =
        Task.async(fn ->
          DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)
        end)

      # Frontier 1: only A (B/C/D all gated behind unconverged deps).
      assert_receive {:dispatched, "a", a_pid}
      refute_receive {:dispatched, "b", _}, 30
      refute_receive {:dispatched, "c", _}, 30
      refute_receive {:dispatched, "d", _}, 30

      # A converges → B AND C become ready and dispatch CONCURRENTLY (overlap).
      send(a_pid, {:release, "a"})
      assert_receive {:dispatched, "b", b_pid}
      assert_receive {:dispatched, "c", c_pid}
      # D still blocked — neither of its deps has converged.
      refute_receive {:dispatched, "d", _}, 30

      # Converge ONLY B; D must still NOT start (C outstanding) — pipelining does
      # not over-eagerly dispatch, and does not wait on any unrelated group.
      send(b_pid, {:release, "b"})
      refute_receive {:dispatched, "d", _}, 30

      # Converge C → NOW both of D's deps are converged → D dispatches immediately.
      send(c_pid, {:release, "c"})
      assert_receive {:dispatched, "d", d_pid}
      send(d_pid, {:release, "d"})

      assert {:ok, result} = Task.await(task)
      assert result.collective == :converged

      assert result.groups == [
               {"a", :converged},
               {"b", :converged},
               {"c", :converged},
               {"d", :converged}
             ]
    end

    test "the dispatch ORDER respects needs while disjoint groups overlap", %{sup: sup} do
      # Record the order groups are dispatched; assert a precedes b,c and b,c
      # precede d, while b and c (disjoint) may interleave.
      test_pid = self()
      goal = dag_goal(a: [], b: [:a], c: [:a], d: [:b, :c])

      reconciler = fn group_id ->
        send(test_pid, {:order, group_id})
        :converged
      end

      assert {:ok, result} =
               DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)

      order = drain_order([])
      assert result.collective == :converged

      assert before?(order, "a", "b")
      assert before?(order, "a", "c")
      assert before?(order, "b", "d")
      assert before?(order, "c", "d")
    end
  end

  describe "degenerate (no needs) ⇒ flat parallel parity" do
    test "a no-needs goal-set dispatches every group at once (the T21 flat run)", %{sup: sup} do
      # No edges ⇒ every group ready at frontier 1 ⇒ all dispatch before any
      # converges (proven by gating: all are in-flight simultaneously).
      test_pid = self()
      goal = dag_goal(a: [], b: [], c: [])
      reconciler = gated_reconciler(test_pid)

      task =
        Task.async(fn ->
          DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)
        end)

      # ALL three are dispatched before any has converged — fully parallel.
      assert_receive {:dispatched, "a", a_pid}
      assert_receive {:dispatched, "b", b_pid}
      assert_receive {:dispatched, "c", c_pid}

      for {id, pid} <- [{"a", a_pid}, {"b", b_pid}, {"c", c_pid}],
          do: send(pid, {:release, id})

      assert {:ok, result} = Task.await(task)
      assert result.collective == :converged
      assert result.groups == [{"a", :converged}, {"b", :converged}, {"c", :converged}]
      assert result.blocked == []
    end
  end

  describe "blocked sub-DAG escalation (does NOT hang)" do
    test "a :stuck dep blocks its dependents; the collective NAMES the blocking dep", %{sup: sup} do
      # a is stuck; b needs a, c needs b ⇒ both b and c are unsatisfiable. An
      # unrelated sibling x (no needs) still finishes. The scheduler does NOT hang.
      goal = dag_goal(a: [], b: [:a], c: [:b], x: [])

      statuses = %{"a" => :stuck, "x" => :converged}
      reconciler = fn group_id -> Map.fetch!(statuses, group_id) end

      assert {:ok, result} =
               DepScheduler.run(goal,
                 reconciler: reconciler,
                 supervisor: sup,
                 reconcile_timeout: 1_000
               )

      # a ran and stuck; x (sibling outside the blocked sub-DAG) converged.
      assert {"a", :stuck} in result.groups
      assert {"x", :converged} in result.groups
      # b and c NEVER dispatched — they are blocked.
      assert {"b", :blocked} in result.groups
      assert {"c", :blocked} in result.groups

      # The collective is non-green and NAMES the blocking dep for each dependent.
      assert result.collective == :stuck
      assert %{group: "b", blocked_by: "a", reason: :stuck} in result.blocked
      assert %{group: "c", blocked_by: "b", reason: :blocked} in result.blocked
    end

    test "an :over_budget dep likewise blocks dependents, naming it", %{sup: sup} do
      goal = dag_goal(a: [], b: [:a])
      reconciler = fn "a" -> :over_budget end

      assert {:ok, result} =
               DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)

      assert {"a", :over_budget} in result.groups
      assert {"b", :blocked} in result.groups
      # over_budget present anywhere ⇒ collective over_budget.
      assert result.collective == :over_budget
      assert %{group: "b", blocked_by: "a", reason: :over_budget} in result.blocked
    end

    test "a crashing group reconciler is contained as :crashed; dependents block; no hang",
         %{sup: sup} do
      goal = dag_goal(a: [], b: [:a])
      reconciler = fn "a" -> raise "boom" end

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, r} =
                 DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)

        send(self(), {:result, r})
      end)

      assert_received {:result, result}

      # a crashed (folds to :stuck for the collective); b can never run → blocked.
      assert {"a", :crashed} in result.groups
      assert {"b", :blocked} in result.groups
      assert result.collective == :stuck
    end
  end

  describe "collective verdict composes per-group outcomes" do
    test "all converged ⇒ converged; any over_budget wins; else any stuck ⇒ stuck", %{sup: sup} do
      goal = dag_goal(a: [], b: [], c: [])

      reconciler = fn
        "a" -> :converged
        "b" -> :stuck
        "c" -> :over_budget
      end

      assert {:ok, result} =
               DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)

      assert result.collective == :over_budget
      assert {"a", :converged} in result.groups
      assert {"b", :stuck} in result.groups
      assert {"c", :over_budget} in result.groups
    end
  end

  describe "Scheduler.run_goals/2 routing (ADR-0028 backward compatibility)" do
    test "a SINGLE goal with a needs-DAG routes through the pipelined DepScheduler", %{sup: sup} do
      # run_goals/2 detects the non-trivial needs-DAG and drives it topologically;
      # an injected :group_reconciler keeps it hermetic. b waits for a.
      test_pid = self()
      goal = dag_goal(a: [], b: [:a])

      group_reconciler = fn group_id ->
        send(test_pid, {:group, group_id})
        :converged
      end

      assert {:ok, result} =
               Kazi.Scheduler.run_goals([goal],
                 workspace: "/unused-when-group-reconciler-injected",
                 group_reconciler: group_reconciler,
                 supervisor: sup
               )

      # The per-GROUP result shape (DepScheduler), not the flat per-partition one.
      assert result.collective == :converged
      assert result.groups == [{"a", :converged}, {"b", :converged}]
      assert Map.has_key?(result, :blocked)

      # a was reconciled before b (the needs order held).
      assert_received {:group, "a"}
      assert_received {:group, "b"}
    end

    test "a no-needs goal does NOT route to the DAG path (stays the flat run)", %{sup: sup} do
      # No edges ⇒ dag?/1 is false ⇒ run_goals/2 takes the flat partition path and
      # returns the per-PARTITION result shape (not :groups). Hermetic via an
      # injected flat reconciler + static graph source.
      goal =
        Goal.new("flat",
          groups: [Group.new("a", "a"), Group.new("b", "b")],
          metadata: %{partition_terms: ["t"]}
        )

      assert {:ok, result} =
               Kazi.Scheduler.run_goals([goal],
                 workspace: "/unused",
                 graph_source: {StaticEmptySource, []},
                 reconciler: fn _part, _path -> :converged end,
                 supervisor: sup,
                 reconcile_timeout: 1_000,
                 worktree: nil,
                 lease: nil
               )

      # Flat per-partition result shape — NOT the DAG per-group shape.
      assert result.collective == :converged
      assert Map.has_key?(result, :partitions)
      refute Map.has_key?(result, :groups)
    end
  end

  # --- helpers ---

  defp drain_order(acc) do
    receive do
      {:order, id} -> drain_order([id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp before?(order, x, y) do
    Enum.find_index(order, &(&1 == x)) < Enum.find_index(order, &(&1 == y))
  end
end
