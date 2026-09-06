defmodule Kazi.Plan.TreeTest do
  @moduledoc """
  T72.4 (ADR-0086 decision 4): `Kazi.Plan.Tree`, the interactive `--tree`
  delivery adapter. Drives real fixture git repos (`git init`, real files,
  real symlinks) — no stubbing of the filesystem or git — against the
  acceptance criteria in docs/plans/E72.md:

    * a fresh fixture repo: `--tree` writes `<root>/AGENTS.md` + the
      `CLAUDE.md` symlink, `git status` stays clean (the written paths are
      excluded via `.git/info/exclude`, never `.gitignore`);
    * a re-run is idempotent (identical bytes, no duplicate exclude lines,
      the symlink untouched);
    * a pre-existing HAND-WRITTEN `AGENTS.md` (missing the generated banner)
      makes the whole call refuse, naming the path, writing NOTHING —
      including a different, otherwise-valid root in the same call;
    * a pre-existing `CLAUDE.md` is byte-identical after the run, and the
      delivery record names the `@AGENTS.md` include instruction;
    * a nesting conflict refuses before any observe pass or write;
    * an observe-pass failure (an unresolvable predicate provider) refuses
      the same way.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal.Roadmap
  alias Kazi.Goal.Roadmap.Render, as: RoadmapRender
  alias Kazi.Plan.Tree

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-plan-tree-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git_init!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # --- fixture helpers ---------------------------------------------------

  defp git_init!(dir) do
    {_out, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    :ok
  end

  # Commits every currently-untracked/-modified fixture file, so a later "git
  # status stays clean" assertion is meaningful (only what THIS RUN wrote, not
  # the fixture goal-files/roadmap themselves, can show up as untracked).
  defp commit_all!(dir) do
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)

    {_out, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=kazi-test@example.com",
          "-c",
          "user.name=kazi test",
          "commit",
          "-q",
          "-m",
          "fixture"
        ],
        cd: dir
      )

    :ok
  end

  defp goal_file(dir, filename, id, scope_write_paths, predicate_lines \\ default_predicate()) do
    path = Path.join(dir, filename)

    File.write!(path, """
    id = "#{id}"

    [scope]
    write_paths = #{inspect(scope_write_paths)}

    #{predicate_lines}
    """)

    path
  end

  defp default_predicate do
    """
    [[predicate]]
    id = "p"
    provider = "custom_script"
    cmd = "true"
    """
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

  defp load!(roadmap_path) do
    {:ok, roadmap} = Roadmap.load(roadmap_path)
    roadmap
  end

  # `-uall` expands an entirely-untracked directory into its individual file
  # entries (plain `--porcelain` collapses `pkg/foo/AGENTS.md` etc. down to a
  # single `?? pkg/` line), so an assertion can name the exact path.
  defp git_status_porcelain(dir) do
    {out, 0} = System.cmd("git", ["status", "--porcelain", "-uall"], cd: dir)
    out
  end

  # `git init` seeds `.git/info/exclude` with its own commented-out template
  # (`# git ls-files ...`, `# *.[oa]`, ...) -- filter those out so an
  # assertion only sees the lines THIS module actually appended.
  defp exclude_lines(dir) do
    case File.read(Path.join([dir, ".git", "info", "exclude"])) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))

      {:error, :enoent} ->
        []
    end
  end

  # ===========================================================================
  # targets/1 -- one target per non-empty scope root
  # ===========================================================================

  describe "targets/1" do
    test "one target per non-empty root; an unscoped goal contributes nothing", %{dir: dir} do
      scoped = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      unscoped = goal_file(dir, "bar.goal.toml", "bar", [])

      roadmap =
        roadmap_file(dir, "r.roadmap.toml", [{"foo", scoped}, {"bar", unscoped}]) |> load!()

      assert [%{goal: goal, declared_root: "pkg/foo/**", dir: "pkg/foo"}] = Tree.targets(roadmap)
      assert goal.id == "foo"
    end

    test "a glob root strips its /** suffix; a plain path passes through", %{dir: dir} do
      glob = goal_file(dir, "a.goal.toml", "a", ["pkg/a/**"])
      plain = goal_file(dir, "b.goal.toml", "b", ["pkg/b"])

      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"a", glob}, {"b", plain}]) |> load!()

      dirs = Tree.targets(roadmap) |> Enum.map(& &1.dir) |> Enum.sort()
      assert dirs == ["pkg/a", "pkg/b"]
    end

    test "a FILE-shaped root (e.g. ios/Auth.plist) resolves to its PARENT directory", %{
      dir: dir
    } do
      goal = goal_file(dir, "a.goal.toml", "a", ["ios/Auth.plist"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"a", goal}]) |> load!()

      assert [%{dir: "ios"}] = Tree.targets(roadmap)
    end

    test "a FILE-shaped root at the workspace root (e.g. fixed.txt, mix.exs) is SKIPPED entirely -- never mkdir_p!'d over",
         %{dir: dir} do
      goal = goal_file(dir, "a.goal.toml", "a", ["fixed.txt"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"a", goal}]) |> load!()

      assert Tree.targets(roadmap) == []
      assert {:ok, []} = Tree.render(roadmap, dir)
      refute File.exists?(Path.join(dir, "fixed.txt"))
    end
  end

  # ===========================================================================
  # render/3 -- the happy path: fresh write, clean git status
  # ===========================================================================

  describe "render/3 — fresh fixture repo" do
    test "writes <root>/AGENTS.md + CLAUDE.md symlink; git status stays clean", %{dir: dir} do
      goal = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap_path = roadmap_file(dir, "r.roadmap.toml", [{"foo", goal}])
      commit_all!(dir)
      roadmap = load!(roadmap_path)

      assert {:ok, [delivery]} = Tree.render(roadmap, dir)

      agents_path = Path.join(dir, "pkg/foo/AGENTS.md")
      claude_path = Path.join(dir, "pkg/foo/CLAUDE.md")

      assert delivery.goal_id == "foo"
      assert delivery.agents_path == agents_path
      assert delivery.written == true
      assert delivery.symlink == :created
      assert delivery.claude_include_hint == nil

      content = File.read!(agents_path)
      assert content =~ RoadmapRender.banner_headline()
      assert content =~ "foo"

      assert File.lstat!(claude_path).type == :symlink
      assert File.read_link!(claude_path) == "AGENTS.md"

      # .git/info/exclude carries both paths, relative to the workspace root
      # (never .gitignore, a tracked file this run must never touch).
      assert exclude_lines(dir) == ["pkg/foo/AGENTS.md", "pkg/foo/CLAUDE.md"]
      refute File.exists?(Path.join(dir, ".gitignore"))

      assert git_status_porcelain(dir) == ""
    end

    test "a goal with no declared scope root renders nothing", %{dir: dir} do
      goal = goal_file(dir, "bar.goal.toml", "bar", [])
      roadmap_path = roadmap_file(dir, "r.roadmap.toml", [{"bar", goal}])
      commit_all!(dir)
      roadmap = load!(roadmap_path)

      assert {:ok, []} = Tree.render(roadmap, dir)
      assert git_status_porcelain(dir) == ""
    end
  end

  # ===========================================================================
  # render/3 -- idempotent re-run
  # ===========================================================================

  describe "render/3 — re-run is idempotent" do
    test "identical bytes, no duplicate exclude lines, symlink untouched", %{dir: dir} do
      goal = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap_path = roadmap_file(dir, "r.roadmap.toml", [{"foo", goal}])
      commit_all!(dir)
      roadmap = load!(roadmap_path)

      assert {:ok, [_first]} = Tree.render(roadmap, dir)
      agents_path = Path.join(dir, "pkg/foo/AGENTS.md")
      claude_path = Path.join(dir, "pkg/foo/CLAUDE.md")
      first_bytes = File.read!(agents_path)
      first_link = File.read_link!(claude_path)

      assert {:ok, [second]} = Tree.render(roadmap, dir)

      assert File.read!(agents_path) == first_bytes
      assert File.read_link!(claude_path) == first_link
      assert second.symlink == :already_present
      assert exclude_lines(dir) == ["pkg/foo/AGENTS.md", "pkg/foo/CLAUDE.md"]
      assert git_status_porcelain(dir) == ""
    end
  end

  # ===========================================================================
  # render/3 -- a hand-written AGENTS.md refuses the WHOLE call
  # ===========================================================================

  describe "render/3 — a hand-written AGENTS.md refuses, writing nothing" do
    test "names the exact path; a second, valid root in the same call is also untouched", %{
      dir: dir
    } do
      foo = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      bar = goal_file(dir, "bar.goal.toml", "bar", ["pkg/bar/**"])
      roadmap_path = roadmap_file(dir, "r.roadmap.toml", [{"foo", foo}, {"bar", bar}])
      commit_all!(dir)
      roadmap = load!(roadmap_path)

      hand_written_path = Path.join(dir, "pkg/foo/AGENTS.md")
      File.mkdir_p!(Path.dirname(hand_written_path))
      File.write!(hand_written_path, "# hand-authored notes, not generated by kazi\n")

      assert {:error, {:hand_written, [^hand_written_path]}} = Tree.render(roadmap, dir)

      # The hand-written file is untouched...
      assert File.read!(hand_written_path) == "# hand-authored notes, not generated by kazi\n"
      # ...and the OTHER, perfectly valid root got NOTHING written either.
      refute File.exists?(Path.join(dir, "pkg/bar/AGENTS.md"))
      # Nothing was excluded either (the call aborted before any exclude
      # append), so the untouched hand-written file still shows as untracked.
      assert git_status_porcelain(dir) =~ "pkg/foo/AGENTS.md"
    end

    test "a STALE generated AGENTS.md (carries the banner) is overwritten, not refused", %{
      dir: dir
    } do
      foo = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", foo}]) |> load!()

      stale_path = Path.join(dir, "pkg/foo/AGENTS.md")
      File.mkdir_p!(Path.dirname(stale_path))
      File.write!(stale_path, RoadmapRender.banner() <> "\nstale content from a prior render\n")

      assert {:ok, [delivery]} = Tree.render(roadmap, dir)
      assert delivery.written == true
      refute File.read!(stale_path) =~ "stale content from a prior render"
    end
  end

  # ===========================================================================
  # render/3 -- a pre-existing CLAUDE.md is left alone
  # ===========================================================================

  describe "render/3 — a pre-existing CLAUDE.md" do
    test "is byte-identical after the run; the delivery names the include instruction", %{
      dir: dir
    } do
      goal = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", goal}]) |> load!()

      claude_path = Path.join(dir, "pkg/foo/CLAUDE.md")
      File.mkdir_p!(Path.dirname(claude_path))
      hand_written_claude = "# team conventions for pkg/foo\n"
      File.write!(claude_path, hand_written_claude)

      assert {:ok, [delivery]} = Tree.render(roadmap, dir)

      assert File.read!(claude_path) == hand_written_claude
      assert delivery.symlink == nil
      assert delivery.claude_include_hint =~ "@AGENTS.md"
      assert delivery.claude_include_hint =~ claude_path

      # We must never have added the operator's own CLAUDE.md to the local
      # exclude file -- it isn't ours to hide from git status.
      refute "pkg/foo/CLAUDE.md" in exclude_lines(dir)
    end
  end

  # ===========================================================================
  # render/3 -- nesting conflict refuses before any write
  # ===========================================================================

  describe "render/3 — a nesting conflict refuses upfront" do
    test "no observe pass, no write, for either goal", %{dir: dir} do
      parent = goal_file(dir, "parent.goal.toml", "parent", ["pkg/foo"])
      child = goal_file(dir, "child.goal.toml", "child", ["pkg/foo/bar"])

      roadmap_path = roadmap_file(dir, "r.roadmap.toml", [{"parent", parent}, {"child", child}])
      commit_all!(dir)
      roadmap = load!(roadmap_path)

      assert {:error, {:nesting_conflict, [conflict]}} = Tree.render(roadmap, dir)
      assert Enum.sort([conflict.a, conflict.b]) == ["child", "parent"]
      assert conflict.root == "pkg/foo"

      refute File.exists?(Path.join(dir, "pkg/foo/AGENTS.md"))
      assert git_status_porcelain(dir) == ""
    end
  end

  # ===========================================================================
  # render/3 -- an observe failure refuses, writing nothing
  # ===========================================================================

  describe "render/3 — an observe-pass failure refuses" do
    test "an unresolvable predicate provider (injected empty provider table) aborts before any write",
         %{dir: dir} do
      goal = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", goal}]) |> load!()

      # `providers: %{}` forwards through Runtime.check/2's own injection seam
      # (the same one `--check` tests use) so `custom_script` cannot resolve,
      # WITHOUT fighting the loader's own known-provider-name validation.
      assert {:error, {:observe_failed, "foo", _reason}} =
               Tree.render(roadmap, dir, providers: %{})

      refute File.exists?(Path.join(dir, "pkg/foo/AGENTS.md"))
    end
  end

  # ===========================================================================
  # render_goal/3 -- the kazi apply single-goal call site
  # ===========================================================================

  describe "render_goal/3 — single goal, no nesting check" do
    test "renders the same node the roadmap path would, with no sibling to conflict with", %{
      dir: dir
    } do
      path = goal_file(dir, "foo.goal.toml", "foo", ["pkg/foo/**"])
      {:ok, goal} = Kazi.Goal.Loader.load(path)

      assert {:ok, [delivery]} = Tree.render_goal(goal, dir)
      assert delivery.goal_id == "foo"
      assert File.exists?(Path.join(dir, "pkg/foo/AGENTS.md"))
    end

    test "a goal with no declared scope root is a no-op", %{dir: dir} do
      path = goal_file(dir, "bar.goal.toml", "bar", [])
      {:ok, goal} = Kazi.Goal.Loader.load(path)

      assert {:ok, []} = Tree.render_goal(goal, dir)
    end
  end
end
