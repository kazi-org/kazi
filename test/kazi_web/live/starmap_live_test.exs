defmodule KaziWeb.StarmapLiveTest do
  @moduledoc """
  LiveView test for the fleet starmap (T46.5, UC-061, ADR-0057).

  Seeds the (sandbox-isolated) run registry directly — no scheduler, no real
  `kazi apply` process — and asserts the view renders the empty state with no
  runs, maps each registry fact to its display state (landed / converging /
  stale / stuck), and reflects a status change on the next poll tick without a
  restart. Hermetic: the read-model IS the fixture source.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Repo

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

  defp age_heartbeat(run, seconds_ago) do
    run
    |> Run.changeset(%{"heartbeat_at" => DateTime.add(DateTime.utc_now(), -seconds_ago, :second)})
    |> Repo.update!()
  end

  test "renders the empty state with no registered runs", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(id="starmap-empty")
    refute html =~ ~s(id="starmap-nodes")
  end

  test "a converged terminal run renders as landed", %{conn: conn} do
    run = seed()
    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(id="canvas-node-#{run.run_id}")
    assert html =~ ~s(data-state="landed")
  end

  test "a stuck terminal run renders as stuck", %{conn: conn} do
    run = seed()
    {:ok, _} = RunRegistry.finish(run.run_id, "stuck")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(id="canvas-node-#{run.run_id}")
    assert html =~ ~s(data-state="stuck")
  end

  test "a converging run's LIVE sublabel carries its elapsed runtime", %{conn: conn} do
    seed(%{goal_ref: "live-elapsed"})

    html = conn |> get("/starmap") |> html_response(200)

    # "CONVERGING · LIVE <elapsed>" — a fresh run reads in seconds.
    assert html =~ ~r/CONVERGING · LIVE \d+[smhd]/
  end

  test "a fresh-heartbeat running run renders as converging", %{conn: conn} do
    run = seed()

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(id="canvas-node-#{run.run_id}")
    assert html =~ ~s(data-state="converging")
  end

  test "a running run with a stale heartbeat renders as stale", %{conn: conn} do
    run = seed()
    age_heartbeat(run, 200)

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(id="canvas-node-#{run.run_id}")
    assert html =~ ~s(data-state="stale")
  end

  test "run tags (harness/model) and fleet counts render", %{conn: conn} do
    seed(%{harness: "codex", model: "gpt-5"})
    seed(%{harness: "codex", model: "gpt-5"})
    run = seed(%{harness: "codex", model: "gpt-5"})
    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ "codex"
    assert html =~ "gpt-5"
    assert html =~ ~s(<span class="fleet-tile-value nd-conv">2</span>)
    assert html =~ ~s(<span class="fleet-tile-value nd-landed">1</span>)
  end

  test "a status change is reflected on the next poll tick without a restart", %{conn: conn} do
    run = seed()

    {:ok, view, html} = live(conn, ~p"/starmap")
    assert html =~ ~s(data-state="converging")

    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    send(view.pid, :tick)
    html = render(view)

    assert html =~ ~s(id="canvas-node-#{run.run_id}")
    assert html =~ ~s(data-state="landed")
  end
end
