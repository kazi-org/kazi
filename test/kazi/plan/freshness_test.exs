defmodule Kazi.Plan.FreshnessTest do
  @moduledoc """
  T72.6 (ADR-0086 decision 5): unit coverage for `Kazi.Plan.Freshness` —
  `deliveries/2` renders + delivers a goal's scope-root node(s) into a real
  workspace (`Kazi.Plan.Tree.render_goal/3`), `arm/1` content-hashes the
  result into a t0 manifest, `verify/1` re-hashes and returns the first
  drift, and `forbidden_paths/2` names every path this run's node(s)
  occupy. Mirrors `Kazi.SealTest`'s (ADR-0080) shape for the same reason:
  the acceptance/loop-level red->green fixture
  (`test/kazi/rendered_node_drift_test.exs`) pins the LOOP behavior; this
  file pins the module's own contract in isolation, against real fixture
  git repos the way `test/kazi/plan/tree_test.exs` does.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal.Loader
  alias Kazi.Plan.Freshness

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-freshness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_out, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp scoped_goal!(dir, root \\ "pkg/foo/**") do
    path = Path.join(dir, "g.goal.toml")

    File.write!(path, """
    id = "g"

    [scope]
    write_paths = #{inspect([root])}

    [[predicate]]
    id = "p"
    provider = "custom_script"
    cmd = "true"
    """)

    {:ok, goal} = Loader.load(path)
    goal
  end

  defp unscoped_goal! do
    {:ok, goal} =
      Loader.from_map(%{
        "id" => "g",
        "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
      })

    goal
  end

  describe "deliveries/2 + arm/1" do
    test "renders the scope root's node and hashes the delivered AGENTS.md path", %{dir: dir} do
      goal = scoped_goal!(dir)
      deliveries = Freshness.deliveries(goal, dir)

      assert [%{agents_path: agents_path}] = deliveries
      assert agents_path == Path.join([dir, "pkg", "foo", "AGENTS.md"])
      assert File.exists?(agents_path)

      manifest = Freshness.arm(deliveries)
      assert Map.has_key?(manifest, agents_path)
      assert {:ok, bytes} = File.read(agents_path)
      assert manifest[agents_path] == :crypto.hash(:sha256, bytes)
    end

    test "an unscoped goal delivers/arms nothing" do
      assert Freshness.deliveries(unscoped_goal!(), "/nonexistent") == []
      assert Freshness.arm([]) == %{}
    end
  end

  describe "verify/1" do
    test "an untampered manifest verifies :ok", %{dir: dir} do
      goal = scoped_goal!(dir)
      manifest = goal |> Freshness.deliveries(dir) |> Freshness.arm()
      assert Freshness.verify(manifest) == :ok
    end

    test "a hand-edited node is detected as :modified, naming the path", %{dir: dir} do
      goal = scoped_goal!(dir)
      [%{agents_path: agents_path}] = deliveries = Freshness.deliveries(goal, dir)
      manifest = Freshness.arm(deliveries)

      File.write!(agents_path, "# hand-edited\n")

      assert Freshness.verify(manifest) == {:drift, %{path: agents_path, change: :modified}}
    end

    test "a removed node is detected as :removed", %{dir: dir} do
      goal = scoped_goal!(dir)
      [%{agents_path: agents_path}] = deliveries = Freshness.deliveries(goal, dir)
      manifest = Freshness.arm(deliveries)

      File.rm!(agents_path)

      assert Freshness.verify(manifest) == {:drift, %{path: agents_path, change: :removed}}
    end

    test "an empty manifest is always :ok" do
      assert Freshness.verify(%{}) == :ok
    end
  end

  describe "forbidden_paths/2" do
    test "names the delivered AGENTS.md and the CLAUDE.md symlink THIS run created", %{dir: dir} do
      goal = scoped_goal!(dir)
      deliveries = Freshness.deliveries(goal, dir)

      assert Freshness.forbidden_paths(deliveries, dir) |> Enum.sort() ==
               Enum.sort(["pkg/foo/AGENTS.md", "pkg/foo/CLAUDE.md"])
    end

    test "does not re-claim a CLAUDE.md this run did not create", %{dir: dir} do
      goal = scoped_goal!(dir)
      File.mkdir_p!(Path.join(dir, "pkg/foo"))
      File.write!(Path.join(dir, "pkg/foo/CLAUDE.md"), "hand-written\n")

      deliveries = Freshness.deliveries(goal, dir)

      assert Freshness.forbidden_paths(deliveries, dir) == ["pkg/foo/AGENTS.md"]
    end

    test "an unscoped goal forbids nothing" do
      assert Freshness.forbidden_paths([], "/nonexistent") == []
    end
  end
end
