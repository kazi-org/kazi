defmodule Kazi.Loop do
  @moduledoc """
  The convergence state machine — the spine of the reconcile loop (concept §5,
  UC-004). A `:gen_statem` process that drives one goal from declared desired
  state to converged actual state by repeating:

  ```
  observe   → evaluate every predicate via its provider, record the VECTOR
  diff      → the failing predicates ARE the work-list
  decide    → pick the next action from the vector + progress so far
  act       → {dispatch agent | integrate | deploy}
  re-observe→ evaluate again and loop
  ```

  ## Decide logic (faithful to concept §5)

  Given a fresh predicate vector and the progress recorded so far, the loop picks
  exactly one next move:

    1. **Whole vector satisfied** (every predicate `:pass`, including live ones) →
       `:converged`, stop. This is the only path to termination-as-success, and
       the basis the T0.8 objective-termination guard hardens
       (`Kazi.PredicateVector.satisfied?/1` over a non-empty vector).
    2. **Code predicates failing** → `:dispatch_agent`: drive the harness
       (`Kazi.HarnessAdapter`) with the failing-predicate evidence as context,
       inside the target workspace (concept §5). Dispatching invalidates any
       prior land/deploy, since the code changed.
    3. **Code predicates green but the change isn't landed** → `:integrate`
       (`Kazi.Action` `:integrate`): branch → commit → push → PR → rebase-merge
       (T0.10a). On success the change is marked landed.
    4. **Landed but not deployed** → `:deploy` (`Kazi.Action` `:deploy`): ship the
       artifact (T0.10b). On success the change is marked deployed, then we
       re-observe so the live predicates can be re-checked against the deployed
       artifact.
    5. Otherwise (no actionable code failure, landed + deployed, but the whole
       vector still not satisfied — e.g. a live predicate is still `:fail`) →
       keep re-observing until the live predicate flips or the operator stops it.

  "Code" vs "live" is decided by predicate `kind`: live predicates probe the
  deployed system (`:http_probe`, `:prod_logs`, `:browser` by default) and only
  pass once the change is deployed; everything else (`:tests`, `:coverage`, …) is
  code. The set is injectable via the `:live_kinds` option so the loop stays
  decoupled from any concrete provider.

  ## Dependency injection

  Everything the loop touches the outside world through is passed IN at start, as
  behaviour implementations — the loop depends only on the behaviours
  (`Kazi.PredicateProvider`, `Kazi.HarnessAdapter`, `Kazi.Action`), never on the
  concrete Slice-0 impls. See `start_link/1` opts.

  ## Lifecycle

  Startable on demand (`start_link/1`); **not** wired into the application
  supervision tree yet (that is T0.10 / T0.7b). On start it immediately begins
  observing. Terminal states (`:converged`, `:stopped`) stop the process with the
  final `t:result/0` available via `await/2`.
  """

  @behaviour :gen_statem

  alias Kazi.{Action, Goal, Predicate, PredicateResult, PredicateVector}
  # T1.3 flake: the pure re-run/quarantine policy lives in its own module; the
  # loop only routes failing-predicate evaluation through it (see observe/1).
  alias Kazi.Loop.Flake
  # T1.4 budget: the pure budget-ceiling guard (iterations / wall-clock / tokens).
  alias Kazi.Loop.Budget
  # T1.5 stuck: the pure stuck detector (N iterations, same non-empty failing
  # set). The loop only feeds it the T1.1 history and fires the human-escalation
  # hook + terminal stop on its verdict (see observe_tick/1).
  alias Kazi.Loop.StuckDetector

  require Logger

  @default_live_kinds [:http_probe, :prod_logs, :browser]

  # When code is green and the change is landed + deployed but the whole vector is
  # still not satisfied (a live predicate has not yet flipped to :pass), the loop
  # re-observes on this interval rather than busy-spinning. Injectable via
  # `:reobserve_interval_ms`.
  @default_reobserve_ms 1_000

  @typedoc """
  The terminal outcome reported when the loop stops.

    * `:converged`   — the whole predicate vector is satisfied (success).
    * `:stopped`     — the loop was asked to stop before converging.
    * `:over_budget` — a hard budget ceiling was hit (T1.4): the loop stopped
      itself rather than burn more iterations / wall-clock / tokens (concept §5,
      ADR-0002). The exceeded dimension is in the result's `:reason`.

  A stuck stop (T1.5) is reported as `:stopped` with reason `:stuck`: the loop
  saw the same non-empty failing set persist across N iterations, escalated to a
  human, and stopped rather than burning more work (concept §5).
  """
  @type outcome :: :converged | :stopped | :over_budget

  @typedoc """
  The final result handed to `await/2` waiters when the loop stops.

  `:reason` names the budget dimension that forced an `:over_budget` stop (T1.4),
  e.g. `:max_iterations`, `:wall_clock`, or `:token_budget`; it is `:stuck` for a
  T1.5 stuck stop (a `:stopped` outcome), and `nil` for a plain `:converged` or
  operator-`:stopped` outcome.
  """
  @type result :: %{
          outcome: outcome(),
          reason: Budget.reason() | :stuck | nil,
          vector: PredicateVector.t() | nil,
          actions: [Action.kind()],
          iterations: non_neg_integer()
        }

  # --- gen_statem data ---------------------------------------------------------
  #
  # `data` is the loop's working set (the BEAM-resident state, concept §7). It is
  # deliberately a plain map of injected dependencies + progress, never coupled to
  # the providers/adapter/actions' internals.
  defmodule Data do
    @moduledoc false
    defstruct goal: nil,
              # injected behaviour impls
              providers: %{},
              harness: nil,
              integrate: nil,
              deploy: nil,
              # static config threaded to providers/adapter/actions
              workspace: nil,
              adapter_opts: [],
              live_kinds: nil,
              reobserve_interval_ms: nil,
              # side-effect-only per-iteration callback (persistence seam, T0.7b)
              on_iteration: nil,
              # static params/context threaded to integrate/deploy actions so the
              # runtime (T0.7b) can configure the real actions (deploy needs
              # service/project/region; the integrate/deploy test seams take an
              # integrator / deploy_cmd) without the loop naming them.
              integrate_params: %{},
              deploy_params: %{},
              extra_action_context: %{},
              # progress facts not captured by the predicate vector
              landed?: false,
              deployed?: false,
              # observability / history
              vector: nil,
              prev_vector: nil,
              # ordered per-iteration vector history (T1.1): a list of
              # `{iteration_index, PredicateVector.t()}` kept newest-first while
              # in `data` (prepend is O(1)); read APIs reverse it to oldest-first.
              # Full (unbounded) at Slice 0/1 scale — every iteration's whole
              # vector is retained so the regression (T1.2) and stuck (T1.5)
              # detectors can analyse the complete trajectory in-state.
              history: [],
              actions: [],
              iterations: 0,
              # --- T1.4 budget: usage tracking + the hard ceiling -------------
              # The goal's hard ceiling (iterations / wall-clock / tokens),
              # cached from the goal at init; the budget guard is checked once at
              # the start of every tick before more work is dispatched.
              budget: nil,
              # Injectable monotonic clock (`:now_fn` opt) so the wall-clock
              # dimension is deterministically testable without sleeping. Returns
              # a millisecond reading; elapsed = now_fn.() - started_at_ms.
              now_fn: nil,
              started_at_ms: nil,
              # Accumulated token estimate across harness invocations (the budget
              # token dimension). Each :dispatch_agent result that carries a token
              # estimate adds to this running total.
              tokens_used: 0,
              # The budget dimension that forced an :over_budget stop, if any
              # (surfaced in snapshot/1 and the terminal result).
              budget_reason: nil,
              # cached terminal result + await/2 waiters
              result: nil,
              waiters: [],
              # T1.3 flake: max re-runs (extra evaluations) for a failing
              # predicate before its result is taken as real (default via
              # Kazi.Loop.Flake.max_retries/0), and the sticky set of predicate
              # ids proven flaky and therefore QUARANTINED — excluded from the
              # convergence/work calculus (see decide/2). Appended last so the
              # existing field order is untouched.
              flake_max_retries: nil,
              quarantine: MapSet.new(),
              # T1.5 stuck: the window N (consecutive observations carrying the
              # same non-empty failing set) that declares the loop stuck, and the
              # human-escalation callback fired on a stuck verdict. Both appended
              # last so the existing field order is untouched. `stuck_reason` is
              # the failing set the loop stopped stuck on (surfaced in snapshot/1).
              stuck_iterations: nil,
              on_escalation: nil,
              stuck_failing: nil
  end

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Starts a convergence loop for a goal. Begins observing immediately.

  ## Required opts

    * `:goal` — the `Kazi.Goal` to converge.
    * `:providers` — a map of `provider_kind => module` (each `module` implements
      `Kazi.PredicateProvider`). The loop evaluates a predicate by dispatching to
      `providers[predicate.kind]`.
    * `:harness` — a module implementing `Kazi.HarnessAdapter`, used by the
      `:dispatch_agent` action.
    * `:integrate` — a module implementing `Kazi.Action` for the `:integrate`
      action.
    * `:deploy` — a module implementing `Kazi.Action` for the `:deploy` action.

  ## Optional opts

    * `:workspace` — target workspace path threaded to providers / harness /
      actions (default `nil`).
    * `:adapter_opts` — keyword opts forwarded to the harness adapter
      (default `[]`).
    * `:live_kinds` — list of predicate kinds treated as *live* (only pass after
      deploy); default `#{inspect(@default_live_kinds)}`.
    * `:flake_max_retries` — extra evaluations spent re-running a failing
      predicate to tell a real failure from a flake (T1.3); default
      `Kazi.Loop.Flake.max_retries/0`. `0` disables flake detection (a single
      fail is taken as real).
    * `:on_iteration` — an optional side-effect-only callback invoked once per
      observation, *after* the vector is built and *before* `decide`, as
      `fun.(%{goal: goal, iteration: index, vector: vector, converged?: boolean})`
      (`index` is the 0-based per-goal iteration counter). It is the persistence
      seam the runtime (T0.7b) uses to project each iteration into the read-model;
      it must not influence convergence (its return value is ignored), and a
      raising callback is contained. Default `nil` (no-op).
    * `:budget` — a `Kazi.Budget` hard ceiling to enforce (T1.4); overrides the
      goal's own `budget`. The loop stops with `:over_budget` once any dimension
      (iterations / wall-clock / tokens) is crossed. Default: the goal's budget.
    * `:now_fn` — a 0-arity function returning a monotonic millisecond reading,
      used for the wall-clock budget dimension (T1.4). Injectable so the
      wall-clock ceiling is deterministically testable without sleeping. Default
      `fn -> System.monotonic_time(:millisecond) end`.
    * `:stuck_iterations` — the stuck window N (T1.5): once the SAME non-empty
      failing-predicate set persists across this many consecutive observations,
      the loop has made no progress, fires the `:on_escalation` hook and stops as
      `:stopped` with reason `:stuck`. Default
      `Kazi.Loop.StuckDetector.default_iterations/0`. `0` disables stuck
      detection.
    * `:on_escalation` — a side-effect-only callback invoked ONCE when the loop
      is detected stuck (T1.5), as
      `fun.(%{goal: goal, failing: failing_set, iterations: index})` — the
      persistent failing-predicate-id set, the goal, and the 0-based iteration
      index at which the stuck verdict fired. This is the human-escalation seam
      (hand the goal off to a person). Default: a logger warning. A raising
      callback is contained and never blocks the terminal stop.
    * `:name` — register the process under a name.
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    case name do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> :gen_statem.start_link(name, __MODULE__, opts, [])
    end
  end

  @doc """
  Asks the loop to stop. The process transitions to `:stopped` and reports
  `:stopped` to any `await/2` waiters. Idempotent / safe on an already-terminal
  loop.
  """
  @spec stop(:gen_statem.server_ref()) :: :ok
  def stop(ref) do
    :gen_statem.cast(ref, :stop)
  end

  @doc """
  Blocks until the loop reaches a terminal state, returning its `t:result/0`.

  Times out (default 5s) with `{:error, :timeout}` if the loop has not terminated
  — the loop keeps running.
  """
  @spec await(:gen_statem.server_ref(), timeout()) :: {:ok, result()} | {:error, :timeout}
  def await(ref, timeout \\ 5_000) do
    try do
      :gen_statem.call(ref, :await, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  @typedoc """
  The in-state, ordered per-iteration vector history (T1.1): a list of
  `{iteration_index, PredicateVector.t()}` in ascending `iteration_index`
  (oldest-first). The downstream regression (T1.2) and stuck (T1.5) detectors
  read this to analyse the goal's trajectory across iterations.
  """
  @type history :: [{non_neg_integer(), PredicateVector.t()}]

  @doc """
  Returns a snapshot of the loop's current vector, action history, and iteration
  count without blocking on termination. Useful for inspection / tests.

  Includes `:history` — the full ordered per-iteration vector history (T1.1),
  oldest-first; see `history/1` for the same data without the rest of the
  snapshot. Also includes `:quarantine` — the list of predicate ids currently
  quarantined as flaky (T1.3), which are excluded from the convergence/work
  calculus — and `:stuck_failing` — the list of predicate ids the loop stopped
  stuck on (T1.5), or `nil` if it did not stop stuck.
  """
  @spec snapshot(:gen_statem.server_ref()) :: %{
          state: atom(),
          vector: PredicateVector.t() | nil,
          history: history(),
          actions: [Action.kind()],
          iterations: non_neg_integer(),
          landed?: boolean(),
          deployed?: boolean(),
          quarantine: [Kazi.Predicate.id()],
          tokens_used: non_neg_integer(),
          budget_reason: Budget.reason() | nil,
          stuck_failing: [Kazi.Predicate.id()] | nil
        }
  def snapshot(ref) do
    :gen_statem.call(ref, :snapshot)
  end

  @doc """
  Returns the loop's in-state per-iteration vector history (T1.1) without
  blocking on termination: a list of `{iteration_index, PredicateVector.t()}` in
  ascending `iteration_index` (oldest-first). One entry is appended per
  observation; the list is empty before the first observation completes.

  This is the read seam the regression (T1.2) and stuck (T1.5) detectors consume.
  """
  @spec history(:gen_statem.server_ref()) :: history()
  def history(ref) do
    :gen_statem.call(ref, :history)
  end

  # =============================================================================
  # gen_statem callbacks
  # =============================================================================

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(opts) do
    goal = fetch!(opts, :goal)
    # T1.4 budget: an injectable monotonic clock (ms) so the wall-clock dimension
    # is deterministically testable; capture the start instant once at init.
    now_fn = Keyword.get(opts, :now_fn, fn -> System.monotonic_time(:millisecond) end)

    data = %Data{
      goal: goal,
      providers: fetch!(opts, :providers),
      harness: fetch!(opts, :harness),
      integrate: fetch!(opts, :integrate),
      deploy: fetch!(opts, :deploy),
      workspace: Keyword.get(opts, :workspace),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      live_kinds: MapSet.new(Keyword.get(opts, :live_kinds, @default_live_kinds)),
      reobserve_interval_ms: Keyword.get(opts, :reobserve_interval_ms, @default_reobserve_ms),
      on_iteration: Keyword.get(opts, :on_iteration),
      integrate_params: Map.new(Keyword.get(opts, :integrate_params, %{})),
      deploy_params: Map.new(Keyword.get(opts, :deploy_params, %{})),
      extra_action_context: Map.new(Keyword.get(opts, :extra_action_context, %{})),
      # T1.3 flake: how many extra evaluations to spend distinguishing a real
      # failure from a flake (default Kazi.Loop.Flake.max_retries/0).
      flake_max_retries: Keyword.get(opts, :flake_max_retries, Flake.max_retries()),
      # T1.4 budget: cache the hard ceiling + clock and start the wall-clock.
      budget: Keyword.get(opts, :budget, goal.budget),
      now_fn: now_fn,
      started_at_ms: now_fn.(),
      # T1.5 stuck: the window N + the human-escalation callback (default a
      # logger warning that hands off the persistent failing set).
      stuck_iterations: Keyword.get(opts, :stuck_iterations, StuckDetector.default_iterations()),
      on_escalation: Keyword.get(opts, :on_escalation, &default_escalation/1)
    }

    # Kick off the first observation as soon as we are initialized, without
    # blocking init/1.
    {:ok, :observing, data, [{:next_event, :internal, :observe}]}
  end

  # --- OBSERVE → DIFF → DECIDE -------------------------------------------------
  #
  # A single internal :observe event evaluates the whole predicate vector, records
  # it (DIFF: failing/regressions are derived from it), and hands off to the
  # decide step. Modeled as one event so observe→diff→decide is atomic per
  # iteration.
  @impl :gen_statem
  def handle_event(:internal, :observe, :observing, %Data{} = data) do
    # T1.4 budget: the hard ceiling is checked ONCE at the start of every tick,
    # BEFORE observing/dispatching more work. If a dimension is exceeded the loop
    # makes a hard stop here — it does not dispatch another agent / integrate /
    # deploy — terminating as :over_budget with the exceeded dimension as reason.
    case budget_check(data) do
      {:stop, reason} ->
        terminate_over_budget(reason, data)

      :ok ->
        observe_tick(data)
    end
  end

  # --- ACT: dispatch the coding agent against failing-predicate evidence -------
  def handle_event(:internal, {:act, %Action{kind: :dispatch_agent} = action}, :acting, data) do
    prompt = dispatch_prompt(action, data)

    result = data.harness.run(prompt, data.workspace, data.adapter_opts)

    # T1.4 budget: accumulate this run's token estimate (if the harness reported
    # one) into the running total the budget guard checks next tick.
    data = accumulate_tokens(data, result)

    # The code changed under us: any prior land/deploy is now stale. Re-observe
    # on the poll interval (not zero) so a goal whose code predicate never goes
    # green polls rather than busy-spinning, and stays interruptible by `:stop`.
    data = record_action(data, action, landed?: false, deployed?: false)
    reobserve(data, data.reobserve_interval_ms)
  end

  # --- ACT: integrate (land the converged code change) -------------------------
  def handle_event(:internal, {:act, %Action{kind: :integrate} = action}, :acting, data) do
    result = data.integrate.execute(action, action_context(action, data))
    # On success mark the change landed; on failure record only — re-observe and
    # let decide pick the next move (it will retry integrate while code is green).
    flags = if succeeded?(result), do: [landed?: true], else: []
    data = record_action(data, action, flags)
    reobserve(data, 0)
  end

  # --- ACT: deploy (ship the landed artifact) ----------------------------------
  def handle_event(:internal, {:act, %Action{kind: :deploy} = action}, :acting, data) do
    result = data.deploy.execute(action, action_context(action, data))
    flags = if succeeded?(result), do: [deployed?: true], else: []
    data = record_action(data, action, flags)
    reobserve(data, 0)
  end

  # --- re-observe poll: every observation after the first is driven by this
  # state timeout. Routing re-observation through a (possibly zero-delay) state
  # timeout rather than an immediate internal event is what keeps the loop from
  # starving its mailbox: queued external casts (notably `:stop`) are drained
  # before the timeout fires, so the loop is always interruptible — and a
  # not-yet-passing live predicate polls on `reobserve_interval_ms` instead of
  # busy-spinning.
  def handle_event({:timeout, :reobserve}, :reobserve, :observing, %Data{}) do
    {:keep_state_and_data, [{:next_event, :internal, :observe}]}
  end

  # --- stop / await / snapshot (handled in any state) --------------------------
  def handle_event(:cast, :stop, state, %Data{} = data)
      when state not in [:converged, :stopped, :over_budget] do
    terminate_with(:stopped, data)
  end

  def handle_event(:cast, :stop, _state, _data), do: :keep_state_and_data

  # In a terminal state the result is cached in data; reply to await immediately.
  def handle_event({:call, from}, :await, state, %Data{} = data)
      when state in [:converged, :stopped, :over_budget] do
    {:keep_state_and_data, [{:reply, from, {:ok, data.result}}]}
  end

  def handle_event({:call, from}, :await, _state, %Data{} = data) do
    {:keep_state, %Data{data | waiters: [from | data.waiters]}}
  end

  def handle_event({:call, from}, :snapshot, state, data) do
    reply = %{
      state: state,
      vector: data.vector,
      history: ordered_history(data),
      actions: Enum.reverse(data.actions),
      iterations: data.iterations,
      landed?: data.landed?,
      deployed?: data.deployed?,
      # T1.3 flake: the predicate ids currently quarantined as flaky.
      quarantine: MapSet.to_list(data.quarantine),
      # T1.4 budget: current token spend + the dimension that stopped the loop
      # (nil unless it stopped :over_budget).
      tokens_used: data.tokens_used,
      budget_reason: data.budget_reason,
      # T1.5 stuck: the persistent failing set the loop stopped stuck on, or nil
      # if it did not stop stuck.
      stuck_failing: stuck_failing_list(data.stuck_failing)
    }

    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def handle_event({:call, from}, :history, _state, data) do
    {:keep_state_and_data, [{:reply, from, ordered_history(data)}]}
  end

  # =============================================================================
  # OBSERVE
  # =============================================================================

  # The normal observe → diff → decide tick, reached only when the budget guard
  # passed (T1.4).
  defp observe_tick(%Data{} = data) do
    # T1.3 flake: observe now also evolves the quarantine set (a failing
    # predicate is re-run via the real provider path and may be classified flaky).
    {vector, quarantine} = observe(data)

    # 0-based per-goal iteration index for this observation (matches the
    # read-model's iteration_index and the on_iteration payload's :iteration).
    index = data.iterations

    data =
      %Data{
        data
        | prev_vector: data.vector,
          vector: vector,
          # T1.3 flake: carry the (sticky) quarantine set forward.
          quarantine: quarantine,
          # Prepend this observation's full vector to the in-state history
          # (newest-first; read APIs reverse to oldest-first). T1.1.
          history: [{index, vector} | data.history],
          iterations: data.iterations + 1
      }

    log_diff(data)
    notify_iteration(data)

    # T1.5 stuck: with the freshly-appended history in hand, ask the pure
    # detector whether the same non-empty failing set has persisted across the
    # last N observations. On a stuck verdict, fire the human-escalation hook and
    # stop (a terminal `:stopped` with reason `:stuck`) rather than dispatching
    # more work. Additive: this composes ahead of `decide` and touches neither
    # the `:converged` guard (T0.8), the budget logic (T1.4), nor the flake logic
    # (T1.3). If not stuck, fall through to `decide` unchanged.
    #
    # The history is reduced to only the CODE predicates the agent can actually
    # act on — live predicates (deployed, legitimately polled in step 5) and
    # quarantined ones (T1.3, no convergence claim) are excluded — so a loop
    # merely WAITING on a live probe is not mistaken for a stalled agent.
    case StuckDetector.stuck?(code_history(data), data.stuck_iterations) do
      {:stuck, failing} -> terminate_stuck(failing, data)
      :not_stuck -> decide(vector, data)
    end
  end

  # T1.5 stuck: the per-iteration history reduced to only the actionable CODE
  # predicates — each historical vector stripped of live predicates (which the
  # loop polls in step 5, not fixes) and quarantined predicates (T1.3). The stuck
  # detector then sees only the failing set the agent is responsible for, so a
  # persistently-red live probe never trips an escalation.
  @spec code_history(Data.t()) :: history()
  defp code_history(%Data{goal: goal, live_kinds: live_kinds, quarantine: quarantine} = data) do
    kinds = predicate_kinds(goal)
    live_ids = for {id, kind} <- kinds, MapSet.member?(live_kinds, kind), do: id
    drop_ids = MapSet.union(quarantine, MapSet.new(live_ids))

    for {index, %PredicateVector{results: results}} <- ordered_history(data) do
      {index, results |> Map.drop(MapSet.to_list(drop_ids)) |> PredicateVector.new()}
    end
  end

  # Evaluate every predicate the goal carries (predicates ++ guards) via its
  # registered provider, building the PredicateVector for this observation.
  #
  # T1.3 flake: returns `{vector, quarantine}` — observation also evolves the
  # (sticky) quarantine set, because a failing predicate is re-run through the
  # real provider path and may be classified flaky. The fold threads the set so
  # one observation can quarantine several predicates.
  @spec observe(Data.t()) :: {PredicateVector.t(), MapSet.t()}
  defp observe(%Data{goal: goal} = data) do
    context = provider_context(data)

    {pairs, quarantine} =
      goal
      |> Goal.all_predicates()
      |> Enum.map_reduce(data.quarantine, fn %Predicate{} = predicate, quarantine ->
        {result, quarantine} = evaluate(predicate, context, data, quarantine)
        {{predicate.id, result}, quarantine}
      end)

    {PredicateVector.new(pairs), quarantine}
  end

  # Evaluate one predicate, applying the T1.3 flake re-run policy and folding any
  # flake into `quarantine`. Returns `{result, quarantine}`.
  @spec evaluate(Predicate.t(), map(), Data.t(), MapSet.t()) :: {PredicateResult.t(), MapSet.t()}
  defp evaluate(%Predicate{id: id} = predicate, context, %Data{} = data, quarantine) do
    cond do
      # Already-quarantined predicates are not re-evaluated as work: record them
      # as :unknown (no convergence claim) so they neither become work nor block
      # convergence. Quarantine is sticky for the run.
      Flake.quarantined?(quarantine, id) ->
        {Flake.quarantined_result(PredicateResult.unknown()), quarantine}

      true ->
        first = run_provider(predicate, context, data)
        apply_flake_policy(predicate, context, data, quarantine, first)
    end
  end

  # T1.3 flake: a passing first result is taken at face value; a failing/erroring
  # one is re-run up to `flake_max_retries` times via the REAL provider path, and
  # the result SEQUENCE is classified (pure `Kazi.Loop.Flake.classify/1`). A
  # `:flaky` verdict quarantines the predicate and records it as :unknown; a real
  # `:fail` is recorded unchanged (the last run's result), so a consistently
  # failing predicate still drives a dispatch exactly as before.
  @spec apply_flake_policy(Predicate.t(), map(), Data.t(), MapSet.t(), PredicateResult.t()) ::
          {PredicateResult.t(), MapSet.t()}
  defp apply_flake_policy(
         %Predicate{id: id} = predicate,
         context,
         %Data{} = data,
         quarantine,
         first
       ) do
    if Flake.needs_rerun?(first) do
      reruns =
        for _ <- 1..data.flake_max_retries//1, do: run_provider(predicate, context, data)

      sequence = [first | reruns]

      case Flake.classify(sequence) do
        :flaky ->
          {Flake.quarantined_result(List.last(sequence)),
           Flake.quarantine(quarantine, id, :flaky)}

        # Consistent non-pass: record the last (re-run) result as the real one.
        _fail ->
          {List.last(sequence), quarantine}
      end
    else
      {first, quarantine}
    end
  end

  # The real provider invocation for one predicate (used by both the first
  # evaluation and every re-run, so the flake policy works for ANY provider).
  @spec run_provider(Predicate.t(), map(), Data.t()) :: PredicateResult.t()
  defp run_provider(%Predicate{kind: kind} = predicate, context, %Data{providers: providers}) do
    case Map.get(providers, kind) do
      nil ->
        # No provider registered for this kind: an infra/config problem, not
        # failing work. Surface as :error (PredicateResult contract).
        PredicateResult.error(%{reason: :no_provider, kind: kind})

      provider ->
        provider.evaluate(predicate, context)
    end
  end

  # =============================================================================
  # DECIDE
  # =============================================================================

  # The heart of the loop: given a fresh vector + progress, choose the next move.
  @spec decide(PredicateVector.t(), Data.t()) :: :gen_statem.event_handler_result(atom())
  defp decide(vector, %Data{} = data) do
    cond do
      # 1. Whole vector satisfied (incl. live predicates): converged, stop.
      #    `:converged` is reachable through this clause and no other — the
      #    objective-termination guard (T0.8, UC-005). T1.3 flake: quarantined
      #    predicates are EXCLUDED from this check (they carry no convergence
      #    claim), so a flake neither counts toward nor blocks convergence.
      all_satisfied?(vector, data.quarantine) ->
        terminate_with(:converged, data)

      # 2. Code predicates failing: dispatch the agent with failing evidence.
      code_failing?(vector, data) ->
        act(dispatch_action(vector, data), data)

      # 3. Code green but not landed: integrate.
      not data.landed? ->
        act(Action.new(:integrate, params: data.integrate_params), data)

      # 4. Landed but not deployed: deploy, then re-observe live predicates.
      not data.deployed? ->
        act(Action.new(:deploy, params: data.deploy_params), data)

      # 5. Landed + deployed, code green, but the whole vector still isn't
      #    satisfied (a live predicate is still :fail / :error / :unknown).
      #    Re-observe on a poll interval until it flips or the operator stops the
      #    loop (a state timeout yields the scheduler — no busy-spin).
      true ->
        reobserve(data, data.reobserve_interval_ms)
    end
  end

  # ---------------------------------------------------------------------------
  # Objective-termination guard (T0.8, UC-005)
  #
  # The ONLY gate to the `:converged` terminal state. `:converged` is success,
  # and success is objective: it requires the ENTIRE predicate vector to hold —
  # every predicate, including LIVE ones (`:http_probe`, `:prod_logs`, …) that
  # only pass once the change is deployed and re-observed against the running
  # system (concept §1, §5). A failing live probe therefore blocks convergence
  # exactly as a failing test does; the loop keeps reconciling instead of
  # declaring a success that isn't live.
  #
  # This is a thin, deliberately named wrapper over
  # `Kazi.PredicateVector.satisfied?/1` (which already rejects an empty vector —
  # the vacuous-goal guard). Naming it here makes the convergence invariant a
  # single, self-documenting clause in `decide/1` that cannot silently regress
  # to "code green is good enough".
  #
  # T1.3 flake: quarantined predicates are dropped from the vector before the
  # satisfaction check — a known-flaky predicate carries no convergence claim and
  # must neither block nor count toward convergence. The empty-vector guard still
  # holds: a goal whose every predicate is quarantined (nothing left to assert
  # over) is NOT satisfied, so it cannot converge vacuously.
  @spec all_satisfied?(PredicateVector.t(), MapSet.t()) :: boolean()
  defp all_satisfied?(%PredicateVector{} = vector, %MapSet{} = quarantine) do
    vector
    |> drop_quarantined(quarantine)
    |> PredicateVector.satisfied?()
  end

  # Return the vector with all quarantined predicate ids removed.
  @spec drop_quarantined(PredicateVector.t(), MapSet.t()) :: PredicateVector.t()
  defp drop_quarantined(%PredicateVector{results: results}, %MapSet{} = quarantine) do
    results
    |> Map.drop(MapSet.to_list(quarantine))
    |> PredicateVector.new()
  end

  # Transition into :observing and schedule the next observation after `delay_ms`
  # via a state timeout (see the :reobserve handler for why this is a timeout and
  # not an immediate internal event).
  defp reobserve(%Data{} = data, delay_ms) do
    {:next_state, :observing, data, [{{:timeout, :reobserve}, delay_ms, :reobserve}]}
  end

  # True iff at least one *code* predicate (non-live kind) is failing. Live
  # predicates only pass after deploy, so they must not trigger a code dispatch.
  @spec code_failing?(PredicateVector.t(), Data.t()) :: boolean()
  defp code_failing?(vector, %Data{goal: goal, live_kinds: live_kinds}) do
    kinds = predicate_kinds(goal)

    vector
    |> PredicateVector.failing()
    |> Enum.any?(fn id -> not MapSet.member?(live_kinds, Map.get(kinds, id)) end)
  end

  # Build the :dispatch_agent action, carrying the failing code predicates and
  # their evidence as params (this is what seeds the harness prompt, concept §5).
  @spec dispatch_action(PredicateVector.t(), Data.t()) :: Action.t()
  defp dispatch_action(vector, %Data{goal: goal, live_kinds: live_kinds} = _data) do
    kinds = predicate_kinds(goal)

    failing =
      vector
      |> PredicateVector.failing()
      |> Enum.reject(fn id -> MapSet.member?(live_kinds, Map.get(kinds, id)) end)

    evidence =
      Map.new(failing, fn id -> {id, PredicateVector.get(vector, id).evidence} end)

    Action.new(:dispatch_agent,
      params: %{failing: failing, evidence: evidence},
      metadata: %{goal_id: goal.id}
    )
  end

  # =============================================================================
  # ACT helpers
  # =============================================================================

  # Move to :acting and fire the chosen action as an internal event so it is
  # handled by the matching ACT clause.
  defp act(%Action{} = action, data) do
    {:next_state, :acting, data, [{:next_event, :internal, {:act, action}}]}
  end

  # The prompt seeding the harness with the failing-predicate evidence
  # (concept §5). The concrete claude -p adapter (T0.6) owns prompt shaping; here
  # we hand it a deterministic, evidence-bearing string the test doubles can
  # observe.
  @spec dispatch_prompt(Action.t(), Data.t()) :: String.t()
  defp dispatch_prompt(%Action{params: params}, %Data{goal: goal}) do
    failing = Map.get(params, :failing, [])

    "goal=#{goal.id} fix failing predicates: #{Enum.map_join(failing, ",", &to_string/1)}\n" <>
      "evidence: #{inspect(Map.get(params, :evidence, %{}))}"
  end

  # Context threaded to an action's execute/2 (Kazi.Action.context). A plain map
  # so the contract stays decoupled from the loop's internal state shape.
  @spec action_context(Action.t(), Data.t()) :: map()
  defp action_context(_action, %Data{} = data) do
    # Caller-supplied static context (e.g. the integrate :integrator seam, the
    # deploy :deploy_cmd seam) is merged UNDER the loop's own keys so the loop's
    # facts (goal/workspace/vector/progress) always win.
    Map.merge(data.extra_action_context, %{
      goal: data.goal,
      workspace: data.workspace,
      vector: data.vector,
      failing: PredicateVector.failing(data.vector),
      landed?: data.landed?,
      deployed?: data.deployed?
    })
  end

  # Context threaded to a provider's evaluate/2 (Kazi.PredicateProvider.context).
  @spec provider_context(Data.t()) :: map()
  defp provider_context(%Data{} = data) do
    %{
      goal: data.goal,
      scope: data.goal.scope,
      workspace: data.workspace,
      landed?: data.landed?,
      deployed?: data.deployed?,
      iteration: data.iterations
    }
  end

  # The in-state history (T1.1) is kept newest-first in `data` for O(1) prepend;
  # readers (snapshot/1, history/1) want it oldest-first (ascending iteration
  # index), so reverse it on the way out.
  @spec ordered_history(Data.t()) :: history()
  defp ordered_history(%Data{history: history}), do: Enum.reverse(history)

  # Record an executed action in history and apply any progress-flag changes.
  defp record_action(%Data{} = data, %Action{kind: kind}, flags) do
    %Data{
      data
      | actions: [kind | data.actions],
        landed?: Keyword.get(flags, :landed?, data.landed?),
        deployed?: Keyword.get(flags, :deployed?, data.deployed?)
    }
  end

  # =============================================================================
  # Termination
  # =============================================================================

  # Transition to a terminal state (`:converged` | `:stopped` | `:over_budget`)
  # and stay alive, caching the final result and flushing it to every pending
  # await waiter. The process is left running (not stopped) so late `await/2` and
  # `snapshot/1` calls still succeed; the operator/owner tears it down. Terminal
  # states accept no further observe/act events.
  defp terminate_with(outcome, %Data{} = data) do
    result = build_result(outcome, data)
    replies = for from <- data.waiters, do: {:reply, from, {:ok, result}}
    data = %Data{data | result: result, waiters: []}
    {:next_state, outcome, data, replies}
  end

  @spec build_result(atom(), Data.t()) :: result()
  defp build_result(state, %Data{} = data) do
    outcome =
      case state do
        :converged -> :converged
        :over_budget -> :over_budget
        _ -> :stopped
      end

    %{
      outcome: outcome,
      # T1.4 budget: the exceeded dimension on an :over_budget stop; T1.5 stuck:
      # `:stuck` on a stuck `:stopped`. nil otherwise.
      reason: stop_reason(data),
      vector: data.vector,
      actions: Enum.reverse(data.actions),
      iterations: data.iterations
    }
  end

  # The terminal result's `:reason`: the budget dimension on an :over_budget stop
  # (T1.4), `:stuck` on a stuck stop (T1.5), nil otherwise.
  @spec stop_reason(Data.t()) :: Budget.reason() | :stuck | nil
  defp stop_reason(%Data{stuck_failing: failing}) when not is_nil(failing), do: :stuck
  defp stop_reason(%Data{budget_reason: reason}), do: reason

  # T1.5 stuck: render the stuck failing set (a MapSet, or nil) as a sorted list
  # for snapshot/1, or nil if the loop did not stop stuck.
  @spec stuck_failing_list(StuckDetector.failing_set() | nil) :: [Kazi.Predicate.id()] | nil
  defp stuck_failing_list(nil), do: nil
  defp stuck_failing_list(%MapSet{} = failing), do: Enum.sort(MapSet.to_list(failing))

  # =============================================================================
  # T1.5 stuck: human escalation + terminal stop
  # =============================================================================

  # Stuck stop (T1.5): record the persistent failing set, fire the
  # human-escalation hook ONCE (hand the goal off to a person), project the stop
  # through the persistence seam, then transition to the terminal `:stopped`
  # state. No further agent/integrate/deploy is dispatched (concept §5:
  # escalate rather than keep burning iterations). The result's reason is `:stuck`
  # (see `stop_reason/1`).
  defp terminate_stuck(failing, %Data{} = data) do
    data = %Data{data | stuck_failing: failing}
    notify_escalation(data, failing)
    notify_stuck_stop(data)
    terminate_with(:stopped, data)
  end

  # Fire the human-escalation callback with the stuck context (the persistent
  # failing set, the goal, and the iteration index at which it fired). Side-effect
  # only and contained: a raising hook is logged and never blocks the stop.
  @spec notify_escalation(Data.t(), StuckDetector.failing_set()) :: :ok
  defp notify_escalation(%Data{on_escalation: callback} = data, failing)
       when is_function(callback, 1) do
    payload = %{
      goal: data.goal,
      failing: failing,
      # 0-based index of the observation that produced the stuck verdict.
      iterations: data.iterations - 1
    }

    try do
      callback.(payload)
    rescue
      error ->
        Logger.warning(fn ->
          "kazi.loop on_escalation callback raised: #{Exception.message(error)}"
        end)
    end

    :ok
  end

  defp notify_escalation(%Data{}, _failing), do: :ok

  # The default human-escalation hook: a warning that names the goal and the
  # persistent failing set, so an operator watching the logs is paged to step in.
  @spec default_escalation(map()) :: :ok
  defp default_escalation(%{goal: goal, failing: failing}) do
    Logger.warning(fn ->
      "kazi.loop goal=#{goal.id} STUCK — same failing set persisted: " <>
        "#{inspect(MapSet.to_list(failing))}. Escalating to a human."
    end)

    :ok
  end

  # Project the stuck stop through the SAME persistence seam (`on_iteration`) as
  # the budget stop (T1.4), so the stuck terminal — and its failing set — is
  # recorded in the iteration log / read-model. Reuses the last observed vector at
  # the index that produced the verdict; carries `:stop_reason` `:stuck`.
  # Side-effect only and contained.
  defp notify_stuck_stop(%Data{on_iteration: nil}), do: :ok

  defp notify_stuck_stop(%Data{on_iteration: callback} = data)
       when is_function(callback, 1) do
    payload = %{
      goal: data.goal,
      iteration: data.iterations - 1,
      vector: data.vector || PredicateVector.new(),
      converged?: false,
      stop_reason: :stuck
    }

    try do
      callback.(payload)
    rescue
      error ->
        Logger.warning(fn ->
          "kazi.loop on_iteration (stuck stop) callback raised: #{Exception.message(error)}"
        end)
    end

    :ok
  end

  # =============================================================================
  # T1.4 budget: usage tracking + the hard ceiling
  # =============================================================================

  # Check the goal's hard budget ceiling against current usage. Pure decision
  # lives in `Kazi.Loop.Budget`; here we only assemble the usage from loop state
  # (iterations so far, elapsed wall-clock via the injectable clock, accumulated
  # token estimate) and pass it through.
  @spec budget_check(Data.t()) :: :ok | {:stop, Budget.reason()}
  defp budget_check(%Data{budget: nil}), do: :ok

  defp budget_check(%Data{budget: budget} = data) do
    Budget.check(budget, %{
      iterations: data.iterations,
      elapsed_ms: elapsed_ms(data),
      tokens: data.tokens_used
    })
  end

  # Wall-clock elapsed since the loop started, in ms, via the injectable clock.
  @spec elapsed_ms(Data.t()) :: non_neg_integer()
  defp elapsed_ms(%Data{now_fn: now_fn, started_at_ms: started_at_ms}) do
    max(now_fn.() - started_at_ms, 0)
  end

  # Hard budget stop: record the exceeded dimension, project the stop into the
  # read-model / persistence seam, then transition to the terminal :over_budget
  # state. No further agent/integrate/deploy is dispatched (concept §5).
  defp terminate_over_budget(reason, %Data{} = data) do
    data = %Data{data | budget_reason: reason}
    notify_budget_stop(data)
    terminate_with(:over_budget, data)
  end

  # Add a harness run's token estimate to the running total. The estimate is read
  # from the result's cost map (`%{cost: %{tokens: n}}`, the HarnessAdapter
  # contract); a result without a token estimate contributes nothing.
  @spec accumulate_tokens(Data.t(), Kazi.HarnessAdapter.result()) :: Data.t()
  defp accumulate_tokens(%Data{} = data, result) do
    %Data{data | tokens_used: data.tokens_used + token_estimate(result)}
  end

  @spec token_estimate(Kazi.HarnessAdapter.result()) :: non_neg_integer()
  defp token_estimate({:ok, %{cost: %{tokens: tokens}}}) when is_integer(tokens) and tokens >= 0,
    do: tokens

  defp token_estimate(_), do: 0

  # =============================================================================
  # Misc helpers
  # =============================================================================

  # Map of predicate id => kind, for classifying code vs live predicates.
  @spec predicate_kinds(Goal.t()) :: %{optional(Predicate.id()) => Predicate.provider_kind()}
  defp predicate_kinds(%Goal{} = goal) do
    goal
    |> Goal.all_predicates()
    |> Map.new(fn %Predicate{id: id, kind: kind} -> {id, kind} end)
  end

  # An Action.result/0 counts as success when it is :ok or {:ok, _}.
  @spec succeeded?(Action.result()) :: boolean()
  defp succeeded?(:ok), do: true
  defp succeeded?({:ok, _}), do: true
  defp succeeded?(_), do: false

  defp fetch!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "Kazi.Loop requires the #{inspect(key)} option"
    end
  end

  # Fire the optional per-iteration persistence seam (T0.7b). Side-effect only:
  # it observes the freshly-built vector and reports whether the WHOLE vector is
  # satisfied — it cannot influence `decide`, and a nil/raising callback is
  # contained so persistence trouble never stalls or alters convergence.
  defp notify_iteration(%Data{on_iteration: nil}), do: :ok

  defp notify_iteration(%Data{on_iteration: callback} = data) when is_function(callback, 1) do
    payload = %{
      goal: data.goal,
      # 0-based per-goal index matching the read-model's iteration_index column.
      iteration: data.iterations - 1,
      vector: data.vector,
      converged?: PredicateVector.satisfied?(data.vector)
    }

    try do
      callback.(payload)
    rescue
      error ->
        Logger.warning(fn ->
          "kazi.loop on_iteration callback raised: #{Exception.message(error)}"
        end)
    end

    :ok
  end

  # T1.4 budget: project the hard budget stop through the SAME persistence seam
  # (`on_iteration`) so the stop — and the exceeded dimension — is recorded in the
  # iteration log, making the budget terminal visible there (acceptance #4). It
  # reuses the last observed vector at a fresh iteration index (one past the last
  # observation) and carries the budget reason as `:stop_reason`. Side-effect
  # only and contained, exactly like `notify_iteration/1`.
  defp notify_budget_stop(%Data{on_iteration: nil}), do: :ok

  defp notify_budget_stop(%Data{on_iteration: callback, budget_reason: reason} = data)
       when is_function(callback, 1) do
    payload = %{
      goal: data.goal,
      # A fresh index beyond the last observation: the budget-stop record.
      iteration: data.iterations,
      vector: data.vector || PredicateVector.new(),
      converged?: false,
      stop_reason: reason
    }

    try do
      callback.(payload)
    rescue
      error ->
        Logger.warning(fn ->
          "kazi.loop on_iteration (budget stop) callback raised: #{Exception.message(error)}"
        end)
    end

    :ok
  end

  defp log_diff(%Data{vector: vector, prev_vector: prev} = data) do
    failing = PredicateVector.failing(vector)

    regressions =
      if prev, do: PredicateVector.regressions(prev, vector), else: []

    Logger.debug(fn ->
      "kazi.loop goal=#{data.goal.id} iter=#{data.iterations} " <>
        "failing=#{inspect(failing)} regressions=#{inspect(regressions)} " <>
        "landed?=#{data.landed?} deployed?=#{data.deployed?}"
    end)
  end
end
