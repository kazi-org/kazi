defmodule KaziWeb.DashboardRoadmapRefTest do
  @moduledoc """
  `kazi dashboard --roadmap <goal-file>` (ADR-0056/ADR-0070, preserving T47.2) —
  the user-visible consumer of `KaziWeb.Starmap.GoalSource`.

  The roadmap grouping only ever rendered a goal a TEST seeded through the
  `GoalSource` injection seam until this contract wired a REAL goal-file on disk
  into it. This file certifies the CLI-seam contract (the rendering itself is
  `KaziWeb.MissionControlRoadmapTest`):

    1. **argv boundary** — `--roadmap <path>` parses at the `Kazi.CLI.parse/1`
       layer, same as any other flag; absent, it's `nil` (pinned behavior).
    2. **loads through GoalSource, matches --explain** — `configure_roadmap/1`
       (the public seam `execute_dashboard/2` calls on a fresh boot) loads the
       path via `Kazi.Goal.Loader` — the SAME loader `apply`/`--explain` use —
       and Mission Control groups that goal's `needs`-DAG into wave sections
       exactly as `Kazi.Goal.DepGraph.frontiers/1` computes them.
    3. **advisory when already running** — like `--port`/`--bind`, a `kazi
       dashboard --roadmap` invoked against a process that already serves the
       endpoint (every test/dev/release boot) is a no-op with a printed
       warning, never a silent behavior change.
    4. **loud boot error** — an unloadable path returns `{:error, reason}`
       and never mutates the configured `GoalSource`.
    5. **absent flag, pinned unchanged** — `configure_roadmap(nil)` is a pure
       no-op.
    6. **documented** — `kazi help --json` lists `--roadmap` on `dashboard`.

  Exercises `configure_roadmap/1` directly (a public seam, mirroring
  `standalone_dashboard_children/0`) for the load/wire-up contracts rather than
  tearing down the shared `KaziWeb.Endpoint` every other test in this suite
  depends on to serve requests.
  """
  use KaziWeb.ConnCase, async: false

  import ExUnit.CaptureIO

  alias Kazi.Goal
  alias Kazi.Goal.DepGraph
  alias Kazi.Goal.Loader

  setup do
    on_exit(fn ->
      Application.delete_env(:kazi, :starmap_goal_source)
      Application.delete_env(:kazi, :starmap_roadmap_goal)
    end)

    :ok
  end

  defp write_chain_goal_file(tmp_dir) do
    path = Path.join(tmp_dir, "roadmap_chain_goal.toml")

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

  describe "argv boundary: --roadmap parses like --port/--bind" do
    test "kazi dashboard --roadmap <path> parses the flag" do
      assert {:dashboard, opts} = Kazi.CLI.parse(["dashboard", "--roadmap", "some/goal.toml"])
      assert opts[:roadmap] == "some/goal.toml"
    end

    test "absent --roadmap parses to nil (pinned unchanged)" do
      assert {:dashboard, opts} = Kazi.CLI.parse(["dashboard"])
      assert opts[:roadmap] == nil
    end
  end

  describe "kazi help --json documents --roadmap" do
    test "the dashboard command lists a --roadmap flag with a description" do
      out = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"]) == 0 end)
      %{"commands" => commands} = Jason.decode!(out)

      dashboard = Enum.find(commands, &(&1["name"] == "dashboard"))
      assert dashboard, "help --json must list the dashboard command"

      roadmap_flag = Enum.find(dashboard["flags"], &(&1["name"] == "--roadmap"))
      assert roadmap_flag, "dashboard's flags must include --roadmap"
      assert roadmap_flag["type"] == "string"
      assert is_binary(roadmap_flag["description"]) and roadmap_flag["description"] != ""
    end
  end

  describe "configure_roadmap/1 loads a real goal-file through GoalSource" do
    @describetag :tmp_dir

    test "a chain goal-file's wave sections match --explain's frontier computation",
         %{conn: conn, tmp_dir: tmp_dir} do
      goal_file = write_chain_goal_file(tmp_dir)

      assert :ok = Kazi.CLI.configure_roadmap(goal_file)

      {:ok, %Goal{} = goal} = Loader.load(goal_file)
      expected_frontiers = DepGraph.frontiers(goal)
      assert length(expected_frontiers) == 3

      assert KaziWeb.Starmap.GoalSource.goal().id == goal.id

      # Mission Control groups the fleet grid into one wave section per frontier
      # (the rendering contract is covered in full by
      # `KaziWeb.MissionControlRoadmapTest`; here we pin that the configured
      # roadmap reaches the home view as three ordered waves).
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "ROADMAP · 3 GOALS · 3 WAVES"
      assert html =~ ~s(data-frontier="0")
      assert html =~ ~s(data-frontier="1")
      assert html =~ ~s(data-frontier="2")
      assert html =~ ~s(id="mc-card-a")
      assert html =~ ~s(id="mc-card-b")
      assert html =~ ~s(id="mc-card-c")
    end
  end

  describe "a bad/unloadable goal-file is a loud boot error, never silently empty" do
    test "an unloadable path returns {:error, reason} and leaves GoalSource untouched" do
      assert {:error, reason} = Kazi.CLI.configure_roadmap("/does/not/exist/goal.toml")
      assert is_binary(reason)

      refute Application.get_env(:kazi, :starmap_goal_source) == KaziWeb.Starmap.GoalSource.Static
    end
  end

  describe "absent --roadmap is a pure no-op" do
    test "configure_roadmap(nil) never touches application env" do
      refute Application.get_env(:kazi, :starmap_goal_source)

      assert :ok = Kazi.CLI.configure_roadmap(nil)

      refute Application.get_env(:kazi, :starmap_goal_source)
    end
  end

  describe "already-running endpoint: --roadmap is advisory, like --port/--bind" do
    @describetag :tmp_dir

    test "a fresh --roadmap is ignored (with a printed warning) against a process already serving",
         %{tmp_dir: tmp_dir} do
      goal_file = write_chain_goal_file(tmp_dir)

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert Kazi.CLI.run(["dashboard", "--roadmap", goal_file],
                       serve_forever: fn -> :ok end
                     ) == 0
            end)

          assert stdout =~ "already serves mission control"
        end)

      assert stderr =~ "--roadmap ignored"

      refute Application.get_env(:kazi, :starmap_goal_source) == KaziWeb.Starmap.GoalSource.Static
    end
  end
end
