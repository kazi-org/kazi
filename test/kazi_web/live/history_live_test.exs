defmodule KaziWeb.HistoryLiveTest do
  @moduledoc """
  LiveView test for the per-goal history view (T3.6d, UC-018).

  Seeds the (sandbox-isolated) read-model with N iterations for a goal and
  asserts the timeline renders them in ascending iteration-index order, each with
  its predicate vector, statuses, and the structured evidence that justified each
  status; that a goal with no iterations renders the empty state; and that a
  freshly recorded iteration for the goal appends to the timeline live. Hermetic:
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

  defp failing_vector do
    PredicateVector.new(%{
      unit: PredicateResult.pass(%{exit: 0}),
      probe: PredicateResult.fail(%{http_status: 503})
    })
  end

  defp converged_vector do
    PredicateVector.new(%{
      unit: PredicateResult.pass(%{exit: 0}),
      probe: PredicateResult.pass(%{http_status: 200})
    })
  end

  test "renders the empty state for a goal with no iterations", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/goals/never-ran/history")

    assert html =~ ~s(id="history-empty")
    assert html =~ "No iterations recorded"
    refute html =~ ~s(id="timeline")
  end

  test "renders an ordered timeline of iterations with predicate vectors and evidence", %{
    conn: conn
  } do
    # Three iterations, recorded out of order to prove the view orders by index.
    record("ship-it", 1, failing_vector())
    record("ship-it", 0, failing_vector())
    record("ship-it", 2, converged_vector(), converged: true)

    {:ok, _view, html} = live(conn, ~p"/goals/ship-it/history")

    assert html =~ ~s(id="timeline")
    assert html =~ ~s(data-goal-ref="ship-it")

    # All three iterations render, each as a list item with its index.
    assert html =~ ~s(id="iteration-0")
    assert html =~ ~s(id="iteration-1")
    assert html =~ ~s(id="iteration-2")

    # Ordered oldest-first: iteration 0 appears before 1 before 2 in the markup.
    pos0 = :binary.match(html, "id=\"iteration-0\"") |> elem(0)
    pos1 = :binary.match(html, "id=\"iteration-1\"") |> elem(0)
    pos2 = :binary.match(html, "id=\"iteration-2\"") |> elem(0)
    assert pos0 < pos1
    assert pos1 < pos2

    # The predicate vector + status renders for an iteration.
    assert html =~ ~s(id="iteration-2-predicate-probe")
    assert html =~ ~s(data-predicate-id="probe")
    # The converged (final) iteration's probe passed.
    assert html =~ ~s(data-status="pass")
    # The first iteration's probe failed.
    assert html =~ ~s(data-status="fail")

    # The structured evidence that justified the status is surfaced.
    assert html =~ "http_status=200"
    assert html =~ "http_status=503"

    # The converged iteration is flagged.
    assert html =~ ~s(data-converged="true")
  end

  test "renders the release ref and action when present", %{conn: conn} do
    record("deployed", 0, converged_vector(),
      converged: true,
      release_ref: "v1.2.3",
      action: Kazi.Action.new(:deploy, params: %{"env" => "prod"})
    )

    {:ok, _view, html} = live(conn, ~p"/goals/deployed/history")

    assert html =~ ~s(data-release-ref="v1.2.3")
    assert html =~ "v1.2.3"
    assert html =~ ~s(data-action-kind="deploy")
  end

  test "a freshly recorded iteration for the goal appends to the timeline live", %{conn: conn} do
    record("alpha", 0, failing_vector())
    {:ok, view, html} = live(conn, ~p"/goals/alpha/history")

    assert html =~ ~s(id="iteration-0")
    refute render(view) =~ ~s(id="iteration-1")

    # Record the next iteration for this goal — record_iteration broadcasts on the
    # goal-board topic; the subscribed view re-reads and appends it.
    record("alpha", 1, converged_vector(), converged: true)

    assert render(view) =~ ~s(id="iteration-1")
  end

  test "an iteration for a different goal does not change this goal's timeline", %{conn: conn} do
    record("alpha", 0, failing_vector())
    {:ok, view, _html} = live(conn, ~p"/goals/alpha/history")

    # A different goal's iteration broadcasts on the same topic; this view, which
    # tracks only "alpha", must ignore it.
    record("beta", 0, converged_vector(), converged: true)

    refute render(view) =~ "beta"
    refute render(view) =~ ~s(id="iteration-1")
  end
end
