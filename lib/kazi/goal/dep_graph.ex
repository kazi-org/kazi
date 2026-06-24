defmodule Kazi.Goal.DepGraph do
  @moduledoc """
  The **planner half** of the predicate-graph waves (T23.2, ADR-0028): the PURE,
  deterministic computation of WHICH groups are eligible to dispatch right now,
  from a goal's `needs` dependency edges (T23.1) and each group's observed
  CONVERGENCE STATE.

  ADR-0028 adds the fourth ingredient kazi's scheduler lacked — SEMANTIC ORDERING.
  A `Kazi.Goal.Group` carries an optional `needs :: [group-id]` "must-converge-
  before" edge set (distinct from `parent`, which is budget rollup only). From
  those edges plus the current per-group convergence state this module derives:

    * the **READY SET** — every group whose every `needs` dependency has
      OBJECTIVELY converged (ADR-0028 §Decision 2). A group with NO `needs` is
      always ready (the fully-parallel ADR-0027 default); a group with even one
      unconverged need is NOT ready. "Objectively converged" means evidence-backed
      `:converged` (the loop's `:converged` terminal / the scheduler's collective
      `:converged`), NOT "an agent said done".
    * the **BLOCKED SET** — every group that can NEVER become ready because a
      TRANSITIVE `needs` dependency is in a non-converging terminal/blocking state
      (`:stuck` / `:over_budget` / `:blocked`, ADR-0028 §Decision 5). A blocked
      group is a DEPENDENT poisoned by a blocking ancestor — NOT the blocking
      group itself (that group is the CAUSE, already in its own terminal state,
      not "waiting" on anything). Each blocked group is attributed to the SPECIFIC
      blocking dep that poisoned its sub-DAG, so the scheduler can NAME it in the
      collective report rather than hanging silently (the `/apply` wave-stall
      failure mode, made observable).

  This is the planner ONLY. The SCHEDULER's execution over this frontier
  (partition the ready set by blast radius, dispatch, re-evaluate as groups
  converge — ADR-0028 §Decision 3) is T23.3; this module does NOT dispatch, run,
  or mutate anything. It is a pure function of `(goal, states)` — the reconciler
  property: feed it an UPDATED state map after a frontier converges and it
  recomputes the next frontier with no hidden state (ADR-0028 §Decision 4).

  ## Convergence-state vocabulary

  The `states` parameter maps a group id to its current convergence state. The
  vocabulary composes with the loop's terminal states (`Kazi.Loop`) and the
  scheduler's collective verdict (`Kazi.Scheduler`) so T23.3 can hand observed
  state straight in:

    * `:converged`   — objectively converged (predicates true, evidence-backed):
      the loop's `:converged` outcome / the scheduler's `:converged` status. The
      ONLY state that satisfies a dependent's `needs` gate.
    * `:pending`     — declared but not yet dispatched / not yet converged. Still
      able to converge; gates dependents (they wait) but does not block them.
    * `:running`     — in-flight (a reconciler is driving it). Like `:pending`: it
      gates dependents but they are not blocked — it may yet converge.
    * `:stuck`       — a non-converging terminal: the loop gave up without
      converging (`Kazi.Loop`'s `:stopped`/`:stuck`; the scheduler's `:stuck`,
      which also absorbs `:stopped`/`:crashed`). A dependent transitively behind a
      `:stuck` group can NEVER become ready → BLOCKED.
    * `:over_budget` — a hard budget ceiling was hit (`Kazi.Loop`/`Kazi.Scheduler`
      `:over_budget`); like `:stuck`, a non-converging terminal that blocks
      dependents.
    * `:blocked`     — already escalated as blocked (e.g. a prior `evaluate/2` or
      the scheduler tagged it). Propagates: a group behind a `:blocked` group is
      itself blocked. Lets the result be fed back in idempotently.

  A group id ABSENT from `states` is treated as `:pending` (declared but
  unobserved — the freshly-authored default, mirroring `GroupTree`'s "absent
  verdict = pending").

  ## Pure + deterministic

  Every function here is a pure function of `(goal, states)` — no I/O, no process
  state, no evaluation. Ready/blocked groups are returned in the goal's DECLARED
  group order at every layer, so the same inputs always yield the same output. A
  goal whose groups all declare `needs: []` yields EVERY group ready at once (the
  fully-parallel default); the `needs` graph is a validated DAG (T23.1), so the
  traversal terminates.
  """

  alias Kazi.Goal
  alias Kazi.Goal.Group

  @typedoc """
  A group's observed convergence state (see the moduledoc vocabulary). Composes
  with `Kazi.Loop`'s terminal outcomes and `Kazi.Scheduler`'s collective verdict.
  """
  @type state ::
          :converged | :pending | :running | :stuck | :over_budget | :blocked

  @typedoc """
  The per-group convergence-state map handed in by the scheduler (T23.3): group
  id → its observed `t:state/0`. An id absent from the map is treated as
  `:pending` (declared but unobserved).
  """
  @type states :: %{optional(Group.id()) => state()}

  @typedoc """
  One blocked group, attributed to the SPECIFIC dependency that poisoned its
  sub-DAG (ADR-0028 §Decision 5):

    * `:group`    — the blocked DEPENDENT's id;
    * `:blocked_by` — the id of the nearest transitive `needs` dependency in a
      non-converging terminal/blocking state that makes this group unsatisfiable;
    * `:reason`   — that blocking dep's state (`:stuck` / `:over_budget` /
      `:blocked`), so the report can say WHY.

  A group that is ITSELF in a blocking state is NOT a blocked entry — it is the
  CAUSE, in its own terminal state rather than waiting on a dep. Only the
  dependents transitively behind it are reported blocked (and named for it).
  """
  @type blocked_entry :: %{
          group: Group.id(),
          blocked_by: Group.id(),
          reason: state()
        }

  @typedoc """
  The combined planner result (`evaluate/2`):

    * `:ready`   — the READY SET, group ids in declared order: every `needs` dep
      converged (or no `needs`), and the group is not itself converged/blocked.
    * `:blocked` — the BLOCKED SET, one `t:blocked_entry/0` per unsatisfiable
      group (declared order), each naming its blocking dep.
  """
  @type evaluation :: %{
          ready: [Group.id()],
          blocked: [blocked_entry()]
        }

  # The non-converging terminal/blocking states: a group in one of these can never
  # converge, so it poisons every group transitively behind it (ADR-0028 §Decision
  # 5). `:pending`/`:running` are NOT here — they may yet converge.
  @blocking_states [:stuck, :over_budget, :blocked]

  @doc """
  Computes the READY SET: the group ids eligible to dispatch right now.

  A group is ready iff:

    * every group id in its `needs` is OBJECTIVELY `:converged` (a group with no
      `needs` is vacuously ready — the fully-parallel default), AND
    * the group's OWN state is dispatchable — `:pending` (declared, or absent →
      pending). A `:running` group is already in-flight (do not re-dispatch); a
      `:converged` group is done (nothing to dispatch); a `:stuck` /
      `:over_budget` / `:blocked` group is in a terminal/blocking state and is
      not eligible as fresh work.

  Returned in the goal's DECLARED group order, so the result is deterministic. An
  id absent from `states` is treated as `:pending` (dispatchable).

  ## Examples

      iex> a = Kazi.Goal.Group.new("a", "A")
      iex> b = Kazi.Goal.Group.new("b", "B", needs: ["a"])
      iex> goal = Kazi.Goal.new("g", groups: [a, b])
      iex> Kazi.Goal.DepGraph.ready_set(goal, %{})
      ["a"]
      iex> Kazi.Goal.DepGraph.ready_set(goal, %{"a" => :converged})
      ["b"]
  """
  @spec ready_set(Goal.t(), states()) :: [Group.id()]
  def ready_set(%Goal{groups: groups}, states \\ %{}) when is_map(states) do
    for %Group{id: id, needs: needs} <- groups,
        dispatchable?(id, states),
        Enum.all?(needs, &converged?(&1, states)),
        do: id
  end

  @doc """
  Computes the BLOCKED SET: the groups that can NEVER become ready because a
  transitive `needs` dependency is in a non-converging terminal/blocking state.

  Walks each group's `needs` ancestry (its dependencies, transitively — NOT the
  group itself); if any group on that ancestry is `:stuck` / `:over_budget` /
  `:blocked`, the group is unsatisfiable and is attributed to the NEAREST such
  blocker (the first one found walking out from the group along `needs`). A group
  that is itself in a blocking state is the CAUSE, not a blocked entry — only its
  dependents are reported. Each entry is a `t:blocked_entry/0` naming the blocking
  dep and its state.

  Returned in the goal's DECLARED group order, so the result is deterministic.

  ## Examples

      iex> a = Kazi.Goal.Group.new("a", "A")
      iex> b = Kazi.Goal.Group.new("b", "B", needs: ["a"])
      iex> goal = Kazi.Goal.new("g", groups: [a, b])
      iex> Kazi.Goal.DepGraph.blocked(goal, %{"a" => :stuck})
      [%{group: "b", blocked_by: "a", reason: :stuck}]
  """
  @spec blocked(Goal.t(), states()) :: [blocked_entry()]
  def blocked(%Goal{groups: groups}, states \\ %{}) when is_map(states) do
    needs_by_id = Map.new(groups, fn %Group{id: id, needs: needs} -> {id, needs} end)

    for %Group{id: id} <- groups,
        blocker = blocker_of(id, needs_by_id, states),
        blocker != nil,
        do: %{group: id, blocked_by: blocker, reason: state_of(blocker, states)}
  end

  @doc """
  The combined planner result: `%{ready: [...], blocked: [...]}` in ONE pass over
  `(goal, states)`.

  This is the seam T23.3 (the scheduler) calls each cycle: dispatch `:ready`,
  escalate `:blocked` (naming each blocking dep), then recompute with the UPDATED
  state map as groups converge. Pure — no mutation; the same inputs always yield
  the same evaluation, and feeding a prior result's blocked groups back in (as
  `:blocked`) is idempotent.

  ## Examples

      iex> a = Kazi.Goal.Group.new("a", "A")
      iex> b = Kazi.Goal.Group.new("b", "B", needs: ["a"])
      iex> c = Kazi.Goal.Group.new("c", "C", needs: ["a"])
      iex> goal = Kazi.Goal.new("g", groups: [a, b, c])
      iex> Kazi.Goal.DepGraph.evaluate(goal, %{"a" => :converged})
      %{ready: ["b", "c"], blocked: []}
  """
  @spec evaluate(Goal.t(), states()) :: evaluation()
  def evaluate(%Goal{} = goal, states \\ %{}) when is_map(states) do
    %{ready: ready_set(goal, states), blocked: blocked(goal, states)}
  end

  @doc """
  Computes the TRANSITIVE DEPENDENTS of a group — every group that reaches `id`
  by following `needs` edges, in the goal's DECLARED order (excluding `id`
  itself).

  This is the re-gating half of ADR-0028 §Decision 4 ("objective, adaptive
  re-gating"): when a previously-`:converged` dep REGRESSES (its convergence
  becomes false again — the loop's regression guard fires, like standing mode),
  the scheduler must RE-GATE the dependents that became ready/converged ON that
  dep. They return to NOT-READY and re-converge. The set of groups to re-gate is
  exactly `id`'s transitive dependents — pure to compute, so the scheduler stays
  a re-evaluate-against-observed-state loop with no hidden ordering.

  The `needs` graph is a validated DAG (T23.1); a `visited` set still guards the
  walk so it is total regardless.

  ## Examples

      iex> a = Kazi.Goal.Group.new("a", "A")
      iex> b = Kazi.Goal.Group.new("b", "B", needs: ["a"])
      iex> c = Kazi.Goal.Group.new("c", "C", needs: ["b"])
      iex> goal = Kazi.Goal.new("g", groups: [a, b, c])
      iex> Kazi.Goal.DepGraph.dependents_of(goal, "a")
      ["b", "c"]
      iex> Kazi.Goal.DepGraph.dependents_of(goal, "c")
      []
  """
  @spec dependents_of(Goal.t(), Group.id()) :: [Group.id()]
  def dependents_of(%Goal{groups: groups}, id) when is_binary(id) do
    # Reverse adjacency: dep_id → [groups that directly `needs` it].
    direct_dependents =
      Enum.reduce(groups, %{}, fn %Group{id: gid, needs: needs}, acc ->
        Enum.reduce(needs, acc, fn dep, inner ->
          Map.update(inner, dep, [gid], &[gid | &1])
        end)
      end)

    reachable = collect_dependents([id], direct_dependents, MapSet.new([id]), MapSet.new())

    # Return in DECLARED order so re-gating is deterministic, excluding `id`.
    for %Group{id: gid} <- groups, MapSet.member?(reachable, gid), do: gid
  end

  # Breadth-first closure over the reverse-`needs` adjacency: every group that
  # transitively depends on a seed id. `visited` guards the walk; `acc` collects
  # the dependents found (the seeds themselves are excluded from `acc`).
  defp collect_dependents([], _direct, _visited, acc), do: acc

  defp collect_dependents([id | rest], direct, visited, acc) do
    dependents = Map.get(direct, id, [])

    {visited, acc, queue} =
      Enum.reduce(dependents, {visited, acc, rest}, fn dep, {v, a, q} ->
        if MapSet.member?(v, dep) do
          {v, a, q}
        else
          {MapSet.put(v, dep), MapSet.put(a, dep), [dep | q]}
        end
      end)

    collect_dependents(queue, direct, visited, acc)
  end

  # --- internals ---

  # The NEAREST blocking group on `id`'s `needs` ANCESTRY (its transitive
  # dependencies — NOT `id` itself), or nil if `id`'s ancestry carries no blocker.
  # A breadth-first walk out along `needs` starting from `id`'s direct deps, so the
  # FIRST blocking group reached (the nearest, by `needs`-distance) is the one
  # named. `id` itself is deliberately excluded from the search — a group in a
  # blocking state is the CAUSE, not a blocked dependent. The `needs` graph is a
  # validated DAG (T23.1), but a `visited` set still guards the walk so it is total
  # regardless.
  @spec blocker_of(Group.id(), %{Group.id() => [Group.id()]}, states()) :: Group.id() | nil
  defp blocker_of(id, needs_by_id, states) do
    direct_needs = Map.get(needs_by_id, id, [])
    walk_for_blocker(direct_needs, needs_by_id, states, MapSet.new([id]))
  end

  defp walk_for_blocker([], _needs_by_id, _states, _visited), do: nil

  defp walk_for_blocker([id | rest], needs_by_id, states, visited) do
    cond do
      MapSet.member?(visited, id) ->
        walk_for_blocker(rest, needs_by_id, states, visited)

      blocking?(id, states) ->
        id

      true ->
        deps = Map.get(needs_by_id, id, [])
        # FIFO (rest ++ deps): a nearer blocker enqueued earlier is found first.
        walk_for_blocker(rest ++ deps, needs_by_id, states, MapSet.put(visited, id))
    end
  end

  # A group is dispatchable iff its OWN state is `:pending` (declared, or absent →
  # pending) — fresh work to start. `:running` is already in-flight, `:converged`
  # is done, and `:stuck`/`:over_budget`/`:blocked` are terminal/blocking — none
  # are dispatchable.
  @spec dispatchable?(Group.id(), states()) :: boolean()
  defp dispatchable?(id, states), do: state_of(id, states) == :pending

  # A group is objectively converged iff its observed state is exactly `:converged`
  # — the only state that satisfies a dependent's `needs` gate (ADR-0028 §Decision
  # 2: evidence-backed, not "an agent said done"). An absent id is `:pending`.
  @spec converged?(Group.id(), states()) :: boolean()
  defp converged?(id, states), do: state_of(id, states) == :converged

  # A group is in a blocking state iff its observed state is a non-converging
  # terminal (`:stuck` / `:over_budget` / `:blocked`).
  @spec blocking?(Group.id(), states()) :: boolean()
  defp blocking?(id, states), do: state_of(id, states) in @blocking_states

  # The observed state of a group id; an id absent from `states` is `:pending`
  # (declared but unobserved — the freshly-authored default).
  @spec state_of(Group.id(), states()) :: state()
  defp state_of(id, states), do: Map.get(states, id, :pending)
end
