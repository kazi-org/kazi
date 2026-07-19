defmodule Kazi.Loop.TerminalVectorFreshTest do
  @moduledoc """
  Issue #790: the loop's hard budget guard (T1.4) checks the ceiling at the
  START of every tick, BEFORE observing again — so a dispatch that finishes
  ALL the remaining work but blows the budget doing it lands on an
  `:over_budget` stop whose `result.vector` still reflects the PRE-dispatch
  observation (stale: reports failure even though the workspace is now green).

  This proves the loop runs ONE final predicate re-evaluation before emitting
  the terminal `:over_budget` result, so `result.vector` reflects the
  workspace as the loop actually leaves it.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # A provider that fails until the harness has dispatched at least once, then
  # passes — modeling a dispatch that completes the work in the same tick that
  # blows the budget (the harness runs BEFORE the next tick's budget check).
  defmodule FixedAfterDispatchProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, _context) do
      if Agent.get(__MODULE__, & &1) do
        PredicateResult.pass(%{id: id, status: :pass})
      else
        PredicateResult.fail(%{id: id, status: :fail})
      end
    end
  end

  defmodule OneShotHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      Agent.update(FixedAfterDispatchProvider, fn _ -> true end)
      {:ok, %{output: "ok", cost: %{tokens: 0}}}
    end
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> false end, name: FixedAfterDispatchProvider)
    :ok
  end

  test "an over_budget stop re-evaluates the vector so completed work is visible" do
    goal =
      Goal.new("terminal-vector-fresh-test",
        predicates: [Predicate.new(:code, :tests)],
        budget: Kazi.Budget.new(max_iterations: 1)
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: FixedAfterDispatchProvider},
        harness: OneShotHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        reobserve_interval_ms: 1,
        stuck_iterations: 0
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :over_budget
    assert result.reason == :max_iterations

    # The stale vector (observed BEFORE the dispatch that finished the work)
    # would report :fail here; the fix re-observes once more before
    # terminating, so the terminal vector reports the predicate as it
    # actually stands.
    assert PredicateResult.passed?(Kazi.PredicateVector.get(result.vector, :code))
  end
end
