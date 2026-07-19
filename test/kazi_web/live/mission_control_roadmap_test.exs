defmodule KaziWeb.MissionControlRoadmapTest do
  @moduledoc """
  Mission Control's roadmap wave grouping (ADR-0070, preserving T47.2).

  When `kazi dashboard --roadmap <goal-file>` configures a roadmap goal
  (`KaziWeb.Starmap.GoalSource`), the FLEET grid groups into topological wave
  sections from `Kazi.Goal.DepGraph.frontiers/1` — the SAME computation
  `kazi apply --explain` prints. Certifies: a declared group with a converged
  run renders a CONVERGED card in its wave; the eligible-now frontier group
  (all deps converged, nothing dispatched) renders a CLAIMED placeholder; a
  group still waiting on a dep renders a PENDING placeholder; and the roadmap
  header reports the goal + wave counts. Wired through the real
  `Kazi.CLI.configure_roadmap/1` seam, so the CLI flag stays covered against the
  new grid. Hermetic: a goal-file on disk + the run registry are the fixture.
  """
  use KaziWeb.ConnCase, async: false

  @moduletag :tmp_dir

  alias Kazi.ReadModel.RunRegistry

  setup do
    # Hermetic default: no cross-machine bus facts. CI has no daemon, but a
    # developer box may have one reachable, which would otherwise inject phantom
    # remote cards into the flat grid and its LIVE count.
    Application.put_env(:kazi, :remote_run_facts_fetcher, fn -> [] end)

    on_exit(fn ->
      Application.delete_env(:kazi, :starmap_goal_source)
      Application.delete_env(:kazi, :starmap_roadmap_goal)
      Application.delete_env(:kazi, :remote_run_facts_fetcher)
    end)

    :ok
  end

  defp write_chain_goal(tmp_dir) do
    path = Path.join(tmp_dir, "roadmap_chain.toml")

    File.write!(path, """
    id = "roadmap-chain"
    name = "Roadmap chain"

    [scope]
    workspace = "#{tmp_dir}"

    [[group]]
    id = "a"
    name = "A"

    [[group]]
    id = "b"
    name = "B"
    needs = ["a"]

    [[group]]
    id = "c"
    name = "C"
    needs = ["b"]

    [[predicate]]
    id = "pa"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "true"]
    group = "a"

    [[predicate]]
    id = "pb"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "true"]
    group = "b"

    [[predicate]]
    id = "pc"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "true"]
    group = "c"
    """)

    path
  end

  defp seed(goal_ref, status) do
    {:ok, run} =
      RunRegistry.start(%{
        run_id: "run-#{System.unique_integer([:positive])}",
        pid: "#PID<0.1.0>",
        workspace: "/tmp/ws",
        goal_ref: goal_ref,
        harness: "claude",
        model: "claude-sonnet-5",
        session_os_pid: "424242"
      })

    if status, do: {:ok, _} = RunRegistry.finish(run.run_id, status)
    run
  end

  test "the fleet grid groups into roadmap wave sections", %{conn: conn, tmp_dir: tmp_dir} do
    :ok = Kazi.CLI.configure_roadmap(write_chain_goal(tmp_dir))

    # Group "a" has converged; "b" (deps met) and "c" (waiting on b) have no run.
    seed("a", "converged")

    {:ok, _view, html} = live(conn, ~p"/")

    # Roadmap header + one wave per topological frontier (a | b | c).
    assert html =~ "ROADMAP · 3 GOALS · 3 WAVES"
    assert html =~ ~s(data-frontier="0")
    assert html =~ ~s(data-frontier="1")
    assert html =~ ~s(data-frontier="2")
    assert html =~ "WAVE 1 · LANDED"

    # "a" converged -> a real card; "b" eligible-now -> CLAIMED placeholder;
    # "c" waiting on "b" -> PENDING placeholder.
    # Anchor each check on the unique card id; state/run attribute order within
    # a `<.link>`'s global attrs is not stable, so assert each attribute alone.
    assert html =~ ~r/id="mc-card-a"[^>]*data-state="landed"/
    assert html =~ ~r/id="mc-card-a"[^>]*data-run="true"/
    assert html =~ ~r/id="mc-card-b"[^>]*data-state="claimed"/
    assert html =~ ~r/id="mc-card-b"[^>]*data-run="false"/
    assert html =~ ~r/id="mc-card-c"[^>]*data-state="pending"/
    assert html =~ ~r/id="mc-card-c"[^>]*data-run="false"/
    assert html =~ "CLAIMED"
    assert html =~ "PENDING"
  end

  test "no roadmap configured falls back to the flat instance grid", %{conn: conn} do
    seed("solo", nil)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "FLEET · 1 LIVE"
    refute html =~ "ROADMAP ·"
    refute html =~ ~s(data-frontier=)
  end
end
