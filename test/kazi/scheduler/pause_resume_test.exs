defmodule Kazi.Scheduler.PauseResumeTest do
  @moduledoc """
  T50.3 acceptance (ADR-0065, #936's full ask): under `:pause_between_waves`,
  the `DepScheduler` halts right after a topological frontier fully settles
  instead of dispatching the next one — no later-frontier group is ever
  started — and returns a resumable state. A follow-up `run/2` call seeded with
  that state (directly, or round-tripped through `resume_token/1` +
  `decode_resume_token/1`) continues from the next frontier to collective
  convergence without re-dispatching anything already settled. Without the
  flag, behavior is byte-identical to today (both frontiers dispatch in one
  run).

  Hermetic throughout: an injected stub reconciler tracks every dispatch (group
  id + call count) via an Agent, so dispatch is asserted on CALL COUNT/ARGV, not
  just timing.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.Scheduler.DepScheduler
  alias Kazi.Scheduler.PartitionSupervisor

  setup do
    {:ok, sup} = start_supervised(PartitionSupervisor)
    %{sup: sup}
  end

  # a, b independent (frontier 0); c needs BOTH a and b (frontier 1) — the same
  # fixture shape frontier_complete_event_test.exs uses, so frontier 1's
  # readiness is genuinely gated on the whole of frontier 0.
  defp two_frontier_goal do
    Goal.new("two-frontier",
      groups: [
        Group.new("a", "A"),
        Group.new("b", "B"),
        Group.new("c", "C", needs: ["a", "b"])
      ]
    )
  end

  # A reconciler that records every dispatch (group id, in order) into an Agent
  # and immediately converges. Lets the test assert dispatch COUNT/ARGV rather
  # than inferring "never dispatched" from timing alone.
  defp counting_reconciler(agent) do
    fn group_id ->
      Agent.update(agent, fn calls -> calls ++ [group_id] end)
      :converged
    end
  end

  describe "--pause-between-waves stops cleanly at a frontier boundary" do
    test "halts after frontier 0 settles; frontier 1's group is NOT dispatched", %{sup: sup} do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      goal = two_frontier_goal()
      reconciler = counting_reconciler(agent)

      assert {:ok, result} =
               DepScheduler.run(goal,
                 reconciler: reconciler,
                 supervisor: sup,
                 pause_between_waves: true
               )

      assert result.paused == true
      assert result.frontier == 0

      # Dispatch call count/argv proves c (frontier 1) never ran — not just
      # that the result came back before it "would have".
      assert Enum.sort(Agent.get(agent, & &1)) == ["a", "b"]

      assert Enum.sort(result.groups) == [{"a", :converged}, {"b", :converged}, {"c", :pending}]
      assert result.resume_state == %{"a" => :converged, "b" => :converged}
    end

    test "the terminal result carries a resume handle that completes frontier 1 to collective convergence",
         %{sup: sup} do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      goal = two_frontier_goal()
      reconciler = counting_reconciler(agent)

      assert {:ok, paused} =
               DepScheduler.run(goal,
                 reconciler: reconciler,
                 supervisor: sup,
                 pause_between_waves: true
               )

      assert paused.paused == true
      assert Agent.get(agent, & &1) |> Enum.sort() == ["a", "b"]

      assert {:ok, resumed} =
               DepScheduler.run(goal,
                 reconciler: reconciler,
                 supervisor: sup,
                 resume_state: paused.resume_state
               )

      # a and b are NOT re-dispatched on resume — only c runs.
      assert Agent.get(agent, & &1) |> Enum.sort() == ["a", "b", "c"]

      assert resumed.collective == :converged
      assert resumed.groups == [{"a", :converged}, {"b", :converged}, {"c", :converged}]
    end

    test "a resume token round-trips through resume_token/1 and decode_resume_token/1", %{
      sup: sup
    } do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      goal = two_frontier_goal()
      reconciler = counting_reconciler(agent)

      assert {:ok, paused} =
               DepScheduler.run(goal,
                 reconciler: reconciler,
                 supervisor: sup,
                 pause_between_waves: true
               )

      assert {:ok, token} = DepScheduler.resume_token(paused)
      assert is_binary(token)
      # An opaque, URL-safe token — safe to carry as a bare CLI argument.
      assert token =~ ~r/^[A-Za-z0-9_-]+$/

      assert {:ok, resume_state} = DepScheduler.decode_resume_token(token)
      assert resume_state == paused.resume_state

      assert {:ok, resumed} =
               DepScheduler.run(goal,
                 reconciler: reconciler,
                 supervisor: sup,
                 resume_state: resume_state
               )

      assert resumed.collective == :converged
      assert Agent.get(agent, & &1) |> Enum.sort() == ["a", "b", "c"]
    end

    test "decode_resume_token/1 rejects garbage input instead of raising" do
      assert DepScheduler.decode_resume_token("not-a-real-token") == {:error, :invalid_token}
      assert DepScheduler.decode_resume_token("") == {:error, :invalid_token}
    end

    test "resume_token/1 rejects a non-paused result" do
      assert DepScheduler.resume_token(%{collective: :converged}) == :error
    end
  end

  describe "without the flag, behavior is unchanged" do
    test "both frontiers dispatch in one run, byte-identical to today's result shape", %{
      sup: sup
    } do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      goal = two_frontier_goal()
      reconciler = counting_reconciler(agent)

      assert {:ok, result} = DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)

      refute Map.has_key?(result, :paused)
      assert result.collective == :converged
      assert result.groups == [{"a", :converged}, {"b", :converged}, {"c", :converged}]
      assert Agent.get(agent, & &1) |> Enum.sort() == ["a", "b", "c"]
    end
  end
end
