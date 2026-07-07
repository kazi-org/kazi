defmodule Kazi.Economy.RediscoveryReadModelTest do
  @moduledoc """
  Tier 2 -- the rediscovery-pressure signal computed from a RECORDED goal
  (T48.10 acc): the per-iteration `tools` counters (T34.3) are recorded through
  `Kazi.ReadModel` and folded back via `Kazi.Economy.Rediscovery.candidates/1`,
  exercising the real SQLite read-model boundary `kazi economy --rediscovery`
  reads through `Kazi.ReadModel.list_iterations/1`.
  """
  use ExUnit.Case, async: false

  alias Kazi.{PredicateResult, PredicateVector, Repo}
  alias Kazi.Economy.Rediscovery
  alias Kazi.ReadModel

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "ranks a recurring search-call category from a goal's recorded dispatches" do
    goal_ref = "rediscovery-recorded"
    failing = PredicateVector.new(%{code: PredicateResult.fail()})
    passing = PredicateVector.new(%{code: PredicateResult.pass()})

    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: 0,
        predicate_vector: failing,
        converged: false,
        observed_at: ~U[2026-07-07 09:00:00.000000Z],
        tools: %{tool_calls: 12, file_reads: 8, search_calls: 3, graph_calls: 1}
      })

    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: 1,
        predicate_vector: failing,
        converged: false,
        observed_at: ~U[2026-07-07 09:00:30.000000Z],
        tools: %{tool_calls: 5, file_reads: 0, search_calls: 4, graph_calls: 0}
      })

    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: 2,
        predicate_vector: passing,
        converged: true,
        observed_at: ~U[2026-07-07 09:01:00.000000Z],
        tools: %{tool_calls: 4, file_reads: 0, search_calls: 3, graph_calls: 0}
      })

    report =
      goal_ref
      |> ReadModel.list_iterations()
      |> Rediscovery.candidates()

    assert %{status: :ranked, candidates: [top | _]} = report
    assert top.category == :search_calls
    assert top.recurring_calls == 7
    assert top.recurring_dispatches == 2
  end

  test "a recorded goal with no tools counters reports :unknown, not an empty claim" do
    goal_ref = "rediscovery-no-counters"
    vector = PredicateVector.new(%{code: PredicateResult.pass()})

    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: 0,
        predicate_vector: vector,
        converged: true,
        observed_at: ~U[2026-07-07 09:00:00.000000Z]
        # no :tools -- recorded as empty %{} (pre-T34.3 / no tool-use stream).
      })

    report =
      goal_ref
      |> ReadModel.list_iterations()
      |> Rediscovery.candidates()

    assert %{status: :unknown, reason: reason} = report
    assert reason =~ "no tool-use stream recorded"
  end

  test "an unregistered goal ref (zero recorded iterations) reports :unknown" do
    report =
      "goal-that-never-ran"
      |> ReadModel.list_iterations()
      |> Rediscovery.candidates()

    assert %{status: :unknown, reason: reason} = report
    assert reason =~ "no iterations recorded"
  end
end
