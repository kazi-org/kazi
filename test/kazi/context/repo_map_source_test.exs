defmodule Kazi.Context.RepoMapSourceTest do
  # Tier-2: exercises the real filesystem boundary of the repo-map fallback over a
  # temp fixture repo (no graph present). Hermetic — no network, no graph CLI.
  use ExUnit.Case, async: true

  alias Kazi.Context
  alias Kazi.Context.{RepoMapSource, Survey}
  alias Kazi.PredicateResult

  setup do
    root = Path.join(System.tmp_dir!(), "kazi_repomap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, "deps/ignored"))

    File.write!(Path.join(root, "lib/calc.ex"), """
    defmodule Calc do
      @type t :: integer()
      def add(a, b), do: a + b
      defp helper(x), do: x
    end
    """)

    File.write!(Path.join(root, "lib/util.ex"), "defmodule Util do\n  def noop, do: :ok\nend\n")

    File.write!(Path.join(root, "test/calc_test.exs"), """
    defmodule CalcTest do
      use ExUnit.Case
      test "add", do: assert Calc.add(1, 1) == 2
    end
    """)

    # A dependency file that must be ignored (not orientation material).
    File.write!(Path.join(root, "deps/ignored/dep.ex"), "defmodule Dep do\nend\n")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "falls back to a repo map when no graph is present", %{root: root} do
    refute File.exists?(Path.join(root, RepoMapSource.graph_db_relpath()))

    survey = RepoMapSource.survey(root, ["Calc"], [])

    assert %Survey{origin: :repo_map} = survey
    paths = Enum.map(survey.files, & &1.path)
    assert "lib/calc.ex" in paths
    assert "lib/util.ex" in paths
    refute Enum.any?(paths, &String.contains?(&1, "deps/"))
  end

  test "scans top-level symbol definitions", %{root: root} do
    survey = RepoMapSource.survey(root, [], [])
    names = Enum.map(survey.symbols, & &1.name)

    assert "Calc" in names
    assert "add" in names
    assert "helper" in names
    assert "t" in names
  end

  test "captures the failing test's source", %{root: root} do
    survey = RepoMapSource.survey(root, ["calc_test"], [])
    test_paths = Enum.map(survey.test_sources, & &1.path)

    assert "test/calc_test.exs" in test_paths
    source = Enum.find(survey.test_sources, &(&1.path == "test/calc_test.exs")).source
    assert source =~ "Calc.add(1, 1) == 2"
  end

  test "the end-to-end pack over the fixture repo is deterministic", %{root: root} do
    failing = [{:unit, PredicateResult.fail(%{output: "Calc.add/2 wrong in lib/calc.ex"})}]

    p1 = Context.orientation_pack(failing, root)
    p2 = Context.orientation_pack(failing, root)

    assert Context.render(p1) == Context.render(p2)
    # The evidence-named file ranks first.
    assert hd(p1.files).path == "lib/calc.ex"
  end

  test "prefers the real graph CLI when a graph db is present (injected CLI)", %{root: root} do
    File.mkdir_p!(Path.join(root, ".code-review-graph"))
    File.write!(Path.join(root, RepoMapSource.graph_db_relpath()), "")

    survey = RepoMapSource.survey(root, ["Calc"], graph_cli: __MODULE__.FakeGraphCli)
    assert survey.origin == :graph
    assert Enum.map(survey.files, & &1.path) == ["lib/from_graph.ex"]
  end

  test "degrades to repo map when the graph CLI errors", %{root: root} do
    File.mkdir_p!(Path.join(root, ".code-review-graph"))
    File.write!(Path.join(root, RepoMapSource.graph_db_relpath()), "")

    survey = RepoMapSource.survey(root, ["Calc"], graph_cli: __MODULE__.ErroringGraphCli)
    assert survey.origin == :repo_map
  end

  defmodule FakeGraphCli do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource
    alias Kazi.Context.{FileRef, Survey}

    @impl true
    def survey(_ws, _terms, _opts) do
      {:ok, Survey.new(:graph, files: [FileRef.new("lib/from_graph.ex")])}
    end
  end

  defmodule ErroringGraphCli do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_ws, _terms, _opts), do: {:error, :boom}
  end
end
