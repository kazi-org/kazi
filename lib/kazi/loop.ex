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

  require Logger

  @default_live_kinds [:http_probe, :prod_logs, :browser]

  # When code is green and the change is landed + deployed but the whole vector is
  # still not satisfied (a live predicate has not yet flipped to :pass), the loop
  # re-observes on this interval rather than busy-spinning. Injectable via
  # `:reobserve_interval_ms`.
  @default_reobserve_ms 1_000

  @typedoc """
  The terminal outcome reported when the loop stops.

    * `:converged` — the whole predicate vector is satisfied (success).
    * `:stopped`   — the loop was asked to stop before converging.
  """
  @type outcome :: :converged | :stopped

  @typedoc "The final result handed to `await/2` waiters when the loop stops."
  @type result :: %{
          outcome: outcome(),
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
              # cached terminal result + await/2 waiters
              result: nil,
              waiters: []
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
    * `:on_iteration` — an optional side-effect-only callback invoked once per
      observation, *after* the vector is built and *before* `decide`, as
      `fun.(%{goal: goal, iteration: index, vector: vector, converged?: boolean})`
      (`index` is the 0-based per-goal iteration counter). It is the persistence
      seam the runtime (T0.7b) uses to project each iteration into the read-model;
      it must not influence convergence (its return value is ignored), and a
      raising callback is contained. Default `nil` (no-op).
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
  snapshot.
  """
  @spec snapshot(:gen_statem.server_ref()) :: %{
          state: atom(),
          vector: PredicateVector.t() | nil,
          history: history(),
          actions: [Action.kind()],
          iterations: non_neg_integer(),
          landed?: boolean(),
          deployed?: boolean()
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
    data = %Data{
      goal: fetch!(opts, :goal),
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
      extra_action_context: Map.new(Keyword.get(opts, :extra_action_context, %{}))
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
    vector = observe(data)

    # 0-based per-goal iteration index for this observation (matches the
    # read-model's iteration_index and the on_iteration payload's :iteration).
    index = data.iterations

    data =
      %Data{
        data
        | prev_vector: data.vector,
          vector: vector,
          # Prepend this observation's full vector to the in-state history
          # (newest-first; read APIs reverse to oldest-first). T1.1.
          history: [{index, vector} | data.history],
          iterations: data.iterations + 1
      }

    log_diff(data)
    notify_iteration(data)

    decide(vector, data)
  end

  # --- ACT: dispatch the coding agent against failing-predicate evidence -------
  def handle_event(:internal, {:act, %Action{kind: :dispatch_agent} = action}, :acting, data) do
    prompt = dispatch_prompt(action, data)

    _ = data.harness.run(prompt, data.workspace, data.adapter_opts)

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
      when state not in [:converged, :stopped] do
    terminate_with(:stopped, data)
  end

  def handle_event(:cast, :stop, _state, _data), do: :keep_state_and_data

  # In a terminal state the result is cached in data; reply to await immediately.
  def handle_event({:call, from}, :await, state, %Data{} = data)
      when state in [:converged, :stopped] do
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
      deployed?: data.deployed?
    }

    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def handle_event({:call, from}, :history, _state, data) do
    {:keep_state_and_data, [{:reply, from, ordered_history(data)}]}
  end

  # =============================================================================
  # OBSERVE
  # =============================================================================

  # Evaluate every predicate the goal carries (predicates ++ guards) via its
  # registered provider, building the PredicateVector for this observation.
  @spec observe(Data.t()) :: PredicateVector.t()
  defp observe(%Data{goal: goal} = data) do
    context = provider_context(data)

    goal
    |> Goal.all_predicates()
    |> Enum.map(fn %Predicate{} = predicate ->
      {predicate.id, evaluate(predicate, context, data)}
    end)
    |> PredicateVector.new()
  end

  @spec evaluate(Predicate.t(), map(), Data.t()) :: PredicateResult.t()
  defp evaluate(%Predicate{kind: kind} = predicate, context, %Data{providers: providers}) do
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
      #    objective-termination guard (T0.8, UC-005).
      all_satisfied?(vector) ->
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
  @spec all_satisfied?(PredicateVector.t()) :: boolean()
  defp all_satisfied?(%PredicateVector{} = vector), do: PredicateVector.satisfied?(vector)

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

  # Transition to a terminal state (`:converged` | `:stopped`) and stay alive,
  # caching the final result and flushing it to every pending await waiter. The
  # process is left running (not stopped) so late `await/2` and `snapshot/1`
  # calls still succeed; the operator/owner tears it down. Terminal states accept
  # no further observe/act events.
  defp terminate_with(outcome, %Data{} = data) do
    result = build_result(outcome, data)
    replies = for from <- data.waiters, do: {:reply, from, {:ok, result}}
    data = %Data{data | result: result, waiters: []}
    {:next_state, outcome, data, replies}
  end

  @spec build_result(atom(), Data.t()) :: result()
  defp build_result(state, %Data{} = data) do
    outcome = if state == :converged, do: :converged, else: :stopped

    %{
      outcome: outcome,
      vector: data.vector,
      actions: Enum.reverse(data.actions),
      iterations: data.iterations
    }
  end

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
