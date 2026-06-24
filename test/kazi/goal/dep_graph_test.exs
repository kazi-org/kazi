defmodule Kazi.Goal.DepGraphTest do
  use ExUnit.Case, async: true
  doctest Kazi.Goal.DepGraph

  alias Kazi.Goal
  alias Kazi.Goal.{DepGraph, Group}

  # A diamond DAG (ADR-0028 §Decision 2/5 fixture):
  #
  #   a            (no needs — the root frontier)
  #   b needs a
  #   c needs a
  #   d needs b, c (the join — ready only once BOTH b and c converge)
  defp diamond_goal do
    groups = [
      Group.new("a", "A"),
      Group.new("b", "B", needs: ["a"]),
      Group.new("c", "C", needs: ["a"]),
      Group.new("d", "D", needs: ["b", "c"])
    ]

    Goal.new("diamond", groups: groups)
  end

  describe "ready_set/2 — the fully-parallel default" do
    test "a group with NO needs is always ready" do
      a = Group.new("a", "A")
      b = Group.new("b", "B")
      goal = Goal.new("g", groups: [a, b])

      assert DepGraph.ready_set(goal, %{}) == ["a", "b"]
    end

    test "an all-`needs: []` goal yields EVERY group ready at once" do
      groups = for n <- 1..5, do: Group.new("g#{n}", "G#{n}")
      goal = Goal.new("g", groups: groups)

      assert DepGraph.ready_set(goal, %{}) == ["g1", "g2", "g3", "g4", "g5"]
    end

    test "a goal with no groups yields an empty ready set" do
      assert DepGraph.ready_set(Goal.new("g"), %{}) == []
    end
  end

  describe "ready_set/2 — needs gating" do
    test "a group whose every needs dep is :converged is ready" do
      a = Group.new("a", "A")
      b = Group.new("b", "B", needs: ["a"])
      goal = Goal.new("g", groups: [a, b])

      ready = DepGraph.ready_set(goal, %{"a" => :converged})
      assert "b" in ready
      # a is already converged → nothing to dispatch for it.
      refute "a" in ready
    end

    test "a group with a :pending need is NOT ready" do
      a = Group.new("a", "A")
      b = Group.new("b", "B", needs: ["a"])
      goal = Goal.new("g", groups: [a, b])

      # a unobserved (→ pending) gates b; only a itself is ready.
      assert DepGraph.ready_set(goal, %{}) == ["a"]
      # a explicitly pending: same gate.
      assert DepGraph.ready_set(goal, %{"a" => :pending}) == ["a"]
    end

    test "a :running (in-flight) need also gates a dependent (not yet converged)" do
      a = Group.new("a", "A")
      b = Group.new("b", "B", needs: ["a"])
      goal = Goal.new("g", groups: [a, b])

      # a is running, not yet converged → b waits; a is in-flight so not re-dispatched.
      assert DepGraph.ready_set(goal, %{"a" => :running}) == []
    end

    test "ALL needs must converge, not just one" do
      a = Group.new("a", "A")
      b = Group.new("b", "B")
      c = Group.new("c", "C", needs: ["a", "b"])
      goal = Goal.new("g", groups: [a, b, c])

      # only a converged → c still waits on b.
      refute "c" in DepGraph.ready_set(goal, %{"a" => :converged})
      # both converged → c ready.
      assert "c" in DepGraph.ready_set(goal, %{"a" => :converged, "b" => :converged})
    end
  end

  describe "ready_set/2 — frontier advances by pure recompute" do
    test "after a frontier converges, the next-layer groups become ready" do
      goal = diamond_goal()

      # t0: only a is ready (b, c gated on a; d gated on b, c).
      assert DepGraph.ready_set(goal, %{}) == ["a"]

      # t1: a converged → b and c become ready; d still gated.
      assert DepGraph.ready_set(goal, %{"a" => :converged}) == ["b", "c"]

      # t2: a, b, c converged → d becomes ready.
      states = %{"a" => :converged, "b" => :converged, "c" => :converged}
      assert DepGraph.ready_set(goal, states) == ["d"]

      # t3: everything converged → nothing left to dispatch.
      states = Map.put(states, "d", :converged)
      assert DepGraph.ready_set(goal, states) == []
    end

    test "the diamond readies correctly layer by layer (only the JOIN waits for both)" do
      goal = diamond_goal()

      # b converged but c only running → d (needs b AND c) is NOT ready yet.
      states = %{"a" => :converged, "b" => :converged, "c" => :running}
      assert DepGraph.ready_set(goal, states) == []

      # c then converges → d readies.
      states = %{states | "c" => :converged}
      assert DepGraph.ready_set(goal, states) == ["d"]
    end
  end

  describe "blocked/2 — unsatisfiable sub-DAGs, with attribution" do
    test "a group directly behind a :stuck dep is blocked, and NAMES the dep" do
      a = Group.new("a", "A")
      b = Group.new("b", "B", needs: ["a"])
      goal = Goal.new("g", groups: [a, b])

      assert DepGraph.blocked(goal, %{"a" => :stuck}) ==
               [%{group: "b", blocked_by: "a", reason: :stuck}]
    end

    test "a TRANSITIVE dep that is :stuck/:over_budget blocks the whole chain downstream" do
      # a → b → c (c transitively needs a via b).
      a = Group.new("a", "A")
      b = Group.new("b", "B", needs: ["a"])
      c = Group.new("c", "C", needs: ["b"])
      goal = Goal.new("g", groups: [a, b, c])

      blocked = DepGraph.blocked(goal, %{"a" => :over_budget})

      # b is directly behind a; c is transitively behind a (its nearest blocker is b's
      # blocker — walking out from c the first blocking group reached is a).
      assert %{group: "b", blocked_by: "a", reason: :over_budget} in blocked
      assert %{group: "c", blocked_by: "a", reason: :over_budget} in blocked
      assert length(blocked) == 2
    end

    test "a group in a blocking state is the CAUSE, not a blocked entry (no self-block)" do
      # A lone stuck group with no dependents has nothing it blocks → empty set.
      a = Group.new("a", "A")
      goal = Goal.new("g", groups: [a])

      assert DepGraph.blocked(goal, %{"a" => :stuck}) == []
    end

    test "a :blocked dep propagates to its dependents (but the dep itself is not re-listed)" do
      a = Group.new("a", "A")
      b = Group.new("b", "B", needs: ["a"])
      goal = Goal.new("g", groups: [a, b])

      # a is the cause (not listed); b — its dependent — is blocked, named for a.
      assert DepGraph.blocked(goal, %{"a" => :blocked}) ==
               [%{group: "b", blocked_by: "a", reason: :blocked}]
    end

    test "the NEAREST blocker is named when several lie on the ancestry" do
      # a (over_budget) → b (stuck) → c. Walking out from c, b is nearer than a.
      a = Group.new("a", "A")
      b = Group.new("b", "B", needs: ["a"])
      c = Group.new("c", "C", needs: ["b"])
      goal = Goal.new("g", groups: [a, b, c])

      blocked = DepGraph.blocked(goal, %{"a" => :over_budget, "b" => :stuck})
      c_entry = Enum.find(blocked, &(&1.group == "c"))

      assert c_entry == %{group: "c", blocked_by: "b", reason: :stuck}
    end

    test "no blocking state → nothing blocked" do
      goal = diamond_goal()
      assert DepGraph.blocked(goal, %{}) == []
      assert DepGraph.blocked(goal, %{"a" => :converged}) == []
      assert DepGraph.blocked(goal, %{"a" => :running}) == []
    end

    test "a stuck dep blocks dependents but NOT its independent siblings" do
      goal = diamond_goal()

      # b is stuck → d (needs b, c) is blocked; c (needs only a) is NOT.
      blocked = DepGraph.blocked(goal, %{"a" => :converged, "b" => :stuck})
      blocked_ids = Enum.map(blocked, & &1.group)

      assert "d" in blocked_ids
      refute "c" in blocked_ids
      # b is the CAUSE — it is not itself a blocked entry.
      refute "b" in blocked_ids
      # d is named for its stuck dep b.
      assert %{group: "d", blocked_by: "b", reason: :stuck} in blocked
    end
  end

  describe "evaluate/2 — ready + blocked in one pass; the blocked are NOT ready" do
    test "ready and blocked are disjoint (a blocked group is never reported ready)" do
      goal = diamond_goal()

      # a converged, b stuck → c ready, d blocked (on b). b is the cause (not a
      # blocked entry); d must not appear ready.
      result = DepGraph.evaluate(goal, %{"a" => :converged, "b" => :stuck})

      assert result.ready == ["c"]
      assert result.blocked == [%{group: "d", blocked_by: "b", reason: :stuck}]
      refute "d" in result.ready
      refute "b" in result.ready
    end

    test "the full diamond happy path: a frontier of one, then two, then the join" do
      goal = diamond_goal()

      assert DepGraph.evaluate(goal, %{}) == %{ready: ["a"], blocked: []}

      assert DepGraph.evaluate(goal, %{"a" => :converged}) ==
               %{ready: ["b", "c"], blocked: []}

      states = %{"a" => :converged, "b" => :converged, "c" => :converged}
      assert DepGraph.evaluate(goal, states) == %{ready: ["d"], blocked: []}
    end

    test "feeding the blocked groups back in (as :blocked) is idempotent" do
      goal = diamond_goal()

      first = DepGraph.evaluate(goal, %{"a" => :converged, "b" => :stuck})

      # Project the blocked attribution back into the state map and re-evaluate.
      states =
        Enum.reduce(first.blocked, %{"a" => :converged, "b" => :stuck}, fn entry, acc ->
          Map.put_new(acc, entry.group, :blocked)
        end)

      second = DepGraph.evaluate(goal, states)

      # The ready set is unchanged; d stays blocked, now attributed to its nearest
      # blocking dep on the second pass.
      assert second.ready == ["c"]
      assert "d" in Enum.map(second.blocked, & &1.group)
      refute "d" in second.ready
    end
  end

  describe "pure + deterministic" do
    test "the same goal + states always yield the same evaluation" do
      goal = diamond_goal()
      states = %{"a" => :converged, "b" => :stuck}

      assert DepGraph.evaluate(goal, states) == DepGraph.evaluate(goal, states)
      assert DepGraph.ready_set(goal, states) == DepGraph.ready_set(goal, states)
      assert DepGraph.blocked(goal, states) == DepGraph.blocked(goal, states)
    end

    test "results preserve declared group order at every layer" do
      # Declare out of dependency order to prove ORDER follows declaration, not deps.
      groups = [
        Group.new("z", "Z", needs: ["root"]),
        Group.new("m", "M", needs: ["root"]),
        Group.new("root", "Root"),
        Group.new("a", "A", needs: ["root"])
      ]

      goal = Goal.new("g", groups: groups)

      # root converged → its three dependents ready in DECLARED order (z, m, a),
      # not sorted.
      assert DepGraph.ready_set(goal, %{"root" => :converged}) == ["z", "m", "a"]
    end

    test "evaluate/2 defaults to an empty state map (all pending)" do
      goal = diamond_goal()
      assert DepGraph.evaluate(goal) == %{ready: ["a"], blocked: []}
    end
  end
end
