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
  deployed system (`:http_probe`, `:prod_log`, `:browser` by default) and only
  pass once the change is deployed; everything else (`:tests`, `:coverage`, …) is
  code. The set is injectable via the `:live_kinds` option so the loop stays
  decoupled from any concrete provider.

  ## Standing (continuous) mode (T3.4a, UC-016)

  By default the loop is a *converge-and-stop* reconciler: the FIRST time the
  whole vector is satisfied it transitions to the terminal `:converged` state and
  reports success (clause 1 of decide, the T0.8 guard). A **standing** loop
  (`standing: true`) is instead a *maintenance reconciler*: when the whole vector
  is satisfied it does NOT terminate — it records the converged observation,
  enters a steady observing state, and keeps re-observing on the bounded
  `:reobserve_interval_ms` interval, staying alive to hold the goal's predicates
  true forever (concept §10, "standing reconcilers"). Everything else about the
  tick is unchanged: while a code predicate is failing it still dispatches, while
  not landed it integrates, etc. Only the success edge differs — converge-and-keep
  rather than converge-and-stop.

  Standing mode is the FOUNDATION for re-trigger-on-drift (T3.4b) and graceful
  stop (T3.4c): because the loop keeps observing past convergence, a satisfied
  predicate that later regresses will be seen on the next observation and routed
  back through the ordinary decide machinery.

  ## Re-trigger on drift (T3.4b, UC-016)

  Drift re-trigger is realized *entirely through the existing convergence
  machinery* — there is no separate drift handler. When a standing loop is steady
  (clause 1 of decide kept it alive and re-observing) and a previously-satisfied
  code predicate REGRESSES on a later re-observation, the fresh vector is no
  longer satisfied, so `decide/2` falls through to clause 2 (`code_failing?`) and
  dispatches the coding agent against the drifted predicate exactly as for a
  first-time failure. The `:dispatch_agent` ACT clause re-invalidates any prior
  land/deploy (`landed?: false, deployed?: false`), so the loop then re-integrates
  and re-deploys "as appropriate" before the next satisfied observation re-enters
  clause 1 and returns it to steady observing (`converge_or_stay/1`). Reusing the
  decide/act path — rather than forking a parallel reconcile — is the design: a
  drift is just another unsatisfied observation. See the `# T3.4b drift` comments
  at those two seams in `decide/2` and `converge_or_stay/1`.

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

  alias Kazi.{Action, Goal, Predicate, PredicateResult, PredicateVector, Retrieval}
  # T4.9c retrieval opt-in (ADR-0012): the loop appends the goal-declared
  # retriever's snippets to the dispatch prompt, reusing the adapter's render so
  # the section is byte-identical to `build_prompt/3`'s (see `dispatch_prompt/2`).
  alias Kazi.Harness.Prompt
  # T36.2 (ADR-0047 §1): the minimal default tool/MCP surface for a reconcile
  # dispatch — injected MCP servers + standard edit/shell tools, not the ambient
  # set. Consumed in `dispatch_agent/2`.
  alias Kazi.Harness.DispatchSurface
  # T3.1d resource lease: the per-key lease substrate (acquire/renew/release via
  # CAS + TTL on an injected clock, ADR-0006). The loop leases the goal's resource
  # key before dispatch so contending instances serialize (see the dispatch-prep
  # region of the `:dispatch_agent` ACT clause and `release_lease/1` on terminate).
  alias Kazi.Coordination.Lease
  # T1.3 flake: the pure re-run/quarantine policy lives in its own module; the
  # loop only routes failing-predicate evaluation through it (see observe/1).
  alias Kazi.Loop.Flake
  # T1.4 budget: the pure budget-ceiling guard (iterations / wall-clock / tokens).
  alias Kazi.Loop.Budget
  # T1.5 stuck: the pure stuck detector (N iterations, same non-empty failing
  # set). The loop only feeds it the T1.1 history and fires the human-escalation
  # hook + terminal stop on its verdict (see observe_tick/1).
  alias Kazi.Loop.StuckDetector
  # T1.2 regression: the pure green→red detector + dispatch attribution. The loop
  # only feeds it the per-iteration history (T1.1) + dispatch log and records the
  # flags it returns (see observe_tick/1).
  alias Kazi.Loop.RegressionDetector
  # T4.7 working-set digest: the pure, bounded "files touched last iteration"
  # distiller. The loop reads the harness result's `:touched` working set through
  # it (map memory ONLY — never the transcript) and threads the digest into the
  # NEXT dispatch's prompt (see the `:dispatch_agent` ACT clause and
  # `dispatch_prompt/2`).
  alias Kazi.Loop.Digest
  # T19.1 orientation prefix (ADR-0010 §3, realizing T4.3): the live dispatch
  # prompt carries kazi's pre-computed map memory (the ranked blast-radius pack)
  # as a STABLE, cacheable PREFIX ahead of the failing-evidence body — so each
  # stateless `claude -p` starts oriented instead of re-exploring. The pack is a
  # pure function of `(failing-slice, workspace, graph_source)`, so its rendered
  # prefix is byte-identical across iterations whose blast radius is unchanged.
  alias Kazi.Context
  alias Kazi.Context.Pack

  require Logger

  # The registered provider kind for production-log evidence is `:prod_log`
  # (singular) — see `Kazi.Providers.ProdLog`, `Kazi.Runtime`, and the goal loader,
  # all of which key on `:prod_log`. It MUST appear here so a red prod-log probe is
  # treated as a LIVE predicate (deploy-gated, polled) rather than a CODE predicate
  # the loop would dispatch a fixer agent to "fix" before the change is even
  # deployed (T1.6/T1.7, UC-021). A prior plural `:prod_logs` here silently
  # mis-classified prod-log predicates as code.
  # T32.10 (ADR-0043): `:metrics` is a live RED/SLO predicate — it only passes
  # against a deployed system, so it MUST be deploy-gated like the other live kinds
  # rather than dispatched to a fixer agent before the change is even deployed.
  @default_live_kinds [:http_probe, :prod_log, :browser, :metrics]

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
          iterations: non_neg_integer(),
          # T3.3d deploy wiring: the release ref recorded on the most recent
          # successful deploy (T3.3c), or nil if nothing was deployed this run.
          release_ref: String.t() | nil,
          # T1.4 budget: the single rolled-up token total the budget guard checks,
          # surfaced so the CLI can render `budget_spent.tokens` (ADR-0046
          # back-compat).
          tokens_used: non_neg_integer(),
          # T34.1 (ADR-0046): the run-aggregate usage envelope — the token/cost
          # components the harness reported, summed across iterations. Only
          # reported components are present (absent ≠ zero); empty when no harness
          # run reported any.
          usage: map()
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
              # T4.5 context injection (ADR-0010 §3): opts forwarded to
              # `Kazi.Workspace.prepare/2`, which runs once before each agent
              # dispatch to expose the code-review-graph MCP in the workspace's
              # `.mcp.json` and refresh its code graph. Carries the `:graph_cmd`
              # seam tests inject; empty in production (real binary default).
              workspace_opts: [],
              live_kinds: nil,
              reobserve_interval_ms: nil,
              # T3.4a standing mode: when true the loop is a maintenance
              # reconciler — it does NOT terminate at :converged but records the
              # converged observation and keeps re-observing on
              # `reobserve_interval_ms`. Default false (converge-and-stop, the
              # T0.8 path). `steady?` is true once a standing loop has reached a
              # satisfied observation (its current observe state is "steady,
              # holding the predicates"); `steady_observations` counts the
              # satisfied observations seen while standing (surfaced in
              # snapshot/1 so a test can assert the loop re-observed past
              # convergence). Both appended last so the existing field order is
              # untouched.
              standing: false,
              steady?: false,
              steady_observations: 0,
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
              # T3.3d deploy wiring: the release ref recorded on the most recent
              # successful deploy (T3.3c release tagging) — the durable identifier
              # naming WHAT was shipped (distinct from the live deploy URL). The
              # deploy ACT clause folds the deploy action result's `:release_ref`
              # here so the runtime/CLI can surface it in the run outcome/snapshot
              # and project it to the read-model. nil until a deploy succeeds with a
              # release ref. Appended last so the existing field order is untouched.
              release_ref: nil,
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
              stuck_failing: nil,
              # --- T1.2 regression: dispatch log + flagged regressions --------
              # Append-only log of {iteration_index, %Action{}} for every agent
              # dispatch, where iteration_index is the observation index the loop
              # had reached when it decided the dispatch (data.iterations - 1 at
              # record time — the observation whose failing work-list seeded it).
              # The regression detector attributes a green→red edge to the most
              # recent dispatch in its [green, red) window. Newest-first in `data`
              # for O(1) prepend; the detector sorts by index. Appended last so the
              # existing field order is untouched.
              dispatch_log: [],
              # The current list of flagged regressions (the detector's output for
              # the latest observation): each a map of predicate_id,
              # green_iteration, red_iteration, status, attributed_dispatch.
              # Recomputed each observation over the full history; surfaced in
              # snapshot/1 and projected to the read-model via on_iteration.
              regressions: [],
              # --- T4.7 working-set digest: map memory across iterations -------
              # The bounded "files touched last iteration" digest (a
              # `Kazi.Loop.Digest`) distilled from the PREVIOUS agent dispatch's
              # touched working set (T4.1 json), threaded into the NEXT dispatch's
              # prompt so a stateless `claude -p` iteration starts knowing WHERE
              # prior work landed without re-exploring (ADR-0010 §4, UC-022).
              # Strictly map memory: it carries file paths only, never the agent's
              # transcript/reasoning/result text — carrying those would re-anchor
              # the agent on a prior approach (ADR-0008). Empty until the first
              # dispatch reports a touched set, so the first iteration's prompt is
              # unchanged. Appended last so the existing field order is untouched.
              working_set_digest: Digest.empty(),
              # --- T3.1d resource lease: serialize work on a resource key -------
              # Before driving the harness against a goal the loop leases the
              # goal's RESOURCE KEY (ADR-0006: coordinate on resources, not
              # identities), so two kazi instances aiming at the SAME key
              # serialize — one works, the other DEFERS rather than colliding
              # (UC-013). All injectable so tests drive the in-memory double and a
              # virtual clock; LEASING IS OFF (a pure no-op) unless a `:lease`
              # backend is supplied, so the existing single-instance loop and its
              # tests are byte-for-byte unchanged. Appended last so the existing
              # field order is untouched.
              #
              #   * `lease` — the `Kazi.Coordination.Lease` backend MODULE, or nil
              #     to disable leasing entirely (the default — no key is held and
              #     dispatch never defers).
              #   * `lease_opts` — backend opts passed verbatim to every
              #     acquire/renew/release (e.g. the in-memory double's `:store`,
              #     and the injectable clock `:now_ms`/`:now_fn`).
              #   * `lease_holder` — this instance's holder id (who holds the
              #     lease); two instances MUST present distinct holders to contend.
              #   * `lease_ttl_ms` — the lease TTL; the loop renews well within it
              #     each time it dispatches so a live instance keeps the key.
              #   * `resource_key` — the derived key this goal leases (computed
              #     once at init from the injectable `:resource_key_fn`); nil when
              #     leasing is off.
              #   * `held_lease` — the `%Kazi.Coordination.Lease{}` currently held
              #     (the CAS revision proving this acquisition), or nil when the
              #     key is not held. Released on terminate.
              lease: nil,
              lease_opts: [],
              lease_holder: nil,
              lease_ttl_ms: nil,
              resource_key: nil,
              held_lease: nil,
              # --- T34.1 (ADR-0046): run-aggregate usage envelope --------------
              # The token/cost components the harness reported, summed across
              # iterations (the cached-vs-fresh split + dollars). Only reported
              # components are accumulated (absent ≠ zero), so an empty map means
              # no harness run reported usage. Surfaced in the terminal result as
              # the additive `usage` envelope; the single rolled-up total stays in
              # `tokens_used` for back-compat. Appended last so the existing field
              # order is untouched.
              usage: %{}
  end

  # T3.1d resource lease: the default TTL a held lease is minted/renewed with. The
  # loop renews on every dispatch (well within the TTL), so a live instance holds
  # the key continuously while a crashed one lets it expire and free for another.
  @default_lease_ttl_ms 30_000

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
      (default `[]`). Also carries dispatch-prompt toggles read by the loop:
      `:orientation_prefix` (T19.4) — when `false`, the T19.1 orientation prefix
      is NOT prepended to the dispatch prompt (the pre-T19.1, evidence-only body;
      the benchmark's arm B). Defaults to `true` (prefix on — the T19.1/arm-C
      default, unchanged).
    * `:live_kinds` — list of predicate kinds treated as *live* (only pass after
      deploy); default `#{inspect(@default_live_kinds)}`.
    * `:standing` — run as a STANDING (continuous/maintenance) reconciler (T3.4a,
      UC-016). When `true`, satisfying the whole vector does NOT terminate the
      loop: it records the converged observation, enters a steady observing
      state, and keeps re-observing on `:reobserve_interval_ms` to hold the
      predicates true forever. When `false` (default) the loop converges-and-stops
      exactly as the T0.8 guard prescribes.
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
    * `:lease` — a `Kazi.Coordination.Lease` backend MODULE to coordinate work on
      the goal's RESOURCE KEY (T3.1d, ADR-0006; UC-013). When supplied, the loop
      acquires the lease BEFORE driving the harness, so two instances targeting
      the same key serialize — one works, the other DEFERS (re-observes without
      dispatching) until the key is free — and RELEASES it on terminate. When
      omitted (default `nil`) leasing is OFF: no key is held and dispatch never
      defers, exactly as before. Pair with `:lease_opts` (backend opts: the
      in-memory double's `:store`, plus the injected clock `:now_ms`/`:now_fn`).
    * `:lease_opts` — opts threaded verbatim to the lease backend's
      acquire/renew/release (default `[]`). Carries the backend handle (e.g.
      `store: store` for `Kazi.Coordination.Lease.Memory`) and, for determinism,
      the injected clock; ignored unless `:lease` is set.
    * `:lease_holder` — this instance's holder id presented to the lease backend
      (default the goal id). Two instances MUST present DISTINCT holders to
      actually contend (same-holder re-acquire is a refresh, not a collision).
    * `:lease_ttl_ms` — the TTL a held lease is minted/renewed with (default
      `#{30_000}` ms); the loop renews on every dispatch, well within it.
    * `:resource_key_fn` — a 1-arity fn `goal -> key` deriving the resource key
      the goal leases (default: `"goal:" <> goal.id`, narrowing to the goal's
      `scope.repo` when set). Injectable so a test can make two goals derive the
      SAME key (to assert serialization) or DISTINCT keys (to assert parallelism).
      Ignored unless `:lease` is set.
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

  # T3.4c supervision safety: a `:gen_statem` does not get a `child_spec/1` for
  # free (that ships with `use GenServer`), so without one a supervisor cannot
  # start the loop as a child — `Supervisor.start_link([{Kazi.Loop, opts}], ...)`
  # would raise `child_spec/1 is undefined`. Defining it here is what lets a
  # standing goal (UC-016) sit in an OTP supervision tree.
  #
  # The default `:restart` is `:transient`: a *clean* stop never restarts. A
  # standing loop reaching a terminal state (`:converged`/`:stopped`) does NOT
  # exit — it stays alive inert so late `await/2`/`snapshot/1` still answer (see
  # `terminate_with/2`) — so a graceful `stop/1` produces no exit and therefore
  # no restart. Only an *abnormal* crash exits the process, and `:transient`
  # restarts exactly that case, giving a supervised standing goal crash recovery
  # without resurrecting a loop the operator deliberately stopped. Callers may
  # override `:id`/`:restart`/`:shutdown` via the standard child-spec overrides.
  @doc """
  Returns a supervisor child specification so a loop can be placed in an OTP
  supervision tree (T3.4c, UC-016) — e.g. `{Kazi.Loop, goal: goal, ...}` as a
  child, or under a `DynamicSupervisor` for one standing goal per child.

  `init_arg` is the same keyword list `start_link/1` takes. The default
  `:restart` is `:transient` (restart only on abnormal exit): a graceful
  `stop/1` leaves the process alive in a terminal state with no exit, so it is
  never restarted; a crash is. Override any field with the standard child-spec
  overrides, e.g. `Kazi.Loop.child_spec(opts) |> Supervisor.child_spec(id: ...)`
  or by passing `:id`/`:restart`/`:shutdown` through.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(init_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Asks the loop to stop. The process transitions to `:stopped` and reports
  `:stopped` to any `await/2` waiters. Idempotent / safe on an already-terminal
  loop.

  Graceful + prompt (T3.4c): `stop/1` is an asynchronous cast. Because every
  re-observe is scheduled as a *state timeout* (never an immediate internal
  event — see the `:reobserve` handler), a queued `:stop` cast is always drained
  by `:gen_statem` BEFORE a pending re-observe timeout fires. A standing loop
  sitting idle between observations therefore stops on the next scheduler turn
  rather than waiting out the full `:reobserve_interval_ms`, no matter how long
  that interval is. The stop is clean: the process moves to the terminal
  `:stopped` state and stays alive (inert) so late `await/2`/`snapshot/1` still
  answer; it dispatches no further agent/integrate/deploy.
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

  Includes `:mode` (T3.4a) — `:standing` for a continuous/maintenance reconciler
  or `:converge` for the default converge-and-stop loop — and `:steady?` — whether
  a standing loop is currently in a steady observing state (its latest observation
  satisfied the whole vector and it is holding it true rather than terminating).
  `:steady_observations` counts the satisfied observations seen while standing, so
  a test can confirm the loop re-observed PAST convergence (it grows past 1). For
  the default loop `:mode` is `:converge`, `:steady?` is `false`, and
  `:steady_observations` is `0`.

  Includes `:history` — the full ordered per-iteration vector history (T1.1),
  oldest-first; see `history/1` for the same data without the rest of the
  snapshot. Also includes `:quarantine` — the list of predicate ids currently
  quarantined as flaky (T1.3), which are excluded from the convergence/work
  calculus; `:stuck_failing` — the list of predicate ids the loop stopped stuck
  on (T1.5), or `nil` if it did not stop stuck; `:regressions` (T1.2) — the
  green→red predicate flags detected over the history so far, each with the
  dispatch it is attributed to (see `Kazi.Loop.RegressionDetector`); and
  `:release_ref` (T3.3d) — the release ref of the most recent successful deploy
  (the T3.3c tag naming WHAT was shipped), or `nil` if nothing has been deployed.
  """
  @spec snapshot(:gen_statem.server_ref()) :: %{
          state: atom(),
          mode: :standing | :converge,
          steady?: boolean(),
          steady_observations: non_neg_integer(),
          vector: PredicateVector.t() | nil,
          history: history(),
          actions: [Action.kind()],
          iterations: non_neg_integer(),
          landed?: boolean(),
          deployed?: boolean(),
          release_ref: String.t() | nil,
          quarantine: [Kazi.Predicate.id()],
          tokens_used: non_neg_integer(),
          budget_reason: Budget.reason() | nil,
          stuck_failing: [Kazi.Predicate.id()] | nil,
          regressions: [RegressionDetector.flag()]
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
      workspace_opts: Keyword.get(opts, :workspace_opts, []),
      live_kinds: MapSet.new(Keyword.get(opts, :live_kinds, @default_live_kinds)),
      reobserve_interval_ms: Keyword.get(opts, :reobserve_interval_ms, @default_reobserve_ms),
      # T3.4a standing mode: opt the loop into the continuous-maintenance
      # behaviour (default false = converge-and-stop).
      standing: Keyword.get(opts, :standing, false),
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
      on_escalation: Keyword.get(opts, :on_escalation, &default_escalation/1),
      # T3.1d resource lease: the backend + opts + holder + TTL, and the resource
      # key derived ONCE from the goal via the injectable `:resource_key_fn`. With
      # no `:lease` backend, `resource_key` stays nil and the dispatch-prep region
      # short-circuits to a no-op (leasing off), so the default loop is unchanged.
      lease: Keyword.get(opts, :lease),
      lease_opts: Keyword.get(opts, :lease_opts, []),
      lease_holder: Keyword.get(opts, :lease_holder, goal.id),
      lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms, @default_lease_ttl_ms),
      resource_key: derive_resource_key(opts, goal)
    }

    # Kick off the first observation as soon as we are initialized, without
    # blocking init/1.
    {:ok, :observing, data, [{:next_event, :internal, :observe}]}
  end

  # T3.1d resource lease: release the held key if the process exits for ANY reason.
  # The clean terminal paths already release via `terminate_with/2`, but an
  # ABNORMAL exit (a crash, a supervisor shutdown) bypasses that — `terminate/3`
  # is `:gen_statem`'s last gasp, so releasing here too means a held lease never
  # leaks when the loop dies unexpectedly (release/2 is idempotent — releasing an
  # already-freed key is a no-op, so double-release on the clean path is safe).
  @impl :gen_statem
  def terminate(_reason, _state, %Data{} = data) do
    release_lease(data)
    :ok
  end

  def terminate(_reason, _state, _data), do: :ok

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
    # T3.1d resource lease (ADR-0006; UC-013): before doing ANY work on the goal,
    # hold the lease on its resource key. `hold_lease/1` acquires it (or renews the
    # one we already hold) on the injected clock. If a DIFFERENT instance holds the
    # key, it returns `:held` — we must NOT dispatch into a resource someone else
    # is working — so we DEFER: re-observe on the poll interval and try again,
    # rather than colliding. When leasing is off (`resource_key: nil`) this is a
    # pure pass-through that always proceeds. The dispatch below runs only once we
    # actually hold the key.
    case hold_lease(data) do
      {:held, data} ->
        # Contention: another instance owns the key. Defer — yield and re-observe
        # on the poll interval (a state timeout, so a queued `:stop` still drains)
        # and let decide re-route to a dispatch on the next free tick.
        reobserve(data, data.reobserve_interval_ms)

      {:ok, data} ->
        dispatch_agent(action, data)
    end
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
    # T3.3d deploy wiring: capture the release ref the deploy action returns
    # (T3.3c release tagging) so it is surfaced in the run outcome/snapshot and
    # projected to the read-model. A failed deploy (or one without a release ref)
    # leaves the prior value untouched.
    data = record_release_ref(data, result)
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

  # T3.4c stop: drop a STALE re-observe timeout that lands in a terminal state.
  # A state timeout's pending *timer* is cancelled on a state change, but a
  # timeout that had ALREADY fired enqueues its `{:timeout, :reobserve}` event
  # before the transition runs; if a `:stop` (or convergence / budget / stuck
  # stop) moves the loop to a terminal state in the same window, that already-
  # enqueued event is still delivered — now in `:converged`/`:stopped`/
  # `:over_budget`. Without this clause it falls through to no matching
  # `handle_event` and crashes the (supposedly cleanly-stopped) process, which
  # under a `:transient` supervisor would even resurrect a deliberately stopped
  # standing loop. Terminal states accept no more observations, so it is a no-op.
  def handle_event({:timeout, :reobserve}, :reobserve, state, %Data{})
      when state in [:converged, :stopped, :over_budget] do
    :keep_state_and_data
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
      # T3.4a standing mode: the loop's mode + whether a standing loop is in a
      # steady observing state, and how many satisfied observations it has made.
      mode: if(data.standing, do: :standing, else: :converge),
      steady?: data.steady?,
      steady_observations: data.steady_observations,
      vector: data.vector,
      history: ordered_history(data),
      actions: Enum.reverse(data.actions),
      iterations: data.iterations,
      landed?: data.landed?,
      deployed?: data.deployed?,
      # T3.3d deploy wiring: the release ref of the most recent successful deploy
      # (T3.3c), or nil if nothing has been deployed yet.
      release_ref: data.release_ref,
      # T1.3 flake: the predicate ids currently quarantined as flaky.
      quarantine: MapSet.to_list(data.quarantine),
      # T1.4 budget: current token spend + the dimension that stopped the loop
      # (nil unless it stopped :over_budget).
      tokens_used: data.tokens_used,
      budget_reason: data.budget_reason,
      # T1.5 stuck: the persistent failing set the loop stopped stuck on, or nil
      # if it did not stop stuck.
      stuck_failing: stuck_failing_list(data.stuck_failing),
      # T1.2 regression: the green→red flags detected over the history so far,
      # each with its attributed dispatch (see Kazi.Loop.RegressionDetector).
      regressions: data.regressions
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

    # T32.2 / ADR-0041: thread each scored predicate's PREVIOUS-iteration score
    # into `prior_score`, so the progress classifier and stuck-detector read the
    # direction-interpreted delta. The provider supplies `score`/`direction`; the
    # LOOP supplies `prior_score` — it is the only component that knows the prior
    # iteration. A boolean predicate (no score) is untouched: prior stays nil, so
    # the vector is byte-identical to the pre-v2 shape.
    vector = thread_prior_scores(vector, data.vector)

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
          # T3.4a standing mode: clear the steady flag for this fresh
          # observation. `converge_or_stay/1` (decide clause 1) re-sets it to
          # true iff THIS observation is satisfied, so `steady?` always reflects
          # the current observation — it drops to false the moment a standing
          # loop sees an unsatisfied vector (the T3.4b drift seam). A no-op for
          # the default loop, which never reads it.
          steady?: false,
          # Prepend this observation's full vector to the in-state history
          # (newest-first; read APIs reverse to oldest-first). T1.1.
          history: [{index, vector} | data.history],
          iterations: data.iterations + 1
      }

    # T1.2 regression: after observe (using the just-updated history), run the
    # pure detector over the full per-iteration history + dispatch log and record
    # any green→red flags (with their attributed dispatch) into state. Additive:
    # it does not touch the convergence guard, budget, or flake logic — decide/2
    # below is unchanged. The flags are surfaced via snapshot/1 and the read-model.
    data = %Data{data | regressions: detect_regressions(data)}

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

  # T32.2 / ADR-0041: copy each predicate's score from the previous observation's
  # same-id result into this observation's `prior_score`. The first observation
  # (no prior vector) leaves every prior_score nil. Boolean predicates (prior
  # score nil) are untouched — the result struct is unchanged, so the stored and
  # in-memory shapes stay byte-identical to the pre-v2 loop.
  @spec thread_prior_scores(PredicateVector.t(), PredicateVector.t() | nil) :: PredicateVector.t()
  defp thread_prior_scores(vector, nil), do: vector

  defp thread_prior_scores(
         %PredicateVector{results: results} = vector,
         %PredicateVector{results: prev}
       ) do
    threaded =
      Map.new(results, fn {id, %PredicateResult{} = result} ->
        prior =
          case Map.get(prev, id) do
            %PredicateResult{score: score} -> score
            _ -> nil
          end

        {id, PredicateResult.with_prior_score(result, prior)}
      end)

    %{vector | results: threaded}
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
      # 1. Whole vector satisfied (incl. live predicates).
      #    `:converged` is reachable through this clause and no other — the
      #    objective-termination guard (T0.8, UC-005). T1.3 flake: quarantined
      #    predicates are EXCLUDED from this check (they carry no convergence
      #    claim), so a flake neither counts toward nor blocks convergence.
      #
      #    T3.4a standing mode: in a STANDING loop satisfaction does NOT
      #    terminate — `converge_or_stay/1` records the converged observation,
      #    marks the loop steady, and re-observes on the bounded interval so it
      #    keeps holding the predicates true (UC-016). In the DEFAULT loop this is
      #    exactly `terminate_with(:converged, data)` — the T0.8 path is
      #    unchanged.
      all_satisfied?(vector, data.quarantine) ->
        converge_or_stay(data)

      # 2. Code predicates failing: dispatch the agent with failing evidence.
      #
      #    T3.4b drift: this is ALSO the standing-mode drift re-trigger. Once a
      #    standing loop is steady (clause 1 marked it `steady?` and re-observed),
      #    a previously-satisfied code predicate that REGRESSES on a later
      #    re-observation is seen as a fresh `code_failing?` here and routed back
      #    through the SAME dispatch path — there is no separate drift handler. The
      #    `:dispatch_agent` ACT clause then re-invalidates land/deploy
      #    (`landed?: false, deployed?: false`), so the loop re-integrates and
      #    re-deploys "as appropriate" before re-converging via clause 1. Reusing
      #    the convergence machinery (rather than forking a parallel path) is the
      #    whole point of T3.4b: drift is just another unsatisfied observation.
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
  # every predicate, including LIVE ones (`:http_probe`, `:prod_log`, …) that
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

  # T3.4a standing mode: the success edge of decide.
  #
  #   * DEFAULT loop (`standing: false`) — converge and STOP: transition to the
  #     terminal `:converged` state exactly as the T0.8 guard prescribes. This
  #     path is byte-for-byte the old `terminate_with(:converged, data)`, so the
  #     default contract (and every existing test) is unchanged.
  #   * STANDING loop (`standing: true`) — converge and STAY: record this
  #     satisfied observation (mark the loop steady, bump the steady counter),
  #     then re-observe on the bounded `reobserve_interval_ms` instead of
  #     terminating. The loop remains alive in `:observing`, holding the
  #     predicates true forever (UC-016) and ready to see a later regression
  #     (the T3.4b drift seam) on its next tick. The interval is the same
  #     injectable-clock-friendly state timeout the loop already uses for live
  #     polling, so there is no busy-spin and `:stop` stays drainable.
  @spec converge_or_stay(Data.t()) :: :gen_statem.event_handler_result(atom())
  defp converge_or_stay(%Data{standing: false} = data) do
    terminate_with(:converged, data)
  end

  defp converge_or_stay(%Data{standing: true} = data) do
    # T3.4b drift: this clause is the RE-CONVERGE endpoint as well as the first
    # converge. After a drift was reconciled back to green (via the dispatch path
    # in decide clause 2), the next satisfied observation lands here again,
    # re-marks the loop steady, and bumps `steady_observations` — so the loop
    # returns to steady observing rather than terminating. `steady?` was cleared
    # for THIS observation in `observe_tick/1`, so it correctly reads false on the
    # drifted (unsatisfied) observation in between and true once re-converged.
    data = %Data{data | steady?: true, steady_observations: data.steady_observations + 1}
    reobserve(data, data.reobserve_interval_ms)
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
  #
  # T32.6 (ADR-0042 §6): `held_out` predicates are filtered out here too, so
  # neither their ids (the work-item line) nor their evidence reach the agent's
  # dispatch context. They are still evaluated and still gate convergence — only
  # the agent's VIEW is narrowed (hidden-for-acceptance). The visible failing
  # predicates still seed the fix context.
  @spec dispatch_action(PredicateVector.t(), Data.t()) :: Action.t()
  defp dispatch_action(vector, %Data{goal: goal, live_kinds: live_kinds} = _data) do
    kinds = predicate_kinds(goal)
    held_out = held_out_ids(goal)

    failing =
      vector
      |> PredicateVector.failing()
      |> Enum.reject(fn id -> MapSet.member?(live_kinds, Map.get(kinds, id)) end)
      |> Enum.reject(fn id -> MapSet.member?(held_out, id) end)

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

  # The harness dispatch proper, reached from the `:dispatch_agent` ACT clause
  # ONLY once we hold the goal's resource lease (T3.1d). Byte-for-byte the
  # pre-lease dispatch body — prepare the workspace, drive the harness, fold the
  # token estimate / working-set digest, invalidate land/deploy, log the dispatch,
  # and re-observe on the poll interval.
  @spec dispatch_agent(Action.t(), Data.t()) :: :gen_statem.event_handler_result(atom())
  defp dispatch_agent(%Action{} = action, data) do
    prompt = dispatch_prompt(action, data)

    # T4.5 context injection (ADR-0010 §3): before the stateless `claude -p`
    # dispatch, prepare the workspace so the agent starts oriented — expose the
    # code-review-graph MCP in the workspace's `.mcp.json` and refresh its code
    # graph if present. Best-effort: a prep error never blocks the dispatch (the
    # MCP/graph is an orientation optimisation, not a precondition).
    prepare_workspace(data)

    # T36.2 (ADR-0047 §1): drive the imminent dispatch with the MINIMAL default
    # tool/MCP surface — `--strict-mcp-config` exposing ONLY the MCP servers kazi
    # injected (the orientation/graph server written by `prepare_workspace/1`
    # above, plus the E35 context store once it lands) and the standard edit/shell
    # tools the agent needs to fix predicates, NOT the ambient set. See
    # `dispatch_adapter_opts/1`.
    result = data.harness.run(prompt, data.workspace, dispatch_adapter_opts(data))

    # T1.4 budget: accumulate this run's token estimate (if the harness reported
    # one) into the running total the budget guard checks next tick.
    data = accumulate_tokens(data, result)

    # T34.1 (ADR-0046): accumulate the run-aggregate usage envelope — the
    # cached-vs-fresh token/cost components the harness reported — surfaced in the
    # terminal `--json` result. Only reported components are summed (absent ≠ zero).
    data = accumulate_usage(data, result)

    # T4.7 working-set digest: distill a BOUNDED, transcript-free note of the
    # files this iteration touched (map memory ONLY — `Digest.from_result/2`
    # reads the result's `:touched` set and nothing else, never the agent's
    # transcript/result text) and carry it forward so the NEXT dispatch's prompt
    # starts oriented to WHERE prior work landed (ADR-0010 §4). A run that reports
    # no touched set leaves the prior digest untouched, so the carried map memory
    # is the most recent iteration that actually reported one.
    data = record_working_set(data, result)

    # The code changed under us: any prior land/deploy is now stale. Re-observe
    # on the poll interval (not zero) so a goal whose code predicate never goes
    # green polls rather than busy-spinning, and stays interruptible by `:stop`.
    data = record_action(data, action, landed?: false, deployed?: false)
    # T1.2 regression: log this dispatch keyed by the observation index that
    # seeded it (data.iterations - 1, the last completed observation), so the
    # detector can attribute a later green→red edge to it.
    data = log_dispatch(data, action)
    reobserve(data, data.reobserve_interval_ms)
  end

  # T36.2 (ADR-0047 §1): the adapter opts for THIS dispatch — the loop's standing
  # `adapter_opts` overlaid on the minimal default tool/MCP surface
  # (`Kazi.Harness.DispatchSurface`). The surface is merged UNDER the loop opts so
  # an explicit operator/goal `:tools` / `:mcp_config` / `:strict_mcp_config`
  # still wins. It is a no-op (byte-identical to the pre-T36.2 dispatch) unless
  # the resolved harness profile advertises the T36.1 economy opts (Claude) AND
  # there is a workspace to scope the MCP config to — so non-Claude harnesses and
  # workspaceless loops are unchanged.
  @spec dispatch_adapter_opts(Data.t()) :: keyword()
  defp dispatch_adapter_opts(%Data{adapter_opts: adapter_opts, workspace: workspace}) do
    case DispatchSurface.minimal_default(workspace, adapter_opts) do
      [] -> adapter_opts
      surface -> Keyword.merge(surface, adapter_opts)
    end
  end

  # The prompt seeding the harness with the failing-predicate evidence
  # (concept §5). The concrete claude -p adapter (T0.6) owns prompt shaping; here
  # we hand it a deterministic, evidence-bearing string the test doubles can
  # observe.
  #
  # T4.7 map memory: a bounded "files touched last iteration" digest is PREPENDED
  # when one exists (a prior dispatch reported a touched working set). It carries
  # WHERE prior work landed — file paths only, never the agent's transcript — so
  # the next stateless iteration starts oriented without re-exploring (ADR-0010
  # §4). On the FIRST iteration the digest is empty and renders to nothing, so the
  # prompt is exactly the evidence string above (back-compat).
  #
  # T4.9c retrieval opt-in (ADR-0012): when the goal DECLARED a retriever (threaded
  # by `Kazi.Runtime` into `adapter_opts[:retriever]`), its top-k snippets are
  # APPENDED as a clearly-delimited section after the evidence (augmenting, never
  # replacing it). Retrieval is OFF by default: with no `:retriever` the resolved
  # default is the no-op (returns `[]`), so NOTHING is appended and the prompt is
  # byte-identical to the pre-retrieval path (ADR-0012's central constraint).
  #
  # T19.1 orientation prefix (ADR-0010 §3, realizing the unwired T4.3): the ranked
  # blast-radius orientation pack (`Kazi.Context`) is PREPENDED as a stable,
  # cacheable PREFIX ahead of the work-item + digest + failing-evidence body — so
  # each stateless dispatch starts oriented to WHERE the work lives without the file
  # being the only carrier (the `.kazi/context.md` written in `prepare_workspace/1`
  # remains, as the fallback for file-reading harnesses). The prefix is built from
  # the SAME `(failing-slice, workspace, graph_source)` inputs every iteration, so
  # it is byte-identical across iterations whose blast radius is unchanged
  # (maximising the inner harness's prompt cache; T19.2). It is purely additive:
  # when there is NO graph/repo-map the pack is empty and NO prefix is added, so
  # the prompt is byte-identical to the pre-T19.1 path (backward compatible).
  #
  # T19.2 stable-prefix discipline (ADR-0010 §4): the sections are FRONT-LOADED
  # stable→volatile so the WHOLE head up to the evidence is byte-identical across
  # iterations whose blast radius + work-item are unchanged, maximising the inner
  # `claude -p`'s OWN prompt cache (kazi sets no `cache_control` — the harness is a
  # subprocess; the only lever is a deterministic, stable prefix). The order is:
  #
  #   1. orientation pack    — stable across same-blast-radius iterations (T19.1)
  #   2. work-item line      — the goal + failing-predicate ids (stable per attempt)
  #   3. working-set digest  — map memory of WHERE prior work landed (T4.7); changes
  #                            only when a prior iteration reports a new touched set
  #   4. failing evidence    — the most volatile content, last (changes every tick)
  #   5. retrieval section   — optional augmentation, appended after (T4.9c)
  #
  # The work-item line is HOISTED ahead of the digest (it was fused with the
  # evidence before) so the stable goal/predicate header is part of the cacheable
  # prefix and only the trailing evidence/digest move when state changes.
  #
  # T19.3 evidence cap (ADR-0010 §6, T4.8): the evidence is rendered through
  # `Kazi.Harness.Prompt.truncate_evidence/2` (default 8 KiB, head+tail window) so a
  # runaway log/diff is bounded at the seam before it reaches the prompt body; small
  # evidence is returned verbatim, so the small-evidence path is unchanged.
  @spec dispatch_prompt(Action.t(), Data.t()) :: String.t()
  defp dispatch_prompt(%Action{params: params}, %Data{goal: goal} = data) do
    failing = Map.get(params, :failing, [])

    # STABLE: the work item — goal id + the failing-predicate ids. Identical across
    # iterations sharing the same failing set, so it belongs in the cacheable head.
    work_item =
      "goal=#{goal.id} fix failing predicates: #{Enum.map_join(failing, ",", &to_string/1)}"

    # VOLATILE: the failing evidence, capped (T19.3/T4.8) so a runaway log/diff is
    # bounded at the seam by a head+tail window. `inspect/1`'s default `limit`
    # would itself truncate large evidence — but head-ONLY, losing the tail signal
    # and at an opaque element count, not a byte budget. Render in FULL
    # (`limit: :infinity`) so the T4.8 cap is the single governing bound and keeps
    # both the failure head and its resolution tail. Small evidence is under the cap
    # and returned verbatim, so the small-evidence path is unchanged.
    evidence =
      "evidence: " <>
        Prompt.truncate_evidence(
          inspect(Map.get(params, :evidence, %{}), limit: :infinity, printable_limit: :infinity)
        )

    # Front-load stable→volatile: orientation → work-item → digest → evidence. The
    # digest sits BETWEEN the stable work-item and the volatile evidence (it is map
    # memory that changes only when a prior iteration reports a new touched set).
    body =
      case Digest.render(data.working_set_digest) do
        "" -> work_item <> "\n" <> evidence
        note -> work_item <> "\n\n" <> note <> "\n\n" <> evidence
      end

    prompt =
      case orientation_prefix(data) do
        nil -> body
        prefix -> prefix <> "\n\n" <> body
      end

    case retrieval_section(data) do
      nil -> prompt
      section -> prompt <> "\n\n" <> section
    end
  end

  # The stable orientation PREFIX for the live dispatch (T19.1, ADR-0010 §3). Builds
  # the ranked blast-radius pack from the current failing slice + workspace and
  # renders it as the cacheable head of the prompt. Returns `nil` — adding NO prefix
  # — when there is no workspace, or when the graph/repo-map produced an EMPTY pack
  # (no impacted files/symbols/test sources): the no-graph case stays byte-identical
  # to the pre-T19.1 prompt rather than emitting an empty-orientation marker.
  #
  # The graph/repo-map source is threaded from `adapter_opts[:graph_source]` (the
  # same hermetic seam `Kazi.Workspace.prepare/2` uses), so tests inject a fixture
  # source with no network or live-MCP access; in production the resolved default
  # (`Kazi.Context.RepoMapSource`) detects a real graph, else an aider-style repo
  # map. The pack is a pure function of its inputs, so the rendered prefix is
  # byte-identical across iterations whose blast radius is unchanged (T19.2).
  #
  # T19.4 no-prefix flag (the benchmark's arm B): the prefix is gated on
  # `orientation_prefix?/1`, which reads an ADDITIVE `:orientation_prefix` opt
  # (from `adapter_opts`, defaulting to `true` — the T19.1 default). When set
  # `false`, NO orientation pack is built or rendered, so the dispatch prompt is
  # the pre-T19.1 evidence-only body — the exact baseline the multi-iteration
  # benchmark (T19.4/T19.5) measures arm C (prefix on) against. The flag is the
  # ONLY behaviour change: with it absent or `true` the path is byte-identical to
  # before, so every existing T19.1/T19.2/T19.3 contract is unchanged.
  @spec orientation_prefix(Data.t()) :: String.t() | nil
  defp orientation_prefix(%Data{workspace: workspace}) when not is_binary(workspace), do: nil

  defp orientation_prefix(%Data{adapter_opts: adapter_opts} = data) do
    if orientation_prefix?(adapter_opts), do: build_orientation_prefix(data), else: nil
  end

  @spec build_orientation_prefix(Data.t()) :: String.t() | nil
  defp build_orientation_prefix(%Data{workspace: workspace, adapter_opts: adapter_opts} = data) do
    pack =
      Context.orientation_pack(failing_slice(data), workspace, orientation_opts(adapter_opts))

    if empty_pack?(pack), do: nil, else: Context.render(pack)
  end

  # The additive `:orientation_prefix` toggle (T19.4). DEFAULTS to `true` so the
  # T19.1 orientation prefix is on unless an arm explicitly disables it (arm B of
  # the benchmark sets `orientation_prefix: false`). Only an explicit `false`
  # disables it; any other value (including absent) keeps the prefix on.
  @spec orientation_prefix?(keyword()) :: boolean()
  defp orientation_prefix?(adapter_opts) do
    Keyword.get(adapter_opts, :orientation_prefix, true) != false
  end

  # A pack with no impacted files, symbols, or test sources carries no orientation —
  # the source found nothing (no graph/repo-map). Suppress the prefix so the no-graph
  # dispatch is byte-identical to the pre-T19.1 prompt (the backward-compat seam).
  @spec empty_pack?(Pack.t()) :: boolean()
  defp empty_pack?(%Pack{files: [], symbols: [], test_sources: []}), do: true
  defp empty_pack?(%Pack{}), do: false

  # Forward only the orientation-builder opts to `Kazi.Context.orientation_pack/3`
  # (the graph source + token budget), ignoring the rest of the adapter opts. Absent
  # a `:graph_source` the builder's resolved default detects a real graph/repo-map.
  defp orientation_opts(adapter_opts),
    do: Keyword.take(adapter_opts, [:graph_source, :token_budget])

  # The optional retrieval augmentation for the dispatch prompt (T4.9c, ADR-0012).
  # Resolves the goal-declared retriever from `adapter_opts` and renders any
  # snippets it returns against the current failing slice. The no-op default
  # returns `[]`, so with retrieval off this is `nil` and the prompt is unchanged.
  @spec retrieval_section(Data.t()) :: String.t() | nil
  defp retrieval_section(%Data{adapter_opts: adapter_opts, workspace: workspace} = data) do
    ws = if is_binary(workspace), do: workspace, else: ""

    case Retrieval.retrieve(failing_slice(data), ws, retrieval_opts(adapter_opts)) do
      [] -> nil
      snippets when is_list(snippets) -> Prompt.render_retrieval_section(snippets)
    end
  end

  # Forward only the retriever-resolution opt to `Kazi.Retrieval` (it ignores the
  # rest of the adapter opts). Absent a `:retriever`, this yields `[]` and the
  # resolved default is the no-op — off by default.
  defp retrieval_opts(adapter_opts), do: Keyword.take(adapter_opts, [:retriever])

  # T4.5/T4.4 context injection (ADR-0010 §3): prepare the target workspace for the
  # imminent stateless dispatch — expose the code-review-graph MCP in its
  # `.mcp.json`, refresh its code graph if one is present, and write the
  # `.kazi/context.md` orientation file from the iteration's failing predicates
  # (all idempotent). A nil workspace (loops driven without a target dir) or any
  # prep error is a no-op for the dispatch: orientation is an optimisation, never a
  # precondition.
  @spec prepare_workspace(Data.t()) :: :ok
  defp prepare_workspace(%Data{workspace: nil}), do: :ok

  defp prepare_workspace(%Data{workspace: workspace, workspace_opts: workspace_opts} = data) do
    opts = Keyword.put_new(workspace_opts, :orientation, {failing_slice(data), []})

    case Kazi.Workspace.prepare(workspace, opts) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          "kazi.loop: workspace prep failed for #{workspace}, dispatching anyway: " <>
            inspect(reason)
        end)

        :ok
    end
  end

  # The failing slice the orientation builder ranks against: `{id, result}` pairs
  # for every `:fail` predicate in the current vector (the shape
  # `Kazi.Context.orientation_pack/3` expects). Empty when there is no vector yet.
  #
  # T32.6 (ADR-0042 §6): `held_out` predicates are excluded so the
  # orientation prefix, retrieval section, and `.kazi/context.md` orientation
  # file built from this slice never leak a held-out predicate's id or evidence
  # into the agent's context — the same hidden-for-acceptance split
  # `dispatch_action/2` enforces on the prompt body.
  @spec failing_slice(Data.t()) :: [{Predicate.id(), PredicateResult.t()}]
  defp failing_slice(%Data{vector: nil}), do: []

  defp failing_slice(%Data{vector: %PredicateVector{results: results}, goal: goal}) do
    held_out = held_out_ids(goal)

    for {id, %PredicateResult{status: :fail} = result} <- results,
        not MapSet.member?(held_out, id),
        do: {id, result}
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

  # T1.2 regression: run the pure detector over the full per-iteration history
  # (oldest-first) and the dispatch log, returning the current green→red flags.
  @spec detect_regressions(Data.t()) :: [RegressionDetector.flag()]
  defp detect_regressions(%Data{} = data) do
    RegressionDetector.detect(ordered_history(data), Enum.reverse(data.dispatch_log))
  end

  # T1.2 regression: record an agent dispatch in the (newest-first) dispatch log,
  # keyed by the observation index that seeded it (the last completed
  # observation, data.iterations - 1).
  @spec log_dispatch(Data.t(), Action.t()) :: Data.t()
  defp log_dispatch(%Data{} = data, %Action{} = action) do
    index = max(data.iterations - 1, 0)
    %Data{data | dispatch_log: [{index, action} | data.dispatch_log]}
  end

  # Record an executed action in history and apply any progress-flag changes.
  defp record_action(%Data{} = data, %Action{kind: kind}, flags) do
    %Data{
      data
      | actions: [kind | data.actions],
        landed?: Keyword.get(flags, :landed?, data.landed?),
        deployed?: Keyword.get(flags, :deployed?, data.deployed?)
    }
  end

  # T3.3d deploy wiring: pull the release ref out of a successful deploy result
  # (the `:release_ref` the T3.3c tagging path puts there) and remember it on the
  # loop's data, so it can be surfaced in snapshot/1, the terminal result, and the
  # read-model projection. A non-`:release_ref`-bearing result (a failed deploy,
  # or a deploy whose tagger could not produce one) leaves the prior value as-is.
  @spec record_release_ref(Data.t(), Action.result()) :: Data.t()
  defp record_release_ref(%Data{} = data, {:ok, %{release_ref: ref}}) when is_binary(ref) do
    %Data{data | release_ref: ref}
  end

  defp record_release_ref(%Data{} = data, _result), do: data

  # =============================================================================
  # T3.1d resource lease: acquire-before-dispatch, renew, release-on-terminate
  # =============================================================================

  # Ensure this instance holds the goal's resource lease before dispatching work
  # (ADR-0006; UC-013). The three outcomes:
  #
  #   * leasing OFF (`resource_key: nil`, no backend) — `{:ok, data}` unchanged: a
  #     pure pass-through, so the default single-instance loop never leases.
  #   * key free / already ours — acquire or renew on the injected clock and carry
  #     the minted `%Lease{}` forward as `held_lease`: `{:ok, data}`.
  #   * key held by a DIFFERENT instance — `{:held, data}`: the caller DEFERS
  #     (re-observes without dispatching) so contending instances serialize rather
  #     than collide. We do NOT hold a lease in this case (`held_lease` stays nil).
  #
  # acquire/4 itself is the serialization point: it succeeds when the key is free
  # at `now_ms` OR already held by us (a re-acquire refreshes the TTL and bumps the
  # CAS revision), and returns `{:error, :held}` only for a different, unexpired
  # holder — so "renew" and "first acquire" are the same call. The injected clock
  # rides in `lease_opts` (`:now_ms`/`:now_fn`), keeping TTL deterministic.
  @spec hold_lease(Data.t()) :: {:ok, Data.t()} | {:held, Data.t()}
  defp hold_lease(%Data{resource_key: nil} = data), do: {:ok, data}

  defp hold_lease(
         %Data{
           lease: backend,
           resource_key: key,
           lease_holder: holder,
           lease_ttl_ms: ttl_ms,
           lease_opts: opts
         } = data
       ) do
    case backend.acquire(key, holder, ttl_ms, opts) do
      {:ok, %Lease{} = lease} -> {:ok, %Data{data | held_lease: lease}}
      {:error, :held} -> {:held, %Data{data | held_lease: nil}}
    end
  end

  # Release the held resource lease, if any (called on every terminal path and
  # from `terminate/3`). A no-op when leasing is off or nothing is held; idempotent
  # via the backend's `release/2`, so releasing twice (clean terminate then
  # `terminate/3`) is safe. Clears `held_lease` so a stale lease can't be released
  # again or mistaken for still-held.
  @spec release_lease(Data.t()) :: Data.t()
  defp release_lease(%Data{held_lease: nil} = data), do: data

  defp release_lease(%Data{lease: backend, held_lease: %Lease{} = lease, lease_opts: opts} = data) do
    :ok = backend.release(lease, opts)
    %Data{data | held_lease: nil}
  end

  # Derive the resource key this goal leases from the injectable `:resource_key_fn`
  # (default `default_resource_key/1`). Returns nil when leasing is OFF (no `:lease`
  # backend), short-circuiting the whole lease path to a no-op.
  @spec derive_resource_key(keyword(), Goal.t()) :: Lease.key() | nil
  defp derive_resource_key(opts, %Goal{} = goal) do
    case Keyword.get(opts, :lease) do
      nil ->
        nil

      _backend ->
        key_fn = Keyword.get(opts, :resource_key_fn, &default_resource_key/1)
        key_fn.(goal)
    end
  end

  # The default resource-key derivation: the goal's identity, narrowed to its
  # repo when the scope names one — so goals on the same repo contend by default
  # while distinct goals get distinct keys. Tests override `:resource_key_fn` to
  # force two goals onto the SAME key (assert serialization) or DISTINCT keys
  # (assert parallelism). ADR-0006's blast-radius partitioning (T3.2) supplies a
  # finer key later; this is the conservative default until then.
  @spec default_resource_key(Goal.t()) :: Lease.key()
  defp default_resource_key(%Goal{scope: %{repo: repo}}) when is_binary(repo), do: "repo:" <> repo
  defp default_resource_key(%Goal{id: id}), do: "goal:" <> id

  # =============================================================================
  # Termination
  # =============================================================================

  # Transition to a terminal state (`:converged` | `:stopped` | `:over_budget`)
  # and stay alive, caching the final result and flushing it to every pending
  # await waiter. The process is left running (not stopped) so late `await/2` and
  # `snapshot/1` calls still succeed; the operator/owner tears it down. Terminal
  # states accept no further observe/act events.
  defp terminate_with(outcome, %Data{} = data) do
    # T3.1d resource lease: on EVERY terminal outcome (:converged / :stopped —
    # incl. an operator stop, stuck stop, await — / :over_budget) release the
    # resource key so another instance can take it up. release/2 is idempotent and
    # a no-op when nothing is held, so this is safe on a loop that never leased.
    data = release_lease(data)
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
      iterations: data.iterations,
      # T3.3d deploy wiring: the release ref of the artifact deployed this run
      # (T3.3c), surfaced so the runtime/CLI can report WHAT was shipped.
      release_ref: data.release_ref,
      # T1.4 budget: the rolled-up token total → `budget_spent.tokens` (ADR-0046).
      tokens_used: data.tokens_used,
      # T34.1 (ADR-0046): the run-aggregate usage envelope (token/cost split).
      usage: data.usage
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

  # T34.1 (ADR-0046): fold a harness run's reported usage components into the
  # run-aggregate envelope. Only components the harness actually reported are
  # summed — an unreported field stays absent (absent ≠ zero, honest-unknown).
  # T34.1 surfaces `cost_usd` (already parsed by the profile, `%{cost_usd: c}`);
  # T34.2 adds the per-profile cached/fresh TOKEN split onto the same envelope.
  @spec accumulate_usage(Data.t(), Kazi.HarnessAdapter.result()) :: Data.t()
  defp accumulate_usage(%Data{} = data, result) do
    %Data{data | usage: merge_usage(data.usage, usage_components(result))}
  end

  # The envelope-shaped usage components a harness result carries, keyed by the
  # `Kazi.CLI.Usage` field names. A result without usage contributes nothing.
  @spec usage_components(Kazi.HarnessAdapter.result()) :: map()
  defp usage_components({:ok, %{cost_usd: cost}}) when is_number(cost), do: %{cost_usd: cost}
  defp usage_components(_), do: %{}

  # Sum two usage maps component-wise; a component present in only one side is
  # carried through, so the aggregate reports exactly the union of what was
  # reported (never zero-filling an unreported field).
  @spec merge_usage(map(), map()) :: map()
  defp merge_usage(acc, components) do
    Map.merge(acc, components, fn _key, a, b -> a + b end)
  end

  # =============================================================================
  # T4.7 working-set digest: map memory across iterations
  # =============================================================================

  # Distill this dispatch's BOUNDED working-set digest from the harness result and
  # carry it forward for the NEXT dispatch's prompt. `Digest.from_result/2` reads
  # the result's `:touched` working set and NOTHING else — never the agent's
  # `:result`/`:output` transcript — so the carried map memory cannot contain
  # conversation memory (ADR-0008 anti-anchoring), by construction.
  #
  # A result that reports a touched set replaces the digest; a result that reports
  # NONE (an error, or a success envelope without `:touched`) leaves the prior
  # digest untouched, so the loop keeps orienting the next iteration with the most
  # recent working set that was actually reported rather than dropping it.
  @spec record_working_set(Data.t(), Kazi.HarnessAdapter.result()) :: Data.t()
  defp record_working_set(%Data{} = data, result) do
    case Digest.from_result(result) do
      %Digest{files: []} -> data
      %Digest{} = digest -> %Data{data | working_set_digest: digest}
    end
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

  # T32.6 (ADR-0042 §6): the set of predicate ids the goal marks `held_out`. The
  # controller evaluates them and they still gate convergence, but they are
  # filtered OUT of everything that reaches the agent — the dispatch prompt's
  # failing-id list + evidence (`dispatch_action/2`) and the
  # orientation/retrieval/workspace context built from the failing slice
  # (`failing_slice/1`). This is the visible-for-iteration vs
  # hidden-for-acceptance split.
  @spec held_out_ids(Goal.t()) :: MapSet.t()
  defp held_out_ids(%Goal{} = goal) do
    goal
    |> Goal.all_predicates()
    |> Enum.filter(&Predicate.held_out?/1)
    |> Enum.map(& &1.id)
    |> MapSet.new()
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
      converged?: PredicateVector.satisfied?(data.vector),
      # T1.2 regression: the green→red flags for this observation, so the runtime
      # projects them into the read-model (making the regression queryable).
      regressions: data.regressions,
      # T3.3d deploy wiring: the release ref of the artifact deployed so far this
      # run (T3.3c), so the runtime projects it into the read-model's
      # `release_ref` column (queryable via Kazi.ReadModel.release_refs/1). nil
      # until a deploy succeeds with a release ref.
      release_ref: data.release_ref
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
