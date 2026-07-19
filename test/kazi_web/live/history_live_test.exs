defmodule KaziWeb.HistoryLiveTest do
  @moduledoc """
  LiveView test for the per-goal narrative history view (T3.6d, rebuilt in
  T63.12; UC-018, UC-062).

  Seeds the (sandbox-isolated) read-model with N iterations for a goal and
  asserts the view renders them NEWEST-FIRST as narrative events (each an
  arrow-separated one-liner computed from the iteration's action + a diff against
  the prior vector), leads with a plain-language convergence summary, keeps the
  full predicate vector available behind a disclosure, and — critically — renders
  an in-progress single-iteration goal WITHOUT a fabricated terminal verdict.
  Hermetic: the read-model IS the fixture source (no NATS, no harness).
  """
  # Not async: the SQLite Sandbox shares one connection and the live view reads it
  # across processes, so the test owns the shared sandbox for the connected mount.
  use KaziWeb.ConnCase, async: false

  alias Kazi.{PredicateResult, PredicateVector, ReadModel}

  defp unescape(html), do: String.replace(html, "-&gt;", "->")

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
    refute html =~ ~s(id="history-summary")
  end

  test "renders a 2-iteration goal newest-first as narrative events with a verdict on the converged one",
       %{conn: conn} do
    # Recorded out of order to prove the view orders by index, not insertion.
    record("ship-it", 1, converged_vector(),
      converged: true,
      action: Kazi.Action.new(:dispatch_agent, params: %{})
    )

    record("ship-it", 0, failing_vector())

    {:ok, _view, html} = live(conn, ~p"/goals/ship-it/history")

    assert html =~ ~s(id="timeline")
    assert html =~ ~s(data-goal-ref="ship-it")

    # Both iterations render as events.
    assert html =~ ~s(id="iteration-0")
    assert html =~ ~s(id="iteration-1")

    # NEWEST-FIRST: iteration 1 appears before iteration 0 in the markup.
    pos1 = :binary.match(html, "id=\"iteration-1\"") |> elem(0)
    pos0 = :binary.match(html, "id=\"iteration-0\"") |> elem(0)
    assert pos1 < pos0

    # Iteration 0 is the first observation: a first-observation narrative, no
    # flips, and — being in progress — NO verdict clause.
    # LiveView escapes `->` to `-&gt;` in rendered HTML; normalize before
    # matching so the narrative assertions exercise the real arrow format.
    assert unescape(html) =~
             "iteration 0: first observation -> 1 of 2 predicates passing -> 1 failing"

    # Iteration 1 diffs against iteration 0: probe flipped fail->pass, all pass,
    # and the controller judged it converged, so the verdict clause is present.
    assert unescape(html) =~
             "iteration 1: dispatched dispatch_agent -> probe flipped fail->pass -> 2 of 2 predicates passing -> converged"

    # The converged event carries the verdict marker; it is the only one.
    assert html =~ ~s(data-verdict="converged")

    # The plain-language convergence summary leads the view.
    assert html =~ ~s(id="history-summary")
    assert html =~ ~s(data-status="converged")
    assert html =~ "This goal converged in 2 iterations"

    # The full predicate vector is still available (behind the disclosure).
    assert html =~ ~s(id="iteration-1-predicate-probe")
    assert html =~ "http_status=200"
  end

  test "an in-progress single-iteration goal renders no fabricated verdict", %{conn: conn} do
    # The real fixture shape (the runtime-gherkin goal in E63): exactly one
    # recorded, still-converging iteration.
    record("in-flight", 0, failing_vector())

    {:ok, _view, html} = live(conn, ~p"/goals/in-flight/history")

    assert html =~ ~s(id="iteration-0")

    # Honest in-progress state — a pending badge, NOT a fabricated verdict.
    assert html =~ ~s(data-pending="true")
    refute html =~ ~s(data-verdict=)
    refute unescape(html) =~ "-> converged"

    # First-observation narrative, no flip against a non-existent prior iteration.
    assert html =~ "iteration 0: first observation"
    refute html =~ "flipped"

    # Summary is honest about the unknown total and the single observation.
    assert html =~ ~s(data-status="in_progress")
    assert html =~ "of an unknown total"
    assert html =~ "only one observation exists"
  end

  test "renders the release ref when present", %{conn: conn} do
    record("deployed", 0, converged_vector(),
      converged: true,
      release_ref: "v1.2.3",
      action: Kazi.Action.new(:deploy, params: %{"env" => "prod"})
    )

    {:ok, _view, html} = live(conn, ~p"/goals/deployed/history")

    assert html =~ ~s(data-release-ref="v1.2.3")
    assert html =~ "v1.2.3"
  end

  test "a freshly recorded iteration for the goal moves to the top of the timeline live", %{
    conn: conn
  } do
    record("alpha", 0, failing_vector())
    {:ok, view, html} = live(conn, ~p"/goals/alpha/history")

    assert html =~ ~s(id="iteration-0")
    refute render(view) =~ ~s(id="iteration-1")

    # record_iteration broadcasts on the goal-board topic; the subscribed view
    # re-reads and the new iteration takes the top slot (newest-first).
    record("alpha", 1, converged_vector(), converged: true)

    rendered = render(view)
    assert rendered =~ ~s(id="iteration-1")
    pos1 = :binary.match(rendered, "id=\"iteration-1\"") |> elem(0)
    pos0 = :binary.match(rendered, "id=\"iteration-0\"") |> elem(0)
    assert pos1 < pos0
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
