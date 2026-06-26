defmodule Kazi.PartitionTest do
  @moduledoc """
  T3.2a acceptance (UC-014): blast-radius partitioning via the T4.2 graph-source
  seam. Every case is hermetic — it injects `Kazi.Context.StaticGraphSource`, so
  there is no real code-review-graph binary, no MCP, and no network.

  The static double returns the **same** survey for every goal, so to give each
  goal its own blast radius the tests select the source per goal via the `:terms`
  -> survey indirection: each goal carries a distinct source built for it. (The
  `partition/2` API takes one source for the run, so overlap is modelled by what
  paths the shared source surfaces; the disjoint cases use a source whose survey
  varies by the goal's evidence terms.)
  """
  use ExUnit.Case, async: true

  alias Kazi.Context.{Survey, FileRef, Symbol}
  alias Kazi.Context.StaticGraphSource
  alias Kazi.Partition

  doctest Kazi.Partition

  # A source double whose survey depends on the goal's evidence terms, so two
  # goals in one run can have overlapping or disjoint radii. `mapping` is
  # `term -> [file paths]`; the survey is the union over the goal's terms.
  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, terms, opts) do
      mapping = Keyword.fetch!(opts, :mapping)

      files =
        terms
        |> Enum.flat_map(fn term -> Map.get(mapping, term, []) end)
        |> Enum.uniq()
        |> Enum.map(&FileRef.new/1)

      Survey.new(:graph, files: files)
    end

    def new(mapping), do: {__MODULE__, mapping: mapping}
  end

  describe "partition/2 — overlapping vs disjoint (UC-014 acceptance)" do
    test "two goals with OVERLAPPING blast radii return ONE merged partition" do
      # g1 touches a.ex + shared.ex; g2 touches shared.ex + b.ex -> they overlap
      # on shared.ex, so a single partition.
      source =
        TermSource.new(%{
          "g1-terms" => ["lib/a.ex", "lib/shared.ex"],
          "g2-terms" => ["lib/shared.ex", "lib/b.ex"]
        })

      goals = [{"g1", ["g1-terms"]}, {"g2", ["g2-terms"]}]

      assert [partition] = Partition.partition(goals, "/ws", graph_source: source)
      assert partition.goal_ids == ["g1", "g2"]
      assert partition.blast_radius == ["lib/a.ex", "lib/b.ex", "lib/shared.ex"]
    end

    test "two goals with DISJOINT blast radii return TWO partitions" do
      source =
        TermSource.new(%{
          "g1-terms" => ["lib/a.ex"],
          "g2-terms" => ["lib/b.ex"]
        })

      goals = [{"g1", ["g1-terms"]}, {"g2", ["g2-terms"]}]

      assert [p1, p2] = Partition.partition(goals, "/ws", graph_source: source)
      assert p1.goal_ids == ["g1"]
      assert p1.blast_radius == ["lib/a.ex"]
      assert p2.goal_ids == ["g2"]
      assert p2.blast_radius == ["lib/b.ex"]
      # Disjoint partitions derive distinct keys -> distinct leases (T3.2b).
      assert p1.key != p2.key
    end
  end

  describe "partition/2 — transitive closure" do
    test "A∩B and B∩C merge A, B, C even when A∩C is empty" do
      source =
        TermSource.new(%{
          "a" => ["lib/a.ex", "lib/ab.ex"],
          "b" => ["lib/ab.ex", "lib/bc.ex"],
          "c" => ["lib/bc.ex", "lib/c.ex"]
        })

      goals = [{"gA", ["a"]}, {"gB", ["b"]}, {"gC", ["c"]}]

      assert [partition] = Partition.partition(goals, "/ws", graph_source: source)
      assert partition.goal_ids == ["gA", "gB", "gC"]

      assert partition.blast_radius ==
               ["lib/a.ex", "lib/ab.ex", "lib/bc.ex", "lib/c.ex"]
    end

    test "a third disjoint goal stays separate from a merged pair" do
      source =
        TermSource.new(%{
          "a" => ["lib/a.ex", "lib/shared.ex"],
          "b" => ["lib/shared.ex"],
          "c" => ["lib/far.ex"]
        })

      goals = [{"gA", ["a"]}, {"gB", ["b"]}, {"gC", ["c"]}]

      assert [merged, lone] = Partition.partition(goals, "/ws", graph_source: source)
      assert merged.goal_ids == ["gA", "gB"]
      assert lone.goal_ids == ["gC"]
    end
  end

  describe "partition/2 — blast radius from files, symbols, and test sources" do
    test "files, symbol-defining files, and test sources all count toward the radius" do
      # A single static survey carrying one of each collection; the radius is the
      # union of their paths, so overlap is detected on any of the three.
      survey =
        Survey.new(:graph,
          files: [FileRef.new("lib/a.ex")],
          symbols: [Symbol.new("f/1", "lib/b.ex")],
          test_sources: [FileRef.new("test/c_test.exs", source: "...")]
        )

      source = StaticGraphSource.new(survey: survey)

      # Both goals see the same survey -> they overlap on every path -> one merged
      # partition whose radius spans files + symbol files + test sources.
      goals = [{"g1", ["x"]}, {"g2", ["y"]}]

      assert [partition] = Partition.partition(goals, "/ws", graph_source: source)
      assert partition.goal_ids == ["g1", "g2"]
      assert partition.blast_radius == ["lib/a.ex", "lib/b.ex", "test/c_test.exs"]
    end
  end

  describe "partition/2 — determinism (ADR-0006)" do
    test "same inputs yield byte-identical partitions across two calls" do
      source =
        TermSource.new(%{
          "a" => ["lib/a.ex", "lib/shared.ex"],
          "b" => ["lib/shared.ex"],
          "c" => ["lib/c.ex"]
        })

      goals = [{"gC", ["c"]}, {"gA", ["a"]}, {"gB", ["b"]}]

      run1 = Partition.partition(goals, "/ws", graph_source: source)
      run2 = Partition.partition(goals, "/ws", graph_source: source)

      assert run1 == run2
      # Order is stable regardless of input order: the merged {gA,gB} sorts before
      # the lone {gC}.
      assert Enum.map(run1, & &1.goal_ids) == [["gA", "gB"], ["gC"]]
    end

    test "input goal order does not change the result" do
      source =
        TermSource.new(%{
          "a" => ["lib/a.ex"],
          "b" => ["lib/b.ex"]
        })

      forward = Partition.partition([{"g1", ["a"]}, {"g2", ["b"]}], "/ws", graph_source: source)
      reverse = Partition.partition([{"g2", ["b"]}, {"g1", ["a"]}], "/ws", graph_source: source)

      assert forward == reverse
    end
  end

  describe "partition/2 — empty blast radius" do
    test "goals the source finds nothing for become distinct singleton partitions" do
      source = TermSource.new(%{})
      goals = [{"g1", ["nope"]}, {"g2", ["also-nope"]}]

      assert [p1, p2] = Partition.partition(goals, "/ws", graph_source: source)
      assert p1.goal_ids == ["g1"]
      assert p1.blast_radius == []
      assert p2.goal_ids == ["g2"]
      assert p2.blast_radius == []
      # Empty radii key off the goal id, so distinct goals get distinct keys.
      assert p1.key != p2.key
    end
  end

  # T21.12 regression: a `:repo_map` survey is BROAD by design — the repo-map
  # fallback returns the WHOLE workspace tree regardless of the evidence terms
  # (it is ranked downstream by Kazi.Context, not filtered). Before the fix the
  # partitioner took that whole-tree survey as each goal's blast radius, so two
  # GENUINELY DISJOINT goals overlapped on the entire repo and COLLAPSED into ONE
  # partition — no spatial concurrency. The fix SCOPES a repo-map survey to the
  # paths relevant to each goal's terms; graph/static surveys (already term-scoped)
  # are untouched (covered by the cases above).
  defmodule WholeTreeRepoMap do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    # Returns the SAME whole-tree survey for ANY terms, with `origin: :repo_map`,
    # exactly like the real repo-map fallback over a populated workspace.
    @impl true
    def survey(_workspace, _terms, opts) do
      paths = Keyword.fetch!(opts, :paths)
      Survey.new(:repo_map, files: Enum.map(paths, &FileRef.new/1))
    end

    def new(paths), do: {__MODULE__, paths: paths}
  end

  describe "partition/2 — repo-map survey is term-scoped (T21.12)" do
    test "disjoint terms over a whole-tree repo-map survey yield SEPARATE partitions" do
      # The survey returns the whole tree for every goal; scoping by terms makes
      # `health` match `health.go` and `result-contract` match nothing here, so the
      # two land in distinct partitions instead of collapsing into one.
      source = WholeTreeRepoMap.new(["health.go", "widget.go", "stream.go"])

      goals = [{"health", ["health"]}, {"result-contract", ["result-contract"]}]

      assert [p1, p2] = Partition.partition(goals, "/ws", graph_source: source)
      assert p1.goal_ids == ["health"]
      assert p1.blast_radius == ["health.go"]
      assert p2.goal_ids == ["result-contract"]
      # No tree path mentions "result-contract" -> empty radius -> own singleton.
      assert p2.blast_radius == []
      assert p1.key != p2.key
    end

    test "terms that match the SAME repo-map paths still MERGE into one partition" do
      # Both goals' terms hit `widget.go`, so the scoped radii overlap and they
      # correctly serialize on one partition (the overlap case is preserved).
      source = WholeTreeRepoMap.new(["widget.go", "health.go"])

      goals = [{"g1", ["widget"]}, {"g2", ["widget"]}]

      assert [partition] = Partition.partition(goals, "/ws", graph_source: source)
      assert partition.goal_ids == ["g1", "g2"]
      assert partition.blast_radius == ["widget.go"]
    end
  end

  describe "partition/2 — input shapes" do
    test "accepts a %{id:, terms:} map" do
      source = TermSource.new(%{"a" => ["lib/a.ex"]})
      goals = [%{id: "g1", terms: ["a"]}]

      assert [p] = Partition.partition(goals, "/ws", graph_source: source)
      assert p.goal_ids == ["g1"]
      assert p.blast_radius == ["lib/a.ex"]
    end

    test "accepts a Kazi.Goal struct (terms from metadata.partition_terms, else empty)" do
      source = TermSource.new(%{"a" => ["lib/a.ex"]})

      with_terms = Kazi.Goal.new("g1", metadata: %{partition_terms: ["a"]})
      without_terms = Kazi.Goal.new("g2")

      assert [p1, p2] =
               Partition.partition([with_terms, without_terms], "/ws", graph_source: source)

      assert p1.goal_ids == ["g1"]
      assert p1.blast_radius == ["lib/a.ex"]
      assert p2.goal_ids == ["g2"]
      assert p2.blast_radius == []
    end
  end

  describe "partition_key/2" do
    test "is stable and content-addressed by the sorted radius" do
      assert Partition.partition_key(["g1"], ["lib/a.ex", "lib/b.ex"]) ==
               Partition.partition_key(["g1"], ["lib/b.ex", "lib/a.ex"])

      refute Partition.partition_key(["g1"], ["lib/a.ex"]) ==
               Partition.partition_key(["g1"], ["lib/b.ex"])
    end

    test "non-empty radius ignores goal ids; empty radius keys off goal ids" do
      # Same radius, different goals -> same key (overlapping goals share a lease).
      assert Partition.partition_key(["g1"], ["lib/a.ex"]) ==
               Partition.partition_key(["g2"], ["lib/a.ex"])

      # Empty radius -> distinct keys per goal-id set.
      refute Partition.partition_key(["g1"], []) == Partition.partition_key(["g2"], [])
    end
  end
end
