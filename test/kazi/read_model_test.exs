defmodule Kazi.ReadModelTest do
  @moduledoc """
  Tier 2 — real SQLite boundary. Inserts iterations through `Kazi.ReadModel`,
  reads them back, and asserts the round-trip including the serialized evidence
  vector (T0.9, UC-006).
  """
  # SQLite has a single writer; the Sandbox shares one connection, so tests run
  # serially.
  use ExUnit.Case, async: false

  alias Kazi.{Action, PredicateResult, PredicateVector, Repo}
  alias Kazi.ReadModel

  setup do
    # Per-test transaction via the SQLite3 Sandbox — isolates rows between tests.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp sample_vector do
    PredicateVector.new(%{
      unit: PredicateResult.pass(%{exit: 0, output: "12 tests, 0 failures", duration_ms: 1200}),
      probe: PredicateResult.fail(%{http_status: 503, url: "https://example.test/healthz"})
    })
  end

  test "records an iteration and reads it back with the serialized evidence" do
    vector = sample_vector()
    action = Action.new(:dispatch_agent, params: %{"failing" => ["probe"]})
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, inserted} =
             ReadModel.record_iteration(%{
               goal_ref: "ship-it",
               iteration_index: 0,
               predicate_vector: vector,
               action: action,
               observed_at: observed_at
             })

    assert inserted.goal_ref == "ship-it"
    assert inserted.iteration_index == 0
    # A vector with a failing predicate is not converged (defaulted from the
    # vector).
    assert inserted.converged == false
    assert inserted.action_kind == "dispatch_agent"

    fetched = ReadModel.get_iteration("ship-it", 0)
    assert fetched.id == inserted.id

    # Round-trip the serialized evidence back into a PredicateVector.
    round_tripped = ReadModel.to_predicate_vector(fetched)
    assert PredicateVector.failing(round_tripped) == ["probe"]

    unit = PredicateVector.get(round_tripped, "unit")
    assert unit.status == :pass
    assert unit.evidence["output"] == "12 tests, 0 failures"
    assert unit.evidence["exit"] == 0

    probe = PredicateVector.get(round_tripped, "probe")
    assert probe.status == :fail
    assert probe.evidence["http_status"] == 503

    # Action params survived.
    assert fetched.action_params == %{"failing" => ["probe"]}
  end

  test "defaults converged to whether the full vector is satisfied" do
    all_pass =
      PredicateVector.new(%{
        unit: PredicateResult.pass(%{exit: 0}),
        probe: PredicateResult.pass(%{http_status: 200})
      })

    assert {:ok, converged} =
             ReadModel.record_iteration(%{
               goal_ref: "done-goal",
               iteration_index: 3,
               predicate_vector: all_pass
             })

    assert converged.converged == true
    # No action at the terminal converged observation.
    assert converged.action_kind == nil
    assert converged.action_params == %{}
  end

  test "lists iterations for a goal in iteration order" do
    for idx <- [2, 0, 1] do
      assert {:ok, _} =
               ReadModel.record_iteration(%{
                 goal_ref: "multi",
                 iteration_index: idx,
                 predicate_vector: sample_vector()
               })
    end

    indices = "multi" |> ReadModel.list_iterations() |> Enum.map(& &1.iteration_index)
    assert indices == [0, 1, 2]

    assert ReadModel.latest_iteration("multi").iteration_index == 2
  end

  test "iteration_history/1 returns the per-iteration vectors in order (T1.1)" do
    # Two distinct vectors recorded out of order; the history must come back
    # oldest-first with each iteration's FULL vector rehydrated.
    iter0 =
      PredicateVector.new(%{
        unit: PredicateResult.fail(%{exit: 1}),
        probe: PredicateResult.fail(%{http_status: 503})
      })

    iter1 =
      PredicateVector.new(%{
        unit: PredicateResult.pass(%{exit: 0}),
        probe: PredicateResult.pass(%{http_status: 200})
      })

    # Insert index 1 before index 0 to prove ordering is by iteration_index.
    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "hist",
               iteration_index: 1,
               predicate_vector: iter1
             })

    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "hist",
               iteration_index: 0,
               predicate_vector: iter0
             })

    history = ReadModel.iteration_history("hist")

    assert [{0, v0}, {1, v1}] = history

    # iter0: both predicates failing (full vector preserved, keyed by string id).
    assert MapSet.new(PredicateVector.failing(v0)) == MapSet.new(["unit", "probe"])
    assert PredicateVector.get(v0, "probe").evidence["http_status"] == 503

    # iter1: the satisfied convergence vector.
    assert PredicateVector.satisfied?(v1)
    assert PredicateVector.get(v1, "unit").status == :pass
  end

  test "iteration_history/1 is empty for a goal with no recorded iterations (T1.1)" do
    assert ReadModel.iteration_history("never-ran") == []
  end

  test "rejects a duplicate (goal_ref, iteration_index)" do
    attrs = %{goal_ref: "dup", iteration_index: 0, predicate_vector: sample_vector()}

    assert {:ok, _} = ReadModel.record_iteration(attrs)
    assert {:error, changeset} = ReadModel.record_iteration(attrs)
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :iteration_index)
  end

  test "records + reads back regression flags (T1.2), with the attributed dispatch" do
    flag = %{
      predicate_id: :keep,
      green_iteration: 0,
      red_iteration: 1,
      status: :fail,
      attributed_dispatch: Action.new(:dispatch_agent, params: %{failing: [:fix]})
    }

    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "regressed",
               iteration_index: 0,
               predicate_vector: sample_vector()
             })

    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "regressed",
               iteration_index: 1,
               predicate_vector: sample_vector(),
               regressions: [flag]
             })

    # Only the iteration that flagged a regression is returned, keyed by index.
    assert [{1, [stored]}] = ReadModel.regressions("regressed")
    assert stored["predicate_id"] == "keep"
    assert stored["green_iteration"] == 0
    assert stored["red_iteration"] == 1
    assert stored["status"] == "fail"
    # The attributed dispatch survives the JSON round-trip, flattened to its kind.
    assert stored["attributed_dispatch"]["kind"] == "dispatch_agent"
  end

  test "regressions/1 is empty when no iteration flagged a regression (T1.2)" do
    assert {:ok, _} =
             ReadModel.record_iteration(%{
               goal_ref: "clean",
               iteration_index: 0,
               predicate_vector: sample_vector()
             })

    assert ReadModel.regressions("clean") == []
  end
end
