defmodule KaziWeb.StarmapWavebandTest do
  @moduledoc """
  LiveView test for the starmap's wave-band goal-DAG layout (T46.5 remainder,
  UC-061, ADR-0057/ADR-0056).

  Seeds a 3-group `needs`-chain goal (a -> b -> c) as the roadmap DAG (via the
  `KaziWeb.Starmap.GoalSource` injection seam — no CLI, no scheduler, no
  goal-file on disk) plus registry facts for some of its groups, and asserts
  the rendered bands match `Kazi.Goal.DepGraph.frontiers/1` (the same
  computation `kazi apply --explain` prints) with each node's display state
  resolved from the seeded read-model/registry facts.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Repo

  defmodule StubGoalSource do
    @moduledoc """
    Test fixture: returns whatever goal is stashed in application env. Application
    env (unlike the process dictionary) is visible from the separate LiveView
    process `mount/3` actually runs in, so this is a valid cross-process seam.
    """
    @behaviour KaziWeb.Starmap.GoalSource

    @impl true
    def goal, do: Application.get_env(:kazi, :starmap_waveband_stub_goal)
  end

  setup do
    Application.put_env(:kazi, :starmap_goal_source, StubGoalSource)

    on_exit(fn ->
      Application.delete_env(:kazi, :starmap_goal_source)
      Application.delete_env(:kazi, :starmap_waveband_stub_goal)
    end)

    :ok
  end

  defp put_goal(goal) do
    Application.put_env(:kazi, :starmap_waveband_stub_goal, goal)
  end

  defp chain_goal do
    Goal.new("roadmap",
      groups: [
        Group.new("a", "Goal A"),
        Group.new("b", "Goal B", needs: ["a"]),
        Group.new("c", "Goal C", needs: ["b"])
      ]
    )
  end

  defp seed(goal_ref, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.1.0>",
          workspace: "/tmp/ws",
          goal_ref: goal_ref,
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

  test "with no roadmap configured, no wave bands render", %{conn: conn} do
    put_goal(nil)

    {:ok, _view, html} = live(conn, ~p"/starmap")

    refute html =~ ~s(id="starmap-canvas")
  end

  test "a seeded 3-wave DAG renders bands matching --explain frontiers", %{conn: conn} do
    put_goal(chain_goal())

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(id="starmap-canvas")
    assert html =~ ~s(data-frontiers="3")
    assert html =~ ~s(id="starmap-band-0" data-frontier="0")
    assert html =~ ~s(id="starmap-band-1" data-frontier="1")
    assert html =~ ~s(id="starmap-band-2" data-frontier="2")

    assert html =~
             ~s(id="canvas-node-group-a" class="canvas-node-group" data-node-id="a" data-frontier="0")

    assert html =~
             ~s(id="canvas-node-group-b" class="canvas-node-group" data-node-id="b" data-frontier="1")

    assert html =~
             ~s(id="canvas-node-group-c" class="canvas-node-group" data-node-id="c" data-frontier="2")
  end

  test "a landed dep, an eligible (claimed) node, and a blocked (pending) node", %{conn: conn} do
    put_goal(chain_goal())
    run = seed("a")
    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(data-node-id="a" data-frontier="0" data-state="landed")
    assert html =~ ~s(data-node-id="b" data-frontier="1" data-state="claimed")
    assert html =~ ~s(data-node-id="c" data-frontier="2" data-state="pending")
  end

  test "a stuck dep renders as stuck and poisons its dependent to pending", %{conn: conn} do
    put_goal(chain_goal())
    run_a = seed("a")
    {:ok, _} = RunRegistry.finish(run_a.run_id, "converged")
    run_b = seed("b")
    {:ok, _} = RunRegistry.finish(run_b.run_id, "stuck")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(data-node-id="b" data-frontier="1" data-state="stuck")
    assert html =~ ~s(data-node-id="c" data-frontier="2" data-state="pending")
  end

  test "a fresh-heartbeat running node renders as converging", %{conn: conn} do
    put_goal(chain_goal())
    seed("a")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(data-node-id="a" data-frontier="0" data-state="converging")
  end

  test "a running node with a stale heartbeat renders as stale", %{conn: conn} do
    put_goal(chain_goal())
    run = seed("a")
    age_heartbeat(run, 200)

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(data-node-id="a" data-frontier="0" data-state="stale")
  end

  test "band nodes carry run tags (harness/model)", %{conn: conn} do
    put_goal(chain_goal())
    seed("a", %{harness: "codex", model: "gpt-5"})

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ "codex"
    assert html =~ "gpt-5"
  end

  test "roadmap `needs` edges render as connector lines between group nodes", %{conn: conn} do
    put_goal(chain_goal())

    for goal_ref <- ~w(a b c) do
      run = seed(goal_ref)
      {:ok, _} = RunRegistry.finish(run.run_id, "converged")
    end

    {:ok, _view, html} = live(conn, ~p"/starmap")

    # One <line> per declared `needs` edge, dep -> group.
    assert html =~ ~s(id="starmap-edges")
    assert html =~ ~s(data-from="a" data-to="b")
    assert html =~ ~s(data-from="b" data-to="c")

    # All endpoints landed: base edge styling only, no active highlight.
    assert html =~ ~s(class="edge" data-from=)
    refute html =~ ~s(class="edge edge-active")
  end

  test "an edge touching a live (converging/stuck) endpoint highlights as active", %{conn: conn} do
    put_goal(chain_goal())
    run_a = seed("a")
    {:ok, _} = RunRegistry.finish(run_a.run_id, "converged")
    # b: fresh-heartbeat running -> converging: both its edges go active.
    seed("b")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(class="edge edge-active" data-from="a" data-to="b")
    assert html =~ ~s(class="edge edge-active" data-from="b" data-to="c")
  end

  test "without a roadmap there are no declared edges, so no connector lines", %{conn: conn} do
    put_goal(nil)
    seed("flat-goal")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    refute html =~ ~s(id="starmap-edges")
  end

  test "a verdict change is reflected on the next poll tick without a restart", %{conn: conn} do
    put_goal(chain_goal())
    run = seed("a")

    {:ok, view, html} = live(conn, ~p"/starmap")
    assert html =~ ~s(data-node-id="a" data-frontier="0" data-state="converging")

    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    send(view.pid, :tick)
    html = render(view)

    assert html =~ ~s(data-node-id="a" data-frontier="0" data-state="landed")
    assert html =~ ~s(data-node-id="b" data-frontier="1" data-state="claimed")
  end
end
