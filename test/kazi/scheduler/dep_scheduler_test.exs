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

  describe "objective re-gating on regression (T23.4, ADR-0028 §Decision 4)" do
    test "a converged dep forced back to :pending re-gates its dependents; both re-run",
         %{sup: sup} do
      # a→b→t chain. `t` (a regressor) needs b, so by the time it runs, b has
      # OBJECTIVELY converged (the scheduler dispatched t only because b's
      # group_done was recorded). On its FIRST run `t` posts {:regress, "a",
      # :pending} — the regression guard firing on a — then converges. a (and its
      # transitive dependents b, t) must RE-RUN: each runs TWICE. The Agent counts
      # invocations, and `t`'s flag fires the regress exactly once so the run
      # terminates instead of looping.
      test_pid = self()
      {:ok, counts} = Agent.start_link(fn -> %{} end)
      {:ok, fired} = Agent.start_link(fn -> false end)

      goal = dag_goal(a: [], b: [:a], t: [:b])

      bump = fn id ->
        Agent.get_and_update(counts, fn m ->
          next = Map.get(m, id, 0) + 1
          {next, Map.put(m, id, next)}
        end)
      end

      # 2-arity so `t` can message the SCHEDULER to post the regression.
      reconciler = fn
        "t", scheduler ->
          n = bump.("t")
          send(test_pid, {:ran, "t", n})

          # Fire the regression exactly ONCE, on t's first run (b is converged now).
          if not Agent.get(fired, & &1) do
            Agent.update(fired, fn _ -> true end)
            send(scheduler, {:regress, "a", :pending})
          end

          :converged

        id, _scheduler ->
          send(test_pid, {:ran, id, bump.(id)})
          :converged
      end

      assert {:ok, result} =
               DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)

      # The dep and its dependent b RE-RAN after a regressed: each ran TWICE (b
      # left the ready set the instant a flipped and re-ran only once a re-converged
      # — no dependent stayed green against the regressed dep). `t` (which fired the
      # regress while itself running) was already converged, so it is not re-gated.
      counts_now = Agent.get(counts, & &1)
      assert counts_now["a"] == 2
      assert counts_now["b"] == 2

      assert result.collective == :converged
      assert result.groups == [{"a", :converged}, {"b", :converged}, {"t", :converged}]
      assert result.blocked == []
    end

    test "a dep that regresses INTO a terminal (:stuck) blocks its dependents", %{sup: sup} do
      # a has two dependents: b and c. c needs a, so when c runs a has objectively
      # converged. c regresses a straight to :stuck (the regression guard firing
      # into a non-converging terminal). a can no longer satisfy b's gate, so b is
      # RE-GATED and, with a now terminal, BLOCKED. a is reported as the cause
      # (:stuck), not blocked. The regress fires exactly once.
      {:ok, fired} = Agent.start_link(fn -> false end)
      goal = dag_goal(a: [], b: [:a], c: [:a])

      reconciler = fn
        "c", scheduler ->
          if not Agent.get(fired, & &1) do
            Agent.update(fired, fn _ -> true end)
            send(scheduler, {:regress, "a", :stuck})
          end

          :converged

        _id, _scheduler ->
          :converged
      end

      assert {:ok, result} =
               DepScheduler.run(goal,
                 reconciler: reconciler,
                 supervisor: sup,
                 reconcile_timeout: 1_000
               )

      # a is the cause (:stuck); b can never re-satisfy its gate → blocked, named
      # for a. (c, a's other dependent, ran before the regress but its sub-DAG is
      # now poisoned by a too, so it is escalated under a as well.)
      assert {"a", :stuck} in result.groups
      assert {"b", :blocked} in result.groups
      assert result.collective == :stuck
      assert %{group: "b", blocked_by: "a", reason: :stuck} in result.blocked

      escalation = Enum.find(result.escalations, &(&1.blocker == "a"))
      assert escalation.reason == :stuck
      assert "b" in escalation.blocked
    end

    test "a regress on a non-converged group is a no-op", %{sup: sup} do
      # Regressing a group that is not currently :converged must not disturb the run.
      # `t` needs a; when it runs, a has converged. t posts a regress for `b`, which
      # is not even a member here... instead it regresses ITSELF (`t`), which is
      # :running, not :converged — a no-op. The run still converges fully.
      {:ok, fired} = Agent.start_link(fn -> false end)
      goal = dag_goal(a: [], t: [:a])

      reconciler = fn
        "t", scheduler ->
          if not Agent.get(fired, & &1) do
            Agent.update(fired, fn _ -> true end)
            # t is :running (not :converged) → this regress is a no-op.
            send(scheduler, {:regress, "t", :pending})
          end

          :converged

        "a", _scheduler ->
          :converged
      end

      assert {:ok, result} =
               DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)

      assert result.collective == :converged
      assert result.groups == [{"a", :converged}, {"t", :converged}]
    end
  end

  describe "blocked-dependency escalation verdict (T23.5, ADR-0028 §Decision 5)" do
    test "the collective verdict ESCALATES the sub-DAG: names the blocker AND lists its blocked dependents",
         %{sup: sup} do
      # a is stuck; b needs a, c needs b ⇒ a poisons {b, c}. A disjoint sibling x
      # finishes. The escalation groups the blocked sub-DAG BY blocker: a names
      # [b], b (now :blocked) names [c]. Siblings outside finish; no hang.
      goal = dag_goal(a: [], b: [:a], c: [:b], x: [])

      statuses = %{"a" => :stuck, "x" => :converged}
      reconciler = fn group_id -> Map.fetch!(statuses, group_id) end

      assert {:ok, result} =
               DepScheduler.run(goal,
                 reconciler: reconciler,
                 supervisor: sup,
                 reconcile_timeout: 1_000
               )

      # The run terminated; siblings outside the sub-DAG finished.
      assert {"x", :converged} in result.groups
      assert {"a", :stuck} in result.groups
      assert result.collective == :stuck

      # The escalations name each blocker AND list the dependents it stalled.
      assert %{blocker: "a", reason: :stuck, blocked: ["b"]} in result.escalations
      assert %{blocker: "b", reason: :blocked, blocked: ["c"]} in result.escalations
      # A converged-everywhere sibling is NOT in any escalation.
      refute Enum.any?(result.escalations, fn e -> "x" in e.blocked end)
    end

    test "one blocker with several dependents is escalated as ONE entry listing them all",
         %{sup: sup} do
      # a stuck; b, c, d all need a ⇒ one escalation for a listing [b, c, d] in
      # declared order (not three separate single-dependent escalations).
      goal = dag_goal(a: [], b: [:a], c: [:a], d: [:a])

      reconciler = fn "a" -> :stuck end

      assert {:ok, result} =
               DepScheduler.run(goal,
                 reconciler: reconciler,
                 supervisor: sup,
                 reconcile_timeout: 1_000
               )

      assert result.collective == :stuck
      assert result.escalations == [%{blocker: "a", reason: :stuck, blocked: ["b", "c", "d"]}]
    end

    test "an over_budget dep escalates likewise, naming it", %{sup: sup} do
      goal = dag_goal(a: [], b: [:a])
      reconciler = fn "a" -> :over_budget end

      assert {:ok, result} =
               DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)

      assert result.collective == :over_budget
      assert %{blocker: "a", reason: :over_budget, blocked: ["b"]} in result.escalations
    end

    test "a fully-converged run has NO escalations", %{sup: sup} do
      goal = dag_goal(a: [], b: [:a])
      reconciler = fn _ -> :converged end

      assert {:ok, result} =
               DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)

      assert result.collective == :converged
      assert result.escalations == []
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
