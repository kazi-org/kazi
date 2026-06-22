defmodule KaziWeb.GoalBoardLiveTest do
  @moduledoc """
  LiveView test for the goal board (T3.6b, UC-018).

  Seeds the (sandbox-isolated) read-model with iterations and asserts the board
  renders each goal with its status, predicate-vector summary, and iteration
  count; that the empty read-model renders the empty state; and that a freshly
  recorded iteration broadcast pushes a LIVE diff to the connected view. Hermetic:
  the read-model IS the fixture source (no NATS, no harness).
  """
  # Not async: the SQLite Sandbox shares one connection and the live view reads it
  # across processes, so the test owns the shared sandbox for the connected mount.
  use KaziWeb.ConnCase, async: false

  alias Kazi.{PredicateResult, PredicateVector, ReadModel}

  defp record(goal_ref, index, vector, opts \\ []) do
    {:ok, _} =
      ReadModel.record_iteration(
        Keyword.merge(
          [goal_ref: goal_ref, iteration_index: index, predicate_vector: vector],
          opts
        )
        |> Map.new()
      )
  end

  defp converged_vector do
    PredicateVector.new(%{
      unit: PredicateResult.pass(%{exit: 0}),
      probe: PredicateResult.pass(%{http_status: 200})
    })
  end

  defp failing_vector do
    PredicateVector.new(%{
      unit: PredicateResult.pass(%{exit: 0}),
      probe: PredicateResult.fail(%{http_status: 503})
    })
  end

  test "renders the empty state when no goals are recorded", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/goals")

    assert html =~ ~s(id="goal-board-empty")
    assert html =~ "No goals yet"
    refute html =~ ~s(id="goals")
  end

  test "renders a seeded goal with status, predicate summary, and iteration count", %{conn: conn} do
    record("ship-it", 0, failing_vector())
    record("ship-it", 1, converged_vector(), converged: true)

    {:ok, _view, html} = live(conn, ~p"/goals")

    assert html =~ ~s(id="goals")
    assert html =~ "ship-it"
    # latest iteration converged → :converged status; full 2/2 predicate badge.
    assert html =~ ~s(data-status="converged")
    assert html =~ ~s(data-predicates="2/2")
    # two iterations recorded.
    assert html =~ ~s(data-iterations="2")
  end

  test "renders an in-progress goal with a partial predicate badge", %{conn: conn} do
    record("wip", 0, failing_vector())

    {:ok, _view, html} = live(conn, ~p"/goals")

    assert html =~ "wip"
    assert html =~ ~s(data-status="in_progress")
    # one of two predicates passing.
    assert html =~ ~s(data-predicates="1/2")
    assert html =~ ~s(data-iterations="1")
  end

  test "a freshly recorded iteration pushes a live update to the board", %{conn: conn} do
    # Mount with one goal already present.
    record("alpha", 0, failing_vector())
    {:ok, view, html} = live(conn, ~p"/goals")

    assert html =~ "alpha"
    refute render(view) =~ "beta"

    # The connected LiveView process re-reads the read-model on the broadcast; the
    # ConnCase sandbox runs in shared mode for this non-async test, so that
    # cross-process read sees the test transaction's rows.
    #
    # Record a NEW goal — record_iteration broadcasts on the goal-board topic; the
    # subscribed view re-reads and re-renders.
    record("beta", 0, converged_vector(), converged: true)

    assert render(view) =~ "beta"
    assert render(view) =~ ~s(id="goal-beta")
  end
end
