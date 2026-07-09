defmodule KaziWeb.StarmapSessionScopeTest do
  @moduledoc """
  Pins the CURRENT/CLOSED session-scope toggle: the starmap's default view
  shows only runs whose driving agent session is still alive; runs from
  closed sessions (dead history) live behind the CLOSED toggle, with both
  counts always visible on the toggle itself.
  """
  use KaziWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Kazi.ReadModel.RunRegistry

  defp seed(goal, status_or_nil, session_os_pid) do
    {:ok, run} =
      RunRegistry.start(%{
        run_id: "run-#{System.unique_integer([:positive])}",
        pid: "#PID<0.1.0>",
        workspace: "/tmp/ws",
        goal_ref: goal,
        harness: "claude",
        model: "claude-sonnet-5",
        session_os_pid: session_os_pid
      })

    if status_or_nil, do: RunRegistry.finish(run, status_or_nil)
    run
  end

  test "default CURRENT scope hides closed-session runs; CLOSED reveals them",
       %{conn: conn} do
    seed("live-stuck", "stuck", "424242")
    seed("dead-stuck", "stuck", "dead-1")
    seed("dead-landed", "converged", "dead-2")

    {:ok, view, html} = live(conn, ~p"/starmap")

    # Toggle renders both counts.
    assert html =~ "CURRENT · 1"
    assert html =~ "CLOSED · 2"

    # Default scope: only the live-session run is on the canvas.
    assert html =~ "live-stuck"
    refute html =~ "dead-stuck"
    refute html =~ "dead-landed"

    # CLOSED scope: the dead history, and only it.
    html = view |> element(~s(button[data-scope-option="closed"])) |> render_click()
    assert html =~ "dead-stuck"
    assert html =~ "dead-landed"
    refute html =~ "live-stuck"

    # And back.
    html = view |> element(~s(button[data-scope-option="current"])) |> render_click()
    assert html =~ "live-stuck"
    refute html =~ "dead-stuck"
  end

  test "a run with no recorded session pid counts as current only while converging",
       %{conn: conn} do
    seed("old-converging", nil, nil)
    seed("old-stuck", "stuck", nil)

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ "old-converging"
    refute html =~ "old-stuck"
    assert html =~ "CLOSED · 1"
  end

  test "the attention queue honors the scope: closed-session stuck runs stay out of CURRENT",
       %{conn: conn} do
    seed("dead-needs-you", "stuck", "dead-3")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    refute html =~ "dead-needs-you"
    refute html =~ "attention-item-", "no attention entries in CURRENT scope"
  end
end
