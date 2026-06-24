defmodule Kazi.Pool.LeaseTest do
  @moduledoc """
  T20.6 acceptance (ADR-0026 L3): a pooled session's per-task BLAST-RADIUS lease.

  Every case is hermetic. The blast-radius partitioning injects a
  `Kazi.Context.GraphSource` double (no real code-review-graph, no MCP, no
  network); the lease contention is asserted against the in-memory lease backend
  `Kazi.Coordination.Lease.Memory` on a fixed injected clock (NO NATS).

  The acceptance bar:

    * a session acquires a run-scoped lease for its blast radius and releases it
      on terminal;
    * two OVERLAPPING-radius runs serialize (the second fails to acquire until the
      first releases); two DISJOINT-radius runs both acquire freely;
    * the lease releases on terminal incl. on crash/error.
  """
  use ExUnit.Case, async: true

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Coordination.Lease
  alias Kazi.Pool.Lease, as: PoolLease

  # A graph-source double whose survey depends on the goal's evidence terms, so
  # two runs can have overlapping or disjoint blast radii. `mapping` is
  # `term -> [file paths]`; the survey is the union over the goal's terms.
  # (Mirrors PartitionLeaseTest.TermSource so the suites model radii the same way.)
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

  setup do
    {:ok, store} = Lease.Memory.start_link()
    # A fixed clock; nothing in these tests advances time, so the only way a key
    # frees is an explicit release (not TTL expiry) — exactly what we assert.
    {:ok, store: store, lease_opts: [store: store, now_ms: 0]}
  end

  describe "acquire/2 + release/1 — run-scoped lease for a blast radius" do
    test "a session acquires its blast radius and releases it on terminal",
         %{lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/a.ex", "lib/b.ex"]})

      assert {:ok, held} =
               PoolLease.acquire([{"g1", ["t"]}],
                 holder: "run-1",
                 graph_source: source,
                 lease_opts: lease_opts
               )

      # One key per blast-radius path (lib/a.ex, lib/b.ex), all held by this run.
      assert [%Lease{holder: "run-1"}, %Lease{holder: "run-1"}] = held.leases

      # While held, a different run on the same radius is denied (serialize)...
      assert {:error, :held, %{key: _}} =
               PoolLease.acquire([{"g2", ["t"]}],
                 holder: "run-2",
                 graph_source: source,
                 lease_opts: lease_opts
               )

      # ...until the first run reaches terminal and releases.
      assert :ok = PoolLease.release(held)

      assert {:ok, _held2} =
               PoolLease.acquire([{"g2", ["t"]}],
                 holder: "run-2",
                 graph_source: source,
                 lease_opts: lease_opts
               )
    end

    test "release/1 is idempotent — releasing twice is :ok", %{lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/a.ex"]})

      assert {:ok, held} =
               PoolLease.acquire([{"g1", ["t"]}],
                 holder: "run-1",
                 graph_source: source,
                 lease_opts: lease_opts
               )

      assert :ok = PoolLease.release(held)
      assert :ok = PoolLease.release(held)
    end

    test "requires a non-empty :holder", %{lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/a.ex"]})

      assert_raise ArgumentError, fn ->
        PoolLease.acquire([{"g1", ["t"]}], graph_source: source, lease_opts: lease_opts)
      end

      assert_raise ArgumentError, fn ->
        PoolLease.acquire([{"g1", ["t"]}],
          holder: "",
          graph_source: source,
          lease_opts: lease_opts
        )
      end
    end
  end

  describe "overlapping vs disjoint radii (the L3 contract)" do
    test "OVERLAPPING-radius runs serialize: the second waits for the first",
         %{lease_opts: lease_opts} do
      # Both runs touch lib/shared.ex -> one merged partition -> one lease key.
      source =
        TermSource.new(%{
          "r1" => ["lib/a.ex", "lib/shared.ex"],
          "r2" => ["lib/shared.ex", "lib/b.ex"]
        })

      assert {:ok, held1} =
               PoolLease.acquire([{"g1", ["r1"]}],
                 holder: "run-1",
                 graph_source: source,
                 lease_opts: lease_opts
               )

      # The overlapping second run cannot acquire while the first holds it.
      assert {:error, :held, %{key: key}} =
               PoolLease.acquire([{"g2", ["r2"]}],
                 holder: "run-2",
                 graph_source: source,
                 lease_opts: lease_opts
               )

      assert is_binary(key)

      # After the first releases on terminal, the second proceeds.
      assert :ok = PoolLease.release(held1)

      assert {:ok, _held2} =
               PoolLease.acquire([{"g2", ["r2"]}],
                 holder: "run-2",
                 graph_source: source,
                 lease_opts: lease_opts
               )
    end

    test "DISJOINT-radius runs both acquire freely (parallel)",
         %{lease_opts: lease_opts} do
      source =
        TermSource.new(%{
          "r1" => ["lib/a.ex"],
          "r2" => ["lib/b.ex"]
        })

      assert {:ok, _held1} =
               PoolLease.acquire([{"g1", ["r1"]}],
                 holder: "run-1",
                 graph_source: source,
                 lease_opts: lease_opts
               )

      assert {:ok, _held2} =
               PoolLease.acquire([{"g2", ["r2"]}],
                 holder: "run-2",
                 graph_source: source,
                 lease_opts: lease_opts
               )
    end

    test "a multi-file radius leases EVERY key; a partial-overlap run is denied",
         %{lease_opts: lease_opts} do
      # run-1's radius is two disjoint partitions {lib/a.ex} and {lib/b.ex}.
      # run-2 overlaps only on lib/b.ex -> still denied (any overlap serializes).
      source =
        TermSource.new(%{
          "a" => ["lib/a.ex"],
          "b" => ["lib/b.ex"]
        })

      assert {:ok, held1} =
               PoolLease.acquire([{"g1", ["a"]}, {"g2", ["b"]}],
                 holder: "run-1",
                 graph_source: source,
                 lease_opts: lease_opts
               )

      assert length(held1.leases) == 2

      assert {:error, :held, _} =
               PoolLease.acquire([{"g3", ["b"]}],
                 holder: "run-2",
                 graph_source: source,
                 lease_opts: lease_opts
               )
    end

    test "a partial acquire rolls back — the uncontended key is NOT stranded",
         %{lease_opts: lease_opts} do
      # run-other holds {lib/b.ex}. run-1 wants {lib/a.ex} AND {lib/b.ex}: it can
      # take lib/a.ex but is denied lib/b.ex, so it must roll back lib/a.ex —
      # otherwise a third run on lib/a.ex would be wrongly blocked.
      source =
        TermSource.new(%{
          "a" => ["lib/a.ex"],
          "b" => ["lib/b.ex"]
        })

      assert {:ok, _other} =
               PoolLease.acquire([{"gB", ["b"]}],
                 holder: "run-other",
                 graph_source: source,
                 lease_opts: lease_opts
               )

      assert {:error, :held, _} =
               PoolLease.acquire([{"g1", ["a"]}, {"g2", ["b"]}],
                 holder: "run-1",
                 graph_source: source,
                 lease_opts: lease_opts
               )

      # lib/a.ex must be free again — run-3 takes it without contention.
      assert {:ok, _held3} =
               PoolLease.acquire([{"g3", ["a"]}],
                 holder: "run-3",
                 graph_source: source,
                 lease_opts: lease_opts
               )
    end
  end

  describe "with_lease/3 — release on EVERY terminal path" do
    test "runs the body and releases on a clean return", %{lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/a.ex"]})

      assert {:ok, :did_edit} =
               PoolLease.with_lease(
                 [{"g1", ["t"]}],
                 [holder: "run-1", graph_source: source, lease_opts: lease_opts],
                 fn -> :did_edit end
               )

      # Released on return: an overlapping run now acquires freely.
      assert {:ok, _} =
               PoolLease.acquire([{"g2", ["t"]}],
                 holder: "run-2",
                 graph_source: source,
                 lease_opts: lease_opts
               )
    end

    test "releases the lease even when the body RAISES", %{lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/a.ex"]})

      assert_raise RuntimeError, "boom", fn ->
        PoolLease.with_lease(
          [{"g1", ["t"]}],
          [holder: "run-1", graph_source: source, lease_opts: lease_opts],
          fn -> raise "boom" end
        )
      end

      # The crash did not strand the lease: an overlapping run acquires freely.
      assert {:ok, _} =
               PoolLease.acquire([{"g2", ["t"]}],
                 holder: "run-2",
                 graph_source: source,
                 lease_opts: lease_opts
               )
    end

    test "releases the lease even when the body THROWS", %{lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/throw.ex"]})

      assert catch_throw(
               PoolLease.with_lease(
                 [{"g1", ["t"]}],
                 [holder: "run-1", graph_source: source, lease_opts: lease_opts],
                 fn -> throw(:abort) end
               )
             ) == :abort

      # The throw did not strand the lease: an overlapping run acquires freely.
      assert {:ok, _} =
               PoolLease.acquire([{"g2", ["t"]}],
                 holder: "run-2",
                 graph_source: source,
                 lease_opts: lease_opts
               )
    end

    test "releases the lease even when the body EXITS", %{lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/exit.ex"]})

      assert catch_exit(
               PoolLease.with_lease(
                 [{"g1", ["t"]}],
                 [holder: "run-1", graph_source: source, lease_opts: lease_opts],
                 fn -> exit(:dead) end
               )
             ) == :dead

      # The exit did not strand the lease: an overlapping run acquires freely.
      assert {:ok, _} =
               PoolLease.acquire([{"g2", ["t"]}],
                 holder: "run-2",
                 graph_source: source,
                 lease_opts: lease_opts
               )
    end

    test "does NOT run the body when an overlapping run already holds the radius",
         %{lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/a.ex"]})

      {:ok, held} =
        PoolLease.acquire([{"g1", ["t"]}],
          holder: "run-1",
          graph_source: source,
          lease_opts: lease_opts
        )

      ran? = :counters.new(1, [])

      assert {:error, :held, %{key: _}} =
               PoolLease.with_lease(
                 [{"g2", ["t"]}],
                 [holder: "run-2", graph_source: source, lease_opts: lease_opts],
                 fn -> :counters.add(ran?, 1, 1) end
               )

      assert :counters.get(ran?, 1) == 0
      assert :ok = PoolLease.release(held)
    end
  end
end
