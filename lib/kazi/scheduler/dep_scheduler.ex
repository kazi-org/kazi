defmodule Kazi.Scheduler.DepScheduler do
  @moduledoc """
  The **topological, pipelined** scheduler over a goal's `needs`-DAG (T23.3,
  ADR-0028) — the KEYSTONE of the predicate-graph waves. It composes the
  ADR-0027 coordinator (`Kazi.Scheduler`) and the pure planner
  (`Kazi.Goal.DepGraph`) into one re-evaluate-on-each-terminal loop, with NO
  global barrier.

  ADR-0028 adds SEMANTIC ORDERING the spatial coordinator lacked. A
  `Kazi.Goal.Group` carries an optional `needs :: [group-id]` "must-converge-
  before" edge set (T23.1). `Kazi.Goal.DepGraph` (T23.2) turns those edges + the
  observed per-group convergence state into a READY SET (groups whose every
  `needs` dep objectively converged) and a BLOCKED SET (groups poisoned by a
  `:stuck`/`:over_budget` ancestor). This module DRIVES that planner:

    1. **dispatch only the READY SET** — a group whose every `needs` dep has
       converged (a no-`needs` group is ready immediately). A group with an
       unconverged dep does NOT start until the dep converges.
    2. run the ready groups **CONCURRENTLY** under the existing
       `Kazi.Scheduler.PartitionSupervisor` `DynamicSupervisor` (the same
       supervised-task-per-unit machinery the coordinator uses), each driven by
       the INJECTABLE reconciler seam.
    3. **RE-EVALUATE the ready set as each group terminates** — the moment a
       group converges, `DepGraph.evaluate/2` is recomputed against the UPDATED
       state and newly-eligible groups dispatch IMMEDIATELY. There is NO barrier:
       a frontier-2 group whose deps just converged starts even while unrelated
       frontier-1 groups are still running (pipelining; no slowest-in-wave tax).
    4. **surface BLOCKED sub-DAGs** — a group whose `needs` dep went
       `:stuck`/`:over_budget` can never run; it is reported as `:blocked`
       NAMING the blocking dep (via `DepGraph.blocked/2`), and the loop does NOT
       hang waiting for it. Siblings outside the blocked sub-DAG still finish.

  ## Objective re-gating on regression (T23.4, ADR-0028 §Decision 4)

  Because readiness is defined by OBJECTIVE convergence and the state map is the
  single source of truth re-evaluated each cycle, a dep that LATER REGRESSES — its
  convergence becomes false again (the loop's regression guard fires, like
  standing mode) — RE-GATES its dependents. A `{:regress, group_id, status}`
  message flips a `:converged` group back to a non-converged state; its TRANSITIVE
  dependents (`DepGraph.dependents_of/2`) that had become ready/converged on it are
  RESET to `:pending` and re-dispatched once the dep re-converges. No dependent
  integrates or merges against a regressed dep: it leaves the ready set the instant
  the dep flips, and re-converges only after the dep does.

  ## Blocked-dependency escalation (T23.5, ADR-0028 §Decision 5)

  A `:stuck`/`:over_budget` dep poisons every group transitively behind it. Beyond
  the flat `:blocked` entries, the result carries an `:escalations` view that
  GROUPS the blocked sub-DAG BY its blocking dep — one entry per blocker NAMING it,
  its reason, and the LIST of blocked dependents — so the collective verdict
  explicitly escalates the affected sub-DAG rather than leaving the reader to
  re-derive it. Siblings OUTSIDE every blocked sub-DAG still finish and the run
  terminates (no silent hang).

  When NO group declares `needs`, every group is ready at the first frontier, so
  the loop dispatches them all at once — behaving EXACTLY like the flat parallel
  coordinator (ADR-0027 default). `Kazi.Scheduler.run_goals/2` routes here only
  when a group has `needs`, so the no-`needs` path is byte-for-byte the
  pre-T23.3 behavior (backward compatible, T21.8 CLI unaffected).

  ## The schedulable unit is the GROUP

  The coordinator (`Kazi.Scheduler`) schedules PARTITIONS (spatial blast-radius
  units). This layer schedules GROUPS (the `needs`-DAG vertices). The two compose
  cleanly: this scheduler decides WHICH groups are eligible right now; within a
  ready frontier, the eligible groups are still disjoint-by-construction work the
  reconciler drives concurrently. A production reconciler partitions a group's
  predicates by blast radius and runs the coordinator under the hood; a test
  injects a stub that returns a chosen terminal status (hermetic, no
  harness/git/NATS).

  ## The injectable reconciler seam

  A reconciler is a `t:reconciler/0`: a 1-arity fn `group_id -> group_status`,
  run in its own supervised process per dispatched group. It returns a terminal
  `t:Kazi.Scheduler.partition_status/0` (`:converged | :stuck | :over_budget |
  :stopped | :crashed`) or any other term (normalized to `:stuck`); an
  exit/crash is recorded `:crashed`. The same seam the coordinator exposes, so
  tests drive convergence by controlling the stub's return per group.

  ## Result

  The collective result extends `Kazi.Scheduler`'s with a per-GROUP view:

    * `:collective` — the collective verdict over the per-group outcomes
      (`Kazi.Scheduler.collective_verdict/1`); a group that was BLOCKED folds in
      as `:stuck` (it never converged), so a blocked sub-DAG keeps the collective
      non-green.
    * `:groups` — one `{group_id, status}` per group in DECLARED order, where a
      dispatched group carries its reconciler's terminal status and a never-
      dispatched-because-blocked group carries `:blocked`.
    * `:blocked` — the `Kazi.Goal.DepGraph.blocked_entry/0` list, each NAMING the
      blocking dep, so the report says WHY a sub-DAG never ran rather than
      hanging silently.
    * `:escalations` — the blocked sub-DAG GROUPED by blocking dep (T23.5): one
      `t:escalation/0` per blocker, naming it, its reason, and the LIST of blocked
      dependents — the explicit collective escalation of the affected sub-DAG.
  """

  use GenServer

  alias Kazi.Goal
  alias Kazi.Goal.DepGraph
  alias Kazi.Goal.Group
  alias Kazi.Scheduler
  alias Kazi.Scheduler.DagSnapshot
  alias Kazi.Scheduler.PartitionSupervisor

  @typedoc """
  The injectable reconciler seam: a 1-arity fn `group_id -> group_status`, run in
  its own supervised process per dispatched group. Returning a non-status term is
  normalized to `:stuck`; an exit/crash is recorded `:crashed` (mirrors
  `Kazi.Scheduler`'s reconciler seam, but keyed by group id).

  A 2-arity reconciler `(group_id, scheduler_pid) -> group_status` is ALSO
  accepted: it is additionally handed the SCHEDULER's pid so it can message the
  loop directly — notably `send(scheduler_pid, {:regress, dep_id, status})` to
  drive a regression (T23.4). The arity is detected at call time, so a plain
  1-arity stub is unaffected (backward compatible).
  """
  @type reconciler ::
          (Group.id() -> Scheduler.partition_status() | {:error, term()})
          | (Group.id(), pid() -> Scheduler.partition_status() | {:error, term()})

  @typedoc """
  One escalation of a blocked sub-DAG (T23.5, ADR-0028 §Decision 5): a blocking
  dep, its reason, and the dependents it poisoned.

    * `:blocker` — the id of the `:stuck`/`:over_budget`/`:blocked` dep that
      poisoned the sub-DAG;
    * `:reason`  — that blocker's terminal/blocking state (`:stuck` /
      `:over_budget` / `:blocked`);
    * `:blocked` — the ids of the dependents that can never run because of it, in
      declared order.

  The collective verdict carries one escalation per blocking dep, so a reader sees
  WHICH dep failed AND the WHOLE sub-DAG it stalled — not just a flat list to
  re-group by hand.
  """
  @type escalation :: %{
          blocker: Group.id(),
          reason: DepGraph.state(),
          blocked: [Group.id()]
        }

  @typedoc """
  The pipelined collective result:

    * `:collective` — the collective verdict over the per-group outcomes; a
      `:blocked` group folds in as non-converged (the collective stays non-green).
    * `:groups` — `{group_id, status}` per group in declared order. A dispatched
      group carries its terminal `t:Kazi.Scheduler.partition_status/0`; a group
      that never dispatched because a `needs` dep blocked it carries `:blocked`.
    * `:blocked` — the blocked entries (`Kazi.Goal.DepGraph.blocked_entry/0`),
      each naming the blocking dep and its reason.
    * `:escalations` — the blocked sub-DAG grouped by blocking dep
      (`t:escalation/0`): one entry per blocker, naming it, its reason, and the
      list of blocked dependents.
  """
  @type result :: %{
          collective: Scheduler.collective(),
          groups: [{Group.id(), DepGraph.state()}],
          blocked: [DepGraph.blocked_entry()],
          escalations: [escalation()]
        }

  @default_reconcile_timeout :infinity

  @doc """
  Runs a goal's `needs`-DAG to a COLLECTIVE verdict, topologically and PIPELINED.

  Dispatches only the ready set, runs ready groups concurrently under the
  partition `DynamicSupervisor`, re-evaluates the ready set as each group
  terminates (newly-eligible groups dispatch immediately, no barrier), surfaces
  blocked sub-DAGs naming their blocking dep, and folds the collective verdict
  over the per-group outcomes. Blocks until every group is terminal or blocked.

  ## Options

    * `:reconciler` — the injectable `t:reconciler/0` run per dispatched group
      (required for hermetic tests; production wraps the coordinator).
    * `:supervisor` — a running `Kazi.Scheduler.PartitionSupervisor` (pid/name).
      Defaults to the application-tree instance.
    * `:reconcile_timeout` — per-group terminal timeout (ms, or `:infinity`).
      Default `:infinity`. A group that does not terminate in time is `:stuck`.

  Returns `{:ok, result}` (see `t:result/0`) once every group is terminal or
  blocked, or `{:error, reason}` if the scheduler could not be started.
  """
  @spec run(Goal.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(%Goal{} = goal, opts) when is_list(opts) do
    reconciler = Keyword.fetch!(opts, :reconciler)
    supervisor = Keyword.get(opts, :supervisor, PartitionSupervisor)
    timeout = Keyword.get(opts, :reconcile_timeout, @default_reconcile_timeout)

    init_arg = %{
      goal: goal,
      reconciler: reconciler,
      supervisor: supervisor,
      timeout: timeout
    }

    case GenServer.start_link(__MODULE__, init_arg) do
      {:ok, scheduler} ->
        result = GenServer.call(scheduler, :await, await_call_timeout(timeout))
        GenServer.stop(scheduler)
        {:ok, result}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  True iff the goal declares any `needs` edge — i.e. its schedule is a non-trivial
  DAG that this scheduler must order. When false, the goal is fully parallel and
  the flat coordinator (`Kazi.Scheduler.run_goals/2`) suffices, so `run_goals/2`
  can route around this module entirely (the degenerate path).
  """
  @spec dag?(Goal.t()) :: boolean()
  def dag?(%Goal{groups: groups}) do
    Enum.any?(groups, fn %Group{needs: needs} -> needs != [] end)
  end

  # =============================================================================
  # GenServer (the pipelined loop)
  # =============================================================================

  @impl true
  def init(%{goal: goal} = arg) do
    %{reconciler: reconciler, supervisor: supervisor, timeout: timeout} = arg

    # Every group starts :pending (declared, unobserved). The states map is the
    # single source of truth the planner re-evaluates against each cycle.
    states = Map.new(goal.groups, fn %Group{id: id} -> {id, :pending} end)

    state = %{
      goal: goal,
      reconciler: reconciler,
      supervisor: supervisor,
      timeout: timeout,
      # The DepGraph-vocabulary state map the planner re-evaluates against (the
      # scheduler's `:crashed`/`:stopped` are NORMALIZED into it as `:stuck`,
      # since DepGraph's blocking vocabulary is `:stuck | :over_budget | :blocked`
      # — it "absorbs" crashed/stopped, T23.2 moduledoc).
      states: states,
      # group_id → its RAW reconciler terminal status (`:crashed`/`:stopped`
      # preserved), for the per-group result view. Distinct from `states`, which
      # carries the normalized planner vocabulary.
      outcomes: %{},
      # group_id → monitor ref for in-flight groups (so a {:DOWN, ...} resolves).
      running: %{},
      # ref → group_id, the reverse map for {:DOWN, ...}.
      ref_to_group: %{},
      awaiting: nil
    }

    # Dispatch the first frontier (the no-needs ready set) before awaiting, so the
    # population overlaps from the start.
    {:ok, dispatch_ready(state)}
  end

  @impl true
  def handle_call(:await, from, state) do
    case finished_result(state) do
      nil -> {:noreply, %{state | awaiting: from}}
      result -> {:reply, result, state}
    end
  end

  @impl true
  # A group's reconciler reported its terminal status. Record it into the states
  # map, then RE-EVALUATE: newly-ready groups dispatch immediately (pipelining).
  def handle_info({:group_done, group_id, status}, state) do
    state =
      state
      |> put_state(group_id, status)
      |> dispatch_ready()
      |> maybe_reply()

    {:noreply, state}
  end

  # A previously-:converged dep REGRESSED (T23.4, ADR-0028 §Decision 4): its
  # convergence became false again (the regression guard fired). Flip it back to a
  # non-converged state and RESET its transitive dependents that had become
  # ready/converged ON it to :pending, so they leave the ready set and re-converge.
  # Then re-evaluate: the regressed dep re-dispatches (it is :pending again) and,
  # once it re-converges, its dependents follow. A regress on a group that is not
  # currently :converged is a no-op (nothing to re-gate).
  def handle_info({:regress, group_id, status}, state) do
    state =
      if Map.get(state.states, group_id) == :converged do
        state
        |> regress(group_id, status)
        |> dispatch_ready()
        |> maybe_reply()
      else
        state
      end

    {:noreply, state}
  end

  # A group's reconciler process exited. If it already reported a terminal status
  # (normal exit after {:group_done, ...}), nothing to do; else an abnormal exit
  # with no recorded status is a crash → record :crashed (folds to :stuck) and
  # re-evaluate so the loop never hangs on a crashed group.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    state =
      case Map.get(state.ref_to_group, ref) do
        nil ->
          state

        group_id ->
          state = %{state | ref_to_group: Map.delete(state.ref_to_group, ref)}
          handle_down(state, group_id, reason)
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_down(state, group_id, reason) do
    if already_terminal?(state, group_id) do
      state
    else
      state
      |> put_state(group_id, down_status(reason))
      |> dispatch_ready()
      |> maybe_reply()
    end
  end

  # =============================================================================
  # The pipelined dispatch (re-evaluate the ready set, start the new frontier)
  # =============================================================================

  # Re-evaluate the planner against current state, mark every newly-ready group
  # :running, and start one supervised reconciler task per newly-ready group.
  # Groups already :running are NOT re-dispatched (the planner excludes them:
  # ready requires :pending). Blocked groups are flagged :blocked in-state so the
  # loop terminates instead of waiting on a dep that can never converge.
  defp dispatch_ready(state) do
    %{ready: ready, blocked: blocked} = DepGraph.evaluate(state.goal, state.states)

    # Mark every blocked group :blocked so finished_result/1 sees a terminal
    # state for it (it will never dispatch). Idempotent — re-marking is a no-op.
    state =
      Enum.reduce(blocked, state, fn %{group: id}, acc ->
        put_state(acc, id, :blocked)
      end)

    state =
      Enum.reduce(ready, state, fn group_id, acc ->
        start_group(acc, group_id)
      end)

    # Publish the post-transition DAG snapshot so the live dependency-DAG
    # dashboard (T23.7, ADR-0011) reflects the run as it progresses. This is the
    # one chokepoint every state change flows through (init + each terminal +
    # each regress), so a single broadcast here keeps the dashboard live. The
    # scheduler is the PRODUCER; the dashboard is a pure read-only consumer — it
    # never calls back in (ADR-0011 §2).
    broadcast_dag(state)
    state
  end

  # Best-effort publish of the render-ready DAG snapshot. The dashboard's PubSub
  # server is supervised only when the web tree boots (`Kazi.Application`); when
  # it isn't running (hermetic scheduler tests, the escript), this is a no-op
  # rather than a crash — mirrors `Kazi.ReadModel`'s broadcast guard.
  defp broadcast_dag(state) do
    if Process.whereis(Kazi.PubSub) do
      Phoenix.PubSub.broadcast(
        Kazi.PubSub,
        DagSnapshot.topic(),
        {:dag_updated, DagSnapshot.from(state.goal, state.states)}
      )
    end

    :ok
  end

  # Mark a group :running and start its supervised reconciler task. The task body
  # runs the (possibly stub) reconciler — contained — and sends the terminal
  # status back tagged with the group id; a {:DOWN, ...} confirms (or, on crash,
  # supplies) it. Siblings run concurrently (the DynamicSupervisor imposes no
  # ordering), so disjoint ready groups overlap.
  defp start_group(state, group_id) do
    coordinator = self()
    reconciler = state.reconciler
    timeout = state.timeout

    spec =
      Supervisor.child_spec(
        {Task, fn -> run_reconciler(coordinator, reconciler, group_id, timeout) end},
        restart: :temporary
      )

    {:ok, pid} = PartitionSupervisor.start_child(state.supervisor, spec)
    ref = Process.monitor(pid)

    %{
      state
      | states: Map.put(state.states, group_id, :running),
        running: Map.put(state.running, group_id, ref),
        ref_to_group: Map.put(state.ref_to_group, ref, group_id)
    }
  end

  # Run the injected reconciler, contained, and report the terminal status to the
  # scheduler tagged with the group id. A finite timeout bounds a wedged
  # reconciler; a crash or non-status return is normalized so the collective fold
  # is total. The reconciler runs in a nested Task purely so the timeout can
  # interrupt it without crashing this supervised child.
  defp run_reconciler(coordinator, reconciler, group_id, timeout) do
    status = invoke_reconciler(coordinator, reconciler, group_id, timeout)
    send(coordinator, {:group_done, group_id, status})
    status
  end

  # Invoke the (possibly stub) reconciler under a timeout. A 1-arity reconciler is
  # called `(group_id)` — the common case. A 2-arity reconciler is also handed the
  # SCHEDULER pid `(group_id, scheduler)` so it can message the loop directly —
  # notably to drive a regression hermetically (`send(scheduler, {:regress, dep,
  # status})`), the seam T23.4 exercises (mirrors `Kazi.Scheduler`'s arity-keyed
  # budget seam). Either way the return is the group's terminal status.
  defp invoke_reconciler(coordinator, reconciler, group_id, timeout) do
    task =
      Task.async(fn ->
        cond do
          is_function(reconciler, 2) -> reconciler.(group_id, coordinator)
          true -> reconciler.(group_id)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, status} -> normalize_status(status)
      nil -> :stuck
      {:exit, _reason} -> :crashed
    end
  end

  defp normalize_status(status)
       when status in [:converged, :stuck, :over_budget, :stopped, :crashed],
       do: status

  # A reconciler that returns an error (or any non-status term) did not converge;
  # the collective fold treats it as :stuck.
  defp normalize_status(_other), do: :stuck

  defp down_status(:normal), do: :stuck
  defp down_status(_abnormal), do: :crashed

  # =============================================================================
  # State + result
  # =============================================================================

  # Record a group's terminal outcome and drop its running entry. The RAW status
  # (`:crashed`/`:stopped` preserved) is stored under `outcomes` for the per-group
  # result; the planner-vocabulary NORMALIZED state (`:crashed`/`:stopped` →
  # `:stuck`) is stored under `states` so `DepGraph.evaluate/2` gates + blocks
  # correctly (its blocking vocabulary absorbs crashed/stopped into `:stuck`).
  defp put_state(state, group_id, observed) do
    ref = Map.get(state.running, group_id)

    %{
      state
      | states: Map.put(state.states, group_id, planner_state(observed)),
        outcomes: Map.put(state.outcomes, group_id, observed),
        running: Map.delete(state.running, group_id),
        ref_to_group: if(ref, do: Map.delete(state.ref_to_group, ref), else: state.ref_to_group)
    }
  end

  # Re-gate a regressed dep (T23.4). The dep itself flips from :converged to the
  # observed non-converged planner state (a regressed dep is FRESH WORK again, so
  # it is reset to :pending and re-dispatches; a regression INTO a terminal state —
  # :stuck/:over_budget — leaves it terminal and blocks dependents instead). Its
  # transitive dependents (DepGraph.dependents_of/2) that had reached a
  # non-:pending state are RESET to :pending so they leave the ready set and
  # re-converge once the dep does; their stale outcomes are dropped so the per-group
  # result reflects the RE-RUN, not the pre-regression convergence.
  defp regress(state, group_id, status) do
    state = regress_dep(state, group_id, status)

    Enum.reduce(DepGraph.dependents_of(state.goal, group_id), state, fn dependent, acc ->
      regate_dependent(acc, dependent)
    end)
  end

  # Flip the regressed dep out of :converged according to WHAT it regressed to:
  #
  #   * a still-convergeable regression (a `:pending`-like status, e.g. the loop
  #     went green→red but is still working) re-enters the dep as FRESH :pending
  #     work — it re-dispatches and re-converges, then its dependents follow;
  #   * a regression STRAIGHT INTO a non-converging terminal (:stuck / :over_budget
  #     / crash / stop) leaves the dep terminal — it is now the CAUSE of a blocked
  #     sub-DAG, so the raw outcome is recorded (it appears in the per-group result
  #     and names the sub-DAG it blocks) rather than dropped.
  defp regress_dep(state, _group_id, :converged), do: state

  defp regress_dep(state, group_id, :pending),
    do: reset_group(state, group_id, :pending)

  defp regress_dep(state, group_id, status),
    do: record_terminal(state, group_id, status)

  # Re-gate ONE transitive dependent of a regressed dep. A dependent that had
  # CONVERGED on the dep is reset to :pending so it leaves the ready set and
  # re-converges once the dep does (it must NOT stay green against a regressed
  # ancestor). A dependent still :running is left in flight — it has not converged,
  # so there is nothing to un-converge, and resetting it to :pending would
  # double-dispatch it; its in-flight result is reconciled against the
  # then-current state when it lands. A :pending / terminal-blocking dependent is
  # untouched.
  defp regate_dependent(state, dependent) do
    case Map.get(state.states, dependent) do
      :converged -> reset_group(state, dependent, :pending)
      _other -> state
    end
  end

  # Reset a group to fresh :pending work, dropping any stale outcome so a
  # re-dispatch starts clean (the per-group result reflects the RE-RUN, not the
  # pre-regression convergence). Only ever applied to :converged groups, which
  # carry no `running`/`ref_to_group` bookkeeping (cleared on their terminal), so
  # those maps need no update.
  defp reset_group(state, group_id, new_state) do
    %{
      state
      | states: Map.put(state.states, group_id, new_state),
        outcomes: Map.delete(state.outcomes, group_id)
    }
  end

  # A regressed dep that landed in a non-converging terminal: store its planner
  # state and RAW outcome so the per-group result reports it as the CAUSE (not
  # :blocked) of the sub-DAG it now blocks.
  defp record_terminal(state, group_id, status) do
    %{
      state
      | states: Map.put(state.states, group_id, planner_state(status)),
        outcomes: Map.put(state.outcomes, group_id, status)
    }
  end

  # Normalize a reconciler/scheduler terminal status into DepGraph's convergence
  # vocabulary (`:converged | :stuck | :over_budget | :blocked`): `:crashed` and
  # `:stopped` are non-converging terminals the planner treats as `:stuck`
  # (T23.2). `:converged`/`:over_budget`/`:blocked` pass through.
  defp planner_state(:converged), do: :converged
  defp planner_state(:over_budget), do: :over_budget
  defp planner_state(:blocked), do: :blocked
  defp planner_state(_other), do: :stuck

  defp already_terminal?(state, group_id) do
    Map.get(state.states, group_id) in [:converged, :stuck, :over_budget, :blocked]
  end

  defp maybe_reply(%{awaiting: nil} = state), do: state

  defp maybe_reply(%{awaiting: from} = state) do
    case finished_result(state) do
      nil ->
        state

      result ->
        GenServer.reply(from, result)
        %{state | awaiting: nil}
    end
  end

  # The result once EVERY group has reached a terminal/blocked state (none
  # :pending or :running). Until then nil — but a BLOCKED group is terminal, so a
  # poisoned sub-DAG never keeps the run waiting (it does NOT hang).
  defp finished_result(state) do
    if Enum.all?(state.goal.groups, fn %Group{id: id} -> settled?(state, id) end) do
      build_result(state)
    else
      nil
    end
  end

  # A group is settled once its PLANNER state is terminal/blocked (none
  # :pending/:running). A blocked group is settled, so a poisoned sub-DAG never
  # keeps the run waiting.
  defp settled?(state, group_id) do
    Map.get(state.states, group_id) in [:converged, :stuck, :over_budget, :blocked]
  end

  defp build_result(state) do
    # Per-group outcomes in DECLARED order. A dispatched group carries its RAW
    # terminal status (`:crashed`/`:stopped` preserved); a group that never
    # dispatched because a dep blocked it carries `:blocked`.
    groups =
      Enum.map(state.goal.groups, fn %Group{id: id} ->
        {id, group_outcome(state, id)}
      end)

    # The collective folds over the per-group outcomes; a :blocked group folds in
    # as non-converged (it never converged), keeping the collective non-green.
    statuses = Enum.map(groups, fn {_id, status} -> fold_status(status) end)

    blocked = DepGraph.blocked(state.goal, state.states)

    %{
      collective: Scheduler.collective_verdict(statuses),
      groups: groups,
      blocked: blocked,
      escalations: escalations(blocked)
    }
  end

  # T23.5: group the flat blocked entries BY their blocking dep into explicit
  # escalations — one `t:escalation/0` per blocker, naming it, its reason, and the
  # FULL list of blocked dependents it stalled. This is the collective verdict's
  # explicit escalation of each affected sub-DAG: a reader sees WHICH dep failed
  # and the WHOLE sub-DAG behind it, instead of re-grouping the flat list by hand.
  # Blockers are emitted in the order they first appear in the (declared-order)
  # blocked list; each blocker's dependents preserve that order.
  defp escalations(blocked) do
    {order, by_blocker} =
      Enum.reduce(blocked, {[], %{}}, fn %{group: group, blocked_by: blocker, reason: reason},
                                         {order, acc} ->
        case Map.get(acc, blocker) do
          nil ->
            {order ++ [blocker], Map.put(acc, blocker, %{reason: reason, blocked: [group]})}

          %{blocked: groups} = entry ->
            {order, Map.put(acc, blocker, %{entry | blocked: groups ++ [group]})}
        end
      end)

    Enum.map(order, fn blocker ->
      %{reason: reason, blocked: groups} = Map.fetch!(by_blocker, blocker)
      %{blocker: blocker, reason: reason, blocked: groups}
    end)
  end

  # The reported per-group outcome: the RAW reconciler status when the group was
  # dispatched, else `:blocked` (it was poisoned by a dep and never ran).
  defp group_outcome(state, group_id) do
    case Map.get(state.outcomes, group_id) do
      nil -> :blocked
      status -> status
    end
  end

  # Map a per-group terminal status to the partition-status vocabulary the
  # collective verdict folds over: :blocked is a non-converging terminal, so it
  # folds in as :stuck (the collective stays non-green when a sub-DAG is blocked).
  defp fold_status(:converged), do: :converged
  defp fold_status(:over_budget), do: :over_budget
  defp fold_status(:stopped), do: :stopped
  defp fold_status(:crashed), do: :crashed
  defp fold_status(_other), do: :stuck

  # The :await call timeout: generous beyond the per-group timeout so the
  # scheduler's own await never fires before a group's. Infinity stays infinity.
  defp await_call_timeout(:infinity), do: :infinity
  defp await_call_timeout(ms) when is_integer(ms), do: ms * 4 + 5_000
end
