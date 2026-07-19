defmodule Kazi.Providers.PlanExpandedTest do
  @moduledoc """
  T45.3 (UC-059): the read-model-only `plan_expanded` gate — a phase passes only
  when its goal-set EXISTS, passed the clarify FLOOR, and is APPROVED, each failing
  independently naming which. Evaluable with ZERO harness dispatch. Tier 2: real
  SQLite.
  """
  use ExUnit.Case, async: false

  alias Kazi.{Authoring, Predicate, PredicateResult, ReadModel}
  alias Kazi.Goal.Roadmap
  alias Kazi.Providers.PlanExpanded

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
  end

  # A fully-specified idea (from the clarify floor tests) — yields zero floor gaps.
  @ok_idea "GET /healthz returns 200 with no auth on https://app.example.com; " <>
             "scope: that endpoint only, no deploy"

  defp entry(id, needs, name) do
    %{
      "id" => id,
      "needs" => needs,
      "name" => name,
      "predicates" => [
        %{
          "id" => "#{id}-live",
          "provider" => "http_probe",
          "url" => "https://app.example.com/healthz"
        }
      ]
    }
  end

  # Persist a roadmap goal-set and return {roadmap_ref, [proposal_ref]}.
  defp roadmap(entries) do
    {:ok, result} = Authoring.propose_roadmap(%{"goals" => entries})
    {result.roadmap_ref, Enum.map(result.proposals, & &1.proposal_ref)}
  end

  defp approve(proposal_ref) do
    proposal = ReadModel.get_proposed_goal(proposal_ref)
    {:ok, _} = ReadModel.transition_proposed_goal(proposal_ref, "approved", proposal.goal)
  end

  defp evaluate(phase) do
    PlanExpanded.evaluate(Predicate.new("gate", :plan_expanded, config: %{phase: phase}), %{})
  end

  test "passes only when the goal-set exists, passed the floor, AND is approved" do
    {roadmap_ref, refs} = roadmap([entry("phase-a", [], @ok_idea)])
    Enum.each(refs, &approve/1)

    assert %PredicateResult{status: :pass} = evaluate(roadmap_ref)
  end

  test "FAIL :exists when the phase ref is not in the read-model" do
    result = evaluate("road-does-not-exist")

    assert %PredicateResult{status: :fail} = result
    assert result.evidence.condition == :exists
    assert result.evidence.reason == :phase_not_found
  end

  test "FAIL :floor when a member has open clarify gaps (exists + approved hold)" do
    {roadmap_ref, refs} = roadmap([entry("phase-a", [], "add a feature")])
    Enum.each(refs, &approve/1)

    result = evaluate(roadmap_ref)

    assert %PredicateResult{status: :fail} = result
    assert result.evidence.condition == :floor
    assert [%{goal: "phase-a", gaps: gaps}] = result.evidence.gaps
    assert gaps != []
  end

  test "FAIL :approved when a member is still proposed (exists + floor hold)" do
    {roadmap_ref, refs} = roadmap([entry("phase-a", [], @ok_idea)])
    # Deliberately do NOT approve.

    result = evaluate(roadmap_ref)

    assert %PredicateResult{status: :fail} = result
    assert result.evidence.condition == :approved
    assert result.evidence.unapproved == refs
  end

  test "is READ-MODEL-ONLY: it evaluates with no harness in scope at all" do
    {roadmap_ref, refs} = roadmap([entry("phase-a", [], @ok_idea)])
    Enum.each(refs, &approve/1)

    # No :harness key, no HarnessAdapter — a bare context. A pure read-model +
    # Clarify + Loader evaluation.
    result =
      PlanExpanded.evaluate(
        Predicate.new("gate", :plan_expanded, config: %{phase: roadmap_ref}),
        %{}
      )

    assert result.status == :pass

    # The provider names no harness behaviour and imports no HarnessAdapter.
    refute Kazi.HarnessAdapter in (PlanExpanded.module_info(:attributes)[:behaviour] || [])
  end

  describe "outline-phase scheduling (frontier order)" do
    defp inline(id, needs) do
      base = %{
        "id" => id,
        "goal" => %{
          "id" => id,
          "predicate" => [%{"id" => "#{id}-c", "provider" => "test_runner"}]
        }
      }

      if needs == [], do: base, else: Map.put(base, "needs", needs)
    end

    test "an outline goal behind a `needs` edge is scheduled AFTER its frontier" do
      # frontier `build` <- outline `plan-phase-2`: the planning work-item cannot be
      # dispatched until the frontier's wave completes.
      {:ok, rm} =
        Roadmap.from_map(%{"goals" => [inline("build", []), inline("plan-phase-2", ["build"])]})

      assert Roadmap.frontiers(rm) == [["build"], ["plan-phase-2"]]
    end
  end

  describe "loader + schema" do
    test "a plan_expanded predicate requires a phase and loads" do
      data = %{
        "id" => "g",
        "predicate" => [%{"id" => "p", "provider" => "plan_expanded", "phase" => "road-x"}]
      }

      assert {:ok, goal} = Kazi.Goal.Loader.from_map(data)
      assert [%Predicate{kind: :plan_expanded, config: %{phase: "road-x"}}] = goal.predicates
    end

    test "a plan_expanded predicate missing phase is a load error" do
      data = %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "plan_expanded"}]}
      assert {:error, reason} = Kazi.Goal.Loader.from_map(data)
      assert reason =~ "phase"
    end

    test "kazi schema plan_expanded lists the phase key" do
      assert {:ok, schema} = Kazi.Predicate.Schema.fetch("plan_expanded")
      assert Enum.any?(schema.keys, &(&1.name == "phase"))
    end
  end
end
