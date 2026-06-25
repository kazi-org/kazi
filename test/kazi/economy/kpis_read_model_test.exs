defmodule Kazi.Economy.KPIsReadModelTest do
  @moduledoc """
  Tier 2 — the run-end economy KPIs compute from a RECORDED run (T34.6 acc): the
  per-iteration `context`/`tools` counters are recorded through `Kazi.ReadModel`
  (T34.3) and folded back into the KPIs via `Kazi.Economy.KPIs.from_iterations/2`,
  exercising the real SQLite read-model boundary the CLI's `run_economy` reads.
  """
  use ExUnit.Case, async: false

  alias Kazi.{PredicateResult, PredicateVector, Repo}
  alias Kazi.Economy.KPIs
  alias Kazi.ReadModel

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "folds the recorded per-iteration counters of a converged run into the KPIs" do
    goal_ref = "econ-recorded"
    failing = PredicateVector.new(%{code: PredicateResult.fail(), live: PredicateResult.fail()})
    passing = PredicateVector.new(%{code: PredicateResult.pass(), live: PredicateResult.pass()})

    # Iteration 0 — cold dispatch: orientation cache MISS, heavy re-discovery.
    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: 0,
        predicate_vector: failing,
        converged: false,
        observed_at: ~U[2026-06-25 09:00:00.000000Z],
        context: %{
          orientation_cache: "miss",
          retrieval_cache: "disabled",
          orientation_tokens: 500,
          evidence_tokens: 60,
          retrieval_tokens: 0
        },
        tools: %{tool_calls: 10, file_reads: 7, search_calls: 2, graph_calls: 1}
      })

    # Iteration 1 — warm dispatch: orientation cache HIT, fewer tool calls, converged.
    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: 1,
        predicate_vector: passing,
        converged: true,
        observed_at: ~U[2026-06-25 09:00:30.000000Z],
        context: %{
          orientation_cache: "hit",
          retrieval_cache: "disabled",
          orientation_tokens: 500,
          evidence_tokens: 40,
          retrieval_tokens: 0
        },
        tools: %{tool_calls: 3, file_reads: 1, search_calls: 0, graph_calls: 0}
      })

    iterations = ReadModel.list_iterations(goal_ref)
    assert length(iterations) == 2

    kpis =
      KPIs.from_iterations(iterations, %{
        status: "converged",
        converged_predicates: 2,
        iteration_count: 2,
        usage: %{cost_usd: 0.05},
        harness: "claude",
        model: "haiku",
        context_tier: "C"
      })

    assert kpis.status == "converged"
    assert kpis.converged_predicates == 2
    # Convergence at the 2nd observation.
    assert kpis.iterations_to_convergence == 2
    # 0.05 / 2 converged predicates.
    assert kpis.cost_per_converged_predicate == 0.025
    # 30s span between recorded observations.
    assert kpis.wall_clock_s == 30.0
    # The orientation HIT served its 500 tokens from cache (retrieval disabled).
    assert kpis.fresh_input_tokens_avoided == 500
    # Cold re-discovery 7+2+1 = 10; warm 1+0+0 = 1 ⇒ 9 avoided.
    assert kpis.rediscovery_tool_calls_avoided == 9
  end

  test "a pre-T34.3 recorded run (no counters) folds the cache/re-discovery KPIs to nil" do
    goal_ref = "econ-no-counters"
    vector = PredicateVector.new(%{code: PredicateResult.pass()})

    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: 0,
        predicate_vector: vector,
        converged: true,
        observed_at: ~U[2026-06-25 09:00:00.000000Z]
        # no :context / :tools — recorded as empty %{} (pre-T34.3 shape).
      })

    kpis =
      ReadModel.list_iterations(goal_ref)
      |> KPIs.from_iterations(%{
        status: "converged",
        converged_predicates: 1,
        iteration_count: 1,
        usage: %{}
      })

    assert kpis.fresh_input_tokens_avoided == nil
    assert kpis.rediscovery_tool_calls_avoided == nil
    # single observation ⇒ no measurable wall-clock span.
    assert kpis.wall_clock_s == nil
    # cost unreported ⇒ unavailable, not zero.
    assert kpis.cost_per_converged_predicate == nil
  end
end
