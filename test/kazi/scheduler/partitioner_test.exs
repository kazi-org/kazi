defmodule Kazi.Scheduler.PartitionerTest do
  @moduledoc """
  T21.2 acceptance (ADR-0027): wiring `Kazi.Partition` into the scheduler. A
  multi-goal / multi-region input partitions into DISJOINT partitions (one
  reconciler each); a single goal / no graph degenerates to ONE partition.

  Hermetic: the graph source is an injected double (a per-term file mapping), so
  there is no real code-review-graph, no MCP, and no network.
  """
  use ExUnit.Case, async: true

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Scheduler.Partitioner

  # A source double whose survey depends on a goal's evidence terms, so goals in
  # one run can have overlapping or disjoint radii. `mapping` is `term -> paths`.
  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, terms, opts) do
      mapping = Keyword.fetch!(opts, :mapping)

      files =
        terms
        |> Enum.flat_map(&Map.get(mapping, &1, []))
        |> Enum.uniq()
        |> Enum.map(&FileRef.new/1)

      Survey.new(:graph, files: files)
    end

    def new(mapping), do: {__MODULE__, mapping: mapping}
  end

  defp goal(id, terms) do
    Kazi.Goal.new(id, metadata: %{partition_terms: terms})
  end

  describe "partition/3 — disjoint regions (the multi-region acceptance)" do
    test "goals touching disjoint regions become SEPARATE partitions, one each" do
      # g1 in region a, g2 in region b, g3 in region c — no shared path.
      source =
        TermSource.new(%{
          "a" => ["lib/a.ex"],
          "b" => ["lib/b.ex"],
          "c" => ["lib/c.ex"]
        })

      goals = [goal("g1", ["a"]), goal("g2", ["b"]), goal("g3", ["c"])]

      parts = Partitioner.partition(goals, "/ws", graph_source: source)

      assert length(parts) == 3
      assert Enum.map(parts, & &1.partition.goal_ids) == [["g1"], ["g2"], ["g3"]]
      # Each partition carries exactly its one goal, rejoined from the id.
      assert Enum.map(parts, fn p -> Enum.map(p.goals, & &1.id) end) == [["g1"], ["g2"], ["g3"]]
    end

    test "disjoint partitions derive DISTINCT lease keys (parallel by construction)" do
      source = TermSource.new(%{"a" => ["lib/a.ex"], "b" => ["lib/b.ex"]})
      goals = [goal("g1", ["a"]), goal("g2", ["b"])]

      keys = goals |> Partitioner.partition("/ws", graph_source: source) |> Enum.map(& &1.key)

      assert length(keys) == 2
      assert Enum.uniq(keys) == keys
    end
  end

  describe "partition/3 — overlapping regions merge" do
    test "goals sharing a path land in ONE partition (serialize on one key)" do
      # g1 touches a + shared; g2 touches shared + b -> overlap on shared.
      source =
        TermSource.new(%{
          "a" => ["lib/a.ex", "lib/shared.ex"],
          "b" => ["lib/shared.ex", "lib/b.ex"]
        })

      goals = [goal("g1", ["a"]), goal("g2", ["b"])]

      assert [partition] = Partitioner.partition(goals, "/ws", graph_source: source)
      assert Enum.map(partition.goals, & &1.id) == ["g1", "g2"]
      assert partition.blast_radius == ["lib/a.ex", "lib/b.ex", "lib/shared.ex"]
    end
  end

  describe "partition/3 — degenerate to ONE partition" do
    test "a single goal yields exactly one partition (serial parity)" do
      source = TermSource.new(%{"a" => ["lib/a.ex"]})

      assert [partition] = Partitioner.partition([goal("g1", ["a"])], "/ws", graph_source: source)
      assert Enum.map(partition.goals, & &1.id) == ["g1"]
    end

    test "no graph (empty radius) ⇒ each goal its own singleton partition" do
      # The source surfaces NOTHING for any goal: no blast radius, so no goal
      # overlaps any other — each is its own partition, like today's serial run.
      empty = TermSource.new(%{})
      goals = [goal("g1", ["a"]), goal("g2", ["b"])]

      parts = Partitioner.partition(goals, "/ws", graph_source: empty)

      assert length(parts) == 2
      assert Enum.all?(parts, &(&1.blast_radius == []))
      # Empty-radius singletons still key distinctly (off their goal ids).
      assert parts |> Enum.map(& &1.key) |> Enum.uniq() |> length() == 2
    end

    test "a single goal with no graph is still exactly one partition" do
      empty = TermSource.new(%{})

      assert [partition] =
               Partitioner.partition([goal("solo", ["x"])], "/ws", graph_source: empty)

      assert Enum.map(partition.goals, & &1.id) == ["solo"]
      assert partition.blast_radius == []
    end
  end
end
