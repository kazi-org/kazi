defmodule Kazi.Goal.TotalDispatchBudgetTest do
  use ExUnit.Case, async: true
  alias Kazi.{Authoring, Goal}

  test "total allowance validates and survives proposal serialization" do
    payload = %{
      "predicates" => [
        %{"id" => "code", "provider" => "custom_script", "config" => %{"cmd" => "true"}}
      ],
      "budget" => %{"max_total_dispatches" => 2},
      "escalation" => %{"ladder" => ["one", "two"]}
    }

    assert {:ok, goal} = Authoring.parse_proposal(payload, "total")
    assert goal.budget.max_total_dispatches == 2
    assert {:ok, loaded} = goal |> Authoring.serialize_goal() |> Goal.Loader.from_map()
    assert loaded.budget.max_total_dispatches == 2
    assert loaded.escalation.ladder == ["one", "two"]

    for invalid <- [0, -1, true, "2", 2.5] do
      assert {:error, _} =
               Authoring.parse_proposal(
                 put_in(payload, ["budget", "max_total_dispatches"], invalid),
                 "bad"
               )
    end

    assert {:ok, legacy} =
             Authoring.parse_proposal(Map.drop(payload, ["budget", "escalation"]), "legacy")

    assert legacy.budget.max_total_dispatches == nil
  end
end
