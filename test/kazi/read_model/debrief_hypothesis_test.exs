defmodule Kazi.ReadModel.DebriefHypothesisTest do
  @moduledoc """
  Tier 2 — real SQLite boundary for the T48.11 (ADR-0058 §3) hypothesis table.
  Inserts capped debrief items through `Kazi.ReadModel.record_debrief_hypotheses/1`
  and reads them back via `list_debrief_hypotheses/1`. This is a WRITE-ONLY
  surface with respect to prompt construction (see `Kazi.Harness.Debrief`); this
  read helper exists only for test/analysis tooling.
  """
  use ExUnit.Case, async: false

  alias Kazi.Repo
  alias Kazi.ReadModel

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "records one row per item and reads them back in iteration order" do
    goal_ref = "debrief-goal-#{System.unique_integer([:positive])}"

    assert {:ok, rows} =
             ReadModel.record_debrief_hypotheses(%{
               goal_ref: goal_ref,
               run_id: "run-abc",
               iteration: 2,
               items: ["needed file A", "needed convention B"]
             })

    assert length(rows) == 2

    persisted = ReadModel.list_debrief_hypotheses(goal_ref)
    assert Enum.map(persisted, & &1.item) == ["needed file A", "needed convention B"]
    assert Enum.all?(persisted, &(&1.iteration == 2))
    assert Enum.all?(persisted, &(&1.run_id == "run-abc"))
    assert Enum.all?(persisted, &(&1.goal_ref == goal_ref))
  end

  test "run_id is nullable — recorded honestly as nil, not a fabricated id" do
    goal_ref = "debrief-goal-#{System.unique_integer([:positive])}"

    assert {:ok, [row]} =
             ReadModel.record_debrief_hypotheses(%{
               goal_ref: goal_ref,
               iteration: 0,
               items: ["one item"]
             })

    assert row.run_id == nil
  end

  test "an empty items list is a no-op (writes nothing)" do
    goal_ref = "debrief-goal-#{System.unique_integer([:positive])}"

    assert {:ok, []} =
             ReadModel.record_debrief_hypotheses(%{goal_ref: goal_ref, iteration: 0, items: []})

    assert ReadModel.list_debrief_hypotheses(goal_ref) == []
  end

  test "a goal with no recorded debrief history reads back an honest empty list" do
    assert ReadModel.list_debrief_hypotheses("never-debriefed-goal") == []
  end

  test "rows across multiple iterations sort ascending by iteration" do
    goal_ref = "debrief-goal-#{System.unique_integer([:positive])}"

    {:ok, _} =
      ReadModel.record_debrief_hypotheses(%{goal_ref: goal_ref, iteration: 3, items: ["later"]})

    {:ok, _} =
      ReadModel.record_debrief_hypotheses(%{goal_ref: goal_ref, iteration: 1, items: ["earlier"]})

    assert Enum.map(ReadModel.list_debrief_hypotheses(goal_ref), & &1.iteration) == [1, 3]
  end
end
