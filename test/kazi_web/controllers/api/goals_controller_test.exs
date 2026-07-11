defmodule KaziWeb.API.GoalsControllerTest do
  @moduledoc """
  Endpoint test for the stateless JSON goals API (issue #1077): asserts the
  route needs no session/CSRF and mirrors `Kazi.ReadModel.list_goals/0`, the
  same projection `KaziWeb.GoalBoardLive` renders.
  """
  use KaziWeb.ConnCase, async: true

  alias Kazi.{PredicateResult, PredicateVector, ReadModel}

  test "GET /api/goals with no goals recorded returns an empty list", %{conn: conn} do
    conn = get(conn, ~p"/api/goals")

    assert json_response(conn, 200) == %{"goals" => []}
  end

  test "GET /api/goals returns each goal's status, predicate vector, and iteration count", %{
    conn: conn
  } do
    vector =
      PredicateVector.new(%{
        unit: PredicateResult.pass(%{exit: 0}),
        probe: PredicateResult.fail(%{http_status: 503})
      })

    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: "goal-a",
        iteration_index: 1,
        predicate_vector: vector
      })

    conn = get(conn, ~p"/api/goals")

    assert %{"goals" => [goal]} = json_response(conn, 200)
    assert goal["id"] == "goal-a"
    assert goal["status"] == "in_progress"
    assert goal["iteration_count"] == 1

    assert goal["predicates"] == [
             %{"id" => "probe", "verdict" => "fail"},
             %{"id" => "unit", "verdict" => "pass"}
           ]
  end
end
