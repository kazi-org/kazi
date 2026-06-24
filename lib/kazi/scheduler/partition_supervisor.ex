defmodule Kazi.Scheduler.PartitionSupervisor do
  @moduledoc """
  The `DynamicSupervisor` that owns one **partition reconciler** child per
  partition of a parallel run (T21.1, ADR-0027).

  ADR-0027 makes kazi own parallelization: a `kazi run` over a partitioned
  goal-set spawns **one supervised reconciler per partition**, each driving the
  existing serial per-goal loop over its disjoint blast radius, and a coordinator
  reports the COLLECTIVE verdict. This module is the supervision anchor for that
  population — the BEAM-native "supervised population of fallible concurrent
  processes" the domain is (concept §8).

  It is a thin, dynamic supervisor: the `Kazi.Scheduler` coordinator starts a
  child per partition under it with `start_child/2`, the children run
  CONCURRENTLY (a `DynamicSupervisor` imposes no ordering between siblings), and a
  child crash is isolated to that child — siblings and the coordinator survive
  (`:one_for_one`). T21.10 deepens the restart/escalation policy; this skeleton
  supervises the population so that work can land on it.

  ## Instance, not global

  Like the in-memory lease store (`Kazi.Coordination.Lease.Memory`), a supervisor
  is an instance referenced by its pid, not a singleton. The application tree
  starts one named instance (`Kazi.Application`), but a test — or a second
  concurrent run — can `start_link/1` its own isolated supervisor and hand its pid
  to a `Kazi.Scheduler`, so parallel runs never contend on one global tree.
  """

  use DynamicSupervisor

  @doc """
  Starts the partition-reconciler `DynamicSupervisor`.

  Accepts the standard `DynamicSupervisor` options (notably `:name` to register
  the application-tree instance). Without a `:name` it starts an anonymous
  instance whose pid the caller (a test, a per-run scheduler) holds directly.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    case name do
      nil -> DynamicSupervisor.start_link(__MODULE__, opts)
      name -> DynamicSupervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts one supervised partition-reconciler child under `supervisor`.

  `child_spec` is any child specification a `DynamicSupervisor` accepts — the
  coordinator passes a `Task` child spec wrapping the injectable reconciler for
  one partition. Returns `DynamicSupervisor.start_child/2`'s result.
  """
  @spec start_child(
          Supervisor.supervisor(),
          :supervisor.child_spec() | {module(), term()} | module()
        ) ::
          DynamicSupervisor.on_start_child()
  def start_child(supervisor, child_spec) do
    DynamicSupervisor.start_child(supervisor, child_spec)
  end
end
