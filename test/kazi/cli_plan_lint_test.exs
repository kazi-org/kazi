defmodule Kazi.CLIPlanLintTest do
  @moduledoc """
  T72.2 (ADR-0086 decision 2): `kazi plan lint <roadmap>` — the CROSS-GOAL
  scope-nesting refusal. This is a DIFFERENT concern from the existing
  single-goal-scoped, purely-advisory `kazi lint <goal-file>`
  (`Kazi.CLILintTest`) and from `kazi lint <roadmap>`'s DAG-validity check
  (`Kazi.Goal.RoadmapTest`): `plan lint` loads a roadmap, and for every pair of
  member goals compares `Kazi.Scope.roots/1` (`Kazi.Scope.nesting_conflicts/1`),
  REFUSING — non-zero exit — when two roots nest inside or exactly equal one
  another, naming both (roadmap-declared) goal ids and the shared root. A
  disjoint roadmap exits 0.

  Tier 1 pins the argv boundary. Tier 2 drives the real CLI exec core
  (`Kazi.CLI.run/2`) against roadmap + goal-file fixtures written to a tmp dir
  (cleaned up `on_exit`), mirroring `Kazi.CLILintTest`'s fixture style.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-plan-lint-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # A minimal goal-file declaring a `[scope] paths` root and one predicate (the
  # loader requires at least one).
  defp goal_file(dir, filename, id, scope_paths) do
    path = Path.join(dir, filename)

    File.write!(path, """
    id = "#{id}"

    [scope]
    paths = #{inspect(scope_paths)}

    [[predicate]]
    id = "p"
    provider = "custom_script"
    cmd = "true"
    """)

    path
  end

  # A roadmap `.toml` whose `[[goals]]` entries reference goal-files by `path`
  # (resolved relative to the roadmap's own directory, so a bare basename works
  # since every fixture file lives in the same tmp dir).
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

  # ===========================================================================
  # Tier 1 — argv parsing
  # ===========================================================================

  describe "parse/1 — plan lint" do
    test "parses `plan lint <roadmap>`, defaulting json to false" do
      assert {:plan_lint, "r.toml", opts} = Kazi.CLI.parse(["plan", "lint", "r.toml"])
      assert opts[:json] == false
    end

    test "carries the --json flag" do
      assert {:plan_lint, "r.toml", opts} = Kazi.CLI.parse(["plan", "lint", "r.toml", "--json"])
      assert opts[:json] == true
    end

    test "requires the <roadmap-file> positional" do
      assert {:error, message} = Kazi.CLI.parse(["plan", "lint"])
      assert message =~ "requires a <roadmap-file>"
    end

    test "rejects extra positionals" do
      assert {:error, message} = Kazi.CLI.parse(["plan", "lint", "r.toml", "extra"])
      assert message =~ "unexpected argument"
    end
  end

  # ===========================================================================
  # Tier 2 — a nested root pair REFUSES (non-zero), naming both ids + the root
  # ===========================================================================

  describe "run/2 — nested roots refuse (exit 1), naming both goal ids and the shared root" do
    test "human surface names both roadmap-declared ids and the ancestor root", %{dir: dir} do
      parent = goal_file(dir, "parent.goal.toml", "parent-goal", ["pkg/foo"])
      child = goal_file(dir, "child.goal.toml", "child-goal", ["pkg/foo/bar"])

      roadmap =
        roadmap_file(dir, "nested.roadmap.toml", [{"parent", parent}, {"child", child}])

      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["plan", "lint", roadmap]) == 1
        end)

      assert out =~ "error:"
      assert out =~ "parent"
      assert out =~ "child"
      assert out =~ "pkg/foo"
    end

    test "--json names both ids, the shared root, and reason nesting_conflict (exit 1)", %{
      dir: dir
    } do
      parent = goal_file(dir, "parent.goal.toml", "parent-goal", ["pkg/foo"])
      child = goal_file(dir, "child.goal.toml", "child-goal", ["pkg/foo/bar"])

      roadmap =
        roadmap_file(dir, "nested.roadmap.toml", [{"parent", parent}, {"child", child}])

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "lint", roadmap, "--json"]) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "nesting_conflict"
      assert [conflict] = payload["conflicts"]
      assert Enum.sort([conflict["a"], conflict["b"]]) == ["child", "parent"]
      assert conflict["root"] == "pkg/foo"
    end
  end

  # ===========================================================================
  # Tier 2 — equal roots ALSO refuse (equal counts as "share a root")
  # ===========================================================================

  describe "run/2 — two goals with the exact same root also refuse" do
    test "--json reports the shared root and both ids (exit 1)", %{dir: dir} do
      one = goal_file(dir, "one.goal.toml", "goal-one", ["pkg/foo"])
      two = goal_file(dir, "two.goal.toml", "goal-two", ["pkg/foo"])

      roadmap = roadmap_file(dir, "equal.roadmap.toml", [{"one", one}, {"two", two}])

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "lint", roadmap, "--json"]) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert [conflict] = payload["conflicts"]
      assert Enum.sort([conflict["a"], conflict["b"]]) == ["one", "two"]
      assert conflict["root"] == "pkg/foo"
    end
  end

  # ===========================================================================
  # Tier 2 — disjoint roots PASS (exit 0)
  # ===========================================================================

  describe "run/2 — disjoint roots pass (exit 0)" do
    test "human surface reports a clean lint", %{dir: dir} do
      a = goal_file(dir, "a.goal.toml", "goal-a", ["pkg/foo"])
      b = goal_file(dir, "b.goal.toml", "goal-b", ["pkg/bar"])

      roadmap = roadmap_file(dir, "disjoint.roadmap.toml", [{"a", a}, {"b", b}])

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "lint", roadmap]) == 0
        end)

      assert out =~ "no nesting scope-root conflicts"
      refute out =~ "error:"
    end

    test "--json reports an empty conflicts list (exit 0)", %{dir: dir} do
      a = goal_file(dir, "a.goal.toml", "goal-a", ["pkg/foo"])
      b = goal_file(dir, "b.goal.toml", "goal-b", ["pkg/bar"])

      roadmap = roadmap_file(dir, "disjoint.roadmap.toml", [{"a", a}, {"b", b}])

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "lint", roadmap, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["conflicts"] == []
      assert payload["goal_count"] == 2
    end
  end

  # ===========================================================================
  # Tier 2 — an invalid roadmap is a load error (non-zero), not a nesting finding
  # ===========================================================================

  describe "run/2 — a broken/missing roadmap is a load error, distinct from a nesting finding" do
    test "a missing roadmap file is a clean load error on stderr (exit 1)" do
      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["plan", "lint", "no-such-roadmap.toml"]) == 1
        end)

      assert out =~ "error:"
      assert out =~ "roadmap"
    end

    test "a missing roadmap file under --json is a JSON error envelope (exit 1)" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "lint", "no-such-roadmap.toml", "--json"]) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["error"] =~ "roadmap"
    end
  end
end
