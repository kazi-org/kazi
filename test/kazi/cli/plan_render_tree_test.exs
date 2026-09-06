defmodule Kazi.CLI.PlanRenderTreeTest do
  @moduledoc """
  T72.4 (ADR-0086 decision 4): `kazi plan render --tree` end-to-end through
  the real CLI exec core (`Kazi.CLI.run/2`) — the argv boundary, the
  human/`--json` surfaces, and the fixture-repo acceptance criteria from
  docs/plans/E72.md, driven through the actual command a user types rather
  than `Kazi.Plan.Tree` directly (see `Kazi.Plan.TreeTest` for the module's
  own unit coverage).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kazi.CLI

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-cli-tree-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_out, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp goal_file(dir, filename, id, scope_write_paths) do
    path = Path.join(dir, filename)

    File.write!(path, """
    id = "#{id}"

    [scope]
    write_paths = #{inspect(scope_write_paths)}

    [[predicate]]
    id = "p"
    provider = "custom_script"
    cmd = "true"
    """)

    path
  end

  defp roadmap_file(dir, filename, entries) do
    path = Path.join(dir, filename)

    body =
      Enum.map_join(entries, "\n\n", fn {roadmap_id, goal_path} ->
        """
        [[goals]]
        id = "#{roadmap_id}"
        path = "#{Path.basename(goal_path)}"
        """
      end)

    File.write!(path, body)
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

  defp run_cli_stderr(argv) do
    ref = make_ref()
    me = self()
    err = capture_io(:stderr, fn -> send(me, {ref, CLI.run(argv, [])}) end)

    receive do
      {^ref, code} -> {err, code}
    after
      0 -> flunk("expected an exit code")
    end
  end

  # ===========================================================================
  # Tier 1 — argv parsing
  # ===========================================================================

  describe "parse/1 — plan render --tree" do
    test "carries --tree, --workspace, and --json" do
      assert {:plan_render, "r.toml", opts} =
               CLI.parse([
                 "plan",
                 "render",
                 "r.toml",
                 "--tree",
                 "--workspace",
                 "/tmp/x",
                 "--json"
               ])

      assert opts[:tree] == true
      assert opts[:workspace] == "/tmp/x"
      assert opts[:json] == true
    end

    test "--tree defaults to false" do
      assert {:plan_render, "r.toml", opts} = CLI.parse(["plan", "render", "r.toml"])
      assert opts[:tree] == false
    end
  end

  # ===========================================================================
  # Tier 2 — end-to-end fixture-repo acceptance
  # ===========================================================================

  describe "run/2 — plan render --tree" do
    test "writes pkg/foo/AGENTS.md + symlink and reports it under --json", %{dir: dir} do
      goal = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", goal}])

      {out, code} = run_cli(["plan", "render", roadmap, "--tree", "--workspace", dir, "--json"])

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["kind"] == "plan_render_tree"
      assert [delivery] = payload["deliveries"]
      assert delivery["goal_id"] == "foo"
      assert delivery["symlink"] == "created"
      assert delivery["written"] == true

      assert File.exists?(Path.join(dir, "pkg/foo/AGENTS.md"))
      assert File.lstat!(Path.join(dir, "pkg/foo/CLAUDE.md")).type == :symlink

      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
      refute status =~ "AGENTS.md"
      refute status =~ "CLAUDE.md"
    end

    test "human surface names the goal, root, and target path", %{dir: dir} do
      goal = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", goal}])

      {out, code} = run_cli(["plan", "render", roadmap, "--tree", "--workspace", dir])

      assert code == 0
      assert out =~ "foo"
      assert out =~ "pkg/foo"
      assert out =~ "AGENTS.md"
      assert out =~ "symlink created"
    end

    test "re-running is idempotent (exit 0, byte-identical AGENTS.md)", %{dir: dir} do
      goal = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", goal}])
      argv = ["plan", "render", roadmap, "--tree", "--workspace", dir, "--json"]

      {_out, 0} = run_cli(argv)
      before = File.read!(Path.join(dir, "pkg/foo/AGENTS.md"))

      {out, code} = run_cli(argv)
      assert code == 0
      assert File.read!(Path.join(dir, "pkg/foo/AGENTS.md")) == before

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert [delivery] = payload["deliveries"]
      assert delivery["symlink"] == "already_present"
    end

    test "a pre-existing hand-written AGENTS.md exits non-zero, naming the path, writing nothing",
         %{dir: dir} do
      goal = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", goal}])

      hand_written_path = Path.join(dir, "pkg/foo/AGENTS.md")
      File.mkdir_p!(Path.dirname(hand_written_path))
      File.write!(hand_written_path, "# not generated by kazi\n")

      {err, code} = run_cli_stderr(["plan", "render", roadmap, "--tree", "--workspace", dir])

      assert code == 1
      assert err =~ "error:"
      assert err =~ hand_written_path
      assert {:error, :enoent} = File.lstat(Path.join(dir, "pkg/foo/CLAUDE.md"))
      assert File.read!(hand_written_path) == "# not generated by kazi\n"
    end

    test "a pre-existing hand-written AGENTS.md under --json names the path and reason", %{
      dir: dir
    } do
      goal = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", goal}])

      hand_written_path = Path.join(dir, "pkg/foo/AGENTS.md")
      File.mkdir_p!(Path.dirname(hand_written_path))
      File.write!(hand_written_path, "# not generated by kazi\n")

      {out, code} =
        run_cli(["plan", "render", roadmap, "--tree", "--workspace", dir, "--json"])

      assert code == 1
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "hand_written_agents_md"
      assert payload["paths"] == [hand_written_path]
    end

    test "a pre-existing CLAUDE.md is byte-identical and the output names the include line", %{
      dir: dir
    } do
      goal = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", goal}])

      claude_path = Path.join(dir, "pkg/foo/CLAUDE.md")
      File.mkdir_p!(Path.dirname(claude_path))
      File.write!(claude_path, "# team conventions\n")

      {out, code} =
        run_cli(["plan", "render", roadmap, "--tree", "--workspace", dir, "--json"])

      assert code == 0
      assert File.read!(claude_path) == "# team conventions\n"

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert [delivery] = payload["deliveries"]
      assert delivery["symlink"] == nil
      assert delivery["claude_include_hint"] =~ "@AGENTS.md"
      assert delivery["claude_include_hint"] =~ claude_path
    end

    test "a nesting conflict exits non-zero naming both goal ids and writes nothing", %{
      dir: dir
    } do
      parent = goal_file(dir, "parent.goal.toml", "parent", ["pkg/foo"])
      child = goal_file(dir, "child.goal.toml", "child", ["pkg/foo/bar"])
      roadmap = roadmap_file(dir, "nested.roadmap.toml", [{"parent", parent}, {"child", child}])

      {err, code} = run_cli_stderr(["plan", "render", roadmap, "--tree", "--workspace", dir])

      assert code == 1
      assert err =~ "parent"
      assert err =~ "child"
      assert err =~ "pkg/foo"
      refute File.exists?(Path.join(dir, "pkg/foo/AGENTS.md"))
    end

    test "a goal with no [scope] root exits 0 and writes nothing", %{dir: dir} do
      goal = goal_file(dir, "unscoped.goal.toml", "unscoped", [])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"unscoped", goal}])

      {out, code} = run_cli(["plan", "render", roadmap, "--tree", "--workspace", dir])
      assert code == 0
      assert out =~ "nothing to render"
    end

    test "--workspace defaults to the current directory", %{dir: dir} do
      goal = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", goal}])

      previous_cwd = File.cwd!()
      File.cd!(dir)

      try do
        {_out, code} = run_cli(["plan", "render", roadmap, "--tree"])
        assert code == 0
        assert File.exists?(Path.join(dir, "pkg/foo/AGENTS.md"))
      after
        File.cd!(previous_cwd)
      end
    end

    test "an unloadable roadmap is a non-zero load error, not a crash", %{dir: dir} do
      bad = Path.join(dir, "cyclic.roadmap.toml")

      File.write!(bad, """
      [[goals]]
      id = "a"
      path = "a.goal.toml"
      needs = ["b"]

      [[goals]]
      id = "b"
      path = "b.goal.toml"
      needs = ["a"]
      """)

      {_err, code} = run_cli_stderr(["plan", "render", bad, "--tree", "--workspace", dir])
      assert code == 1
    end
  end
end
