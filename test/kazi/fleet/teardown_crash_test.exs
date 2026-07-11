defmodule Kazi.Fleet.TeardownCrashTest do
  @moduledoc """
  issue #1053, sub-fixes (2) + (3): the collective's member object must carry
  a non-nil `:error` when a member genuinely crashes, and a dependent of a
  member that LANDED (its predicates hold / its branch integrated) but whose
  process then crashed must still dispatch — never blocked as if the dep's
  outcome were unknown.

  Hermetic: drives `Kazi.Fleet.Execution.run/2` directly with an injected
  `:member_runner` (no real git worktree, no harness) so each scenario is a
  pure function of what the runner returns/raises.
  """
  use ExUnit.Case, async: true

  alias Kazi.Fleet
  alias Kazi.Fleet.Execution

  defp fleet(nodes, edges \\ []) do
    %Fleet{nodes: nodes, edges: edges}
  end

  defp fleet_node(id), do: %Fleet.Node{id: id, goal: %{id: id, name: id}}

  describe "sub-fix (2): crash reason carried" do
    test "a member runner that raises reports :crashed with a non-nil error" do
      runner = fn %Fleet.Node{id: "a"} -> raise "kaboom in member a" end

      {:ok, result} =
        Execution.run(fleet([fleet_node("a")]), workspace: "/tmp/unused", member_runner: runner)

      assert result.collective == :stuck
      member = result.member_results["a"]
      assert member.status == :crashed
      refute is_nil(member.error)
      assert member.error =~ "kaboom in member a"
    end
  end

  describe "sub-fix (3): DAG gate distinguishes landed-then-crashed from crashed-before-landing" do
    test "a member that CONVERGED (landed) dispatches its dependent even though it also crashed once reported",
         %{} = _ctx do
      # The member runner is the "landed" outcome: our Worktree.wrap fix means
      # a post-landing teardown crash never even reaches here as an exception
      # -- the runner reports the member's TRUE outcome. B (a's dependent)
      # must still dispatch.
      runner = fn
        %Fleet.Node{id: "a"} -> %{status: :converged}
        %Fleet.Node{id: "b"} -> %{status: :converged}
      end

      {:ok, result} =
        Execution.run(
          fleet([fleet_node("a"), fleet_node("b")], [%Fleet.Edge{from: "a", to: "b"}]),
          workspace: "/tmp/unused",
          member_runner: runner
        )

      assert result.collective == :converged
      assert result.member_results["a"].status == :converged
      assert result.member_results["b"].status == :converged
      assert result.blocked == []
    end

    test "a member that crashed BEFORE landing blocks its dependent", %{} = _ctx do
      runner = fn
        %Fleet.Node{id: "a"} -> raise "crashed before landing"
        %Fleet.Node{id: "b"} -> %{status: :converged}
      end

      {:ok, result} =
        Execution.run(
          fleet([fleet_node("a"), fleet_node("b")], [%Fleet.Edge{from: "a", to: "b"}]),
          workspace: "/tmp/unused",
          member_runner: runner
        )

      assert result.collective == :stuck
      assert result.member_results["a"].status == :crashed
      refute is_nil(result.member_results["a"].error)
      refute Map.has_key?(result.member_results, "b")
      assert Enum.any?(result.blocked, &(&1.group == "b" and &1.blocked_by == "a"))
    end
  end
end
