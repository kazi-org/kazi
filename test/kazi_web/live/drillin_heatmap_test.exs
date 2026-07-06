defmodule KaziWeb.DrillinHeatmapLiveTest do
  @moduledoc """
  LiveView test for the per-goal drill-in convergence heatmap + iteration
  scrubber (T46.7, UC-062).

  Seeds the (sandbox-isolated) read-model with a per-iteration history and
  asserts: the predicates x iterations matrix renders with pass/fail/not-evaluated
  cells; a pinned green->red->green regression flip in one row is marked visually
  distinct on the iteration where it flipped; the newest column is marked
  current; clicking a column header (the scrubber) shows that iteration's vector,
  dispatch, and ADR-0046 counters in the detail panel; a 2-iteration goal renders
  without layout errors (degenerate pin); and a goal with no iterations renders
  the empty state. Hermetic: the read-model IS the fixture source (no NATS, no
  harness).
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.{Action, PredicateResult, PredicateVector, ReadModel}

  defp record(goal_ref, index, vector, opts \\ []) do
    {:ok, iteration} =
      ReadModel.record_iteration(
        Keyword.merge(
          [goal_ref: goal_ref, iteration_index: index, predicate_vector: vector],
          opts
        )
        |> Map.new()
      )

    iteration
  end

  defp vector(unit_status, probe_status) do
    PredicateVector.new(%{
      unit: PredicateResult.new(unit_status, %{exit: 0}),
      probe: PredicateResult.new(probe_status, %{http_status: 200})
    })
  end

  test "renders the empty state for a goal with no iterations", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/goals/never-ran/drillin")

    assert html =~ ~s(id="drillin-empty")
    assert html =~ "No iterations recorded"
    refute html =~ ~s(id="drillin-matrix")
  end

  test "renders a predicates x iterations matrix with statuses, current column, and a scrubbable detail panel",
       %{conn: conn} do
    record("ship-it", 0, vector(:fail, :fail))
    record("ship-it", 1, vector(:pass, :fail))

    record("ship-it", 2, vector(:pass, :pass),
      converged: true,
      action: Action.new(:dispatch_agent, params: %{}),
      context: %{"orientation_tokens" => 42, "tier" => 1},
      tools: %{"tool_calls" => 7, "file_reads" => 3}
    )

    {:ok, view, html} = live(conn, ~p"/goals/ship-it/drillin")

    assert html =~ ~s(id="drillin-matrix")
    assert html =~ ~s(data-goal-ref="ship-it")
    assert html =~ ~s(data-iteration-count="3")

    # One row per predicate, one column per iteration.
    assert html =~ ~s(id="heatmap-row-probe")
    assert html =~ ~s(id="heatmap-row-unit")
    assert html =~ ~s(id="heatmap-col-0")
    assert html =~ ~s(id="heatmap-col-1")
    assert html =~ ~s(id="heatmap-col-2")

    # Cell statuses render.
    assert html =~ ~s(id="heatmap-cell-unit-0" class="heatmap-cell status-fail")
    assert html =~ ~s(id="heatmap-cell-unit-1" class="heatmap-cell status-pass")
    assert html =~ ~s(id="heatmap-cell-probe-2" class="heatmap-cell status-pass")

    # The newest column (2) is marked current; the others are not.
    assert html =~
             ~s(id="heatmap-col-2" class="heatmap-col current" data-iteration-index="2" data-current="true")

    assert html =~ ~s(data-iteration-index="0" data-current="false")

    # With no explicit scrub, the detail panel follows the current (latest)
    # iteration: its vector, dispatch action, and counters.
    assert html =~ ~s(id="drillin-detail" data-selected-index="2")
    assert html =~ ~s(id="drillin-detail-action" data-action-kind="dispatch_agent")
    assert html =~ ~r/data-counter="tool_calls">\s*7\s*</
    assert html =~ ~r/data-counter="orientation_tokens">\s*42\s*</
    assert html =~ ~r/data-counter="tier">\s*1\s*</

    # Scrub to iteration 0: the detail panel shows THAT iteration's (failing)
    # vector instead, and no dispatch action was recorded for it.
    html = view |> element("#scrub-0") |> render_click()

    assert html =~ ~s(id="drillin-detail" data-selected-index="0")
    refute html =~ ~s(id="drillin-detail-action")
    assert html =~ ~s(id="drillin-detail-predicate-unit" class="predicate-status status-fail")
  end

  test "a pinned green->red->green regression flip is marked visually distinct on the flip iteration",
       %{conn: conn} do
    record("flaky", 0, vector(:pass, :pass))

    record("flaky", 1, vector(:fail, :pass),
      regressions: [
        %{predicate_id: :unit, green_iteration: 0, red_iteration: 1, status: :fail}
      ]
    )

    record("flaky", 2, vector(:pass, :pass))

    {:ok, _view, html} = live(conn, ~p"/goals/flaky/drillin")

    # green (0) -> red (1) -> green (2), one row.
    assert html =~ ~s(id="heatmap-cell-unit-0" class="heatmap-cell status-pass")
    assert html =~ ~s(id="heatmap-cell-unit-1" class="heatmap-cell status-fail regression-flip")
    assert html =~ ~s(id="heatmap-cell-unit-2" class="heatmap-cell status-pass")

    # Only the flip cell carries the marker.
    assert html =~
             ~s(id="heatmap-cell-unit-1" class="heatmap-cell status-fail regression-flip" data-status="fail" data-regression-flip="true")

    assert html =~
             ~s(id="heatmap-cell-unit-0" class="heatmap-cell status-pass" data-status="pass" data-regression-flip="false")
  end

  test "a 2-iteration goal renders without layout errors (degenerate pin)", %{conn: conn} do
    record("short-run", 0, vector(:fail, :fail))
    record("short-run", 1, vector(:pass, :pass), converged: true)

    {:ok, _view, html} = live(conn, ~p"/goals/short-run/drillin")

    assert html =~ ~s(data-iteration-count="2")
    assert html =~ ~s(id="heatmap-col-0")
    assert html =~ ~s(id="heatmap-col-1")
    assert html =~ ~s(id="drillin-detail" data-selected-index="1")
  end

  test "a predicate introduced mid-run renders not-evaluated for earlier iterations", %{
    conn: conn
  } do
    record("growing", 0, PredicateVector.new(%{unit: PredicateResult.pass(%{exit: 0})}))

    record(
      "growing",
      1,
      PredicateVector.new(%{
        unit: PredicateResult.pass(%{exit: 0}),
        probe: PredicateResult.fail(%{http_status: 503})
      })
    )

    {:ok, _view, html} = live(conn, ~p"/goals/growing/drillin")

    assert html =~ ~s(id="heatmap-cell-probe-0" class="heatmap-cell status-not_evaluated")
    assert html =~ ~s(id="heatmap-cell-probe-1" class="heatmap-cell status-fail")
  end

  test "a freshly recorded iteration for the goal appends a column live", %{conn: conn} do
    record("alpha", 0, vector(:fail, :fail))
    {:ok, view, html} = live(conn, ~p"/goals/alpha/drillin")

    assert html =~ ~s(id="heatmap-col-0")
    refute render(view) =~ ~s(id="heatmap-col-1")

    record("alpha", 1, vector(:pass, :pass), converged: true)

    assert render(view) =~ ~s(id="heatmap-col-1")
  end

  test "an iteration for a different goal does not change this goal's matrix", %{conn: conn} do
    record("alpha", 0, vector(:fail, :fail))
    {:ok, view, _html} = live(conn, ~p"/goals/alpha/drillin")

    record("beta", 0, vector(:pass, :pass), converged: true)

    refute render(view) =~ "beta"
    refute render(view) =~ ~s(id="heatmap-col-1")
  end
end
