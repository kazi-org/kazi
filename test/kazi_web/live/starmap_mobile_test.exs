defmodule KaziWeb.StarmapMobileTest do
  @moduledoc """
  LiveView test for the starmap's mobile bottom-tab bar (UC-061, ADR-0057,
  docs/dashboard-design.md "Mobile layout").

  Below the breakpoint the rail's sections become tab panes selected by the
  `data-mtab` attribute on the shell; the tab is a server assign so the
  poll-tick DOM patches preserve it. These tests pin the tab bar markup, the
  `set_mtab` event round-trip, the NEEDS YOU badge count, and the VIEWS nav
  that restores the goal-board / DAG / lease-map / event-river links. Hermetic:
  the read-model IS the fixture source, exactly like `KaziWeb.StarmapLiveTest`.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.{PredicateResult, PredicateVector}
  alias Kazi.ReadModel
  alias Kazi.ReadModel.RunRegistry

  defp seed(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.1.0>",
          workspace: "/tmp/ws",
          goal_ref: "goal-#{System.unique_integer([:positive])}",
          harness: "claude",
          model: "claude-sonnet-5",
          session_os_pid: "424242"
        },
        overrides
      )

    {:ok, run} = RunRegistry.start(attrs)
    run
  end

  test "the shell renders the tab bar with MAP active by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="starmap-tabbar")
    assert html =~ ~s(data-mtab="map")

    for tab <- ~w(map needs sessions more) do
      assert html =~ ~s(id="starmap-mtab-#{tab}")
    end

    assert html =~ ~s(id="starmap-mtab-map" class="mtab on")
  end

  test "set_mtab switches the active pane and survives a poll tick", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> element("#starmap-mtab-needs") |> render_click()
    assert html =~ ~s(data-mtab="needs")
    assert html =~ ~s(id="starmap-mtab-needs" class="mtab on")

    send(view.pid, :tick)
    assert render(view) =~ ~s(data-mtab="needs")
  end

  test "an unknown tab value is ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = render_hook(view, "set_mtab", %{"tab" => "bogus"})
    assert html =~ ~s(data-mtab="map")
  end

  test "the NEEDS YOU tab carries a badge with the attention count", %{conn: conn} do
    run = seed()

    for index <- 0..2 do
      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: run.goal_ref,
          iteration_index: index,
          predicate_vector: PredicateVector.new(%{"unit" => PredicateResult.fail()})
        })
    end

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(class="mtab-badge")
  end

  test "no badge renders on an empty fleet", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ ~s(class="mtab-badge")
  end

  test "the VIEWS nav links every dashboard view from the rail", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="starmap-nav")

    for path <- ~w(/goals /dag /leases /events) do
      assert html =~ ~s(href="#{path}")
    end
  end

  test "the sessions pane shows an empty state when no sessions are live", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="starmap-sessions-empty")
  end
end
