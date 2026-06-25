defmodule Kazi.Scheduler.DagSnapshot do
  @moduledoc """
  The render-ready projection of a `needs`-DAG run at a moment in time (T23.7,
  UC-038, ADR-0011 / ADR-0028) — the data the live dependency-DAG dashboard
  renders.

  The `Kazi.Scheduler.DepScheduler` drives a goal's `needs` graph topologically
  and pipelined (T23.3); it holds the single source of truth — the per-group
  convergence `states` map it re-evaluates each cycle. This module turns that
  raw `(goal, states)` pair into a flat, render-ready value: one **node** per
  group (carrying its resolved DISPLAY state and per-group convergence) and one
  **edge** per `needs` dependency. It is a PURE function of `(goal, states)` —
  no process state, no I/O — so the same inputs always yield the same snapshot
  and a LiveView/test can build one from a fixture state map with no scheduler
  running.

  ## Display-state resolution

  The dashboard's "wave" vocabulary is narrower than the planner's raw states:
  it wants to distinguish a group that is *eligible to run right now* (`:ready`)
  from one merely *waiting on a dep* (`:pending`). So each node's display state
  is resolved from the raw `Kazi.Goal.DepGraph.state/0` plus the planner's
  `ready_set/2` and `blocked/2`:

    * `:running`     — a reconciler is driving the group right now.
    * `:converged`   — objectively converged (the only state that satisfies a
      dependent's `needs` gate).
    * `:stuck` / `:over_budget` — a non-converging terminal (the CAUSE of any
      blocked sub-DAG behind it).
    * `:blocked`     — a DEPENDENT poisoned by a blocking ancestor; it can never
      run. Carries the blocking dep in `:blocked_by`.
    * `:ready`       — declared, not yet dispatched, and every `needs` dep has
      converged: eligible to dispatch right now (the live frontier).
    * `:pending`     — declared but still waiting on an unconverged dep (not yet
      eligible).

  ## Per-group convergence

  Each node carries `needs_converged` / `needs_total`: how many of the group's
  `needs` dependencies have objectively converged. For a group with no `needs`
  this is `0/0` (vacuously satisfied). It is the per-group convergence the
  dashboard surfaces alongside the state badge (the "predicates passed / total"
  analogue at the GROUP-DAG layer).

  ## Edges

  Each `needs` edge `b needs a` is an edge `%{from: "a", to: "b"}` — the
  dependency points at its dependent (data flows dep → dependent), so the
  dashboard can lay the DAG out left-to-right by frontier.
  """

  alias Kazi.Goal
  alias Kazi.Goal.DepGraph
  alias Kazi.Goal.Group

  @typedoc "A group's resolved DISPLAY state for the dashboard (see moduledoc)."
  @type display_state ::
          :running | :converged | :stuck | :over_budget | :blocked | :ready | :pending

  @typedoc """
  One DAG node — a group with its resolved display state and per-group
  convergence:

    * `:id`              — the group's stable slug.
    * `:name`            — its human display label.
    * `:state`           — the resolved `t:display_state/0`.
    * `:blocked_by`      — when `:blocked`, the id of the blocking dep; else `nil`.
    * `:needs_total`     — how many `needs` dependencies the group declares.
    * `:needs_converged` — how many of those have objectively converged.
  """
  @type node_entry :: %{
          id: Group.id(),
          name: String.t(),
          state: display_state(),
          blocked_by: Group.id() | nil,
          needs_total: non_neg_integer(),
          needs_converged: non_neg_integer()
        }

  @typedoc "One `needs` edge, `to` depends on `from` (data flows dep → dependent)."
  @type edge :: %{from: Group.id(), to: Group.id()}

  @type t :: %__MODULE__{
          goal_ref: Goal.id() | nil,
          nodes: [node_entry()],
          edges: [edge()]
        }

  @enforce_keys [:goal_ref, :nodes, :edges]
  defstruct goal_ref: nil, nodes: [], edges: []

  # The `Kazi.PubSub` topic the scheduler broadcasts `{:dag_updated, snapshot}`
  # on as a run progresses. The dashboard (and its snapshot cache) subscribe to
  # it for live pushes. A plain string so the producer (`DepScheduler`) and the
  # consumer (`KaziWeb.DagSource`) share it without coupling to one another.
  @topic "scheduler:dag"

  @doc "The `Kazi.PubSub` topic DAG snapshots are broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Builds the render-ready snapshot from a goal and its raw per-group convergence
  `states` map (the `DepScheduler`'s source of truth). Nodes are in the goal's
  DECLARED group order; edges in declared order over each group's `needs`. Pure.
  """
  @spec from(Goal.t(), DepGraph.states()) :: t()
  def from(%Goal{} = goal, states) when is_map(states) do
    ready = MapSet.new(DepGraph.ready_set(goal, states))
    blocked_by = Map.new(DepGraph.blocked(goal, states), &{&1.group, &1.blocked_by})

    nodes =
      Enum.map(goal.groups, fn %Group{} = group ->
        node(group, states, ready, blocked_by)
      end)

    edges =
      for %Group{id: id, needs: needs} <- goal.groups,
          dep <- needs,
          do: %{from: dep, to: id}

    %__MODULE__{goal_ref: goal.id, nodes: nodes, edges: edges}
  end

  @doc """
  The empty snapshot — no goal, no nodes, no edges. What the dashboard shows when
  no run is active (an honest "no active run" state, not fabricated sample nodes).
  """
  @spec empty() :: t()
  def empty, do: %__MODULE__{goal_ref: nil, nodes: [], edges: []}

  defp node(%Group{id: id, name: name, needs: needs}, states, ready, blocked_by) do
    raw = Map.get(states, id, :pending)
    {state, blocker} = resolve(id, raw, ready, blocked_by)

    %{
      id: id,
      name: name,
      state: state,
      blocked_by: blocker,
      needs_total: length(needs),
      needs_converged: Enum.count(needs, &(Map.get(states, &1, :pending) == :converged))
    }
  end

  # Resolve a group's display state. The terminal/in-flight raw states pass
  # straight through; a raw `:blocked` (the scheduler marked it) or a `:pending`
  # group poisoned by a blocking ancestor resolves to `:blocked` naming the dep;
  # a `:pending` group whose deps have all converged is `:ready` (the live
  # frontier); otherwise it is still `:pending` (waiting on a dep).
  defp resolve(_id, :running, _ready, _blocked_by), do: {:running, nil}
  defp resolve(_id, :converged, _ready, _blocked_by), do: {:converged, nil}
  defp resolve(_id, :stuck, _ready, _blocked_by), do: {:stuck, nil}
  defp resolve(_id, :over_budget, _ready, _blocked_by), do: {:over_budget, nil}

  defp resolve(id, :blocked, _ready, blocked_by),
    do: {:blocked, Map.get(blocked_by, id)}

  defp resolve(id, :pending, ready, blocked_by) do
    cond do
      Map.has_key?(blocked_by, id) -> {:blocked, Map.fetch!(blocked_by, id)}
      MapSet.member?(ready, id) -> {:ready, nil}
      true -> {:pending, nil}
    end
  end
end
