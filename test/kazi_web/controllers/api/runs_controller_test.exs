defmodule KaziWeb.API.RunsControllerTest do
  @moduledoc """
  Endpoint test for the stateless JSON runs API (issue #1077): asserts the
  route needs no session/CSRF and mirrors `Kazi.ReadModel.RunRegistry.list/0`.
  """
  use KaziWeb.ConnCase, async: true

  alias Kazi.ReadModel.RunRegistry

  test "GET /api/runs with no runs registered returns an empty list", %{conn: conn} do
    conn = get(conn, ~p"/api/runs")

    assert json_response(conn, 200) == %{"runs" => []}
  end

  test "GET /api/runs returns each registered run's fields", %{conn: conn} do
    {:ok, _run} =
      RunRegistry.start(%{
        run_id: "run-1",
        pid: "1234",
        workspace: "/tmp/work",
        goal_ref: "goal-a",
        harness: "claude",
        model: "claude-sonnet-5"
      })

    conn = get(conn, ~p"/api/runs")

    assert %{"runs" => [run]} = json_response(conn, 200)
    assert run["run_id"] == "run-1"
    assert run["goal_ref"] == "goal-a"
    assert run["status"] == "running"
    assert run["harness"] == "claude"
    assert run["model"] == "claude-sonnet-5"
    assert is_integer(run["heartbeat_age_s"])
  end
end
