defmodule KaziWeb.DagLiveTest do
  @moduledoc """
  LiveView test for the live dependency-DAG dashboard (T23.7, UC-038).

  Drives the view from an injected `KaziWeb.DagFixtureSource` (no scheduler, no
  harness) and asserts: a seeded `Kazi.Scheduler.DagSnapshot` renders its group
  nodes with the expected running/ready/blocked/converged states, the `needs`
  edges, and per-group convergence; a fresh snapshot pushed on the source topic
  (a group moving ready → running → converged) re-renders the DAG live; and an
  empty snapshot renders the honest "no active run" empty state. Hermetic: the
  fixture IS the snapshot.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.Scheduler.DagSnapshot
  alias KaziWeb.DagFixtureSource, as: Fixture

  setup do
    # Point the view at the in-memory fixture source for this test, restoring the
    # default afterwards so other tests are unaffected.
    prev = Application.get_env(:kazi, :dag_source)
    Application.put_env(:kazi, :dag_source, Fixture)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:kazi, :dag_source, prev),
        else: Application.delete_env(:kazi, :dag_source)
    end)

    :ok
  end

  defp start_fixture(snapshot) do
    start_supervised!({Fixture, snapshot: snapshot})
    :ok
  end

  # A diamond DAG: a → {b, c} → d. With `a` converged and `b` running, the
  # planner makes `c` ready (its only dep converged) and `d` pending (it waits on
  # b and c). Exercises all four headline states at once.
  defp goal do
    Goal.new("demo",
      groups: [
        Group.new("a", "Auth"),
        Group.new("b", "Billing", needs: ["a"]),
        Group.new("c", "Catalog", needs: ["a"]),
        Group.new("d", "Delivery", needs: ["b", "c"])
      ]
    )
  end

  test "renders the empty state when no run is active", %{conn: conn} do
    start_fixture(DagSnapshot.empty())

    {:ok, _view, html} = live(conn, ~p"/dag")

    assert html =~ ~s(id="dag-empty")
    assert html =~ "No active run"
    refute html =~ ~s(id="dag-nodes")
  end

  test "renders group nodes with live states, edges, and per-group convergence", %{conn: conn} do
    states = %{"a" => :converged, "b" => :running}
    start_fixture(DagSnapshot.from(goal(), states))

    {:ok, _view, html} = live(conn, ~p"/dag")

    # Nodes with their resolved display states.
    assert html =~ ~s(id="dag-node-a")
    assert html =~ ~s(data-group="a" data-state="converged")
    assert html =~ ~s(data-group="b" data-state="running")
    # c's only dep (a) converged → ready; d still waits on b and c → pending.
    assert html =~ ~s(data-group="c" data-state="ready")
    assert html =~ ~s(data-group="d" data-state="pending")

    # The `needs` edges: a→b, a→c, b→d, c→d.
    assert html =~ ~s(id="dag-edge-a-b")
    assert html =~ ~s(id="dag-edge-a-c")
    assert html =~ ~s(id="dag-edge-b-d")
    assert html =~ ~s(id="dag-edge-c-d")

    # Per-group convergence: d needs two deps, neither converged yet.
    assert html =~ ~s(data-converged="0" data-total="2")
  end

  test "a blocked sub-DAG surfaces its blocking dep", %{conn: conn} do
    # `a` stuck → its dependents b and c are blocked, and d behind them too.
    start_fixture(DagSnapshot.from(goal(), %{"a" => :stuck}))

    {:ok, _view, html} = live(conn, ~p"/dag")

    assert html =~ ~s(data-group="a" data-state="stuck")
    assert html =~ ~s(data-group="b" data-state="blocked")
    assert html =~ "blocked by a"
  end

  test "a fresh snapshot re-renders the DAG live (a group converging)", %{conn: conn} do
    start_fixture(DagSnapshot.from(goal(), %{"a" => :converged, "b" => :running}))

    {:ok, view, _html} = live(conn, ~p"/dag")

    assert render(view) =~ ~s(data-group="b" data-state="running")

    # Simulate b converging: push a fresh snapshot. d is still pending (c not
    # done), but b now reads converged — the subscribed view re-renders.
    :ok =
      Fixture.put_snapshot(
        DagSnapshot.from(goal(), %{"a" => :converged, "b" => :converged, "c" => :running})
      )

    html = render(view)
    assert html =~ ~s(data-group="b" data-state="converged")
    assert html =~ ~s(data-group="c" data-state="running")
  end
end
