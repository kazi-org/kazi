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

  alias Kazi.Scheduler.PartitionSupervisor

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
  """
  @type result :: %{
          collective: collective(),
          partitions: [{partition(), partition_status()}]
        }

  # The default per-partition reconcile timeout. Production runs are long; the
  # default is generous and overridable via the `:reconcile_timeout` opt (tests
  # pass a short, deterministic value).
  @default_reconcile_timeout :infinity

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

  Returns `{:ok, result}` (see `t:result/0`) once every partition is terminal, or
  `{:error, reason}` if the coordinator could not be started.
  """
  @spec run([partition()], keyword()) :: {:ok, result()} | {:error, term()}
  def run(partitions, opts \\ []) when is_list(partitions) and is_list(opts) do
    reconciler = Keyword.get(opts, :reconciler, default_reconciler(opts))
    supervisor = Keyword.get(opts, :supervisor, PartitionSupervisor)
    timeout = Keyword.get(opts, :reconcile_timeout, @default_reconcile_timeout)

    init_arg = %{
      partitions: partitions,
      reconciler: reconciler,
      supervisor: supervisor,
      timeout: timeout
    }

    case GenServer.start_link(__MODULE__, init_arg) do
      {:ok, coordinator} ->
        result = GenServer.call(coordinator, :await, await_call_timeout(timeout))
        GenServer.stop(coordinator)
        {:ok, result}

      {:error, _reason} = error ->
        error
    end
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

    # Start one supervised reconciler per partition under the DynamicSupervisor
    # BEFORE awaiting any of them, so the population overlaps — a serial-only
    # design would deadlock a stub that waits on a sibling. Each task is keyed by
    # its monitor ref; its body sends {:partition_done, ref, status} on completion
    # and a {:DOWN, ref, ...} confirms (or, on a crash, supplies) its terminal
    # status. `order` preserves input order for the result.
    tasks =
      Enum.map(partitions, fn partition ->
        start_partition_task(supervisor, partition, reconciler, timeout)
      end)

    state = %{
      tasks: Map.new(tasks, fn task -> {task.ref, task} end),
      order: Enum.map(tasks, & &1.ref),
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
  # returning). We record it; the matching {:DOWN, ...} then drops the monitor.
  def handle_info({:partition_done, ref, status}, state) do
    {:noreply, collect(state, ref, status)}
  end

  # A reconciler process exited. A normal exit means it already reported a status
  # via {:partition_done, ...}; an abnormal exit with no recorded status is a
  # crash — recorded :crashed so the collective fold accounts for it. The
  # coordinator survives the child crash (DynamicSupervisor :one_for_one).
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    state =
      if Map.has_key?(state.collected, ref) do
        state
      else
        collect(state, ref, down_status(reason))
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # =============================================================================
  # Internals
  # =============================================================================

  # Start one supervised reconciler Task for a partition under the DynamicSupervisor
  # and monitor it. The task body runs the (possibly stub) reconciler — contained,
  # so a status return passes through and a crash/non-status return is normalized —
  # and sends the terminal status back keyed by the monitor ref. Siblings run
  # concurrently (a DynamicSupervisor imposes no ordering).
  defp start_partition_task(supervisor, partition, reconciler, timeout) do
    coordinator = self()

    spec =
      Supervisor.child_spec(
        {Task, fn -> run_reconciler(reconciler, partition, timeout) end},
        restart: :temporary
      )

    {:ok, pid} = PartitionSupervisor.start_child(supervisor, spec)
    ref = Process.monitor(pid)

    # Hand the task its own monitor ref so it can tag the status it sends back.
    send(pid, {:coordinator, coordinator, ref})

    %{ref: ref, partition: partition, pid: pid}
  end

  # Run the injected reconciler, contained, and report the terminal status to the
  # coordinator tagged with this task's monitor ref. A finite timeout bounds a
  # wedged reconciler; a crash or non-status return is normalized so the collective
  # fold is total. The reconciler runs in a nested Task purely so the timeout can
  # interrupt it without crashing this supervised child.
  defp run_reconciler(reconciler, partition, timeout) do
    receive do
      {:coordinator, coordinator, ref} ->
        status = invoke_reconciler(reconciler, partition, timeout)
        send(coordinator, {:partition_done, ref, status})
        status
    end
  end

  defp invoke_reconciler(reconciler, partition, timeout) do
    task = Task.async(fn -> reconciler.(partition) end)

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
  # the collective fold treats it as :stuck (escalate), never as success.
  defp normalize_status(_other), do: :stuck

  # A child DOWN reason → status when no explicit status was reported. A :normal
  # exit without a reported status (it never sent one) is treated as :stuck rather
  # than success; an abnormal exit is a :crashed.
  defp down_status(:normal), do: :stuck
  defp down_status(_abnormal), do: :crashed

  # Record a partition's terminal status and reply to a waiting :await if the run
  # is now finished.
  defp collect(state, ref, status) do
    state = %{state | collected: Map.put_new(state.collected, ref, status)}
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

  # The result once EVERY ordered partition has a collected status, else nil.
  defp finished_result(state) do
    if Enum.all?(state.order, &Map.has_key?(state.collected, &1)) do
      partitions =
        Enum.map(state.order, fn ref ->
          {Map.fetch!(state.tasks, ref).partition, Map.fetch!(state.collected, ref)}
        end)

      statuses = Enum.map(partitions, fn {_p, status} -> status end)
      %{collective: collective_verdict(statuses), partitions: partitions}
    else
      nil
    end
  end

  # The :await call timeout: generous beyond the per-partition timeout so the
  # coordinator's own await never fires before a partition's. Infinity stays
  # infinity.
  defp await_call_timeout(:infinity), do: :infinity
  defp await_call_timeout(ms) when is_integer(ms), do: ms * 4 + 5_000

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
