defmodule Kazi.Coordination.PartitionLease do
  @moduledoc """
  Maps blast-radius **partitions** (T3.2a) to **lease keys** (T3.1) so overlapping
  partitions contend on one lease while disjoint partitions proceed in parallel
  (T3.2b, ADR-0006; UC-014).

  This is the seam that joins the two halves of kazi's resource-coordination
  model. `Kazi.Partition` answers *which goals share a blast radius* — goals whose
  edits would touch the same files land in one partition, disjoint goals in
  separate partitions. `Kazi.Coordination.Lease` answers *who may work a resource
  now* — a CAS/TTL lease per key, mutually exclusive. This module is the function
  between them: it turns a partition's stable content-addressed identity into the
  `t:Kazi.Coordination.Lease.key/0` an agent acquires before working any goal in
  that partition.

  The mapping is intentionally trivial — *because the work was already done in
  `Kazi.Partition`*. Each `Kazi.Partition` carries a `:key` that is a `sha256` of
  its sorted blast radius (an empty radius keys off the partition's goal ids), so:

    * goals with **overlapping** blast radii are placed in **one** partition by
      `Kazi.Partition.partition/3`, hence share one `:key`, hence
      `lease_key/1` returns the **same** lease key — the second acquirer against a
      live lease loses and must defer (serialize);
    * goals in **disjoint** partitions hash distinct radii to distinct `:key`s,
      hence distinct lease keys, hence both acquire freely (parallel).

  So `lease_key/1` is a total, pure projection of a partition onto a lease key; it
  adds no new hashing or graph access. `lease_keys/3` is the convenience that runs
  the partitioning and projects every resulting partition in one call.

  ## Why a key, not a held lease

  This module deliberately stops at the *key*. It does not acquire, renew, or
  release — that is dispatch wiring (T3.1d), which owns when a kazi instance takes
  the lease and how contention defers. Keeping the mapping a pure function lets
  both the dispatch path and the operator surfaces (a lease map, T3.6c) derive the
  same key from the same partition without coupling to lease lifecycle.

  ## Determinism

  Inherited wholesale from `Kazi.Partition`: same goals + same graph source ⇒
  identical partitions ⇒ identical keys ⇒ identical lease keys, across calls. This
  module introduces no ordering, time, or randomness of its own.
  """

  alias Kazi.Coordination.Lease
  alias Kazi.Partition

  @doc """
  The `Kazi.Coordination.Lease` key for a single `partition`.

  A partition's stable `:key` *is* its lease key: it is a `sha256` of the
  partition's sorted blast radius, so two partitions with the same radius (the
  same overlapping group) project to the same lease and serialize, while
  partitions with different radii project to different leases and run in parallel.

  ## Examples

      iex> p = %Kazi.Partition{goal_ids: ["g1"], blast_radius: ["lib/a.ex"], key: "abc"}
      iex> Kazi.Coordination.PartitionLease.lease_key(p)
      "abc"
  """
  @spec lease_key(Partition.t()) :: Lease.key()
  def lease_key(%Partition{key: key}) when is_binary(key), do: key

  @doc """
  Partitions `goals` against `workspace` and returns one lease key per partition.

  A thin composition of `Kazi.Partition.partition/3` and `lease_key/1`: it runs
  the blast-radius partitioning under the (injectable) graph source and projects
  each partition onto its lease key, preserving `partition/3`'s deterministic
  order. Overlapping goals collapse into one partition and so contribute **one**
  key; disjoint goals contribute **distinct** keys.

  `opts` are forwarded verbatim to `Kazi.Partition.partition/3` (notably
  `:graph_source`, for a hermetic run with an injected source).

  ## Examples

      iex> overlap = Kazi.Context.StaticGraphSource.new(files: ["lib/a.ex"])
      iex> goals = [{"g1", ["x"]}, {"g2", ["y"]}]
      iex> [key] = Kazi.Coordination.PartitionLease.lease_keys(goals, "/ws", graph_source: overlap)
      iex> is_binary(key)
      true
  """
  @spec lease_keys([Partition.goal_input()], String.t(), Partition.opts()) :: [Lease.key()]
  def lease_keys(goals, workspace, opts \\ [])
      when is_list(goals) and is_binary(workspace) and is_list(opts) do
    goals
    |> Partition.partition(workspace, opts)
    |> Enum.map(&lease_key/1)
  end
end
