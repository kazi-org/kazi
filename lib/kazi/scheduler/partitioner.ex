defmodule Kazi.Scheduler.Partitioner do
  @moduledoc """
  Wires `Kazi.Partition` blast-radius partitioning into the scheduler (T21.2,
  ADR-0027): turns a goal-set into the DISJOINT partitions the coordinator runs
  one reconciler per.

  ADR-0027 step 1: a `kazi run` over a goal-set **partitions by blast radius**
  (`Kazi.Partition.partition/3` over the graph / repo-map `:graph_source`) into
  conflict-free partitions BY CONSTRUCTION, then spawns one supervised reconciler
  per partition. `Kazi.Partition` already computes the disjoint grouping and the
  stable lease `:key`; this module is the thin seam that:

    1. partitions the goals' ids/terms through the injected graph source, then
    2. **rejoins** each `Kazi.Partition` to the actual `%Kazi.Goal{}` structs its
       `:goal_ids` name, so the reconciler/lease/worktree downstream have the
       runnable goals, not just ids.

  The result is a list of `t:t/0` — one per partition — each carrying the member
  goals, the union blast radius, and the lease `:key`. Overlapping goals land in
  ONE entry (they share a key, hence serialize on one lease); disjoint goals land
  in SEPARATE entries (distinct keys, run in parallel).

  ## Degenerate to one partition (today's serial run)

  A **single goal**, or a goal-set the graph source finds **no blast radius** for,
  degenerates to a partition-per-goal where each runs alone — and a single goal is
  exactly one partition, so the run behaves precisely like today's serial
  single-goal convergence (ADR-0027 step 1, the on-ramp). This is not a special
  case in the code: it falls out of `Kazi.Partition.partition/3` (an empty radius
  is its own singleton), so the same path serves one goal and N.

  ## Determinism

  Inherited wholesale from `Kazi.Partition`: same goals + same source ⇒ identical
  partitions, identical keys, identical order. This module adds no ordering,
  time, or randomness — it only maps ids back to the goals the caller supplied.
  """

  alias Kazi.Partition

  @typedoc """
  One runnable partition: a `Kazi.Partition` rejoined to the `%Kazi.Goal{}`
  structs its `:goal_ids` name.

    * `:goals` — the member goals (those whose id is in the partition), ordered to
      match the partition's deterministic `:goal_ids`;
    * `:key` — the stable lease key (T3.2b); overlapping partitions share it,
      disjoint partitions differ;
    * `:blast_radius` — the sorted union of the members' blast-radius paths;
    * `:partition` — the underlying `Kazi.Partition` (for observability / keys).
  """
  @type t :: %__MODULE__{
          goals: [Kazi.Goal.t()],
          key: String.t(),
          blast_radius: [String.t()],
          partition: Partition.t()
        }

  @enforce_keys [:goals, :key, :blast_radius, :partition]
  defstruct [:goals, :key, :blast_radius, :partition]

  @doc """
  Partitions `goals` against `workspace` into disjoint runnable partitions.

  Each goal is partitioned by its blast radius (its declared `partition_terms`,
  expanded through the injected `:graph_source`), then each resulting
  `Kazi.Partition` is rejoined to the member `%Kazi.Goal{}` structs. Returns the
  partitions in `Kazi.Partition.partition/3`'s deterministic order.

  A single goal, or any goal-set with no overlapping blast radii, yields one
  partition per goal (a single goal ⇒ exactly one partition — the serial
  degenerate case).

  ## Options

  Forwarded verbatim to `Kazi.Partition.partition/3` (notably `:graph_source`,
  injected for a hermetic, network-free run).
  """
  @spec partition([Kazi.Goal.t()], String.t(), keyword()) :: [t()]
  def partition(goals, workspace, opts \\ [])
      when is_list(goals) and is_binary(workspace) and is_list(opts) do
    by_id = Map.new(goals, fn %Kazi.Goal{id: id} = goal -> {id, goal} end)

    goals
    |> Partition.partition(workspace, opts)
    |> Enum.map(fn %Partition{goal_ids: goal_ids} = partition ->
      %__MODULE__{
        goals: Enum.map(goal_ids, &Map.fetch!(by_id, &1)),
        key: partition.key,
        blast_radius: partition.blast_radius,
        partition: partition
      }
    end)
  end
end
