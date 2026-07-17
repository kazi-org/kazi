defmodule Kazi.Goal.RoadmapTest do
  @moduledoc """
  T45.1 (UC-059, ADR-0075): the roadmap artifact — a declarative goal-to-goal DAG.
  Tier 1 exercises the DAG validation (acyclicity, ref resolution, id uniqueness)
  in isolation via `from_map/2` with inline goals — pure, no I/O. Tier 2 loads a
  real roadmap `.toml` from disk and drives `kazi schema roadmap` / `kazi lint`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kazi.CLI
  alias Kazi.Goal.Roadmap

  # A minimal valid inline goal-file map: an id plus one predicate (the loader
  # requires at least one).
  defp goal_map(id) do
    %{
      "id" => id,
      "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
    }
  end

  # An inline roadmap entry whose embedded goal is the barest valid goal-file.
  defp inline(id, needs \\ []) do
    entry = %{"id" => id, "goal" => goal_map("#{id}-goal")}
    if needs == [], do: entry, else: Map.put(entry, "needs", needs)
  end

  defp roadmap(entries), do: %{"goals" => entries}

  describe "from_map/2 — DAG structure" do
    test "a 3-goal roadmap with needs loads and exposes nodes + edges" do
      data = roadmap([inline("a"), inline("b", ["a"]), inline("c", ["b"])])

      assert {:ok, %Roadmap{nodes: nodes, edges: edges}} = Roadmap.from_map(data)

      assert Enum.map(nodes, & &1.id) == ["a", "b", "c"]
      assert MapSet.new(edges, &{&1.from, &1.to}) == MapSet.new([{"a", "b"}, {"b", "c"}])
    end

    test "frontiers expose the topological waves" do
      # a -> {b, c} -> d (diamond)
      data =
        roadmap([
          inline("a"),
          inline("b", ["a"]),
          inline("c", ["a"]),
          inline("d", ["b", "c"])
        ])

      assert {:ok, roadmap} = Roadmap.from_map(data)
      assert Roadmap.frontiers(roadmap) == [["a"], ["b", "c"], ["d"]]
    end

    test "an inline goal inherits the entry id when it omits its own" do
      inline_goal = Map.delete(goal_map("ignored"), "id") |> Map.put("name", "no id here")
      data = %{"goals" => [%{"id" => "only", "goal" => inline_goal}]}

      assert {:ok, %Roadmap{nodes: [node]}} = Roadmap.from_map(data)
      assert node.id == "only"
      assert node.goal.id == "only"
    end
  end

  describe "from_map/2 — cycle detection names the cycle" do
    test "a 3-node cycle error lists every goal id on the cycle" do
      data = roadmap([inline("a", ["c"]), inline("b", ["a"]), inline("c", ["b"])])

      assert {:error, message} = Roadmap.from_map(data)
      assert message =~ "cycle"
      assert message =~ "a"
      assert message =~ "b"
      assert message =~ "c"
      # the chain closes on the entry node
      assert message =~ "->"
    end

    test "a self-loop is a cycle naming the goal" do
      data = roadmap([inline("solo", ["solo"])])

      assert {:error, message} = Roadmap.from_map(data)
      assert message =~ "cycle"
      assert message =~ "solo -> solo"
    end
  end

  describe "from_map/2 — unresolvable refs name the ref" do
    test "a needs entry pointing at an undeclared goal id names that id" do
      data = roadmap([inline("a"), inline("b", ["ghost"])])

      assert {:error, message} = Roadmap.from_map(data)
      assert message =~ "unknown goal id"
      assert message =~ "ghost"
      assert message =~ "b"
    end

    test "an entry missing id is rejected with its position" do
      data = %{"goals" => [%{"goal" => %{"id" => "x"}}]}

      assert {:error, message} = Roadmap.from_map(data)
      assert message =~ "id"
    end

    test "a duplicate goal id is rejected naming the id" do
      data = roadmap([inline("dup"), inline("dup")])

      assert {:error, message} = Roadmap.from_map(data)
      assert message =~ "more than once"
      assert message =~ "dup"
    end

    test "an entry with neither path nor inline goal is rejected" do
      data = %{"goals" => [%{"id" => "empty"}]}

      assert {:error, message} = Roadmap.from_map(data)
      assert message =~ "no goal source"
      assert message =~ "empty"
    end

    test "an entry with BOTH path and inline goal is rejected" do
      data = %{"goals" => [%{"id" => "both", "path" => "x.toml", "goal" => %{"id" => "x"}}]}

      assert {:error, message} = Roadmap.from_map(data)
      assert message =~ "BOTH"
      assert message =~ "both"
    end

    test "an empty [[goals]] array is rejected" do
      assert {:error, message} = Roadmap.from_map(%{"goals" => []})
      assert message =~ "at least one goal"
    end

    test "a missing [[goals]] array is rejected" do
      assert {:error, message} = Roadmap.from_map(%{})
      assert message =~ "[[goals]]"
    end
  end

  describe "load/1 — real files on disk" do
    setup do
      dir = Path.join(System.tmp_dir!(), "kazi-roadmap-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    defp write_goal(dir, filename, id) do
      File.write!(Path.join(dir, filename), """
      id = "#{id}"

      [[predicate]]
      id = "p"
      provider = "custom_script"
      cmd = "true"
      """)
    end

    test "a path-based 3-goal roadmap loads from disk", %{dir: dir} do
      write_goal(dir, "foundation.goal.toml", "foundation")
      write_goal(dir, "api.goal.toml", "api")
      write_goal(dir, "ui.goal.toml", "ui")

      roadmap_toml = """
      [[goals]]
      id = "foundation"
      path = "foundation.goal.toml"

      [[goals]]
      id = "api"
      path = "api.goal.toml"
      needs = ["foundation"]

      [[goals]]
      id = "ui"
      path = "ui.goal.toml"
      needs = ["api"]
      """

      roadmap_path = Path.join(dir, "roadmap.toml")
      File.write!(roadmap_path, roadmap_toml)

      assert {:ok, roadmap} = Roadmap.load(roadmap_path)
      assert Enum.map(roadmap.nodes, & &1.id) == ["foundation", "api", "ui"]
      assert Roadmap.frontiers(roadmap) == [["foundation"], ["api"], ["ui"]]
    end

    test "an unresolvable path ref names the path", %{dir: dir} do
      roadmap_path = Path.join(dir, "broken.toml")

      File.write!(roadmap_path, """
      [[goals]]
      id = "missing"
      path = "does-not-exist.goal.toml"
      """)

      assert {:error, message} = Roadmap.load(roadmap_path)
      assert message =~ "does-not-exist.goal.toml"
      assert message =~ "missing"
    end
  end

  describe "kazi schema roadmap" do
    test "emits the roadmap artifact shape" do
      output = capture_io(fn -> assert CLI.run(["schema", "roadmap"]) == 0 end)

      decoded = Jason.decode!(output)
      assert decoded["artifact"] == "roadmap"
      field_names = Enum.map(decoded["fields"], & &1["name"])
      assert "goals" in field_names
      assert "goals[].id" in field_names
      assert "goals[].needs" in field_names
    end
  end

  describe "kazi lint <roadmap>" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "kazi-roadmap-lint-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "a valid roadmap lints clean (exit 0)", %{dir: dir} do
      path = Path.join(dir, "ok.roadmap.toml")

      File.write!(path, """
      [[goals]]
      id = "a"
      needs = []

        [goals.goal]
        id = "a-goal"

          [[goals.goal.predicate]]
          id = "p"
          provider = "custom_script"
          cmd = "true"

      [[goals]]
      id = "b"
      needs = ["a"]

        [goals.goal]
        id = "b-goal"

          [[goals.goal.predicate]]
          id = "p"
          provider = "custom_script"
          cmd = "true"
      """)

      output = capture_io(fn -> assert CLI.run(["lint", path, "--json"]) == 0 end)
      decoded = Jason.decode!(output)
      assert decoded["kind"] == "roadmap"
      assert decoded["goal_count"] == 2
      assert decoded["edge_count"] == 1
    end

    test "a cyclic roadmap is a lint error naming the cycle (non-zero)", %{dir: dir} do
      path = Path.join(dir, "cyclic.roadmap.toml")

      File.write!(path, """
      [[goals]]
      id = "x"
      needs = ["y"]

        [goals.goal]
        id = "x-goal"

          [[goals.goal.predicate]]
          id = "p"
          provider = "custom_script"
          cmd = "true"

      [[goals]]
      id = "y"
      needs = ["x"]

        [goals.goal]
        id = "y-goal"

          [[goals.goal.predicate]]
          id = "p"
          provider = "custom_script"
          cmd = "true"
      """)

      output = capture_io(fn -> assert CLI.run(["lint", path, "--json"]) == 1 end)
      decoded = Jason.decode!(output)
      assert decoded["error"] =~ "cycle"
      assert decoded["error"] =~ "x"
      assert decoded["error"] =~ "y"
    end
  end
end
