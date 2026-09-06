defmodule Kazi.CLI.PlanRenderDagTest do
  @moduledoc """
  T73.4 (ADR-0087): `kazi plan render --dag <fleet-dir|manifest>` end-to-end
  through the real CLI exec core (`Kazi.CLI.run/2`) — argv parsing, the
  fleet-source JSON document, and the golden-file byte-stability acceptance
  criterion from docs/plans/E73.md.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.CLI

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-cli-dag-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_out, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    {_out, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    {_out, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write_goal(dir, filename, id, extra) do
    path = Path.join(dir, filename)

    File.write!(path, """
    id = "#{id}"

    [[predicate]]
    id = "p"
    provider = "custom_script"
    cmd = "true"
    #{extra}
    """)

    path
  end

  defp run_cli(argv) do
    ref = make_ref()
    me = self()
    out = capture_io(fn -> send(me, {ref, CLI.run(argv, [])}) end)

    receive do
      {^ref, code} -> {out, code}
    after
      0 -> flunk("expected an exit code")
    end
  end

  # A three-goal fixture with one explicit edge (b depends_on a), one
  # inferred-overlap edge (b and c share an un-declared lib/shared path), and
  # one shared-key exclusion (a and c both declare mix.exs as a shared_path,
  # so THAT overlap never becomes an edge on its own).
  defp write_fixture(dir) do
    write_goal(dir, "0001-a.goal.toml", "a", """
    [scope]
    write_paths = ["lib/a/**"]
    shared_paths = ["mix.exs"]
    """)

    write_goal(dir, "0002-b.goal.toml", "b", """
    [metadata]
    depends_on = ["a"]

    [scope]
    write_paths = ["lib/b/**", "lib/shared/**"]
    """)

    write_goal(dir, "0003-c.goal.toml", "c", """
    [scope]
    write_paths = ["mix.exs", "lib/shared/**"]
    shared_paths = ["mix.exs"]
    """)

    File.write!(Path.join(dir, "mix.exs"), "# fixture\n")
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "fixture"], cd: dir)
    :ok
  end

  # ===========================================================================
  # Tier 1 — argv parsing
  # ===========================================================================

  describe "parse/1 — plan render --dag" do
    test "carries --dag, --workspace, and --out" do
      assert {:plan_render, "fleet-dir", opts} =
               CLI.parse([
                 "plan",
                 "render",
                 "fleet-dir",
                 "--dag",
                 "--workspace",
                 "/tmp/x",
                 "--out",
                 "/tmp/out.json"
               ])

      assert opts[:dag] == true
      assert opts[:workspace] == "/tmp/x"
      assert opts[:out] == "/tmp/out.json"
    end

    test "--dag defaults to false" do
      assert {:plan_render, "r.toml", opts} = CLI.parse(["plan", "render", "r.toml"])
      assert opts[:dag] == false
    end
  end

  # ===========================================================================
  # Tier 2 — end-to-end fixture-repo acceptance
  # ===========================================================================

  describe "run/2 — plan render --dag" do
    test "renders a stable JSON DAG document, byte-stable across two runs", %{dir: dir} do
      write_fixture(dir)

      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
      expected_commit = String.trim(sha)

      {out1, code1} = run_cli(["plan", "render", dir, "--dag", "--workspace", dir])
      {out2, code2} = run_cli(["plan", "render", dir, "--dag", "--workspace", dir])

      assert code1 == 0
      assert code2 == 0
      assert out1 == out2

      assert {:ok, doc} = Jason.decode(out1)

      # source_commit equals `git rev-parse HEAD` of the fixture.
      assert doc["source_commit"] == expected_commit

      # goals[]: id, file, sha256 of the goal-file bytes, write_paths, roots.
      goals = Map.new(doc["goals"], &{&1["id"], &1})
      assert Map.keys(goals) |> Enum.sort() == ["a", "b", "c"]

      for {id, filename} <- [
            {"a", "0001-a.goal.toml"},
            {"b", "0002-b.goal.toml"},
            {"c", "0003-c.goal.toml"}
          ] do
        goal = Map.fetch!(goals, id)
        path = Path.join(dir, filename)
        assert goal["file"] == path

        {sha256sum_out, 0} = System.cmd("sh", ["-c", "sha256sum #{path} | cut -d' ' -f1"])
        assert goal["sha256"] == String.trim(sha256sum_out)
      end

      assert goals["a"]["write_paths"] == ["lib/a/**"]
      assert goals["a"]["roots"] == ["lib/a/**"]
      assert goals["b"]["write_paths"] == ["lib/b/**", "lib/shared/**"]
      assert goals["c"]["write_paths"] == ["mix.exs", "lib/shared/**"]

      # shared_paths: the effective fleet-level set.
      assert doc["shared_paths"] == ["mix.exs"]

      # nodes[]: one entry per goal, each carrying a planning-time render_sha256.
      nodes = Map.new(doc["nodes"], &{&1["id"], &1})
      assert Map.keys(nodes) |> Enum.sort() == ["a", "b", "c"]
      assert is_binary(nodes["a"]["render_sha256"])
      assert String.length(nodes["a"]["render_sha256"]) == 64

      # edges[]: one explicit (b depends on a), one inferred_overlap (b/c share
      # lib/shared un-declared); a/c's mix.exs overlap is excluded by
      # shared_paths so it contributes no edge of its own.
      edges = doc["edges"]
      assert length(edges) == 2

      explicit = Enum.find(edges, &(&1["kind"] == "explicit"))
      assert explicit["from"] == "a"
      assert explicit["to"] == "b"

      inferred = Enum.find(edges, &(&1["kind"] == "inferred_overlap"))
      assert inferred["from"] == "b"
      assert inferred["to"] == "c"
      assert inferred["overlap"] == [["lib/shared/**", "lib/shared/**"]]

      # top-level note about dispatch-time re-rendering.
      assert doc["note"] =~ "dispatch"
    end

    test "--out writes to a file; without it the document prints to stdout", %{dir: dir} do
      write_fixture(dir)
      out_path = Path.join(dir, "dag.json")

      {stdout, code} =
        run_cli(["plan", "render", dir, "--dag", "--workspace", dir, "--out", out_path])

      assert code == 0
      assert stdout == ""
      assert File.exists?(out_path)
      assert {:ok, _doc} = File.read!(out_path) |> Jason.decode()

      {stdout2, code2} = run_cli(["plan", "render", dir, "--dag", "--workspace", dir])
      assert code2 == 0
      assert {:ok, _doc} = Jason.decode(stdout2)
    end

    test "the plain roadmap markdown render form is unchanged", %{dir: dir} do
      goal_path =
        write_goal(dir, "solo.goal.toml", "solo", """
        [scope]
        write_paths = ["lib/solo/**"]
        """)

      roadmap_path = Path.join(dir, "r.roadmap.toml")

      File.write!(roadmap_path, """
      [[goals]]
      id = "solo"
      path = "#{Path.basename(goal_path)}"
      """)

      {out, code} = run_cli(["plan", "render", roadmap_path])
      assert code == 0
      assert out =~ "GENERATED"
      assert out =~ "solo"
      refute out =~ "source_commit"
    end
  end
end
