defmodule Kazi.AuthoringRoadmapTest do
  @moduledoc """
  T45.2 (UC-059): `Kazi.Authoring.propose_roadmap/2` persists a MULTI-GOAL
  caller-drafts payload as N LINKED proposals sharing one roadmap ref, runs the
  per-goal floor unchanged plus a roadmap-scope floor. Tier 2: real SQLite.
  """
  use ExUnit.Case, async: false

  alias Kazi.Authoring
  alias Kazi.ReadModel
  alias Kazi.ReadModel.ProposedGoal
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp goal_entry(id, needs, integration_mode \\ nil) do
    base = %{
      "id" => id,
      "needs" => needs,
      "name" => id,
      "predicates" => [
        %{"id" => "#{id}-live", "provider" => "http_probe", "url" => "https://x.test/#{id}"}
      ]
    }

    if integration_mode,
      do: Map.put(base, "integration", %{"mode" => integration_mode}),
      else: base
  end

  test "persists N linked proposals sharing one roadmap ref, retrievable by roadmap ref" do
    payload = %{
      "goals" => [
        goal_entry("foundation", []),
        goal_entry("api", ["foundation"], "pr"),
        goal_entry("ui", ["api"], "pr")
      ]
    }

    assert {:ok, result} = Authoring.propose_roadmap(payload)
    assert result.roadmap_ref =~ ~r/^road-/
    assert length(result.proposals) == 3

    members = ReadModel.list_proposed_goals_by_roadmap(result.roadmap_ref)
    # Ordered by goal_id, each linked to the shared roadmap ref.
    assert Enum.map(members, & &1.goal_id) == ["api", "foundation", "ui"]
    assert Enum.all?(members, &(&1.roadmap_ref == result.roadmap_ref))
    assert Enum.all?(members, &(&1.status == "proposed"))
  end

  test "a needs-LESS multi-goal payload raises the roadmap-unordered clarify" do
    payload = %{"goals" => [goal_entry("a", []), goal_entry("b", []), goal_entry("c", [])]}

    assert {:ok, result} = Authoring.propose_roadmap(payload)
    assert Enum.any?(result.clarify, &(&1.id == "roadmap-unordered"))
  end

  test "a frontier goal lacking [integration] raises the frontier-integration clarify" do
    # foundation <- ui; ui is the frontier (no dependents) and declares no integration.
    payload = %{"goals" => [goal_entry("foundation", [], "pr"), goal_entry("ui", ["foundation"])]}

    assert {:ok, result} = Authoring.propose_roadmap(payload)
    assert Enum.any?(result.clarify, &(&1.id == "roadmap-frontier-integration-ui"))
    # foundation is a predecessor, not a frontier -> not flagged.
    refute Enum.any?(result.clarify, &(&1.id == "roadmap-frontier-integration-foundation"))
    # It IS ordered, so the unordered-pile flag does not fire.
    refute Enum.any?(result.clarify, &(&1.id == "roadmap-unordered"))
  end

  test "an ordered roadmap whose frontier lands cleanly has no roadmap-scope clarify" do
    payload = %{
      "goals" => [goal_entry("foundation", []), goal_entry("ui", ["foundation"], "merge")]
    }

    assert {:ok, result} = Authoring.propose_roadmap(payload)
    assert result.clarify == []
  end

  test "a duplicate id / unresolvable need is a structural error, nothing persisted" do
    dup = %{"goals" => [goal_entry("a", []), goal_entry("a", [])]}
    assert {:error, {:invalid_roadmap, _}} = Authoring.propose_roadmap(dup)

    unresolved = %{"goals" => [goal_entry("a", ["ghost"])]}
    assert {:error, {:invalid_roadmap, _}} = Authoring.propose_roadmap(unresolved)

    assert ReadModel.list_proposed_goals() == []
  end

  test "regression: a single-goal caller-drafts plan is unchanged (roadmap_ref nil)" do
    proposal = %{
      "id" => "solo",
      "predicates" => [%{"id" => "live", "provider" => "http_probe", "url" => "https://x.test/z"}]
    }

    assert {:ok, draft} = Authoring.propose("solo", proposal: proposal)
    row = Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
    assert row.roadmap_ref == nil
  end
end
