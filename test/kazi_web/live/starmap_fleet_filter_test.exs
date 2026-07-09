defmodule KaziWeb.StarmapFleetFilterTest do
  @moduledoc """
  LiveView test for the FLEET-tile state filter and the single-column
  scrolling canvas:

    * clicking RUNNING / LANDED / STUCK dims every node the tile doesn't
      count; clicking the active tile again clears the filter;
    * the state filter and the SESSIONS filter are mutually exclusive —
      setting one clears the other;
    * a band taller than the base canvas grows the viewBox height (nodes
      never wrap into sub-columns; the canvas scrolls instead).
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.ReadModel.RunRegistry

  defp seed(goal_ref, status_or_nil \\ nil) do
    {:ok, run} =
      RunRegistry.start(%{
        run_id: "run-#{goal_ref}",
        pid: "#PID<0.1.0>",
        workspace: "/tmp/ws",
        goal_ref: goal_ref,
        harness: "claude",
        model: "claude-sonnet-5",
        session_os_pid: "424242"
      })

    if status_or_nil, do: {:ok, _} = RunRegistry.finish(run.run_id, status_or_nil)
    run
  end

  test "clicking a fleet tile filters by state; clicking it again clears", %{conn: conn} do
    seed("goal-live")
    seed("goal-done", "converged")
    seed("goal-wedged", "stuck")

    {:ok, view, html} = live(conn, ~p"/starmap")
    refute html =~ "data-fleet-filter"

    html = view |> element(~s(.fleet-tile[data-tile="landed"])) |> render_click()

    assert html =~ ~s(data-fleet-filter="landed")
    assert html =~ ~s(class="fleet-tile active" data-tile="landed")
    # The landed node stays lit; the others dim.
    refute html =~ ~s(id="canvas-node-group-run-goal-done" class="canvas-node-group dimmed")
    assert html =~ ~s(id="canvas-node-group-run-goal-live" class="canvas-node-group dimmed")
    assert html =~ ~s(id="canvas-node-group-run-goal-wedged" class="canvas-node-group dimmed")

    html = view |> element(~s(.fleet-tile[data-tile="landed"])) |> render_click()

    refute html =~ "data-fleet-filter"
    refute html =~ ~s(class="canvas-node-group dimmed")
  end

  test "the state filter and the session filter clear each other", %{conn: conn} do
    seed("goal-live")
    seed("goal-done", "converged")

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element(~s(.session-row[data-session="S1"])) |> render_click()
    assert html =~ ~s(data-session-filter="S1")

    html = view |> element(~s(.fleet-tile[data-tile="landed"])) |> render_click()
    assert html =~ ~s(data-fleet-filter="landed")
    refute html =~ "data-session-filter"

    html = view |> element(~s(.session-row[data-session="S1"])) |> render_click()
    assert html =~ ~s(data-session-filter="S1")
    refute html =~ "data-fleet-filter"
  end

  test "a dense landed pile caps at the column limit instead of stretching the canvas",
       %{conn: conn} do
    for n <- 1..12, do: seed("dense-goal-#{n}", "converged")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    # State columns cap at 8 nodes (newest first); overflow folds into the
    # label, so the canvas stays at the base height instead of scrolling.
    assert html =~ "LANDED · 8 OF 12"
    assert html =~ ~s(viewBox="0 0 1160 888")
  end

  test "an active fleet tile lifts the column cap: all matching goals render", %{conn: conn} do
    for n <- 1..12, do: seed("filtered-goal-#{n}", "converged")

    {:ok, view, html} = live(conn, ~p"/starmap")
    assert html =~ "LANDED · 8 OF 12"

    html = view |> element(~s(.fleet-tile[data-tile="landed"])) |> render_click()

    # The operator asked for exactly these goals: the LANDED column shows all
    # 12 (no "OF" folding), and the canvas grows to carry them.
    assert html =~ "LANDED · 12"
    refute html =~ "LANDED · 8 OF 12"
    assert html =~ "filtered-goal-1"
    assert html =~ "filtered-goal-12"

    # Clearing the filter restores the capped glance.
    html = view |> element(~s(.fleet-tile[data-tile="landed"])) |> render_click()
    assert html =~ "LANDED · 8 OF 12"
  end

  test "a small fleet keeps the mockup's base canvas height", %{conn: conn} do
    seed("small-goal", "converged")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(viewBox="0 0 1160 742")
  end
end
