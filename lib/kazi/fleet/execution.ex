defmodule Kazi.Fleet.Execution do
  @moduledoc """
  **Fleet execution** (T50.5, ADR-0065 decision 3): drives a loaded
  `Kazi.Fleet` DAG to a collective verdict — the execution half of
  `kazi apply --fleet <dir|manifest>`, completing T50.4's discovery/DAG half.

  ## Design choice: fleet members ARE synthetic DepScheduler groups

  ADR-0065 says "reuse E21's machinery one level up". Rather than a sibling
  scheduler that re-implements pipelined frontiers, this module maps the fleet
  onto the EXISTING `Kazi.Scheduler.DepScheduler` by building a SYNTHETIC goal
  whose groups are the fleet's member goal-ids and whose `needs` edges are the
  fleet's edges (explicit `depends_on` AND inferred scope-overlap alike — an
  overlap edge serializes execution exactly like a dependency, which is its
  point). Every DepScheduler property then holds at the fleet level BY
  CONSTRUCTION, not by re-implementation:

    * **pipelined frontier advancement** — a member dispatches the instant its
      deps settle, no wave barrier (`dispatch_ready`);
    * **blocked sub-DAG surfacing + escalations** — a stuck member's dependents
      are `:blocked`, naming the blocker;
    * **`:on_frontier_complete` events** — the SAME schema at fleet-node
      boundaries (`schema_version` 2, `event: "frontier_complete"`);
    * **`:pause_between_waves` / `:resume_token`** — T50.3's checkpoint pause
      applies to fleet frontiers with identical resume semantics (one
      mechanism, two levels).

  The groups are built as raw `%Kazi.Goal.Group{}` structs (NOT `Group.new/3`)
  so member goal-ids round-trip verbatim — `Group.new/3` normalizes ids to
  slugs, which would break the group-id → member-id mapping for any goal id
  the slugger rewrites.

  ## Worktree isolation + landing per member

  Each member goal runs in its OWN kazi-owned task worktree created off the
  shared base workspace's HEAD (or `:base_ref`) via `Kazi.Scheduler.Worktree`
  — T50.1's machinery, the fleet-level analog of worktree-per-partition — and
  a converged member LANDS its task-branch commits on the base through
  `Kazi.Scheduler.SerialLanding` (T50.2) BEFORE its terminal status is
  reported to the scheduler. That ordering matters: a dependent's worktree is
  created only after its deps settled, so it branches from a base that already
  carries their landed work. A member that converged but FAILED to land is
  reported `:stuck`, not `:converged` — its dependents would otherwise build
  on a base missing the work they need; the surviving task branch is named in
  the member's `:integration` info, so nothing is lost. A non-git base
  workspace runs members in place (worktree isolation needs a git repo),
  matching the serial path's fail-open.

  ## Concurrency cap

  `:fleet_concurrency` bounds how many member goals RUN at once via a
  counting-semaphore gate around the member runner. Default: nil — unbounded
  within a frontier, the DepScheduler's own behavior, so a fleet without the
  cap schedules exactly like a `needs`-DAG goal. The gate holds a member in
  "acquired-a-slot" waiting rather than delaying dispatch, so DAG semantics
  (readiness, blocking, frontier events) are untouched by the cap.

  ## Registry + duplicate guard

  Members run through `Kazi.Runtime.run/2`, so each executing member registers
  its own `Kazi.ReadModel.RunRegistry` row (status/heartbeat/economics) —
  concurrent operator sessions see fleet members as live runs, and the
  duplicate-run guard composes per member goal_ref (a second apply on a goal a
  live fleet member holds refuses).

  ## Economy rollup (honest-unknown)

  The result's `:economy` aggregates per-member spend dimension-wise via
  `Kazi.Scheduler.Budget.rollup/1`. A member whose run reported NO usage
  envelope contributes `nil` — never fabricated zeros — and the rollup says
  how many members reported (`members_reported` / `members_total`); when no
  member reported, `totals` is `nil`.
  """

  alias Kazi.Fleet
  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.Scheduler.DepScheduler
  alias Kazi.Scheduler.SerialLanding
  alias Kazi.Scheduler.Worktree

  @typedoc """
  One member's execution record, produced by the member runner:

    * `:status` — the member's terminal `t:Kazi.Scheduler.partition_status/0`;
    * `:economy` — the member's observed spend (`t:Kazi.Scheduler.Budget.spent/0`)
      when its run reported a usage envelope, else `nil` (honest-unknown);
    * `:workspace` — the effective workspace the member ran in (its task
      worktree, or the base for an in-place run);
    * `:integration` — the T50.2 landing info map for a worktree-isolated
      converged member, or `nil`;
    * `:error` — the run error term when the member's run could not start.
  """
  @type member :: %{
          status: Kazi.Scheduler.partition_status(),
          economy: Kazi.Scheduler.Budget.spent() | nil,
          workspace: Path.t() | nil,
          integration: map() | nil,
          error: term() | nil
        }

  @typedoc """
  The fleet collective result: `Kazi.Scheduler.DepScheduler.t:result/0` with the
  member view —

    * `:members` — `{member_goal_id, status}` in loaded order (the scheduler's
      `:groups`, renamed to the fleet vocabulary);
    * `:member_results` — member_goal_id → `t:member/0` for every member that
      actually ran;
    * `:economy` — the honest-unknown rollup (see the moduledoc).
  """
  @type result :: %{
          collective: Kazi.Scheduler.collective() | :paused,
          members: [{String.t(), atom()}],
          member_results: %{String.t() => member()},
          economy: %{
            members_total: non_neg_integer(),
            members_reported: non_neg_integer(),
            totals:
              %{
                iterations: non_neg_integer(),
                elapsed_ms: non_neg_integer(),
                tokens: non_neg_integer()
              }
              | nil
          },
          blocked: list(),
          escalations: list(),
          resume_token: String.t() | nil
        }

  @doc """
  Executes the fleet DAG to a collective verdict.

  ## Options

    * `:workspace` — the shared base workspace every member integrates onto
      (required). Each member's task worktree is created off it.
    * `:fleet_concurrency` — cap on concurrently RUNNING members (default
      `nil` = unbounded within a frontier; see the moduledoc).
    * `:runtime_opts` — keyword opts forwarded to each member's
      `Kazi.Runtime.run/2` (harness/adapter/persistence seams). `:workspace`,
      `:base_workspace`, and `:goal_ref` are set per member and win.
    * `:persist?` — project member runs into the read-model (default `true`;
      an explicit `:persist?` inside `:runtime_opts` wins).
    * `:base_ref` — the git ref member worktrees are created FROM (T50.8);
      default `nil` = the base workspace's HEAD, with the stale-base warning.
    * `:member_runner` — the injectable member seam, a 1-arity fn
      `Fleet.Node.t() -> t:member/0` (hermetic tests). Default: the production
      runner (worktree + `Kazi.Runtime.run/2` + landing) described in the
      moduledoc.
    * `:supervisor`, `:reconcile_timeout`, `:on_frontier_complete`,
      `:pause_between_waves`, `:resume_token` — forwarded to
      `Kazi.Scheduler.DepScheduler.run/2` verbatim.

  Returns `{:ok, t:result/0}`, or `{:error, reason}` when the scheduler could
  not start or a resume was refused (`DepScheduler.run/2`'s errors).
  """
  @spec run(Fleet.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(%Fleet{} = fleet, opts) when is_list(opts) do
    workspace = Keyword.fetch!(opts, :workspace)

    member_runner =
      Keyword.get_lazy(opts, :member_runner, fn -> default_runner(workspace, opts) end)

    {:ok, results} = Agent.start_link(fn -> %{} end)
    slots = start_slots(Keyword.get(opts, :fleet_concurrency))
    nodes_by_id = Map.new(fleet.nodes, &{&1.id, &1})

    reconciler = fn member_id ->
      node = Map.fetch!(nodes_by_id, member_id)
      member = with_slot(slots, fn -> run_member_reconciler(member_runner, node) end)
      Agent.update(results, &Map.put(&1, member_id, member))
      member.status
    end

    dep_opts =
      opts
      |> Keyword.take([
        :supervisor,
        :reconcile_timeout,
        :on_frontier_complete,
        :pause_between_waves,
        :resume_token
      ])
      |> Keyword.put(:reconciler, reconciler)

    try do
      case DepScheduler.run(synthetic_goal(fleet, workspace), dep_opts) do
        {:ok, dep_result} ->
          member_results = Agent.get(results, & &1)

          {:ok,
           dep_result
           |> Map.delete(:groups)
           |> Map.put(:members, dep_result.groups)
           |> Map.put(:member_results, member_results)
           |> Map.put(:economy, rollup(fleet, member_results))}

        {:error, _reason} = error ->
          error
      end
    after
      Agent.stop(results)
      stop_slots(slots)
    end
  end

  @doc """
  The synthetic `needs`-DAG goal the fleet maps onto (exposed so the CLI can
  render the fleet schedule through the SAME `Kazi.Goal.DepGraph.frontiers/1`
  layering the scheduler runs — explain, execution, and report can never
  disagree). One group per member, id VERBATIM (see the moduledoc), `needs` =
  the ids of the member's incoming fleet edges.
  """
  @spec synthetic_goal(Fleet.t(), Path.t()) :: Goal.t()
  def synthetic_goal(%Fleet{nodes: nodes, edges: edges}, workspace) do
    groups =
      Enum.map(nodes, fn %Fleet.Node{id: id} ->
        needs = edges |> Enum.filter(&(&1.to == id)) |> Enum.map(& &1.from)
        %Group{id: id, name: id, needs: needs}
      end)

    %Goal{
      id: "fleet",
      name: "fleet",
      groups: groups,
      scope: %Kazi.Scope{workspace: workspace}
    }
  end

  # Normalize whatever a (possibly injected) runner returned into a full member
  # record, so the collective fold and the rollup are total.
  defp normalize_member(%{status: _} = member) do
    Map.merge(%{economy: nil, workspace: nil, integration: nil, error: nil}, member)
  end

  defp normalize_member(other) do
    %{status: :stuck, economy: nil, workspace: nil, integration: nil, error: {:bad_member, other}}
  end

  # issue #1053 sub-fix (2): a member runner that genuinely CRASHES (not the
  # already-guarded worktree-teardown noise, a real exception in the member's
  # own run) must still surface in the collective as `:crashed` with a non-nil
  # `:error` naming the failure — never silently reported as an unexplained
  # `nil` error, which left #1053's operator unable to tell "crashed" apart
  # from "crashed, but why".
  defp run_member_reconciler(member_runner, node) do
    normalize_member(member_runner.(node))
  rescue
    e ->
      %{
        status: :crashed,
        economy: nil,
        workspace: nil,
        integration: nil,
        error: "member crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
      }
  end

  # ---------------------------------------------------------------------------
  # The production member runner: task worktree + Runtime.run + landing
  # ---------------------------------------------------------------------------

  defp default_runner(base_workspace, opts) do
    runtime_opts = Keyword.get(opts, :runtime_opts, [])
    persist? = Keyword.get(opts, :persist?, true)
    base_ref = Keyword.get(opts, :base_ref)

    fn %Fleet.Node{} = node ->
      if git_repo?(base_workspace) do
        run_in_worktree(node, base_workspace, base_ref, runtime_opts, persist?)
      else
        # Fail-open like the serial path: a non-git base cannot host a
        # worktree, so the member runs in place (isolation unavailable).
        run_member(node, base_workspace, base_workspace, runtime_opts, persist?)
      end
    end
  end

  defp run_in_worktree(node, base_workspace, base_ref, runtime_opts, persist?) do
    reconciler =
      Worktree.wrap(
        fn _partition, worktree_path ->
          run_member(node, worktree_path, base_workspace, runtime_opts, persist?)
        end,
        repo: base_workspace,
        # T54.1 (#1079/#1080): check the member's worktree out onto its goal's
        # REAL target branch (SerialLanding.land/4 recognizes it by identity).
        owned_branch: Goal.integration_branch(node.goal),
        base_ref: base_ref
      )

    case reconciler.(%{key: node.id}) do
      %{status: _} = member ->
        member

      # Worktree.wrap returns :stuck when the worktree could not be created;
      # the member never ran un-isolated.
      _stuck ->
        normalize_member(%{
          status: :stuck,
          error: "could not create an isolated task worktree off #{base_workspace}"
        })
    end
  end

  defp run_member(%Fleet.Node{} = node, workspace, base_workspace, runtime_opts, persist?) do
    run_opts =
      runtime_opts
      |> Keyword.put(:workspace, workspace)
      |> Keyword.put(:base_workspace, base_workspace)
      |> Keyword.put_new(:persist?, persist?)
      |> Keyword.put_new(:goal_ref, node.id)

    started_ms = System.monotonic_time(:millisecond)

    case Kazi.Runtime.run(node.goal, run_opts) do
      {:ok, %{outcome: :converged} = result} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_ms
        land_member(node, result, runtime_opts, base_workspace, workspace, elapsed_ms)

      {:ok, %{outcome: outcome} = result} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_ms

        normalize_member(%{
          status: status_for(outcome, result),
          economy: member_economy(result, elapsed_ms),
          workspace: workspace
        })

      {:error, reason} ->
        normalize_member(%{status: :stuck, error: reason, workspace: workspace})
    end
  end

  # T50.2 one level up: land the converged member's committed task-branch work
  # on the base BEFORE reporting :converged, so a dependent's worktree (created
  # only after this member settles) branches from a base that carries it. A
  # landing failure reports :stuck — dependents must not build on a base
  # missing their dep's work — with the surviving task branch named in
  # `:integration` (the work is never lost). In-place members (worktree ==
  # base) have nothing to land by construction.
  defp land_member(node, result, runtime_opts, base_workspace, workspace, elapsed_ms) do
    verdict =
      if Path.expand(base_workspace) == Path.expand(workspace) do
        :nothing_to_land
      else
        SerialLanding.land(node.goal, runtime_opts, base_workspace, workspace)
      end

    base = %{
      status: :converged,
      economy: member_economy(result, elapsed_ms),
      workspace: workspace
    }

    case verdict do
      :nothing_to_land ->
        normalize_member(base)

      {:landed, info} ->
        normalize_member(Map.put(base, :integration, info))

      {:unlanded, info} ->
        normalize_member(%{base | status: :stuck} |> Map.put(:integration, info))
    end
  end

  # Map the runtime's terminal outcome/reason onto the scheduler's
  # partition-status vocabulary (mirrors the CLI's exit-code fold).
  defp status_for(:over_budget, _result), do: :over_budget
  defp status_for(:stopped, %{reason: :stuck}), do: :stuck
  defp status_for(:stopped, _result), do: :stopped
  defp status_for(_other, _result), do: :stuck

  # The member's observed spend for the rollup. Honest-unknown (ADR-0046): a
  # run whose usage envelope is EMPTY (no dispatch reported any component)
  # contributes nil — `tokens_used`/`iterations` alone would fabricate a
  # confident-looking spend for a run whose harness reports nothing by design.
  defp member_economy(%{usage: usage} = result, elapsed_ms) when map_size(usage) > 0 do
    %{
      iterations: Map.get(result, :iterations, 0),
      elapsed_ms: elapsed_ms,
      tokens: Map.get(result, :tokens_used, 0)
    }
  end

  defp member_economy(_result, _elapsed_ms), do: nil

  # `workspace` is only isolatable when it is itself a repo/worktree ROOT
  # (`--show-toplevel` resolves back to it) — the same rule the serial path
  # applies (a dir NESTED inside some ancestor repo must not silently branch
  # off the ancestor's HEAD).
  defp git_repo?(workspace) when is_binary(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> Path.expand(String.trim(out)) == Path.expand(workspace)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp git_repo?(_workspace), do: false

  # ---------------------------------------------------------------------------
  # Economy rollup (honest-unknown)
  # ---------------------------------------------------------------------------

  defp rollup(%Fleet{nodes: nodes}, member_results) do
    reported =
      member_results
      |> Map.values()
      |> Enum.map(& &1.economy)
      |> Enum.reject(&is_nil/1)

    %{
      members_total: length(nodes),
      members_reported: length(reported),
      totals: if(reported == [], do: nil, else: Kazi.Scheduler.Budget.rollup(reported))
    }
  end

  # ---------------------------------------------------------------------------
  # The concurrency gate (:fleet_concurrency)
  # ---------------------------------------------------------------------------

  defp start_slots(nil), do: nil

  defp start_slots(limit) when is_integer(limit) and limit > 0 do
    {:ok, pid} = __MODULE__.Slots.start_link(limit)
    pid
  end

  defp stop_slots(nil), do: :ok
  defp stop_slots(pid), do: GenServer.stop(pid)

  defp with_slot(nil, fun), do: fun.()

  defp with_slot(slots, fun) do
    :ok = __MODULE__.Slots.acquire(slots)

    try do
      fun.()
    after
      __MODULE__.Slots.release(slots)
    end
  end

  defmodule Slots do
    @moduledoc """
    A counting semaphore gating member concurrency (`:fleet_concurrency`).
    `acquire/1` blocks (FIFO) until a permit frees; a permit-holding process
    that dies without releasing is reaped via its monitor, so a crashed member
    can never leak a permit and wedge the rest of the fleet.
    """

    use GenServer

    def start_link(limit) when is_integer(limit) and limit > 0 do
      GenServer.start_link(__MODULE__, limit)
    end

    @spec acquire(pid()) :: :ok
    def acquire(pid), do: GenServer.call(pid, :acquire, :infinity)

    @spec release(pid()) :: :ok
    def release(pid), do: GenServer.cast(pid, {:release, self()})

    @impl true
    def init(limit) do
      {:ok, %{free: limit, waiting: :queue.new(), holders: %{}}}
    end

    @impl true
    def handle_call(:acquire, {caller, _tag} = from, state) do
      if state.free > 0 do
        {:reply, :ok, grant(state, caller, state.free - 1)}
      else
        {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
      end
    end

    @impl true
    def handle_cast({:release, caller}, state) do
      {:noreply, do_release(state, caller)}
    end

    @impl true
    # A holder died without releasing (crash/kill): reap its permit. A waiter
    # that died is simply dropped when its turn comes (reply to a dead pid is
    # harmless, but pruning keeps the queue honest).
    def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
      if Map.has_key?(state.holders, pid) do
        {:noreply, do_release(state, pid)}
      else
        waiting = :queue.filter(fn {waiter, _tag} -> waiter != pid end, state.waiting)
        {:noreply, %{state | waiting: waiting}}
      end
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp grant(state, caller, free) do
      ref = Process.monitor(caller)
      %{state | free: free, holders: Map.put(state.holders, caller, ref)}
    end

    defp do_release(state, caller) do
      case Map.pop(state.holders, caller) do
        {nil, _holders} ->
          state

        {ref, holders} ->
          Process.demonitor(ref, [:flush])
          state = %{state | holders: holders}

          case :queue.out(state.waiting) do
            {{:value, {waiter, _tag} = from}, waiting} ->
              GenServer.reply(from, :ok)
              grant(%{state | waiting: waiting}, waiter, state.free)

            {:empty, _waiting} ->
              %{state | free: state.free + 1}
          end
      end
    end
  end
end
