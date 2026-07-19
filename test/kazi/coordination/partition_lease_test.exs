defmodule Kazi.Coordination.PartitionLeaseTest do
  @moduledoc """
  T3.2b acceptance (UC-014): partitions map to lease keys such that overlapping
  blast radii contend on **one** lease (serialize) while disjoint partitions take
  **distinct** leases (parallel).

  Every case is hermetic. The blast-radius partitioning injects
  `Kazi.Context.GraphSource` doubles (no real code-review-graph, no MCP, no
  network); the lease contention is asserted against the in-memory lease double
  `Kazi.Coordination.Lease.Memory` on an injected clock (no NATS).
  """
  use ExUnit.Case, async: true

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Coordination.{Lease, PartitionLease}
  alias Kazi.Partition

  doctest Kazi.Coordination.PartitionLease

  # A graph-source double whose survey depends on the goal's evidence terms, so
  # two goals in one run can have overlapping or disjoint radii. `mapping` is
  # `term -> [file paths]`; the survey is the union over the goal's terms.
  # (Mirrors PartitionTest.TermSource so the two suites model radii the same way.)
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

  describe "lease_key/1" do
    test "is the partition's stable content-addressed key" do
      partition = %Partition{goal_ids: ["g1"], blast_radius: ["lib/a.ex"], key: "deadbeef"}
      assert PartitionLease.lease_key(partition) == "deadbeef"
    end
  end

  describe "lease_keys/3 — overlapping vs disjoint (UC-014 acceptance)" do
    test "OVERLAPPING goals derive the SAME lease key (one partition, one key)" do
      # Both goals touch lib/shared.ex -> one merged partition -> one lease key.
      source =
        TermSource.new(%{
          "g1-terms" => ["lib/a.ex", "lib/shared.ex"],
          "g2-terms" => ["lib/shared.ex", "lib/b.ex"]
        })

      goals = [{"g1", ["g1-terms"]}, {"g2", ["g2-terms"]}]

      assert [key] = PartitionLease.lease_keys(goals, "/ws", graph_source: source)
      assert is_binary(key)
    end

    test "DISJOINT goals derive DISTINCT lease keys (two partitions, two keys)" do
      source =
        TermSource.new(%{
          "g1-terms" => ["lib/a.ex"],
          "g2-terms" => ["lib/b.ex"]
        })

      goals = [{"g1", ["g1-terms"]}, {"g2", ["g2-terms"]}]

      assert [k1, k2] = PartitionLease.lease_keys(goals, "/ws", graph_source: source)
      assert k1 != k2
    end
  end

  describe "lease contention via the in-memory lease double" do
    setup do
      {:ok, store} = Lease.Memory.start_link()
      # A generous TTL on a fixed clock; nothing in these tests advances time.
      {:ok, store: store, opts: [store: store, now_ms: 0], ttl: 30_000}
    end

    test "OVERLAPPING goals share one key -> second acquirer LOSES (serialize)",
         %{opts: opts, ttl: ttl} do
      source =
        TermSource.new(%{
          "g1-terms" => ["lib/a.ex", "lib/shared.ex"],
          "g2-terms" => ["lib/shared.ex", "lib/b.ex"]
        })

      goals = [{"g1", ["g1-terms"]}, {"g2", ["g2-terms"]}]
      assert [key] = PartitionLease.lease_keys(goals, "/ws", graph_source: source)

      # The first instance leases the shared partition; a second *different*
      # instance targeting the same key is denied and must defer.
      assert {:ok, %Lease{}} = Lease.Memory.acquire(key, "instance-1", ttl, opts)
      assert {:error, :held} = Lease.Memory.acquire(key, "instance-2", ttl, opts)
    end

    test "DISJOINT goals derive distinct keys -> BOTH acquire (parallel)",
         %{opts: opts, ttl: ttl} do
      source =
        TermSource.new(%{
          "g1-terms" => ["lib/a.ex"],
          "g2-terms" => ["lib/b.ex"]
        })

      goals = [{"g1", ["g1-terms"]}, {"g2", ["g2-terms"]}]
      assert [k1, k2] = PartitionLease.lease_keys(goals, "/ws", graph_source: source)
      assert k1 != k2

      # Disjoint partitions -> disjoint lease keys -> both instances proceed.
      assert {:ok, %Lease{}} = Lease.Memory.acquire(k1, "instance-1", ttl, opts)
      assert {:ok, %Lease{}} = Lease.Memory.acquire(k2, "instance-2", ttl, opts)
    end

    test "transitively-overlapping goals (A∩B, B∩C) all serialize on one key",
         %{opts: opts, ttl: ttl} do
      # A∩B on lib/ab.ex and B∩C on lib/bc.ex put A, B, C in one partition even
      # though A∩C is empty -> one lease key -> only the first acquirer wins.
      source =
        TermSource.new(%{
          "a" => ["lib/a.ex", "lib/ab.ex"],
          "b" => ["lib/ab.ex", "lib/bc.ex"],
          "c" => ["lib/bc.ex", "lib/c.ex"]
        })

      goals = [{"gA", ["a"]}, {"gB", ["b"]}, {"gC", ["c"]}]
      assert [key] = PartitionLease.lease_keys(goals, "/ws", graph_source: source)

      assert {:ok, %Lease{}} = Lease.Memory.acquire(key, "instance-A", ttl, opts)
      assert {:error, :held} = Lease.Memory.acquire(key, "instance-B", ttl, opts)
      assert {:error, :held} = Lease.Memory.acquire(key, "instance-C", ttl, opts)
    end
  end

  describe "determinism (ADR-0006)" do
    test "same inputs yield identical lease keys across calls, order-independent" do
      source =
        TermSource.new(%{
          "a" => ["lib/a.ex", "lib/shared.ex"],
          "b" => ["lib/shared.ex"],
          "c" => ["lib/c.ex"]
        })

      forward =
        PartitionLease.lease_keys([{"gA", ["a"]}, {"gB", ["b"]}, {"gC", ["c"]}], "/ws",
          graph_source: source
        )

      reverse =
        PartitionLease.lease_keys([{"gC", ["c"]}, {"gB", ["b"]}, {"gA", ["a"]}], "/ws",
          graph_source: source
        )

      assert forward == reverse
      # The merged {gA,gB} partition and the lone {gC} partition -> two keys.
      assert length(forward) == 2
    end
  end
end
