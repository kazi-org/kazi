defmodule Kazi.Harness.WalkupTest do
  @moduledoc """
  T72.5 (ADR-0086 decision 6): proves, PER SUPPORTED HARNESS, that a harness
  launched with `cwd` set to a scope root (`pkg/foo`) actually loads the
  `Kazi.Plan.Tree` (T72.4)-rendered node through that harness's OWN
  instruction-file walk-up, and does NOT load a sibling scope's node when
  launched at the sibling root instead.

  ADR-0086's context section names exactly two harnesses with a documented
  walk-up convention: "Claude Code walks up from the working directory
  merging every `CLAUDE.md` it finds; Codex does the same for `AGENTS.md`."
  Decision 6 explicitly defers to "a test in the implementing task" the
  question of whether each harness's walk-up follows the `CLAUDE.md ->
  AGENTS.md` symlink T72.4 creates -- this is that test, scoped to those two
  harnesses (matching the project's own "It drives harnesses (Claude Code,
  Codex)" framing in CLAUDE.md; the other four `Kazi.Harness.Registry`
  profiles have no ADR-0086 walk-up convention documented and are out of
  scope for this task -- a JUDGMENT CALL, flagged in the PR body).

  Neither harness's real CLI is invoked (no network, no auth, no live agent
  loop) -- instead, per the `test/support/stub_*.sh` pattern already
  established for harness boundary tests (e.g. `stub_claude.sh`,
  `stub_harness_argv.sh`), each harness's instruction-file walk-up algorithm
  is reproduced as a REAL, separately-executed shell script that performs a
  REAL filesystem walk-up from a REAL `cwd`, through the REAL symlink T72.4
  creates -- exercising the actual OS-level question this test cares about
  (does a plain file read/`cat` follow the symlink) rather than kazi's own
  application code, which the T72.4 unit tests already cover directly.

  Mechanism per harness, recorded in each test name:
    * **claude** -- walks up merging `CLAUDE.md`. T72.4 creates
      `CLAUDE.md -> AGENTS.md` as a symlink (ADR-0086 decision 6's default),
      so this exercises the SYMLINK mechanism.
    * **codex** -- walks up merging `AGENTS.md` directly. T72.4 always
      writes a real `AGENTS.md` file at the scope root, so this harness
      needs no symlink at all -- the DIRECT mechanism.

  Both stubs use a plain `cat`, which follows symlinks transparently at the
  OS level (standard POSIX `open()` semantics) -- so both mechanisms are
  proven to work with T72.4's implementation exactly as it stands; no fix
  was needed in `Kazi.Plan.Tree` for this task.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal.Roadmap
  alias Kazi.Plan.Tree

  @claude_walkup Path.expand("../../support/stub_walkup_claude.sh", __DIR__)
  @codex_walkup Path.expand("../../support/stub_walkup_codex.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-walkup-#{System.unique_integer([:positive])}")
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

  # Renders two sibling, non-nested scope roots (`pkg/foo`, `pkg/bar`) so each
  # gets its own node carrying its own goal id as the sentinel string --
  # proving not just "the node is found" but "the RIGHT node is found".
  defp render_two_scopes!(dir) do
    foo = goal_file(dir, "foo.goal.toml", "walkup-sentinel-foo", ["pkg/foo/**"])
    bar = goal_file(dir, "bar.goal.toml", "walkup-sentinel-bar", ["pkg/bar/**"])
    roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", foo}, {"bar", bar}])
    {:ok, roadmap} = Roadmap.load(roadmap)
    {:ok, _deliveries} = Tree.render(roadmap, dir)
    :ok
  end

  defp run_walkup(script, cwd) do
    {out, 0} = System.cmd(script, [], cd: cwd, stderr_to_stdout: true)
    out
  end

  describe "claude harness -- CLAUDE.md -> AGENTS.md symlink walk-up" do
    test "reads the scope root's own node and not a sibling scope's node", %{dir: dir} do
      render_two_scopes!(dir)

      foo_dir = Path.join(dir, "pkg/foo")
      bar_dir = Path.join(dir, "pkg/bar")

      at_foo = run_walkup(@claude_walkup, foo_dir)
      assert at_foo =~ "walkup-sentinel-foo"
      refute at_foo =~ "walkup-sentinel-bar"

      at_bar = run_walkup(@claude_walkup, bar_dir)
      assert at_bar =~ "walkup-sentinel-bar"
      refute at_bar =~ "walkup-sentinel-foo"
    end

    test "the CLAUDE.md dirent at the scope root is actually a symlink to AGENTS.md", %{
      dir: dir
    } do
      render_two_scopes!(dir)
      claude_md = Path.join(dir, "pkg/foo/CLAUDE.md")

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(claude_md)
      assert File.read_link(claude_md) == {:ok, "AGENTS.md"}
    end
  end

  describe "codex harness -- direct AGENTS.md walk-up (no symlink needed)" do
    test "reads the scope root's own node and not a sibling scope's node", %{dir: dir} do
      render_two_scopes!(dir)

      foo_dir = Path.join(dir, "pkg/foo")
      bar_dir = Path.join(dir, "pkg/bar")

      at_foo = run_walkup(@codex_walkup, foo_dir)
      assert at_foo =~ "walkup-sentinel-foo"
      refute at_foo =~ "walkup-sentinel-bar"

      at_bar = run_walkup(@codex_walkup, bar_dir)
      assert at_bar =~ "walkup-sentinel-bar"
      refute at_bar =~ "walkup-sentinel-foo"
    end
  end

  describe "a harness with a pre-existing CLAUDE.md (T72.4's include-line fallback)" do
    test "claude's walk-up does NOT see the node through an untouched hand-written CLAUDE.md",
         %{dir: dir} do
      foo_dir = Path.join(dir, "pkg/foo")
      File.mkdir_p!(foo_dir)
      File.write!(Path.join(foo_dir, "CLAUDE.md"), "# hand-written, pre-existing\n")

      foo = goal_file(dir, "foo.goal.toml", "walkup-sentinel-foo", ["pkg/foo/**"])
      roadmap = roadmap_file(dir, "r.roadmap.toml", [{"foo", foo}])
      {:ok, roadmap} = Roadmap.load(roadmap)
      {:ok, [delivery]} = Tree.render(roadmap, dir)

      # T72.4's decision-6 default: a pre-existing CLAUDE.md is left
      # byte-identical, and the delivery record names the include-line hint
      # instead of writing anything.
      assert delivery.symlink == nil
      assert delivery.claude_include_hint =~ "@AGENTS.md"
      assert File.read!(Path.join(foo_dir, "CLAUDE.md")) == "# hand-written, pre-existing\n"

      # claude's walk-up genuinely does not see the rendered node this way --
      # proving the hint is load-bearing, not cosmetic: the operator must
      # act on it (add the include line by hand) for claude's walk-up to
      # ever reach the node.
      refute run_walkup(@claude_walkup, foo_dir) =~ "walkup-sentinel-foo"

      # codex is unaffected either way -- it never reads CLAUDE.md at all,
      # only the AGENTS.md T72.4 always writes regardless of CLAUDE.md state.
      assert run_walkup(@codex_walkup, foo_dir) =~ "walkup-sentinel-foo"
    end
  end
end
