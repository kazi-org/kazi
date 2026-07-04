defmodule Kazi.Scheduler do
  @moduledoc """
  The parallel **coordinator** over a partitioned goal-set (T21.1, ADR-0027) —
  the foundation of "kazi owns parallelization."

  ADR-0027 moves the scheduler INTO kazi: a `kazi run` over a partitioned
  goal-set partitions by blast radius, spawns **one supervised reconciler per
  partition** under a `DynamicSupervisor`, and drives them to COLLECTIVE
  convergence — codifying the operator's `/apply --pool` + `/claim` workflow into
  the product. On a single machine this is NATS-FREE: the in-memory lease
  (`Kazi.Coordination.Lease.Memory`) and a `DynamicSupervisor` coordinate N
  reconcilers in one BEAM.

  This module is the **coordinator skeleton**. Given a list of partitions and an
  injectable reconciler function, `run/2`:

    1. starts one supervised reconciler **per partition** under the
       `Kazi.Scheduler.PartitionSupervisor` `DynamicSupervisor`;
    2. runs them **concurrently** (each is its own supervised `Task`; a
       `DynamicSupervisor` imposes no ordering, so siblings overlap);
    3. **collects each terminal status**, then
    4. reports the **collective verdict**: every partition `:converged` ⇒
       `:converged`; any `:over_budget` ⇒ `:over_budget`; otherwise any `:stuck`
       (or `:stopped`/`:crashed`) ⇒ `:stuck` (see `collective_verdict/1`).

  ## Scope (skeleton only — ADR-0027 deepening is separate tasks)

  This is deliberately the SKELETON. It does NOT yet wire:

    * real `Kazi.Partition` blast-radius partitioning — T21.2;
    * real `Kazi.Coordination.PartitionLease` leases — T21.3;
    * git-worktree-per-partition isolation — T21.4;
    * collective integration / merge convergence — T21.5;
    * CLI / dashboard / supervision-restart surfaces — T21.8/T21.9/T21.10.

  It takes the **partition list** and a **reconciler function** as INPUTS so it is
  hermetically testable with STUB reconcilers (no real harness, no NATS). The
  reconciler default is the real per-goal runtime (`reconcile_partition/2` →
  `Kazi.Runtime.run/2`), so production wiring (T21.5) injects nothing; tests
  inject a stub that returns a chosen terminal status.

  ## The injectable reconciler seam

  A reconciler is a `t:reconciler/0`: a 1-arity function `partition ->
  partition_status`, run in its own supervised process per partition. It returns
  one of the terminal partition statuses (`t:partition_status/0`) or
  `{:error, reason}`; an exit/crash is recorded as `:crashed` (the coordinator
  survives — `:one_for_one`). The default reconciler drives the existing serial
  loop for the partition's goal via `Kazi.Runtime.run/2` and normalizes the loop
  result to a partition status, so a single-partition set behaves exactly like
  today's serial run.

  ## Collective verdict (the heart of the skeleton)

  The collective verdict is a pure fold over the per-partition statuses
  (`collective_verdict/1`), order-independent and total:

    * **all `:converged`** ⇒ `:converged` (collective success);
    * **any `:over_budget`** ⇒ `:over_budget` (a hard ceiling was hit somewhere —
      surfaced first because it is the most actionable "we spent the budget" signal);
    * **otherwise any `:stuck` / `:stopped` / `:crashed` / error** ⇒ `:stuck` (the
      run did not collectively converge and needs escalation).

  An empty partition list collectively converges vacuously (nothing failed); a
  SINGLE partition's verdict is exactly that partition's status, so a one-partition
  goal-set degenerates to the serial single-goal outcome.
  """

  use GenServer

  alias Kazi.Scheduler.{PartitionSupervisor, Worktree}

  @typedoc """
  The terminal status of one partition's reconciler (the unit the collective
  verdict folds over). Mirrors the loop's terminal outcomes (ADR-0027 / `Kazi.Loop`):

    * `:converged`   — the partition's goal reached convergence;
    * `:stuck`       — the reconciler gave up without converging (the loop's
      `:stopped`/`:stuck` escalation);
    * `:over_budget` — a hard budget ceiling was hit;
    * `:stopped`     — an operator stop short of convergence;
    * `:crashed`     — the reconciler process exited abnormally (isolated by the
      `DynamicSupervisor`; folds into the collective `:stuck` verdict).
  """
  @type partition_status :: :converged | :stuck | :over_budget | :stopped | :crashed

  @typedoc """
  The COLLECTIVE verdict over all partitions: `:converged` only when every
  partition converged; `:over_budget` when any hit a budget ceiling; `:stuck`
  otherwise (some partition did not converge).
  """
  @type collective :: :converged | :stuck | :over_budget

  @typedoc """
  A partition to reconcile. The skeleton is partition-shape-agnostic: any term
  the injected reconciler understands (a `Kazi.Partition` in production wiring,
  a stub tuple in tests). It is passed through verbatim to the reconciler.
  """
  @type partition :: term()

  @typedoc """
  The injectable reconciler seam: a 1-arity fn `partition -> partition_status`,
  run in its own supervised process per partition. Returning anything other than
  a `t:partition_status/0` (e.g. `{:error, reason}`) is normalized to `:stuck` in
  the collective fold; an exit/crash is recorded `:crashed`.
  """
  @type reconciler :: (partition() -> partition_status() | {:error, term()})

  @typedoc """
  The collective run result:

    * `:collective`  — the collective verdict (`t:collective/0`);
    * `:partitions`  — one `{partition, partition_status}` per input partition,
      in input order (a single-partition list yields exactly that partition's
      status — the serial degenerate case).

  `run_goals/2` may additionally carry (additive, present only when opted into):

    * `:integration`       — the `Kazi.Scheduler.Integration.result/0` (when
      `:integrate` was supplied, T21.5);
    * `:budget_spent`      — the COLLECTIVE derived spend rollup (the dimension-wise
      SUM across partitions) when a `:budget` was split (T21.7);
    * `:partitions_budget` — one `{partition, status, spent}` per partition (its
      share's actual spend) when a `:budget` was split (T21.7).
  """
  @type result :: %{
          :collective => collective(),
          :partitions => [{partition(), partition_status()}],
          optional(:integration) => Kazi.Scheduler.Integration.result(),
          optional(:budget_spent) => Kazi.Scheduler.Budget.spent(),
          optional(:partitions_budget) => [
            {partition(), partition_status(), Kazi.Scheduler.Budget.spent()}
          ]
        }

  # The default per-partition reconcile timeout. Production runs are long; the
  # default is generous and overridable via the `:reconcile_timeout` opt (tests
  # pass a short, deterministic value).
  @default_reconcile_timeout :infinity

  # The default per-partition RESTART budget (T21.10, ADR-0027): how many times a
  # crashed partition reconciler is re-spawned before the partition ESCALATES to
  # `:crashed` (a hard, contained failure that folds into the collective `:stuck`
  # verdict). Default 0 — a crash escalates immediately, the pre-T21.10 behavior —
  # so existing `run/2` callers (and the CLI via `run_goals/2`) are unchanged
  # unless they opt into restarts with `:max_restarts`. A restart re-runs the SAME
  # injectable reconciler on the SAME partition; the `try/after` lease+worktree
  # cleanup (T21.3/T21.4) already ran as the crashed child unwound, so a restart
  # never inherits a dangling lease or leaked worktree.
  @default_max_restarts 0

  @doc """
  Runs the partitioned goal-set to a COLLECTIVE verdict and returns the result.

  Starts one supervised reconciler per partition under the (instance) partition
  `DynamicSupervisor`, runs them CONCURRENTLY, collects each terminal status, and
  reports the collective verdict (`collective_verdict/1`). Blocks until every
  partition reaches a terminal state (or `:reconcile_timeout` elapses).

  ## Options

    * `:reconciler` — the injectable `t:reconciler/0` run per partition. Defaults
      to `reconcile_partition/2` over `Kazi.Runtime.run/2` (the real serial
      per-goal loop) — production injects nothing; tests inject a stub returning a
      chosen status.
    * `:supervisor` — a running `Kazi.Scheduler.PartitionSupervisor` (pid or
      name). Defaults to the application-tree instance
      (`Kazi.Scheduler.PartitionSupervisor`). Tests pass an isolated instance so
      runs never contend on one global tree.
    * `:reconcile_timeout` — per-partition terminal timeout (ms, or `:infinity`).
      Default `:infinity`. A partition that does not terminate in time is recorded
      `:stuck` (the run never blocks forever on a wedged reconciler when a finite
      timeout is set).
    * `:run_opts` — keyword opts forwarded to the default reconciler's
      `Kazi.Runtime.run/2` (ignored when a custom `:reconciler` is injected).
    * `:max_restarts` — per-partition RESTART budget (T21.10, ADR-0027): how many
      times a CRASHED reconciler is re-spawned before the partition escalates to
      `:crashed`. Default `0` (a crash escalates immediately — the pre-T21.10
      behavior). A restart re-runs the same reconciler on the same partition. An
      ORDINARY raise's `try/after` lease + worktree cleanup already ran as it
      unwound; an untrappable `Process.exit(pid, :kill)` does NOT (M8,
      deep-review-001) — the lease backend auto-releases on the holder process's
      `:DOWN` regardless, and the coordinator finishes any leftover worktree
      cleanup itself, so a restart never inherits dangling lease/worktree state
      either way. The coordinator survives every child crash regardless of this
      budget (`:one_for_one`).

  Returns `{:ok, result}` (see `t:result/0`) once every partition is terminal, or
  `{:error, reason}` if the coordinator could not be started.
  """
  @spec run([partition()], keyword()) :: {:ok, result()} | {:error, term()}
  def run(partitions, opts \\ []) when is_list(partitions) and is_list(opts) do
    reconciler = Keyword.get(opts, :reconciler, default_reconciler(opts))
    supervisor = Keyword.get(opts, :supervisor, PartitionSupervisor)
    timeout = Keyword.get(opts, :reconcile_timeout, @default_reconcile_timeout)
    max_restarts = Keyword.get(opts, :max_restarts, @default_max_restarts)

    init_arg = %{
      partitions: partitions,
      reconciler: reconciler,
      supervisor: supervisor,
      timeout: timeout,
      max_restarts: max_restarts
    }

    case GenServer.start_link(__MODULE__, init_arg) do
      {:ok, coordinator} ->
        await_coordinator(coordinator, await_call_timeout(timeout, max_restarts))

      {:error, _reason} = error ->
        error
    end
  end

  # M7 (deep-review-001): a wedged/restarting partition's worst-case wall time is
  # `(max_restarts + 1) * reconcile_timeout` (the per-attempt timeout applies to
  # EACH restart attempt), so the coordinator's own `:await` must outlive that,
  # not just one attempt's timeout. Wrapped in try/catch :exit so a genuinely
  # unreachable coordinator (or a bound that still proves too tight) reports a
  # structured `{:error, :await_timeout}` verdict instead of crashing the whole
  # `run/2` caller with an uncaught `exit(:timeout)`.
  defp await_coordinator(coordinator, await_timeout) do
    result = GenServer.call(coordinator, :await, await_timeout)
    GenServer.stop(coordinator)
    {:ok, result}
  catch
    :exit, reason ->
      # The coordinator may still be alive (a call timeout is not a coordinator
      # crash) — kill it defensively so it never leaks past this run. `:kill` is
      # untrappable and never blocks, unlike `GenServer.stop/1` which could itself
      # hang against a genuinely wedged coordinator.
      if Process.alive?(coordinator), do: Process.exit(coordinator, :kill)
      {:error, {:await_timeout, reason}}
  end

  @doc """
  Runs a GOAL-SET to a COLLECTIVE verdict, partitioning by blast radius and
  bracketing each partition with its lease + isolated worktree (T21.2/T21.3/T21.4,
  ADR-0027).

  This is the production on-ramp over `run/2`: instead of pre-built partitions and
  a bare reconciler, it takes the raw `goals` and a `workspace`, then:

    1. **partitions** the goals by blast radius
       (`Kazi.Scheduler.Partitioner.partition/3` over the injected `:graph_source`)
       into DISJOINT partitions — a single goal / no graph degenerates to one
       partition, exactly today's serial run (T21.2);
    2. wraps the inner reconciler so each partition **acquires its
       `PartitionLease` on start and releases on terminal** — including on crash —
       with residual overlap SERIALIZING on the lease (T21.3); the in-memory
       backend is the single-node default (NATS is config-selected, not required);
    3. wraps it again so each partition runs in its **own git worktree**, created
       on start and removed on terminal incl. crash, guard-safe (T21.4);
    4. hands the composed per-partition reconciler to `run/2`, which supervises
       one per partition and folds the collective verdict.

  The wrappers compose lease-OUTSIDE-worktree: a partition waiting on a contended
  lease does not create its worktree until it actually holds the lease.

  ## Options

    * `:workspace` — the target repo the goals are partitioned against AND the git
      repo worktrees branch from (required).
    * `:graph_source` — forwarded to the partitioner for a hermetic run (a test
      injects `Kazi.Context.StaticGraphSource`).
    * `:reconciler` — the INNER reconciler, a 2-arity
      `(t:Kazi.Scheduler.Partitioner.t/0, worktree_path) -> partition_status`.
      Production injects nothing (defaults to the real per-goal loop over the
      partition's goals in its worktree); tests inject a stub.
    * `:lease` — keyword opts for `Kazi.Scheduler.LeasedReconciler.wrap/2`
      (notably `:backend` and `:lease_opts` with the in-memory `:store`). When
      omitted, leasing is skipped (a degenerate single-partition run needs no
      lease); supply it to bracket partitions with leases.
    * `:worktree` — keyword opts for `Kazi.Scheduler.Worktree.wrap/2` (notably
      `:repo`, defaulting to `:workspace`). When omitted, worktree isolation is
      skipped (the inner reconciler is handed the workspace path directly).
    * `:max_restarts` — per-partition crash restart budget (T21.10) forwarded to
      `run/2`. Default `0` (a crashed partition escalates immediately).
    * `:budget` — OPT-IN per-partition budgets (T21.7, ADR-0027 step 3). When a
      `Kazi.Budget` is supplied, the goal budget is SPLIT across the partitions
      (`Kazi.Scheduler.Budget.split/2` — derived shares that sum back to the
      whole) and each partition runs under its SHARE. A partition that exhausts
      its share reports `:over_budget` and ESCALATES without aborting its
      siblings (each is its own supervised task), so the collective verdict
      reflects per-partition outcomes. The result then carries `:budget_spent`
      (the collective derived rollup — the SUM of per-partition spend) and
      `:partitions_budget` (each `{partition, status, spent}`). When omitted, no
      split happens and the result shape is unchanged (backward-compatible).
    * `:integrate` — OPT-IN collective integration (T21.5, ADR-0027 step 4). When
      supplied (a keyword list of `Kazi.Scheduler.Integration.integrate/2` opts —
      notably `:integrator`, `:base`, `:max_attempts`, `:redispatcher`), the
      CONVERGED partitions are integrated into the shared base in a safe order
      AFTER reconcile, residual cross-partition conflicts re-dispatch the affected
      partition, and the collective is green ONLY when the merged whole is. The
      result then carries an `:integration` key (`t:Kazi.Scheduler.Integration.result/0`)
      and `:collective` reflects the INTEGRATED verdict (a clean reconcile that
      fails to merge is `:stuck`). When omitted, `run_goals/2` returns exactly
      `run/2`'s result (the pre-T21.5 behavior — backward-compatible for the CLI,
      T21.8).
    * `:supervisor`, `:reconcile_timeout` — forwarded to `run/2`.

  Returns `run/2`'s result, but each `result.partitions` entry is keyed by the
  `Kazi.Scheduler.Partitioner` partition (not a bare term). With `:integrate`, the
  result additionally carries `:integration` and a collective verdict that
  accounts for the merge.
  """
  @spec run_goals([Kazi.Goal.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def run_goals(goals, opts) when is_list(goals) and is_list(opts) do
    # T23.3 (ADR-0028): when a SINGLE goal carries a non-trivial `needs`-DAG over
    # its groups, route to the topological + pipelined `DepScheduler` — dispatch
    # only the ready set, re-evaluate as groups converge, surface blocked
    # sub-DAGs. When NO group declares `needs` (or the set is not a single
    # DAG-bearing goal), fall through to the EXACT pre-T23.3 flat parallel path
    # (`run_goals_flat/2`) — backward compatible; the T21.8 CLI is unaffected.
    case dag_goal(goals) do
      {:ok, goal} -> run_goal_dag(goal, opts)
      :flat -> run_goals_flat(goals, opts)
    end
  end

  # Route to the GROUP scheduler (`DepScheduler`) when the goal-set is EXACTLY one
  # goal whose predicates are organized into groups — either a non-trivial
  # `needs`-DAG (some group declares an edge) OR 2+ independent groups with no
  # edges. The latter is still GROUP-PARALLEL: with no `needs`, `DepScheduler`
  # dispatches every group in ONE frontier (fully parallel, the ADR-0027 default),
  # so disjoint groups run concurrently instead of collapsing into one serial
  # partition (the partition unit for a single bare goal is the whole goal, so the
  # flat path would otherwise yield exactly one partition — the group-collapse bug).
  #
  # Anything else — many goals, or a goal with no/one group — is `:flat`. The
  # 2+-group route is GUARDED so nothing is dropped: it triggers only when every
  # acceptance predicate carries a declared group (`group_parallel?/1`), since the
  # per-group sub-goal split keeps only each group's predicates (guards, which may
  # be ungrouped, are replicated to every group's sub-goal). A goal with ungrouped
  # acceptance predicates stays flat so those predicates are never lost.
  defp dag_goal([%Kazi.Goal{} = goal]) do
    cond do
      Kazi.Scheduler.DepScheduler.dag?(goal) -> {:ok, goal}
      group_parallel?(goal) -> {:ok, goal}
      true -> :flat
    end
  end

  defp dag_goal(_goals), do: :flat

  # True when a single goal's acceptance predicates are fully organized into 2+
  # groups (no edges required): its disjoint groups should run in parallel, so it
  # routes through the group scheduler. Requires every acceptance predicate to
  # carry a declared group so the per-group sub-goal split (which keeps only that
  # group's predicates) loses nothing; an ungrouped acceptance predicate forces the
  # flat path. Guards may be ungrouped — they are replicated into every sub-goal.
  defp group_parallel?(%Kazi.Goal{groups: groups, predicates: predicates}) do
    length(groups) >= 2 and predicates != [] and
      Enum.all?(predicates, fn %Kazi.Predicate{group: group} -> group != nil end)
  end

  # Drive a single goal's `needs`-DAG topologically + pipelined (ADR-0028). Each
  # READY group is reconciled by a GROUP reconciler; the default reconciles the
  # group's predicate SUB-GOAL through the flat partition path (so a group is
  # still spatially partitioned + leased + worktree-isolated like any goal), and
  # the `DepScheduler` orders the groups by `needs`, re-evaluating as each
  # converges. Tests inject a `:group_reconciler` stub to drive convergence
  # hermetically. The result is the `DepScheduler` per-group result.
  defp run_goal_dag(goal, opts) do
    group_reconciler =
      Keyword.get_lazy(opts, :group_reconciler, fn ->
        default_group_reconciler(goal, opts)
      end)

    dep_opts =
      opts
      |> Keyword.take([:supervisor, :reconcile_timeout])
      |> Keyword.put(:reconciler, group_reconciler)

    Kazi.Scheduler.DepScheduler.run(goal, dep_opts)
  end

  # The default GROUP reconciler (production): reconcile one group by running its
  # predicate SUB-GOAL — the parent goal restricted to the predicates that
  # declare this group — through the flat `run_goals_flat/2` path, so the group's
  # work is still blast-radius partitioned, leased, and worktree-isolated. The
  # sub-goal carries NO `needs` (a single group is a leaf), so it takes the flat
  # path and never recurses into the DAG router. The group's collective verdict
  # becomes its node status in the `needs`-DAG.
  defp default_group_reconciler(goal, opts) do
    flat_opts = Keyword.drop(opts, [:group_reconciler, :reconciler])

    fn group_id ->
      sub_goal = group_subgoal(goal, group_id)

      case run_goals_flat([sub_goal], flat_opts) do
        {:ok, %{collective: collective}} -> collective
        {:error, _reason} -> :stuck
      end
    end
  end

  # Build the predicate SUB-GOAL for a group: the parent goal with its predicates
  # (and guards) restricted to those declaring `group_id`. Guards are kept (they
  # are invariants the group's work must not regress); the sub-goal keeps the
  # parent's budget/scope/harness so the group runs under the same envelope.
  defp group_subgoal(%Kazi.Goal{} = goal, group_id) do
    %Kazi.Goal{
      goal
      | id: "#{goal.id}::#{group_id}",
        predicates: Enum.filter(goal.predicates, &(&1.group == group_id)),
        guards: Enum.filter(goal.guards, &(&1.group in [group_id, nil])),
        groups: []
    }
  end

  defp run_goals_flat(goals, opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    partition_opts = Keyword.take(opts, [:graph_source])

    partitions = Kazi.Scheduler.Partitioner.partition(goals, workspace, partition_opts)

    # T21.7: the DEFAULT inner is budget-aware (3-arity) when a `:budget` is
    # supplied, so the share reaches the real loop; otherwise the pre-T21.7
    # 2-arity default. A custom `:reconciler` is used as-is (its arity decides
    # whether it sees the share — a 2-arity stub simply ignores budgets).
    inner =
      Keyword.get_lazy(opts, :reconciler, fn ->
        if Keyword.has_key?(opts, :budget) do
          default_goal_reconciler_budgeted(opts)
        else
          default_goal_reconciler(opts)
        end
      end)

    # T21.7: when a `:budget` is supplied, split it across the partitions and
    # bracket the inner reconciler so each partition runs under its SHARE and
    # records its spend; `budget_ctx` carries the per-partition shares + the spend
    # accumulator the rollup reads after `run/2`. Returns `nil` when no `:budget`
    # is given (the budget-unaware path, backward-compatible).
    {inner, budget_ctx} = maybe_split_budget(inner, partitions, opts)

    reconciler = compose_reconciler(inner, workspace, opts)

    run_opts =
      opts
      |> Keyword.take([:supervisor, :reconcile_timeout, :max_restarts])
      |> Keyword.put(:reconciler, reconciler)

    case run(partitions, run_opts) do
      {:ok, result} ->
        result
        |> maybe_rollup_budget(budget_ctx)
        |> maybe_integrate(opts)

      {:error, _} = error ->
        # `maybe_rollup_budget/2` is the only path that stops the per-run spend
        # Agent; on this error path `run/2` never returns a result to route
        # through it, so stop it here too rather than leaking it until the
        # (short-lived CLI) caller dies (deep review L9).
        stop_budget_agent(budget_ctx)
        error
    end
  end

  defp stop_budget_agent(nil), do: :ok
  defp stop_budget_agent(%{spent: spent}), do: Agent.stop(spent)

  # T21.7: split a goal `:budget` across the partitions (derived shares) and wrap
  # the inner reconciler so each partition runs under its share and records its
  # spend. Returns `{wrapped_inner, budget_ctx}`, or `{inner, nil}` when no
  # `:budget` was supplied (the budget-unaware path is untouched — backward
  # compatible).
  #
  # Each partition is assigned a share BY IDENTITY (its stable lease `:key`), so a
  # partition reconciled (and re-dispatched) more than once keeps the same share.
  # The inner is handed its share under `run_opts[:budget]` and a `report_spent`
  # seam; the spend it reports is accumulated per key for the rollup.
  defp maybe_split_budget(inner, partitions, opts) do
    case Keyword.get(opts, :budget) do
      nil ->
        {inner, nil}

      %Kazi.Budget{} = budget ->
        n = max(length(partitions), 1)
        shares = Kazi.Scheduler.Budget.split(budget, n)

        # key → share, so the wrapper assigns each partition its own share.
        share_by_key =
          partitions
          |> Enum.zip(shares)
          |> Map.new(fn {partition, share} -> {partition.key, share} end)

        {:ok, spent} = Agent.start_link(fn -> %{} end)

        wrapped = budget_aware_inner(inner, share_by_key, spent)

        {wrapped, %{shares: share_by_key, spent: spent}}
    end
  end

  # Wrap the inner reconciler so each partition runs under its budget SHARE and
  # records its spend, WITHOUT mutating the partition struct (the worktree +
  # integration layers pattern-match the `Kazi.Scheduler.Partitioner` shape).
  #
  # The budget + a `report_spent/1` seam are threaded by ARITY: a budget-aware
  # inner takes `(partition, worktree, budget)` where `budget` is a
  # `t:budget_share/0` (`%{budget: share, report_spent: fn}`); a budget-UNAWARE
  # 2-arity inner (a plain test stub, or the pre-T21.7 default) is called as
  # `(partition, worktree)` and simply never sees its share. The default goal
  # reconciler is 3-arity and threads the share into `Kazi.Runtime.run/2`.
  defp budget_aware_inner(inner, share_by_key, spent) do
    fn partition, worktree ->
      share = Map.get(share_by_key, partition.key)

      report_spent = fn used when is_map(used) ->
        Agent.update(spent, fn acc ->
          Map.update(acc, partition.key, used, &Kazi.Scheduler.Budget.rollup([&1, used]))
        end)
      end

      budget = %{budget: share, report_spent: report_spent}

      cond do
        is_function(inner, 3) -> inner.(partition, worktree, budget)
        true -> inner.(partition, worktree)
      end
    end
  end

  # T21.7 rollup: after `run/2`, attach per-partition `:budget_spent` (keyed like
  # `result.partitions`) and the collective `:budget_spent` (the derived SUM) to
  # the result. A no-op when no budget was split (`budget_ctx == nil`), keeping the
  # result shape unchanged for budget-unaware runs.
  defp maybe_rollup_budget(result, nil), do: result

  defp maybe_rollup_budget(result, %{spent: spent}) do
    by_key = Agent.get(spent, & &1)
    Agent.stop(spent)

    per_partition =
      Enum.map(result.partitions, fn {partition, status} ->
        used = Map.get(by_key, partition.key, %{})
        {partition, status, Kazi.Scheduler.Budget.rollup([used])}
      end)

    collective_spent =
      per_partition
      |> Enum.map(fn {_p, _s, used} -> used end)
      |> Kazi.Scheduler.Budget.rollup()

    Map.merge(result, %{
      budget_spent: collective_spent,
      partitions_budget: per_partition
    })
  end

  # T21.5: when `:integrate` is supplied, run collective integration over the
  # CONVERGED partitions and fold the merge verdict into the collective; otherwise
  # return `run/2`'s result unchanged (backward-compatible). Only partitions that
  # actually converged are integrated — a partition that did not converge has
  # nothing to merge, and the collective is already non-green.
  defp maybe_integrate(result, opts) do
    case Keyword.get(opts, :integrate) do
      nil ->
        {:ok, result}

      integrate_opts when is_list(integrate_opts) ->
        converged =
          for {partition, :converged} <- result.partitions, do: partition

        {:ok, integration} = Kazi.Scheduler.Integration.integrate(converged, integrate_opts)

        # The collective is green ONLY when reconcile converged everywhere AND the
        # merged whole is green. A reconcile-stuck partition keeps the collective
        # non-green; a clean reconcile that fails to merge downgrades to :stuck.
        collective =
          case {result.collective, integration.collective} do
            {:converged, :converged} -> :converged
            {:converged, :stuck} -> :stuck
            {other, _} -> other
          end

        {:ok, Map.merge(result, %{collective: collective, integration: integration})}
    end
  end

  # Compose the per-partition reconciler chain: lease (outer) → worktree (inner) →
  # the supplied 2-arity reconciler. Each wrapper is OPTIONAL — omitting its opts
  # skips that layer — so a degenerate single-partition run can run with neither
  # lease nor worktree, exactly like today's serial path.
  defp compose_reconciler(inner, workspace, opts) do
    worktree_opts = Keyword.get(opts, :worktree)
    lease_opts = Keyword.get(opts, :lease)

    # Worktree layer: a 1-arity `partition -> status` over the 2-arity inner. When
    # no worktree opts are given, the inner is handed the workspace path directly
    # (no isolation), preserving the 2-arity contract.
    worktree_reconciler =
      case worktree_opts do
        nil ->
          fn partition -> inner.(partition, workspace) end

        wt_opts ->
          wt_opts = Keyword.put_new(wt_opts, :repo, workspace)
          Kazi.Scheduler.Worktree.wrap(inner, wt_opts)
      end

    # Lease layer (outermost): brackets the worktree+reconcile in the partition's
    # lease so overlap serializes BEFORE a worktree is created.
    case lease_opts do
      nil -> worktree_reconciler
      l_opts -> Kazi.Scheduler.LeasedReconciler.wrap(worktree_reconciler, l_opts)
    end
  end

  # The default INNER reconciler for run_goals/2: run each of the partition's
  # goals' serial loop in the partition's worktree, collapsing to one partition
  # status. T21.5 deepens cross-goal integration; the skeleton runs the member
  # goals and folds their statuses with the same collective rule.
  # The 2-arity (budget-unaware) default: run each goal under the shared run_opts.
  # Unchanged from the pre-T21.7 path. The budget-aware variant
  # (`default_goal_reconciler_budgeted/1`) is selected by `maybe_split_budget/3`
  # only when a `:budget` is supplied.
  defp default_goal_reconciler(opts) do
    run_opts = Keyword.get(opts, :run_opts, [])

    fn %Kazi.Scheduler.Partitioner{goals: goals}, worktree_path ->
      run_partition_goals(goals, run_opts, worktree_path)
    end
  end

  # The 3-arity (budget-aware) default, T21.7: the partition's budget SHARE
  # overrides the goal's own budget for this run (so the partition is bounded by
  # its share), and the loop's terminal usage is reported back via `report_spent`
  # so the rollup sums it into the collective spend.
  defp default_goal_reconciler_budgeted(opts) do
    run_opts = Keyword.get(opts, :run_opts, [])

    fn %Kazi.Scheduler.Partitioner{goals: goals},
       worktree_path,
       %{
         budget: share,
         report_spent: report_spent
       } ->
      goal_run_opts =
        case share do
          %Kazi.Budget{} -> Keyword.put(run_opts, :budget, share)
          nil -> run_opts
        end

      {status, spent} = run_partition_goals_with_spend(goals, goal_run_opts, worktree_path)
      report_spent.(spent)
      status
    end
  end

  # Run a partition's member goals' serial loops in its worktree, folding their
  # statuses with the collective rule (no spend tracking — the budget-unaware path).
  defp run_partition_goals(goals, run_opts, worktree_path) do
    statuses =
      Enum.map(goals, fn goal ->
        reconcile_partition(%{goal: goal}, Keyword.put(run_opts, :workspace, worktree_path))
      end)

    collective_verdict(statuses)
  end

  # As `run_partition_goals/3`, but also accumulate the loops' terminal budget
  # usage so the partition can report its spend (T21.7 rollup). Returns
  # `{partition_status, spent}`.
  defp run_partition_goals_with_spend(goals, run_opts, worktree_path) do
    {statuses, spents} =
      goals
      |> Enum.map(fn goal ->
        opts = Keyword.put(run_opts, :workspace, worktree_path)
        reconcile_partition_with_spend(%{goal: goal}, opts)
      end)
      |> Enum.unzip()

    {collective_verdict(statuses), Kazi.Scheduler.Budget.rollup(spents)}
  end

  @doc """
  Folds the per-partition statuses into the COLLECTIVE verdict (a pure function).

  Order-independent and total:

    * every status `:converged` ⇒ `:converged` (including the empty list — nothing
      failed, vacuous success);
    * any `:over_budget` ⇒ `:over_budget`;
    * otherwise (any `:stuck` / `:stopped` / `:crashed` / non-status) ⇒ `:stuck`.

  A SINGLE-element list returns exactly that partition's collective mapping, so a
  one-partition goal-set degenerates to the serial single-goal verdict.

  ## Examples

      iex> Kazi.Scheduler.collective_verdict([:converged, :converged])
      :converged
      iex> Kazi.Scheduler.collective_verdict([:converged, :over_budget, :stuck])
      :over_budget
      iex> Kazi.Scheduler.collective_verdict([:converged, :stuck])
      :stuck
      iex> Kazi.Scheduler.collective_verdict([])
      :converged
  """
  @spec collective_verdict([partition_status()]) :: collective()
  def collective_verdict(statuses) when is_list(statuses) do
    cond do
      Enum.any?(statuses, &(&1 == :over_budget)) -> :over_budget
      Enum.all?(statuses, &(&1 == :converged)) -> :converged
      true -> :stuck
    end
  end

  # =============================================================================
  # GenServer (the coordinator)
  # =============================================================================

  @impl true
  def init(%{partitions: partitions} = arg) do
    %{reconciler: reconciler, supervisor: supervisor, timeout: timeout} = arg
    max_restarts = Map.get(arg, :max_restarts, @default_max_restarts)

    # Start one supervised reconciler per partition under the DynamicSupervisor
    # BEFORE awaiting any of them, so the population overlaps — a serial-only
    # design would deadlock a stub that waits on a sibling. Each task is keyed by
    # a stable SLOT id (so a restart of the same partition keeps its position in
    # `order` and result), and its body sends {:partition_done, slot, status} on
    # completion; a {:DOWN, ref, ...} confirms (or, on a crash, supplies) its
    # terminal status. `order` preserves input order for the result.
    slots =
      partitions
      |> Enum.with_index()
      |> Enum.map(fn {partition, slot} ->
        task = start_partition_task(supervisor, partition, reconciler, timeout, slot)
        Map.put(task, :restarts_left, max_restarts)
      end)

    state = %{
      supervisor: supervisor,
      reconciler: reconciler,
      timeout: timeout,
      # tasks keyed by SLOT id; each carries its current monitor ref + restart budget.
      tasks: Map.new(slots, fn task -> {task.slot, task} end),
      # ref → slot, so a {:DOWN, ref, ...} resolves to the slot it belongs to.
      ref_to_slot: Map.new(slots, fn task -> {task.ref, task.slot} end),
      order: Enum.map(slots, & &1.slot),
      collected: %{},
      awaiting: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:await, from, state) do
    case finished_result(state) do
      nil -> {:noreply, %{state | awaiting: from}}
      result -> {:reply, result, state}
    end
  end

  @impl true
  # A reconciler reports its terminal status here (its Task body sends this before
  # returning, tagged with its SLOT). We record it; the matching {:DOWN, ...} then
  # drops the monitor.
  def handle_info({:partition_done, slot, status}, state) do
    {:noreply, collect(state, slot, status)}
  end

  # A reconciler process exited. We resolve the ref to its slot:
  #
  #   * if the slot already has a collected status (a normal exit after it reported
  #     via {:partition_done, ...}), nothing to do;
  #   * else an abnormal exit with no recorded status is a CRASH. An ORDINARY raise
  #     runs its try/after during unwind (lease + worktree cleanup already ran); an
  #     untrappable Process.exit(pid, :kill) does NOT (M8, deep-review-001) — that
  #     signal kills the whole linked reconcile chain together, so THIS is the only
  #     surviving process that can finish that cleanup (`reap_leftover_worktree/2`).
  #     If the slot has RESTART budget left (T21.10), re-spawn the SAME reconciler
  #     on the SAME partition, decrementing the budget; otherwise escalate to
  #     :crashed so the collective fold accounts for it.
  #
  # The coordinator survives every child crash (it traps nothing — the child runs
  # under the DynamicSupervisor :one_for_one and we only hold a monitor).
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    state =
      case Map.get(state.ref_to_slot, ref) do
        nil ->
          state

        slot ->
          state = %{state | ref_to_slot: Map.delete(state.ref_to_slot, ref)}
          handle_down(state, slot, reason)
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # A monitored child went DOWN. If its slot already reported a terminal status,
  # ignore. A crash with budget left restarts; a crash with no budget escalates to
  # :crashed.
  defp handle_down(state, slot, reason) do
    cond do
      Map.has_key?(state.collected, slot) ->
        state

      crashed?(reason) and restarts_left?(state, slot) ->
        reap_leftover_worktree(state, slot)
        restart_slot(state, slot)

      true ->
        reap_leftover_worktree(state, slot)
        collect(state, slot, down_status(reason))
    end
  end

  # M8 (deep-review-001): finish a brutal-killed partition's worktree cleanup.
  # A no-op unless `Kazi.Scheduler.Worktree.wrap/2` actually left an entry behind
  # (an ordinary raise already cleaned up via its own `after`, so this only ever
  # does real work after an untrappable :kill).
  defp reap_leftover_worktree(state, slot) do
    case Map.fetch(state.tasks, slot) do
      {:ok, %{partition: partition}} -> Worktree.reap(partition)
      :error -> :ok
    end
  end

  defp crashed?(:normal), do: false
  defp crashed?(_abnormal), do: true

  defp restarts_left?(state, slot) do
    case Map.fetch(state.tasks, slot) do
      {:ok, %{restarts_left: n}} -> n > 0
      :error -> false
    end
  end

  # Re-spawn the slot's reconciler on the same partition, decrementing its restart
  # budget and re-keying the new monitor ref to the slot. Idempotent w.r.t. the
  # result: the slot keeps its position in `order`, so a restarted partition's
  # eventual status lands in the same place.
  defp restart_slot(state, slot) do
    task = Map.fetch!(state.tasks, slot)

    new_task =
      start_partition_task(
        state.supervisor,
        task.partition,
        state.reconciler,
        state.timeout,
        slot
      )

    updated = Map.put(new_task, :restarts_left, task.restarts_left - 1)

    %{
      state
      | tasks: Map.put(state.tasks, slot, updated),
        ref_to_slot: Map.put(state.ref_to_slot, updated.ref, slot)
    }
  end

  # =============================================================================
  # Internals
  # =============================================================================

  # Start one supervised reconciler Task for a partition under the DynamicSupervisor
  # and monitor it. The task body runs the (possibly stub) reconciler — contained,
  # so a status return passes through and a crash/non-status return is normalized —
  # and sends the terminal status back keyed by the task's SLOT (stable across a
  # restart). Siblings run concurrently (a DynamicSupervisor imposes no ordering).
  defp start_partition_task(supervisor, partition, reconciler, timeout, slot) do
    coordinator = self()

    spec =
      Supervisor.child_spec(
        {Task, fn -> run_reconciler(reconciler, partition, timeout) end},
        restart: :temporary
      )

    {:ok, pid} = PartitionSupervisor.start_child(supervisor, spec)
    ref = Process.monitor(pid)

    # Hand the task its slot so it can tag the status it sends back; the slot is
    # stable across restarts, so a restarted partition reports into the same slot.
    send(pid, {:coordinator, coordinator, slot})

    %{slot: slot, ref: ref, partition: partition, pid: pid}
  end

  # Run the injected reconciler, contained, and report the terminal status to the
  # coordinator tagged with this task's SLOT. A finite timeout bounds a wedged
  # reconciler; a crash or non-status return is normalized so the collective fold
  # is total. The reconciler runs in a nested Task purely so the timeout can
  # interrupt it without crashing this supervised child.
  #
  # IMPORTANT for T21.10: if the reconciler RAISES (a real crash), no
  # {:partition_done, ...} is sent and this child exits abnormally — the
  # coordinator sees the {:DOWN, ...} and applies the restart/escalate policy. The
  # nested-Task TIMEOUT path (`Task.shutdown/2` unlinks before brutal-killing) is
  # contained here, returning :stuck as a normal status without crashing this
  # process. A SELF-KILLED reconciler (`Process.exit(self(), :kill)`) is
  # DIFFERENT: `:kill` is untrappable and propagates through the link
  # regardless, killing this process too — that case is NOT contained here; it
  # surfaces at the coordinator's {:DOWN, ...} handler like any other crash (M8,
  # deep-review-001: this is also why a self-kill's lease/worktree cleanup
  # cannot run in a `try/after` here and needs the coordinator/lease-backend
  # survivor-side cleanup instead).
  defp run_reconciler(reconciler, partition, timeout) do
    receive do
      {:coordinator, coordinator, slot} ->
        status = invoke_reconciler(reconciler, partition, timeout)
        send(coordinator, {:partition_done, slot, status})
        status
    end
  end

  defp invoke_reconciler(reconciler, partition, timeout) do
    task = Task.async(fn -> reconciler.(partition) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, status} ->
        normalize_status(status)

      nil ->
        # M8 (deep-review-001): `Task.shutdown/2` unlinks THEN brutal-kills the
        # wedged task, so THIS process (invoke_reconciler's caller) survives —
        # but the killed task's own `try/after` (lease release, worktree
        # removal) never ran. This is the surviving process finishing that
        # cleanup: a no-op unless `Worktree.wrap/2` actually left an entry.
        Worktree.reap(partition)
        :stuck

      {:exit, _reason} ->
        :crashed
    end
  end

  defp normalize_status(status)
       when status in [:converged, :stuck, :over_budget, :stopped, :crashed],
       do: status

  # A reconciler that returns an error (or any non-status term) did not converge;
  # the collective fold treats it as :stuck (escalate), never as success.
  defp normalize_status(_other), do: :stuck

  # A child DOWN reason → status when no explicit status was reported. A :normal
  # exit without a reported status (it never sent one) is treated as :stuck rather
  # than success; an abnormal exit is a :crashed.
  defp down_status(:normal), do: :stuck
  defp down_status(_abnormal), do: :crashed

  # Record a partition's terminal status (keyed by its stable SLOT) and reply to a
  # waiting :await if the run is now finished.
  defp collect(state, slot, status) do
    state = %{state | collected: Map.put_new(state.collected, slot, status)}
    maybe_reply(state)
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

  # The result once EVERY ordered slot has a collected status, else nil. Keyed by
  # slot (stable across restarts), so a restarted partition's eventual status still
  # lands in its original input position.
  defp finished_result(state) do
    if Enum.all?(state.order, &Map.has_key?(state.collected, &1)) do
      partitions =
        Enum.map(state.order, fn slot ->
          {Map.fetch!(state.tasks, slot).partition, Map.fetch!(state.collected, slot)}
        end)

      statuses = Enum.map(partitions, fn {_p, status} -> status end)
      %{collective: collective_verdict(statuses), partitions: partitions}
    else
      nil
    end
  end

  # The :await call timeout: generous beyond the per-partition WORST-CASE wall
  # time so the coordinator's own await never fires before a partition's. A
  # slot's worst case is `(max_restarts + 1) * reconcile_timeout` -- the
  # per-attempt timeout applies to EACH restart attempt, not just the first
  # (M7, deep-review-001) -- plus slack for coordinator overhead. Infinity
  # stays infinity regardless of the restart budget.
  defp await_call_timeout(:infinity, _max_restarts), do: :infinity

  defp await_call_timeout(ms, max_restarts)
       when is_integer(ms) and is_integer(max_restarts) and max_restarts >= 0 do
    ms * (max_restarts + 1) + 5_000
  end

  # =============================================================================
  # Default reconciler (production wiring: the real per-goal serial loop)
  # =============================================================================

  # The default reconciler drives the EXISTING serial loop for a partition's goal
  # via Kazi.Runtime.run/2 and normalizes its terminal result to a partition
  # status, so a single-partition set behaves exactly like today's serial run.
  # T21.2 supplies real Kazi.Partition structs; until then the default expects a
  # partition that carries a goal it can run. Tests inject a stub and never reach
  # this path.
  defp default_reconciler(opts) do
    run_opts = Keyword.get(opts, :run_opts, [])
    fn partition -> reconcile_partition(partition, run_opts) end
  end

  @doc """
  Reconcile one partition by running its goal's serial loop (the default
  reconciler).

  The partition shape is finalized in T21.2 (it will carry/resolve the goal); for
  the skeleton this accepts a partition that exposes a `%Kazi.Goal{}` (directly or
  under `:goal`) and maps the loop result to a partition status. A partition with
  no resolvable goal is `:stuck`.
  """
  @spec reconcile_partition(partition(), keyword()) :: partition_status()
  def reconcile_partition(partition, run_opts) do
    case partition_goal(partition) do
      {:ok, goal} ->
        case Kazi.Runtime.run(goal, run_opts) do
          {:ok, result} -> result_to_status(result)
          {:error, _reason} -> :stuck
        end

      :error ->
        :stuck
    end
  end

  # As `reconcile_partition/2`, but also extract the loop's terminal budget SPEND
  # (T21.7) so the partition can report it for the collective rollup. Returns
  # `{partition_status, spent}`; the loop result surfaces `:iterations` (the
  # deterministic, hermetically-testable dimension), so spend is reported on the
  # iterations axis (tokens/wall-clock are not yet surfaced by the loop result —
  # T1.4 deepening, not this task). A partition with no resolvable goal, or a run
  # error, spends nothing.
  @spec reconcile_partition_with_spend(partition(), keyword()) ::
          {partition_status(), Kazi.Scheduler.Budget.spent()}
  defp reconcile_partition_with_spend(partition, run_opts) do
    case partition_goal(partition) do
      {:ok, goal} ->
        case Kazi.Runtime.run(goal, run_opts) do
          {:ok, result} ->
            {result_to_status(result), %{iterations: Map.get(result, :iterations, 0)}}

          {:error, _reason} ->
            {:stuck, %{}}
        end

      :error ->
        {:stuck, %{}}
    end
  end

  defp partition_goal(%Kazi.Goal{} = goal), do: {:ok, goal}
  defp partition_goal(%{goal: %Kazi.Goal{} = goal}), do: {:ok, goal}
  defp partition_goal(_other), do: :error

  # Map the loop's terminal result (ADR-0027 / Kazi.Loop) to a partition status:
  # the loop reports a :stuck stop as outcome :stopped with reason :stuck, which
  # the collective verdict treats as :stuck.
  defp result_to_status(%{outcome: :converged}), do: :converged
  defp result_to_status(%{outcome: :over_budget}), do: :over_budget
  defp result_to_status(%{outcome: :stopped, reason: :stuck}), do: :stuck
  defp result_to_status(%{outcome: :stopped}), do: :stopped
  defp result_to_status(_other), do: :stuck
end
