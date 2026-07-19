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
  alias Kazi.ContextStore
  alias Kazi.ContextStore.Labels, as: StoreLabels
  alias Kazi.Context.StuckBundle

  # T35.4 (ADR-0045 §3): evidence compression via the context store. An artifact
  # whose rendered size exceeds this threshold is INDEXED under a SHA-scoped label
  # and replaced in the dispatch prompt by a compact reference plus budget-fitted
  # snippets retrieved from the store — instead of inlining the whole thing every
  # iteration. Sub-threshold artifacts inline as before. Default 5 KB (ADR-0045 §3).
  @context_store_threshold 5_120

  # Default per-iteration retrieval budget (bytes) when the goal/run did not set
  # `:context_budget` (ADR-0045 §9: apply-iteration snippets ≈ 6 000).
  @context_store_default_budget 6_000
  # T32.4 anti-gaming enforcement (ADR-0042): the loop composes the enforcement
  # profile onto the ordinary reconcile tick — clean-tree + separate-process checker
  # isolation for the tamper-prone graders (guard + held-out predicates) at the
  # `run_provider/3` seam, the skipped/errored/xfail → :fail mapping, and the
  # read-only-lease write flagging around the agent dispatch. The pure profile +
  # detection logic lives in `Kazi.Enforcement`; the loop only wires the seams and
  # records the active guarantees + any flagged gaming event for the snapshot/result.
  alias Kazi.Enforcement
  alias Kazi.Enforcement.DiffGuard
  alias Kazi.Enforcement.Isolation
  # T4.9c retrieval opt-in (ADR-0012): the loop appends the goal-declared
  # retriever's snippets to the dispatch prompt, reusing the adapter's render so
  # the section is byte-identical to `build_prompt/3`'s (see `dispatch_prompt/2`).
  alias Kazi.Harness.Prompt
  # T36.2 (ADR-0047 §1): the minimal default tool/MCP surface for a reconcile
  # dispatch — injected MCP servers + standard edit/shell tools, not the ambient
  # set. Consumed in `dispatch_agent/2`.
  alias Kazi.Harness.DispatchSurface
  # T48.11 (ADR-0058 §3): the opt-in post-dispatch debrief question + the
  # write-only extraction of a capped hypothesis list from a dispatch result.
  alias Kazi.Harness.Debrief
  # T44.4 (ADR-0055 decision 4b): the controller-owned process-contract renderer.
  alias Kazi.Harness.ProcessContract
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
  # T45.7 (ADR-0056 decision 5): the model escalation ladder.
  alias Kazi.Loop.Ladder
  # T48.3 (ADR-0058, UC-064): the pure error-permanence taxonomy classifying a
  # `:error` reason as `:permanent` (config/wiring, never clears) or `:transient`
  # (may clear). The loop passes `classify_result/1` into
  # `StuckDetector.permanent_error_stuck?/3` (see `live_history/1` below) —
  # neither module depends on the other at runtime.
  alias Kazi.Loop.ErrorPermanence
  # T48.4 (ADR-0058 decision 4, UC-064): the pure, closed classifier deciding
  # whether an `:over_budget` or `:stuck` stop is honestly what it says it is,
  # or a mislabel (`:budget_exhausted` vs `:error_wedged` vs
  # `:quarantine_blocked`) — see `cause_for/2` below, the single seam that
  # feeds it from `build_result/2` and the `:snapshot` handler.
  alias Kazi.Loop.CauseClass
  # T1.2 regression: the pure green→red detector + dispatch attribution. The loop
  # only feeds it the per-iteration history (T1.1) + dispatch log and records the
  # flags it returns (see observe_tick/1).
  alias Kazi.Loop.RegressionDetector
  alias Kazi.Memory.AttemptLedger
  alias Kazi.Memory.SemanticIndex
  # T4.7 working-set digest: the pure, bounded "files touched last iteration"
  # distiller. The loop reads the harness result's `:touched` working set through
  # it (map memory ONLY — never the transcript) and threads the digest into the
  # NEXT dispatch's prompt (see the `:dispatch_agent` ACT clause and
  # `dispatch_prompt/2`).
  alias Kazi.Loop.Digest
  # T34.3 (ADR-0046 §2): per-iteration `context` + `tools` counters. The loop owns
  # the context (orientation/retrieval cache state + section token estimates,
  # computed from the prompt it built); the harness result carries the tool-use
  # stream the `tools` counters are parsed from. Pure — see `Kazi.Loop.Counters`.
  alias Kazi.Loop.Counters
  # T19.1 orientation prefix (ADR-0010 §3, realizing T4.3): the live dispatch
  # prompt carries kazi's pre-computed map memory (the ranked blast-radius pack)
  # as a STABLE, cacheable PREFIX ahead of the failing-evidence body — so each
  # stateless `claude -p` starts oriented instead of re-exploring. The pack is a
  # pure function of `(failing-slice, workspace, graph_source)`, so its rendered
  # prefix is byte-identical across iterations whose blast radius is unchanged.
  alias Kazi.Context
  alias Kazi.Context.Pack
  # T36.3 (ADR-0047 §2): the context-budget tier ladder. Gates the orientation
  # prefix (tier 0 drops it) and records the active tier per iteration; the graph
  # MCP surface gate lives in `Kazi.Harness.DispatchSurface`.
  alias Kazi.Context.Tier
  # T36.4 (ADR-0047 §2/§4): escalate the active tier on non-progress (1→2→3→4),
  # with a stop rule that reverts a net-negative (cost-up, no-progress) bump. Pure
  # policy + thresholds-from-config; the loop owns the signal (progress/cost) and
  # applies the resulting tier. See `observe_tick/1` and `active_tier/1`.
  alias Kazi.Context.Escalation

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
  # issue #1020: default ceiling for a single `:integrate` execute/2 call.
  @default_integrate_timeout_ms 600_000

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
  @type outcome :: :converged | :stopped | :over_budget | :tampered

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
          usage: map(),
          # T32.4 enforcement: the active anti-gaming guarantees + flagged gaming
          # events for the run (ADR-0042 §7). `active: false` when enforcement off.
          enforcement: %{
            active: boolean(),
            guarantees: [atom()],
            gaming_events: [map()]
          },
          # i795/#795: the predicate ids quarantined as flaky (T1.3) at the
          # terminal observation, or `[]` if none. `all_satisfied?/1` blocks
          # `:converged` on any of these (their status is `:unknown`, never
          # `:pass`) — this field is WHY: it names the ids so a `:stopped` result
          # is diagnosable without re-deriving quarantine state from the vector.
          quarantine: [Kazi.Predicate.id()],
          # T48.7 (ADR-0058 decision 1): the number of `:dispatch_agent` actions
          # actually run this run (loop-tracked, always known — never nil).
          dispatches: non_neg_integer(),
          # T48.7: the active ADR-0047 context tier at termination (the same
          # value `snapshot/1` reads via `active_tier/1`).
          context_tier: Tier.t(),
          # T48.7: the goal shape — predicate count + kind histogram — computed
          # from the goal at termination, so the read-model can persist it
          # alongside the economics without reloading the goal file.
          goal_shape: %{
            predicate_count: non_neg_integer(),
            kind_histogram: %{optional(Kazi.Predicate.provider_kind()) => pos_integer()}
          },
          # T48.5 (ADR-0058 §4): degraded-fidelity flag for the RUN's budget
          # honesty — `:unreported` once any dispatch under a `max_tokens`
          # ceiling came back with no usage the loop could count (the `claw`
          # profile, ADR-0022, reports none by design), `nil` otherwise. This is
          # distinct from the per-dispatch `:usage_fidelity` (`:full`/`:partial`/
          # `:none`) a harness PROFILE parses onto ONE result (T34.2) — that one
          # says "how much of THIS envelope did we get"; this one says "can the
          # goal's token ceiling bind AT ALL this run". A ceiling that cannot
          # bind must say so rather than silently never tripping.
          usage_fidelity: :unreported | nil,
          # T48.3 (ADR-0058, UC-064): the persistent failing set's last-observed
          # `:error` reason per id, keyed the same as `:stuck_failing`, when the
          # stop was a LIVE permanent-error verdict (`permanent_error_stuck?/3`);
          # `nil` for every other `:stuck` stop (the ordinary T1.5 failing-set or
          # code error_stuck? verdicts carry no reason taxonomy) and for every
          # non-stuck outcome. Additive — the existing `:stuck_failing` id list
          # shape is unchanged; this only adds WHY those ids are stuck.
          stuck_reasons: %{Kazi.Predicate.id() => term()} | nil,
          # T48.4 (ADR-0058 decision 4, UC-064): the honest terminal cause
          # class alongside the outcome — `nil` unless the stop is one of the
          # three named mislabels (`Kazi.Loop.CauseClass`'s moduledoc). An
          # `:over_budget` stop is NOT always `:budget_exhausted`, and a
          # `:stuck` stop is NOT always an ordinary failing-set stall.
          cause: CauseClass.t() | nil
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
              # T45.7 (ADR-0056 decision 5): the model escalation ladder
              # (`Kazi.Loop.Ladder`) or `nil` when no `[escalation]` block is
              # declared. `nil` keeps the loop byte-identical to its single-model
              # self (no re-dispatch, no per-rung window/budget rebasing).
              ladder: nil,
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
              # issue #1020: the wall-clock ceiling on a single `:integrate`
              # execute/2 call. `handle_event/4` runs it in-process, and a real
              # integrator can hang (observed: alive, 0% CPU, no children, no
              # sockets, the gen_statem simply never comes back) -- with no
              # timeout that wedges the whole loop forever. Appended last so
              # the existing field order is untouched.
              integrate_timeout_ms: nil,
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
              # Full (unbounded) for a DEFAULT (non-standing) loop — it terminates,
              # so the trajectory never grows past a modest run. M6
              # (deep-review-001): a STANDING loop (UC-016) re-observes forever, so
              # ITS history is bounded to a sliding window (`bound_history/2`)
              # covering both the stuck and regression detection windows — a
              # DEFAULT loop is unaffected (`bound_history/2` is a no-op when
              # `standing: false`).
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
              # T48.6 (ADR-0058) budget: count of completed :dispatch_agent actions
              # (the max_dispatches dimension). Incremented ONLY in dispatch_agent/2,
              # once per agent dispatch — an observe-only tick never touches this, so
              # a run wedged on a persistently erroring predicate cannot trip
              # max_dispatches by spinning no-op ticks alone (unlike max_iterations).
              dispatches: 0,
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
              # T48.3 (ADR-0058, UC-064): the reason map for a LIVE permanent-error
              # stuck stop (see `stuck_reasons` in `t:result/0`). nil for every
              # other stop. Appended last so the existing field order is untouched.
              stuck_reasons: nil,
              # T48.4 (ADR-0058 decision 4, UC-064): which of the THREE named
              # cause classes a `:stuck` stop is, set explicitly by the call site
              # in `terminate_stuck/4` (not inferred — the call site already knows
              # exactly why it is stopping). `nil` for the ordinary T1.5
              # failing-set stop and the pre-existing code `error_stuck?` (M5)
              # stop — see `cause_for/2`.
              stuck_cause: nil,
              # T53.2 (#1022): opt-in workspace-liveness precheck (see `init/1`).
              # Appended last so the existing field order is untouched.
              check_workspace_liveness: false,
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
              usage: %{},
              # --- T32.4 anti-gaming enforcement (ADR-0042) -------------------
              # The resolved enforcement profile (`Kazi.Enforcement`), or nil =
              # enforcement off (the default — the loop is byte-for-byte unchanged).
              # When active, the loop runs the tamper-prone graders (guard +
              # held-out predicates) from a clean detached worktree
              # (`enforcement.clean_ref`) at the `run_provider/3` seam, maps
              # skipped/errored/xfail sub-results to :fail, and flags writes to the
              # read-only-leased paths around each dispatch. All appended last so
              # the existing field order is untouched.
              enforcement: nil,
              # Whether clean-tree isolation was actually established on the last
              # observation (false if it degraded — not a git repo / ref
              # unresolvable). The REPORTED guarantees drop `:clean_tree` when this
              # is false, so a partial guarantee is visible (ADR-0042 §7).
              clean_tree_active?: false,
              # The content-hash snapshot of the read-only-leased paths taken just
              # before the last agent dispatch (`Kazi.Enforcement.digest_paths/2`);
              # compared after the dispatch to flag a write.
              read_only_before: %{},
              # Append-only list of flagged gaming events (a read-only-path write,
              # ADR-0042 §2; a diff-inspection hit, ADR-0042 §5/T32.5), surfaced in
              # snapshot/1 + the terminal result.
              gaming_events: [],
              # T32.5 diff-inspection guard (ADR-0042 §5): how the loop obtains the
              # agent's iteration diff to scan for gaming signatures. A 1-arity fn
              # `workspace -> diff_text` (a `git diff HEAD` by default), injectable
              # so a test can feed a canned diff without a git workspace. Only
              # called when enforcement is active.
              diff_fn: nil,
              # T32.5: the set of observation indices whose seeding dispatch the diff
              # guard flagged. The stuck classifier (`code_history/1`) discounts a
              # flagged observation's graded scores so a GAMED apparent improvement
              # is not credited as progress — an ADVISORY downgrade, never a
              # convergence block (the failing-set/boolean stuck logic is untouched).
              gaming_flagged_iterations: MapSet.new(),
              # --- T34.3 (ADR-0046 §2): per-iteration context + tool counters ---
              # The most recent dispatch's `context`/`tools` counter maps, attached
              # to the NEXT iteration event (the dispatch's effect is measured by
              # the observation that follows it). `last_orientation_prefix` /
              # `last_retrieval_section` carry the PRIOR dispatch's prefix strings
              # so the next dispatch can decide the orientation/retrieval cache
              # hit/miss (byte-identical prefix ⇒ "hit", T19.2). All nil/empty until
              # the first dispatch, so the first observation's event reports the
              # all-disabled/zero context and absent tools (no work yet). Appended
              # last so the existing field order is untouched.
              last_context: nil,
              last_tools: %{},
              last_orientation_prefix: nil,
              last_retrieval_section: nil,
              # The inner harness's own session id from the latest dispatch
              # result (the claude envelope's `session_id`), carried on the
              # iteration payload so the runtime can record it on the fleet
              # registry row (resumable via `claude -r <id>`). nil until a
              # dispatch reports one; a later dispatch's id supersedes.
              last_session_id: nil,
              # Issue #857: the OS pid of the latest dispatch's harness
              # subprocess (as reported by `Kazi.Harness.CliAdapter`'s
              # child-supervision wrapper), carried on the iteration payload so
              # the runtime can record it on the fleet registry row — the
              # orphan-on-resume check reads it back on a later run's startup.
              # nil until a dispatch reports one; a later dispatch's pid
              # supersedes.
              last_harness_pid: nil,
              # --- T36.4 (ADR-0047 §2/§4): context-tier escalation --------------
              # The resolved escalation `Config` (thresholds + stop-rule flag) and
              # the running escalation `State` (the active tier, the non-progress
              # streak, the stop-rule bookkeeping). `escalation_state.tier` is the
              # tier the NEXT dispatch assembles its context at — it starts at the
              # operator/goal base tier (`Tier.resolve/1`, default 1) and steps up
              # on sustained non-progress. `escalation_prev_cost` is the cumulative
              # run cost snapshot from which the per-iteration cost DELTA (the
              # stop-rule signal) is computed each observation. `escalation_events`
              # is an append-only log of the {kind, from, to, iteration} tier
              # changes, surfaced in `snapshot/1`. All appended last so the existing
              # field order is untouched; with no non-progress the active tier never
              # moves and the loop is byte-identical to before.
              escalation_config: nil,
              escalation_state: nil,
              escalation_prev_cost: 0,
              escalation_events: [],
              # --- #820: quarantine rehabilitation + honest no-work stop -------
              # `quarantine_streaks` counts each quarantined id's consecutive REAL
              # passes toward `Kazi.Loop.Flake.rehab_streak/0` (rehabilitation);
              # an id absent from the map has a streak of zero, and it never holds
              # an entry for a non-quarantined id. `noop_ticks` counts consecutive
              # decide/2 ticks that hit the terminal "nothing to dispatch, not yet
              # satisfied" clause (waiting on a live predicate or a quarantine-only
              # blockage) — it resets to 0 the moment any OTHER clause fires
              # (dispatch/integrate/deploy/converge) and drives both the reobserve
              # backoff and the quarantine-only stuck bound. Both appended last so
              # the existing field order is untouched.
              quarantine_streaks: %{},
              noop_ticks: 0,
              # --- T48.5 (ADR-0058 §4): token-ceiling honesty ------------------
              # `nil` until a dispatch under a `max_tokens` ceiling reports no
              # usage the loop can count; then `:unreported` for the rest of the
              # run (set once, never cleared — see `maybe_flag_unreported_usage/2`).
              # Distinct from the per-dispatch `usage_fidelity` a harness PROFILE
              # parses onto one result (T34.2); this is the RUN-level "the
              # ceiling cannot bind" flag, surfaced on `snapshot/1` and the
              # terminal result so the CLI/read-model can say so. Appended last
              # so the existing field order is untouched.
              usage_fidelity: nil,
              # --- issue #769: permission-denial honesty ------------------------
              # The tool calls the harness ATTEMPTED and had denied, accumulated
              # across the run (deduped by tool name, newest dispatch wins). A
              # headless `claude -p` against a workspace that has not been through
              # Claude Code's interactive trust dialog has every Write/Bash denied
              # and STILL exits 0 with `is_error: false`, so the loop sees a clean
              # dispatch, observes no file change, re-dispatches, and burns the
              # budget to `:stuck` with the cause nowhere in its output. The
              # profile already parses `:permission_denials` off the envelope
              # (`Profiles.Claude`); this is where the loop RETAINS it so
              # `build_stuck_bundle/1` can surface it. Empty list = none seen.
              permission_denials: [],
              # --- T48.11 (ADR-0058 §3): opt-in post-dispatch debrief -----------
              # `debrief` opts the loop into appending the capped debrief question
              # to every dispatch prompt (default false = byte-identical to
              # today). `last_debrief` is the MOST RECENT dispatch's extracted,
              # capped hypothesis list, attached to the NEXT iteration event —
              # same "measured this dispatch, surfaced on the following
              # observation" shape as `last_context`/`last_tools` (T34.3). `[]`
              # until a dispatch reports one (or when debrief is disabled).
              # Appended last so the existing field order is untouched.
              debrief: false,
              last_debrief: [],
              # --- T49.8 (ADR-0064 d4): consecutive FAILED demonstrations -------
              # Counts back-to-back rejected/errored demonstrator dispatches with
              # no intervening fixer dispatch (a workspace change resets it). Two in
              # a row means re-demonstrating is futile — the run terminates
              # `:stuck` with cause `:capability_unreachable` (a red replay that
              # keeps failing without a code change is a capability the demonstrator
              # cannot reach). Appended last so the existing field order is
              # untouched.
              consecutive_failed_demos: 0,
              # --- ADR-0080 (#1520): sealed-predicate tamper detection ----------
              # `seal_manifest` is the t0 content-hash manifest of the goal-file +
              # sealed inputs (`Kazi.Seal.arm/3`), armed by the runtime and threaded
              # in as a loop opt. Before every observe pass the loop re-verifies it
              # (`Kazi.Seal.verify/1`); the FIRST mismatch sets `tampered_file`
              # (`%{path:, change:}`) and terminates the run `:tampered`. Empty
              # manifest (a Loop.start_link with no seal, or `[seal] enabled=false`)
              # = nothing sealed, byte-identical to pre-ADR-0080. Appended last so
              # the existing field order is untouched.
              seal_manifest: %{},
              tampered_file: nil,
              # --- ADR-0081 (#1521): controller-owned capture recipes ------------
              # `capture_fn` is the controller-side capture executor (built by the
              # runtime, `build_capture_fn/4`): given the 0-based observe iteration
              # it runs every `[[capture]]` recipe into the run-keyed evidence store
              # and returns `%{name => result}`. Default is a no-op returning `%{}`
              # (a Loop.start_link with no captures, byte-identical to before).
              # `captures` holds the LATEST pass's results, threaded into each
              # predicate's `context[:captures]` so a `render_proof` predicate reads
              # the CONTROLLER-produced artifact, never a worker claim. Appended last
              # so the existing field order is untouched.
              capture_fn: nil,
              captures: %{}
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
    * `:integrate_timeout_ms` — the wall-clock ceiling on a single `:integrate`
      execute/2 call (issue #1020). A hung integrator (e.g. a wedged `gh pr
      checks --watch` or a stalled network push) no longer blocks the loop
      forever; past this deadline the attempt is abandoned and treated as
      `{:error, :integrate_timeout}`, so the loop records it and re-observes
      normally. Default `#{@default_integrate_timeout_ms}` (10 minutes).
    * `:standing` — run as a STANDING (continuous/maintenance) reconciler (T3.4a,
      UC-016). When `true`, satisfying the whole vector does NOT terminate the
      loop: it records the converged observation, enters a steady observing
      state, and keeps re-observing on `:reobserve_interval_ms` to hold the
      predicates true forever. When `false` (default) the loop converges-and-stops
      exactly as the T0.8 guard prescribes.
    * `:debrief` — opt into post-dispatch debrief capture (T48.11, ADR-0058 §3).
      When `true`, every dispatch prompt carries one capped debrief question
      (`Kazi.Harness.Debrief.question/0`) and a fixture-shaped structured answer
      in the reply is parsed, capped, and surfaced on the NEXT iteration event
      (`Kazi.Runtime` persists it as hypothesis rows). When `false` (default)
      the prompt and the iteration event's `:debrief` field are byte-identical
      to today.
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
    * `:enforcement` — a resolved `Kazi.Enforcement` profile (T32.4, ADR-0042) to
      compose onto the reconcile tick: clean-tree + separate-process isolation for
      the goal's GUARD + HELD-OUT predicates (the tamper-prone graders) at the
      `run_provider/3` seam, the skipped/errored/xfail → `:fail` mapping, and
      read-only-lease write flagging around each dispatch. Default `nil` =
      enforcement OFF — every seam is a no-op and the loop is byte-for-byte
      unchanged. `Kazi.Runtime.run/2` resolves the default-on-for-creation policy
      and threads the profile here.
    * `:context_escalation` — tune the context-budget tier escalation ladder
      (T36.4, ADR-0047 §2/§4): a `Kazi.Context.Escalation.Config`, a keyword/map of
      overrides (`:enabled`, `:threshold`, `:min_tier`, `:max_tier`, `:stop_rule`),
      or `nil` to resolve `config :kazi, :context_escalation` then the provisional
      defaults. On `:threshold` consecutive non-progress observations against the
      same failing set (the ADR-0041 score gradient), the active tier steps up
      (1 → 2 → 3 → 4) so the next dispatch assembles richer context; the stop rule
      reverts a bump that raised cost without progress. The default `:threshold` is
      `Kazi.Context.Escalation.default_threshold/0` (provisional, pending the
      E19/T36.5 benchmark). Set `enabled: false` to pin the active tier at the base.
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
  on (T1.5), or `nil` if it did not stop stuck; `:stuck_reasons` (T48.3,
  ADR-0058) — the persistent set's last-observed `:error` reason per id when the
  stop was a LIVE permanent-error verdict, or `nil` for every other stop;
  `:cause` (T48.4, ADR-0058 decision 4) — the honest terminal cause class
  alongside the outcome (`:budget_exhausted` / `:error_wedged` /
  `:quarantine_blocked`), or `nil` when no mislabel applies (see
  `Kazi.Loop.CauseClass`); `:regressions` (T1.2) — the
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
          dispatches: non_neg_integer(),
          budget_reason: Budget.reason() | nil,
          stuck_failing: [Kazi.Predicate.id()] | nil,
          stuck_reasons: %{Kazi.Predicate.id() => term()} | nil,
          cause: CauseClass.t() | nil,
          regressions: [RegressionDetector.flag()],
          enforcement: %{
            active: boolean(),
            guarantees: [atom()],
            gaming_events: [map()]
          },
          context_tier: Tier.t(),
          context_tier_escalations: [map()],
          usage_fidelity: :unreported | nil
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

    # T36.4 (ADR-0047 §2/§4): bind the adapter opts (the base-tier source) and the
    # resolved escalation config once, so the struct can seed the escalation state.
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    escalation_config = Escalation.config(Keyword.get(opts, :context_escalation))

    # T45.7 (ADR-0056 decision 5): the MODEL escalation ladder from the goal's
    # `[escalation]` block, or nil when none is declared (single-model, unchanged).
    # A declared ladder is authoritative: rung 0 PINS the initial dispatch model,
    # so the dispatched model sequence is exactly the declared ladder.
    started_at_ms = now_fn.()
    ladder = Ladder.from_escalation(goal.escalation, started_at_ms)
    adapter_opts = pin_ladder_model(adapter_opts, ladder)

    data = %Data{
      goal: goal,
      providers: fetch!(opts, :providers),
      harness: fetch!(opts, :harness),
      integrate: fetch!(opts, :integrate),
      deploy: fetch!(opts, :deploy),
      workspace: Keyword.get(opts, :workspace),
      adapter_opts: adapter_opts,
      # T45.7 (ADR-0056 decision 5): the model escalation ladder (nil = none).
      ladder: ladder,
      workspace_opts: Keyword.get(opts, :workspace_opts, []),
      live_kinds: MapSet.new(Keyword.get(opts, :live_kinds, @default_live_kinds)),
      reobserve_interval_ms: Keyword.get(opts, :reobserve_interval_ms, @default_reobserve_ms),
      # T3.4a standing mode: opt the loop into the continuous-maintenance
      # behaviour (default false = converge-and-stop).
      standing: Keyword.get(opts, :standing, false),
      # T48.11 (ADR-0058 §3): opt the loop into appending the debrief question
      # to every dispatch prompt (default false = byte-identical to today).
      debrief: Keyword.get(opts, :debrief, false),
      on_iteration: Keyword.get(opts, :on_iteration),
      integrate_timeout_ms:
        Keyword.get(opts, :integrate_timeout_ms, @default_integrate_timeout_ms),
      integrate_params: Map.new(Keyword.get(opts, :integrate_params, %{})),
      deploy_params: Map.new(Keyword.get(opts, :deploy_params, %{})),
      extra_action_context: Map.new(Keyword.get(opts, :extra_action_context, %{})),
      # T1.3 flake: how many extra evaluations to spend distinguishing a real
      # failure from a flake (default Kazi.Loop.Flake.max_retries/0).
      flake_max_retries: Keyword.get(opts, :flake_max_retries, Flake.max_retries()),
      # T1.4 budget: cache the hard ceiling + clock and start the wall-clock.
      budget: Keyword.get(opts, :budget, goal.budget),
      now_fn: now_fn,
      started_at_ms: started_at_ms,
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
      resource_key: derive_resource_key(opts, goal),
      # T32.4 anti-gaming enforcement (ADR-0042): the resolved profile is threaded
      # IN by `Kazi.Runtime` (which applies the default-on-for-creation policy);
      # absent it, enforcement is off and every enforcement seam is a no-op, so the
      # default loop is unchanged.
      enforcement: Keyword.get(opts, :enforcement),
      # T32.5 diff-inspection guard (ADR-0042 §5): the diff source the guard scans,
      # defaulting to a `git diff HEAD` of the workspace. Injectable so a test can
      # feed a canned diff; only invoked when enforcement is active.
      diff_fn: Keyword.get(opts, :diff_fn, &default_diff_fn/1),
      # T36.4 (ADR-0047 §2/§4): resolve the escalation config (the `:context_escalation`
      # opt > `config :kazi, :context_escalation` > provisional defaults) and seed the
      # escalation state from the operator/goal base tier. With escalation enabled but
      # no non-progress the active tier stays at the base, so the dispatch path is
      # byte-identical to before until a stall is detected.
      escalation_config: escalation_config,
      escalation_state: Escalation.init(Tier.resolve(adapter_opts), escalation_config),
      # T53.2 (#1022): opt-in workspace-liveness precheck, default false. Many
      # callers (tests, fixture-path loops) pass a `:workspace` that names a
      # target for context threading only and is never expected to exist on
      # disk — checking existence there would be a false positive, not a
      # detection. `Kazi.Runtime` turns this on for every REAL `kazi apply`,
      # where the workspace is an actual checkout that can actually vanish.
      check_workspace_liveness: Keyword.get(opts, :check_workspace_liveness, false),
      # ADR-0080 (#1520): the t0 seal manifest, armed by the runtime. Absent = %{}
      # (nothing sealed), so a loop with no seal is byte-identical to pre-ADR-0080.
      seal_manifest: Keyword.get(opts, :seal_manifest, %{}),
      # ADR-0081 (#1521): the controller-side capture executor, built by the
      # runtime. Absent = a no-op returning `%{}`, so a loop with no captures is
      # byte-identical to before.
      capture_fn: Keyword.get(opts, :capture_fn) || fn _iter -> %{} end
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
    # T53.2 (#1022): checked BEFORE budget/observe — a vanished workspace is a
    # distinct fatal cause, not just another failing observation. Grinding
    # predicate iterations (or burning budget) against a dead path can never
    # converge, so the loop stops immediately with a named remedy instead.
    case workspace_missing_check(data) do
      {:missing, remedy} ->
        terminate_workspace_missing(remedy, data)

      :ok ->
        seal_check_then_observe(data)
    end
  end

  # --- ACT: dispatch the coding agent against failing-predicate evidence -------
  # Both the fixer (`:dispatch_agent`) and the demonstrator (`:dispatch_demonstrator`,
  # T49.7) route through the SAME lease + dispatch machinery; only the work differs
  # (the demonstrator mints a pin under a role-scoped write lease, see
  # `dispatch_demonstrator/2`).
  def handle_event(:internal, {:act, %Action{kind: kind} = action}, :acting, data)
      when kind in [:dispatch_agent, :dispatch_demonstrator] do
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
        dispatch(action, data)
    end
  end

  # --- ACT: integrate (land the converged code change) -------------------------
  def handle_event(:internal, {:act, %Action{kind: :integrate} = action}, :acting, data) do
    result = run_integrate(data.integrate, action, action_context(action, data), data)
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
      when state in [:converged, :stopped, :over_budget, :tampered] do
    :keep_state_and_data
  end

  # --- stop / await / snapshot (handled in any state) --------------------------
  def handle_event(:cast, :stop, state, %Data{} = data)
      when state not in [:converged, :stopped, :over_budget, :tampered] do
    terminate_with(:stopped, data)
  end

  def handle_event(:cast, :stop, _state, _data), do: :keep_state_and_data

  # In a terminal state the result is cached in data; reply to await immediately.
  def handle_event({:call, from}, :await, state, %Data{} = data)
      when state in [:converged, :stopped, :over_budget, :tampered] do
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
      # T48.6 (ADR-0058) budget: completed :dispatch_agent actions so far (the
      # max_dispatches dimension) — observe-only ticks never increment this.
      dispatches: data.dispatches,
      budget_reason: data.budget_reason,
      # T1.5 stuck: the persistent failing set the loop stopped stuck on, or nil
      # if it did not stop stuck.
      stuck_failing: stuck_failing_list(data.stuck_failing),
      # T48.3 (ADR-0058, UC-064): the reason map for a LIVE permanent-error stuck
      # stop, or nil for every other stop (see `build_result/2`).
      stuck_reasons: data.stuck_reasons,
      # T48.4 (ADR-0058 decision 4, UC-064): the honest terminal cause class, or
      # nil pre-termination / on a non-mislabel stop (see `cause_for/2`).
      cause: cause_for(state, data),
      # T1.2 regression: the green→red flags detected over the history so far,
      # each with its attributed dispatch (see Kazi.Loop.RegressionDetector).
      regressions: data.regressions,
      # T32.4 enforcement: the active anti-gaming guarantees + any flagged gaming
      # event, so `kazi status` / `run --json` can show the bar was held
      # (ADR-0042 §7). A disabled shape (`active: false`) when enforcement is off.
      enforcement: enforcement_status(data),
      # T36.4 (ADR-0047 §2/§4): the live context-budget tier the loop is currently
      # assembling dispatches at (escalated from the base on non-progress), and the
      # ordered log of tier changes (escalations + stop-rule reverts) this run made,
      # so a test / `kazi status` can confirm a stalled run escalated and a
      # net-negative bump was reverted.
      context_tier: active_tier(data),
      context_tier_escalations: Enum.reverse(data.escalation_events),
      # T48.5 (ADR-0058 §4): `:unreported` once a max_tokens ceiling has seen a
      # dispatch report no usage this run (the ceiling cannot bind), else nil.
      usage_fidelity: data.usage_fidelity
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
  # ADR-0080 (#1520): re-verify the seal BEFORE budget/observe — a tampered
  # acceptance contract (the goal-file or a sealed input edited mid-run) is a
  # distinct fatal cause, checked at the same precedence as the workspace-liveness
  # precheck (and AFTER it, so a vanished workspace reports workspace_missing, not
  # a spurious tamper). A converging worker that edits its own bar to reach green
  # must never be able to report `:converged`; the run terminates `:tampered`
  # naming the file instead. A no-op when nothing is sealed.
  defp seal_check_then_observe(%Data{} = data) do
    case Kazi.Seal.verify(data.seal_manifest) do
      {:tampered, info} ->
        terminate_tampered(info, data)

      :ok ->
        # T1.4 budget: the hard ceiling is checked ONCE at the start of every
        # tick, BEFORE observing/dispatching more work. If a dimension is
        # exceeded the loop makes a hard stop here — it does not dispatch
        # another agent / integrate / deploy — terminating as :over_budget
        # with the exceeded dimension as reason.
        case budget_check(data) do
          {:stop, reason} ->
            # T45.7 (ADR-0056 decision 5): before terminating :over_budget, try the
            # escalation ladder — a next rung re-dispatches the SAME goal at a
            # stronger model with a fresh per-rung budget; otherwise the terminal
            # stop stands.
            case maybe_escalate(data, current_failing_set(data)) do
              {:escalated, data} -> reobserve(data, 0)
              :halt -> terminate_over_budget(reason, data)
            end

          :ok ->
            observe_tick(data)
        end
    end
  end

  defp observe_tick(%Data{} = data) do
    # ADR-0081 (#1521): run the controller-owned capture recipes FIRST, so every
    # predicate this pass observes against the SAME controller-produced artifacts
    # (a `render_proof` predicate reads them via `context[:captures]`). Keyed to
    # this observe iteration; a goal with no captures gets `%{}` (no-op). Runs at
    # the seal-verify precedence tier — after workspace-liveness + seal, before
    # predicate evaluation.
    data = %Data{data | captures: data.capture_fn.(data.iterations)}

    # T1.3 flake: observe now also evolves the quarantine set (a failing
    # predicate is re-run via the real provider path and may be classified flaky).
    # T32.4 enforcement: observe runs the tamper-prone graders (guard + held-out
    # predicates) against a clean detached worktree when enforcement isolation is
    # active; `clean_tree_active?` records whether that actually held (it degrades
    # to the working copy if the workspace is not a git repo), so the reported
    # guarantees reflect the ACTUAL level (ADR-0042 §7).
    {vector, quarantine, streaks, clean_tree_active?} = observe_with_isolation(data)
    data = %Data{data | clean_tree_active?: clean_tree_active?}

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
          # T1.3 flake: carry the quarantine set forward (#820: no longer purely
          # sticky — `evaluate/5` may have rehabilitated an id out of it this tick).
          quarantine: quarantine,
          # #820: carry the rehabilitation streak map forward alongside it.
          quarantine_streaks: streaks,
          # T3.4a standing mode: clear the steady flag for this fresh
          # observation. `converge_or_stay/1` (decide clause 1) re-sets it to
          # true iff THIS observation is satisfied, so `steady?` always reflects
          # the current observation — it drops to false the moment a standing
          # loop sees an unsatisfied vector (the T3.4b drift seam). A no-op for
          # the default loop, which never reads it.
          steady?: false,
          # Prepend this observation's full vector to the in-state history
          # (newest-first; read APIs reverse to oldest-first). T1.1. M6
          # (deep-review-001): bounded for a standing loop (see `bound_history/2`).
          history: bound_history([{index, vector} | data.history], data),
          iterations: data.iterations + 1
      }

    # #1290: reconcile the `landed?` progress flag with the `:landed` predicate's
    # freshly observed status, BEFORE `decide/2` reads it. Landing is
    # controller-owned (the `Integrate` action, clause 3), so clause 3
    # (`not data.landed?` -> `:integrate`) must fire whenever landing has not held
    # — including a REGRESSION after a prior successful integrate (the branch was
    # force-pushed away, commits stripped). Without this the flag stays a pure
    # action-history value, decoupled from the predicate, and a regressed landed
    # predicate can never re-route to integrate. A goal with no `:landed` predicate
    # (`[integration] mode = none`, e.g. every fleet member) is untouched: the flag
    # keeps its action-history meaning.
    data = reconcile_landed(data)

    # T1.2 regression: after observe (using the just-updated history), run the
    # pure detector over the full per-iteration history + dispatch log and record
    # any green→red flags (with their attributed dispatch) into state. Additive:
    # it does not touch the convergence guard, budget, or flake logic — decide/2
    # below is unchanged. The flags are surfaced via snapshot/1 and the read-model.
    data = %Data{data | regressions: detect_regressions(data)}

    # T36.4 (ADR-0047 §2/§4): fold this observation's progress/cost signal into the
    # escalation state BEFORE deciding, so a stalled run's NEXT dispatch (chosen by
    # `decide/2` below) assembles its context at the escalated tier. On sustained
    # non-progress against the same failing set the active tier steps up; the stop
    # rule reverts a bump that raised cost without progress. A no-op for a
    # progressing run (the tier holds at the base).
    data = escalate_context(data)

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
      {:stuck, failing} ->
        # T45.7 (ADR-0056 decision 5): the ORDINARY failing-set stall is the T30.3
        # "same failing predicate set" signal — try the escalation ladder before
        # terminating. A next rung re-dispatches the SAME goal at the next model
        # with a fresh per-rung stuck window; otherwise the terminal stuck stands.
        # (The error_stuck / permanent_error / capability_unreachable causes below
        # are NOT escalated — they are not the failing-set stall the ADR covers.)
        case maybe_escalate(data, failing) do
          {:escalated, data} -> reobserve(data, 0)
          :halt -> terminate_stuck(failing, data)
        end

      :not_stuck ->
        # M5 (deep-review-001): a predicate persistently in :error is a terminal,
        # checker-unrunnable condition -- it never converges, never dispatches
        # (`code_failing?`/`PredicateVector.failing` match only :fail), and never
        # trips the ABOVE :fail-based stuck check, so left unchecked the loop
        # would re-observe forever with no budget (when no [budget] table is
        # declared). Reuse the same terminal :stuck stop rather than a new
        # terminal state, on the SAME window the ordinary stuck check uses.
        case StuckDetector.error_stuck?(code_history(data), data.stuck_iterations) do
          {:error_stuck, erroring} ->
            terminate_stuck(erroring, data)

          :not_error_stuck ->
            # T48.3 (ADR-0058, UC-064): the ABOVE error_stuck? check reduces to
            # `code_history/1`, which drops live predicates entirely (by design —
            # step 5 legitimately polls them) — so a live predicate erroring
            # forever (e.g. an `:http_probe` missing its required `:url`) is
            # invisible to it and the loop falls through to `decide/2`'s
            # `handle_no_work/2` backoff FOREVER, spinning to `:max_iterations`/
            # `:over_budget` (the ADR-0058 wedge: a config error the loop could
            # have named on the first observation). Mirror the check over the
            # LIVE-only complement (`live_history/1`), but gate it on
            # `ErrorPermanence` classification: only a PERSISTENT PERMANENT
            # reason stops promptly; a persistent TRANSIENT reason (a probe
            # still legitimately warming up) falls through unchanged to the
            # existing bounded-backoff polling below.
            case StuckDetector.permanent_error_stuck?(
                   live_history(data),
                   data.stuck_iterations,
                   &ErrorPermanence.classify_result/1
                 ) do
              {:permanent_error_stuck, erroring, reasons} ->
                # T48.4 (ADR-0058 decision 4): this IS the error-wedge — a live
                # predicate stuck in a permanent `:error` — so tag the cause
                # explicitly rather than leaving `cause_for/2` to infer it.
                terminate_stuck(erroring, data, reasons, :error_wedged)

              :not_permanent_error_stuck ->
                decide(vector, data)
            end
        end
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
    flagged = data.gaming_flagged_iterations

    for {index, %PredicateVector{results: results}} <- rung_history(data) do
      results = Map.drop(results, MapSet.to_list(drop_ids))
      # T32.5 advisory downgrade: an observation the diff guard flagged has its
      # graded scores stripped here, so the stuck detector's score-progress escape
      # (ADR-0041) cannot fire on a GAMED apparent improvement — the gamed iteration
      # is not credited as progress. Only the stuck CLASSIFIER sees this; the stored
      # vector keeps its real score, and the boolean failing-set logic is untouched,
      # so convergence is never blocked (advisory, not a hard guard).
      results = discount_if_flagged(results, MapSet.member?(flagged, index))
      {index, PredicateVector.new(results)}
    end
  end

  # T45.7 (ADR-0056 decision 5): the history window the stuck classifier sees,
  # trimmed to iterations SINCE the current escalation rung began (`window_base`),
  # so each rung gets a FRESH stuck window rather than inheriting the prior model's
  # stall. `nil` ladder (no escalation) returns the full history unchanged —
  # byte-identical to the pre-T45.7 stuck detection.
  @spec rung_history(Data.t()) :: history()
  defp rung_history(%Data{ladder: %Ladder{window_base: base}} = data) do
    for {index, vector} <- ordered_history(data), index >= base, do: {index, vector}
  end

  defp rung_history(%Data{} = data), do: ordered_history(data)

  # T48.3 (ADR-0058, UC-064): the per-iteration history reduced to only LIVE,
  # non-quarantined predicates — the mirror image of `code_history/1` (which
  # DROPS these same ids). This is what feeds `permanent_error_stuck?/3`: a live
  # predicate erroring every observation is invisible to `code_history/1` by
  # design (step 5 polls it, the agent cannot "fix" it by re-dispatching), so
  # its persistent-error detection needs its OWN reduced view over the identical
  # goal/quarantine state. A quarantined live predicate is excluded here exactly
  # as `code_history/1` excludes it — its flakiness is already being tolerated by
  # the T1.3 quarantine mechanism, not the ADR-0058 permanence taxonomy.
  @spec live_history(Data.t()) :: history()
  defp live_history(%Data{goal: goal, live_kinds: live_kinds, quarantine: quarantine} = data) do
    kinds = predicate_kinds(goal)
    live_ids = for {id, kind} <- kinds, MapSet.member?(live_kinds, kind), do: id
    keep_ids = MapSet.difference(MapSet.new(live_ids), quarantine)

    for {index, %PredicateVector{results: results}} <- ordered_history(data) do
      results = Map.take(results, MapSet.to_list(keep_ids))
      {index, PredicateVector.new(results)}
    end
  end

  # Strip graded scores from a flagged observation's results (T32.5). A nil score
  # makes `PredicateResult.scored?/1` false, so the stuck detector excludes it from
  # the score-progress escape. A no-op for an unflagged observation.
  @spec discount_if_flagged(%{optional(Predicate.id()) => PredicateResult.t()}, boolean()) ::
          %{optional(Predicate.id()) => PredicateResult.t()}
  defp discount_if_flagged(results, false), do: results

  defp discount_if_flagged(results, true) do
    Map.new(results, fn {id, %PredicateResult{} = result} -> {id, %{result | score: nil}} end)
  end

  # =============================================================================
  # T36.4 context-tier escalation (ADR-0047 §2/§4)
  # =============================================================================

  # Fold this observation's progress/cost signal into the escalation state and
  # apply the decision. The active tier (`escalation_state.tier`) is what every
  # tier consumer (`active_tier/1`) reads, so a step up here makes the NEXT
  # dispatch assemble richer context. Records each tier change in
  # `escalation_events` for `snapshot/1`.
  @spec escalate_context(Data.t()) :: Data.t()
  defp escalate_context(%Data{escalation_state: nil} = data), do: data

  defp escalate_context(%Data{escalation_config: config, escalation_state: state} = data) do
    cost_now = run_cost(data)
    signal = %{progressing?: code_progressing?(data), cost: cost_now - data.escalation_prev_cost}

    {state, decision} = Escalation.step(state, config, signal)

    %Data{
      data
      | escalation_state: state,
        escalation_prev_cost: cost_now,
        escalation_events: record_escalation_event(data, decision)
    }
  end

  # The active context tier the loop assembles a dispatch at — the escalation
  # state's current tier (T36.4), which starts at the operator/goal base tier
  # (`Tier.resolve/1`, default 1) and steps up on non-progress. Falls back to the
  # base-tier resolution if escalation was never seeded (defensive; always seeded
  # in `init/1`).
  @spec active_tier(Data.t()) :: Tier.t()
  defp active_tier(%Data{escalation_state: %Escalation.State{} = state}),
    do: Escalation.tier(state)

  defp active_tier(%Data{adapter_opts: adapter_opts}), do: Tier.resolve(adapter_opts)

  # The non-progress signal escalation reads (ADR-0047 §2): the loop is NOT
  # progressing when the last two CODE observations carry the same non-empty
  # failing set with no graded-score improvement — exactly the
  # `Kazi.Loop.StuckDetector` verdict over a 2-window (the minimal delta that can
  # show "no change"). So escalation and the stuck stop read the SAME signal; the
  # CONFIG threshold (not this window) decides how many such steps trigger a step
  # up. Fewer than two observations, an empty/changed failing set, or an improving
  # score all read as progressing.
  @spec code_progressing?(Data.t()) :: boolean()
  defp code_progressing?(%Data{} = data) do
    StuckDetector.stuck?(code_history(data), 2) == :not_stuck
  end

  # The cumulative run cost the stop rule's per-iteration delta is computed from
  # (ADR-0046/0047 §4): the harness-reported dollars when present, else the rolled-
  # up token total as the cost proxy. Both accumulate across dispatches, so the
  # per-observation delta is the cost of the dispatch that observation measures.
  @spec run_cost(Data.t()) :: number()
  defp run_cost(%Data{usage: %{cost_usd: cost}}) when is_number(cost), do: cost
  defp run_cost(%Data{tokens_used: tokens}), do: tokens

  # Append a tier-change event (an escalation or a stop-rule revert) to the log,
  # keyed by the observation index that triggered it; a `:hold` records nothing.
  @spec record_escalation_event(Data.t(), Escalation.decision()) :: [map()]
  defp record_escalation_event(%Data{escalation_events: events}, :hold), do: events

  defp record_escalation_event(%Data{escalation_events: events, iterations: iterations}, decision) do
    {kind, from, to} = decision
    [%{kind: kind, from: from, to: to, iteration: iterations - 1} | events]
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

  # T32.4 enforcement (H1 fix, deep-review 001): wrap the observation in clean-tree
  # isolation when the enforcement profile is active AND the goal carries a
  # tamper-prone grader (a guard or held-out predicate). The clean tree is a
  # throwaway detached worktree at `enforcement.clean_ref`, overlaid with the
  # agent's candidate working-tree state and with `enforcement.read_only_paths`
  # (the grader's OWN definition files) re-pinned to `clean_ref`
  # (`Kazi.Enforcement.Isolation`); the isolated graders are evaluated against it so
  # a working-copy edit to a GRADER file cannot change their verdict, while a
  # working-copy edit to the CANDIDATE fix under test IS seen — held-out/guard
  # predicates can converge once the fix satisfies them, without waiting for
  # `integrate` to commit it first. The ordinary visible predicates still evaluate
  # against the working copy so the agent's in-flight work is seen and the loop
  # converges normally. Returns `{vector, quarantine, streaks, clean_tree_active?}`
  # (`streaks` is the #820 rehabilitation counter map, threaded exactly like
  # `quarantine` — see `observe/2`); `clean_tree_active?` is false when isolation
  # degraded (the workspace is not a git repo / the ref is unresolvable) — the
  # checker still ran, in the working copy, and the reported guarantees drop
  # `:clean_tree` (honest reporting, ADR-0042 §7). With enforcement off the
  # worktree is never created and this is exactly the pre-T32.4 single-workspace
  # observe.
  @spec observe_with_isolation(Data.t()) :: {PredicateVector.t(), MapSet.t(), map(), boolean()}
  defp observe_with_isolation(%Data{enforcement: enf, workspace: ws} = data) do
    if Enforcement.isolate?(enf) and is_binary(ws) and any_isolated?(data) do
      result =
        Isolation.with_clean_tree(ws, enf.clean_ref, enf.read_only_paths, fn clean_ws ->
          observe(data, fn predicate -> if isolated?(predicate), do: clean_ws, else: ws end)
        end)

      case result do
        {:ok, {vector, quarantine, streaks}} ->
          {vector, quarantine, streaks, true}

        {:degraded, _reason, {vector, quarantine, streaks}} ->
          {vector, quarantine, streaks, false}
      end
    else
      {vector, quarantine, streaks} = observe(data, fn _predicate -> ws end)
      {vector, quarantine, streaks, false}
    end
  end

  # Whether the goal carries any tamper-prone grader that clean-tree isolation
  # applies to — a guard or held-out predicate. When none exist, the clean worktree
  # is never created (no cost on the common path).
  @spec any_isolated?(Data.t()) :: boolean()
  defp any_isolated?(%Data{goal: goal}) do
    goal |> Goal.all_predicates() |> Enum.any?(&isolated?/1)
  end

  # The predicates clean-tree isolation guards: the tamper-prone graders — guard
  # predicates (test-count / coverage ratchets, ADR-0042 §4) and held-out
  # acceptance predicates (ADR-0042 §6). The ordinary visible iterating predicates
  # are NOT isolated, so the agent's working-copy work is seen and the loop can
  # converge (running them from a clean ref would never see uncommitted work).
  @spec isolated?(Predicate.t()) :: boolean()
  defp isolated?(%Predicate{} = predicate) do
    Predicate.guard?(predicate) or Predicate.held_out?(predicate)
  end

  # Evaluate every predicate the goal carries (predicates ++ guards) via its
  # registered provider, building the PredicateVector for this observation.
  #
  # `checker_workspace_fn` resolves the cwd each predicate's checker runs in (T32.4
  # clean-tree isolation): an isolated grader gets the clean worktree, everything
  # else the working copy. With enforcement off it is `fn _ -> data.workspace end`,
  # so the context is byte-identical to the pre-T32.4 path.
  #
  # T1.3 flake: returns `{vector, quarantine, streaks}` — observation also
  # evolves the quarantine set (a failing predicate is re-run through the real
  # provider path and may be classified flaky) AND the #820 rehabilitation streak
  # map (an already-quarantined predicate is polled through the real provider too,
  # so a sustained run of real passes can un-quarantine it). The fold threads both
  # accumulators so one observation can quarantine/rehabilitate several
  # predicates.
  #
  # T32.4 enforcement: each result passes through `Kazi.Enforcement.enforce_result/2`
  # so a checker that "passed" only by skipping/erroring/xfailing work is downgraded
  # to :fail (a no-op when enforcement is off, ADR-0042 §3).
  @spec observe(Data.t(), (Predicate.t() -> String.t() | nil)) ::
          {PredicateVector.t(), MapSet.t(), map()}
  defp observe(%Data{goal: goal} = data, checker_workspace_fn) do
    {pairs, {quarantine, streaks}} =
      goal
      |> Goal.all_predicates()
      |> Enum.map_reduce({data.quarantine, data.quarantine_streaks}, fn %Predicate{} = predicate,
                                                                        {quarantine, streaks} ->
        context = provider_context(data, checker_workspace_fn.(predicate))
        {result, quarantine, streaks} = evaluate(predicate, context, data, quarantine, streaks)
        result = Enforcement.enforce_result(data.enforcement, result)
        {{predicate.id, result}, {quarantine, streaks}}
      end)

    {PredicateVector.new(pairs), quarantine, streaks}
  end

  # Evaluate one predicate, applying the T1.3 flake re-run policy and folding any
  # flake into `quarantine`, OR — if already quarantined — the #820 rehabilitation
  # check into `streaks`. Returns `{result, quarantine, streaks}`.
  @spec evaluate(Predicate.t(), map(), Data.t(), MapSet.t(), map()) ::
          {PredicateResult.t(), MapSet.t(), map()}
  defp evaluate(%Predicate{id: id} = predicate, context, %Data{} = data, quarantine, streaks) do
    cond do
      # #820: an already-quarantined predicate is still polled through the real
      # provider (unlike ordinary work it is NOT re-dispatched to an agent — see
      # `code_failing?`/`PredicateVector.failing/1` — this is pure observation) so
      # a sustained run of real passes can rehabilitate it. A single non-pass, or
      # a still-short streak of passes, keeps it quarantined (:unknown, no
      # convergence claim); `rehab_streak/0` consecutive real passes un-quarantines
      # it and records THIS observation's genuine result.
      Flake.quarantined?(quarantine, id) ->
        result = run_provider(predicate, context, data)

        case Flake.record_pass_streak(streaks, id, result) do
          {:rehabilitated, streaks} -> {result, MapSet.delete(quarantine, id), streaks}
          {:still_quarantined, streaks} -> {Flake.quarantined_result(result), quarantine, streaks}
        end

      true ->
        first = run_provider(predicate, context, data)
        {result, quarantine} = apply_flake_policy(predicate, context, data, quarantine, first)
        {result, quarantine, streaks}
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
      #    objective-termination guard (T0.8, UC-005). T1.3/i795 flake: a
      #    quarantined predicate is EXCLUDED from the work-list (clause 2 below,
      #    via `PredicateVector.failing/1` matching only real `:fail`s) so a
      #    flake is never re-dispatched as an agent task — but it is NOT excluded
      #    here. Its status is `:unknown`, `PredicateVector.satisfied?/1` requires
      #    every result to be `:pass`, so a quarantined predicate blocks
      #    `:converged` exactly like any other unresolved one (issue #795: an
      #    `:unknown` verdict must never count toward the bar — a run must not
      #    report `converged` while a predicate's true state is genuinely
      #    unknown, quarantine included). With no work to dispatch and no
      #    convergence reachable, the loop falls through to clause 5 and keeps
      #    re-observing — a real fix (or a human unquarantining/re-authoring the
      #    predicate) is required to resolve it, never a silent false positive.
      #
      #    T3.4a standing mode: in a STANDING loop satisfaction does NOT
      #    terminate — `converge_or_stay/1` records the converged observation,
      #    marks the loop steady, and re-observes on the bounded interval so it
      #    keeps holding the predicates true (UC-016). In the DEFAULT loop this is
      #    exactly `terminate_with(:converged, data)` — the T0.8 path is
      #    unchanged.
      #
      #    #820: reaching :converged is also how a REHABILITATED predicate
      #    resolves — `evaluate/5` un-quarantines an id the moment its real result
      #    passes `rehab_streak/0` consecutive times and records that pass in THIS
      #    tick's vector, so an otherwise-green vector converges here exactly like
      #    any other predicate turning green — no separate rehab-termination path.
      all_satisfied?(vector) ->
        converge_or_stay(reset_noop_ticks(data))

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
        act(dispatch_action(vector, data), reset_noop_ticks(data))

      # 3. Code green but not landed: integrate.
      not data.landed? ->
        act(Action.new(:integrate, params: data.integrate_params), reset_noop_ticks(data))

      # 4. Landed but not deployed: deploy, then re-observe live predicates.
      not data.deployed? ->
        act(Action.new(:deploy, params: data.deploy_params), reset_noop_ticks(data))

      # 5. Landed + deployed, code green, but the whole vector still isn't
      #    satisfied (a live predicate is still :fail / :error / :unknown, or a
      #    predicate is quarantined-:unknown). There is NOTHING to dispatch — see
      #    `handle_no_work/2` (#820) for what happens next: an honest :stuck stop
      #    if the ONLY blockage is quarantine, otherwise a backed-off reobserve
      #    (never a sub-second busy-spin) while genuinely live work is pending.
      true ->
        handle_no_work(vector, data)
    end
  end

  # #820: the terminal "nothing to dispatch, not yet satisfied" clause of
  # `decide/2`. Two outcomes:
  #
  #   * `Flake.quarantine_blocks_only?/2` — every non-passing id is quarantined,
  #     i.e. there is no dispatchable work and never will be without rehabilitation
  #     or a human intervening. After `Flake.quarantine_only_stuck_ticks/0`
  #     consecutive such observations the loop stops honestly `:stuck`, naming the
  #     quarantined ids, rather than idling at the reobserve interval until
  #     `max_iterations`/wall-clock forces an uninformative `:over_budget` (the
  #     live occurrence in #820: 40 iterations at ~1 tick/s, every evaluation
  #     green, one predicate pinned `:unknown` by a single flake flap).
  #   * otherwise — a live predicate is legitimately still pending (deploy just
  #     happened; the probe has not gone green yet) — keep polling, but back off
  #     the interval on each consecutive no-work tick (capped) so an indefinite
  #     wait never busy-spins sub-second.
  #
  # `noop_ticks` counts consecutive calls to this clause; `decide/2`'s other four
  # clauses reset it to 0 the moment there is real work (or convergence), so the
  # count always reflects the CURRENT stretch of no-work ticks.
  @spec handle_no_work(PredicateVector.t(), Data.t()) :: :gen_statem.event_handler_result(atom())
  defp handle_no_work(vector, %Data{} = data) do
    ticks = data.noop_ticks + 1
    data = %Data{data | noop_ticks: ticks}

    if Flake.quarantine_blocks_only?(vector, data.quarantine) and
         ticks >= Flake.quarantine_only_stuck_ticks() do
      # T48.4 (ADR-0058 decision 4): this stop is blocked SOLELY by quarantine —
      # tag the cause explicitly (there is no reason map for this class).
      terminate_stuck(data.quarantine, data, nil, :quarantine_blocked)
    else
      reobserve(data, backoff_reobserve_ms(data.reobserve_interval_ms, ticks))
    end
  end

  # #820: reset the no-work tick counter — called from every `decide/2` clause
  # OTHER than the terminal no-work one, so a fresh stretch of no-work ticks
  # (after real work happened) starts the backoff/stuck-bound count at zero
  # rather than continuing a stale streak from before that work.
  @spec reset_noop_ticks(Data.t()) :: Data.t()
  defp reset_noop_ticks(%Data{noop_ticks: 0} = data), do: data
  defp reset_noop_ticks(%Data{} = data), do: %Data{data | noop_ticks: 0}

  # #820: the capped, exponentially-backed-off reobserve interval for a no-work
  # tick. `ticks == 1` (the first no-work observation) yields exactly `base_ms` —
  # byte-identical to the pre-#820 fixed-interval poll — so a single no-work tick
  # (the common "just deployed, waiting on the live probe" case) is unchanged.
  # From the second consecutive no-work tick the interval doubles each time, up to
  # `@max_noop_backoff_ms`, so an indefinite wait never spins sub-second forever.
  @max_noop_backoff_ms 30_000

  @spec backoff_reobserve_ms(non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp backoff_reobserve_ms(base_ms, ticks) do
    # Cap the exponent, not just the result, so a very long-lived standing loop's
    # tick count never risks a float blow-up in :math.pow/2.
    multiplier = trunc(:math.pow(2, min(ticks, 20) - 1))
    min(base_ms * multiplier, @max_noop_backoff_ms)
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
  # T1.3/i795 flake: a quarantined predicate's recorded status is `:unknown`
  # (`Flake.quarantined_result/1`), which `PredicateVector.satisfied?/1` already
  # treats as not-passing — so quarantine is NOT special-cased here. A goal with
  # a quarantined predicate blocks on this exactly like any other unresolved
  # predicate; only the WORK-LIST (`code_failing?`/`PredicateVector.failing/1`,
  # matching only real `:fail`s) excludes it, so it is never re-dispatched as an
  # agent task. Fixing issue #795 (a quarantined `:unknown` must never let a run
  # report `:converged`) is exactly why this thin wrapper no longer drops
  # anything before delegating.
  @spec all_satisfied?(PredicateVector.t()) :: boolean()
  defp all_satisfied?(%PredicateVector{} = vector), do: PredicateVector.satisfied?(vector)

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

  # True iff at least one AGENT-DISPATCHABLE code predicate is failing — a failure
  # the inner harness can fix by editing code, so it triggers a dispatch. A live
  # predicate (only green post-deploy) is not one; neither is the controller-owned
  # `:landed` predicate (see `agent_dispatchable?/2`), so a failing `:landed`
  # routes past clause 2 to clause 3's `:integrate`, never to agent re-dispatch
  # (#1290).
  @spec code_failing?(PredicateVector.t(), Data.t()) :: boolean()
  defp code_failing?(vector, %Data{goal: goal, live_kinds: live_kinds}) do
    kinds = predicate_kinds(goal)

    vector
    |> PredicateVector.failing()
    |> Enum.any?(fn id -> agent_dispatchable?(Map.get(kinds, id), live_kinds) end)
  end

  # A failing predicate of this kind is fixable by the inner AGENT editing code, so
  # it belongs on the dispatch work-list. Two kinds are NOT: a LIVE predicate (only
  # passes once the change is deployed and re-observed, so it must not trigger a
  # code dispatch) and the controller-owned `:landed` predicate — landing is kazi's
  # OWN `Integrate` action (`decide/2` clause 3), never an agent task. Excluding
  # `:landed` here is what stops clause 2 (`code_failing?`) from shadowing clause 3
  # (`not data.landed?` -> `:integrate`) on a failing landed predicate (#1290,
  # ADR-0055: rides the existing live-kind exclusion, adds no `decide/2` branch).
  @spec agent_dispatchable?(Predicate.provider_kind() | nil, MapSet.t()) :: boolean()
  defp agent_dispatchable?(kind, live_kinds) do
    kind != :landed and not MapSet.member?(live_kinds, kind)
  end

  # #1290: derive `data.landed?` from the `:landed` predicate's observed result so
  # `decide/2` clause 3 tracks whether landing currently holds, not just whether an
  # `Integrate` action once succeeded. Only a goal that opts into `[integration]
  # mode` carries a `:landed`-kind predicate; a goal without one is returned
  # unchanged, preserving the flag's action-history meaning for the common
  # (`mode = none`) case. A `:landed` predicate that was observed but has no result
  # yet is treated as not-landed (fail-safe toward re-integrating, never toward a
  # false-positive converge).
  @spec reconcile_landed(Data.t()) :: Data.t()
  defp reconcile_landed(%Data{goal: goal, vector: %PredicateVector{} = vector} = data) do
    kinds = predicate_kinds(goal)

    case Enum.find(kinds, fn {_id, kind} -> kind == :landed end) do
      {id, _kind} ->
        result = PredicateVector.get(vector, id)
        %Data{data | landed?: not is_nil(result) and PredicateResult.passed?(result)}

      nil ->
        data
    end
  end

  defp reconcile_landed(%Data{} = data), do: data

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
      |> Enum.filter(fn id -> agent_dispatchable?(Map.get(kinds, id), live_kinds) end)
      |> Enum.reject(fn id -> MapSet.member?(held_out, id) end)

    evidence =
      Map.new(failing, fn id -> {id, PredicateVector.get(vector, id).evidence} end)

    # T49.7 (ADR-0064 d3/d4): when a failing `scenario` predicate is blocked by its
    # PIN (`:unpinned` / `{:stale, :spec_changed}`) and its `repin` policy allows,
    # dispatch a DEMONSTRATOR to mint the pin instead of a fixer to patch code. The
    # routing rides entirely on the failing-predicate evidence already collected
    # here — `decide/2` gains NO special case (ADR-0055). One scenario per dispatch
    # (the pin is a per-Scenario artifact); any remaining failures are handled on
    # later iterations through this same machinery.
    case demonstrator_target(failing, evidence, goal) do
      {id, predicate} ->
        Action.new(:dispatch_demonstrator,
          params: %{failing: [id], evidence: Map.take(evidence, [id]), predicate: predicate},
          metadata: %{goal_id: goal.id}
        )

      nil ->
        Action.new(:dispatch_agent,
          params: %{failing: failing, evidence: evidence},
          metadata: %{goal_id: goal.id}
        )
    end
  end

  # The first failing `scenario` predicate whose pin is the blocker and whose repin
  # policy permits automatic re-demonstration, or nil. Read off the same failing +
  # evidence the fixer dispatch uses, so no new decision branch is introduced.
  @spec demonstrator_target([Predicate.id()], map(), Goal.t()) ::
          {Predicate.id(), Predicate.t()} | nil
  defp demonstrator_target(failing, evidence, %Goal{} = goal) do
    preds = predicate_by_id(goal)

    Enum.find_value(failing, fn id ->
      predicate = Map.get(preds, id)

      if (predicate && predicate.kind == :scenario) and
           demonstrable?(Map.get(evidence, id)) and repin_allows?(predicate) do
        {id, predicate}
      end
    end)
  end

  defp demonstrable?(%{pin_state: :unpinned}), do: true
  defp demonstrable?(%{pin_state: {:stale, :spec_changed}}), do: true
  defp demonstrable?(%{pin_state: {:stale, :code_drift}}), do: true
  defp demonstrable?(_), do: false

  defp repin_allows?(%Predicate{config: config}), do: Map.get(config, :repin, "auto") != "manual"

  defp predicate_by_id(%Goal{} = goal) do
    goal |> Goal.all_predicates() |> Map.new(fn predicate -> {predicate.id, predicate} end)
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
  # Route a leased dispatch to its role handler: the demonstrator (T49.7) or the
  # fixer. Both share this dispatch machinery; only the work differs.
  defp dispatch(%Action{kind: :dispatch_demonstrator} = action, data),
    do: dispatch_demonstrator(action, data)

  defp dispatch(%Action{} = action, data), do: dispatch_agent(action, data)

  @spec dispatch_agent(Action.t(), Data.t()) :: :gen_statem.event_handler_result(atom())
  defp dispatch_agent(%Action{} = action, data) do
    # T34.3 (ADR-0046 §2): build the prompt SECTIONS once (orientation prefix,
    # work-item, digest, evidence, retrieval) so the per-iteration `context`
    # counters are computed from the exact bytes sent — without re-running the
    # (possibly graph-touching) orientation builder. `assemble_prompt/1` joins them
    # byte-identically to the pre-T34.3 `dispatch_prompt/2`.
    parts = dispatch_prompt_parts(action, data)
    prompt = assemble_prompt(parts)

    # T4.5 context injection (ADR-0010 §3): before the stateless `claude -p`
    # dispatch, prepare the workspace so the agent starts oriented — expose the
    # code-review-graph MCP in the workspace's `.mcp.json` and refresh its code
    # graph if present. Best-effort: a prep error never blocks the dispatch (the
    # MCP/graph is an orientation optimisation, not a precondition).
    prepare_workspace(data)

    # T32.4 read-only lease (ADR-0042 §2): hash the read-only-leased paths just
    # before handing the workspace to the agent, so a post-dispatch change to one is
    # a flagged gaming event. A no-op (empty snapshot) when enforcement is off or no
    # paths are leased.
    before = read_only_snapshot(data)

    # T36.2 (ADR-0047 §1): drive the imminent dispatch with the MINIMAL default
    # tool/MCP surface — `--strict-mcp-config` exposing ONLY the MCP servers kazi
    # injected (the orientation/graph server written by `prepare_workspace/1`
    # above, plus the E35 context store once it lands) and the standard edit/shell
    # tools the agent needs to fix predicates, NOT the ambient set. See
    # `dispatch_adapter_opts/1`.
    result = data.harness.run(prompt, data.workspace, dispatch_adapter_opts(data))

    # T32.4 read-only lease: re-hash the leased paths and flag any write to one —
    # "a write attempt is a flagged event, not a silent edit" (ADR-0042 §2).
    data = flag_read_only_writes(data, before)

    # T32.5 diff-inspection guard (ADR-0042 §5): scan the agent's iteration diff for
    # gaming signatures (skip/xfail markers, test-input special-casing, grader
    # edits). A hit is SURFACED as a gaming event and flags the upcoming observation
    # so its graded progress is discounted — advisory, never a hard block.
    data = flag_diff_gaming(data)

    # T1.4 budget: accumulate this run's token estimate (if the harness reported
    # one) into the running total the budget guard checks next tick.
    data = accumulate_tokens(data, result)

    # T48.6 (ADR-0058) budget: this IS a completed :dispatch_agent action, so it
    # counts against max_dispatches regardless of the result (success or error) —
    # the dimension budgets dispatch attempts, not successful ones.
    data = accumulate_dispatches(data)

    # T34.1 (ADR-0046): accumulate the run-aggregate usage envelope — the
    # cached-vs-fresh token/cost components the harness reported — surfaced in the
    # terminal `--json` result. Only reported components are summed (absent ≠ zero).
    data = accumulate_usage(data, result)

    # T48.5 (ADR-0058 §4): if `max_tokens` is set and THIS dispatch reported no
    # usage at all, the ceiling cannot bind — warn loudly once per run and flag
    # the run's degraded usage fidelity so the operator sees WHY a budget never
    # trips rather than assuming the run is simply cheap.
    data = maybe_flag_unreported_usage(data, result)

    # (issue #769): if THIS dispatch had tool calls denied, the agent could not
    # act — warn loudly and retain the denials so the stuck bundle names the
    # cause. Without this the run is a silent, billable no-op: the harness exits
    # 0, nothing changes on disk, and the loop grinds to `:stuck` with no signal.
    data = maybe_flag_permission_denials(data, result)

    # T34.3 (ADR-0046 §2): record this dispatch's per-iteration `context` + `tools`
    # counters on the loop state so the NEXT observation's iteration event carries
    # them. `context` is computed from the prompt sections just built (orientation/
    # retrieval cache state vs the PRIOR dispatch + section token estimates);
    # `tools` from the harness result's tool-use stream where it exposes one.
    data = record_counters(data, parts, result)

    # T4.7 working-set digest: distill a BOUNDED, transcript-free note of the
    # files this iteration touched (map memory ONLY — `Digest.from_result/2`
    # reads the result's `:touched` set and nothing else, never the agent's
    # transcript/result text) and carry it forward so the NEXT dispatch's prompt
    # starts oriented to WHERE prior work landed (ADR-0010 §4). A run that reports
    # no touched set leaves the prior digest untouched, so the carried map memory
    # is the most recent iteration that actually reported one.
    data = record_working_set(data, result)

    # T49.8: a fixer dispatch is the "intervening workspace change" that makes a
    # subsequent demonstration worth trying again — reset the consecutive-failed
    # demonstration counter so `:capability_unreachable` only fires on demonstrations
    # that stall with NO code work between them.
    data = %Data{data | consecutive_failed_demos: 0}

    # T48.11 (ADR-0058 §3): when the goal opted in, extract this dispatch's
    # capped hypothesis list from the reply text and carry it forward the same
    # way `record_counters/3` carries `context`/`tools` — surfaced on the NEXT
    # iteration event, never read back into a prompt (write-only, see
    # `Kazi.Harness.Debrief`'s moduledoc). Disabled (default) always resets to
    # `[]`, so the iteration event stays byte-identical to today.
    data = record_debrief(data, result)

    # The code changed under us: any prior land/deploy is now stale. Re-observe
    # on the poll interval (not zero) so a goal whose code predicate never goes
    # green polls rather than busy-spinning, and stays interruptible by `:stop`.
    data = record_action(data, action, landed?: false, deployed?: false)
    # T1.2 regression: log this dispatch keyed by the observation index that
    # seeded it (data.iterations - 1, the last completed observation), so the
    # detector can attribute a later green→red edge to it.
    data = log_dispatch(data, action)

    # Two fail-fast fingerprints that grinding can never converge — stop now
    # rather than buy the identical no-op N more times. `terminate_stuck/4` takes
    # a StuckDetector.failing_set() (a MapSet, not the list PredicateVector.failing/1
    # returns).
    cond do
      # T54.6 (#1072) fix (b): the agent was REFUSED, not merely unsuccessful.
      permission_denial_wedged?(data) ->
        failing = MapSet.new(PredicateVector.failing(data.vector))
        terminate_stuck(failing, data, nil, :permission_denied)

      # T68.4 (#1546): the dispatch ended parked on its own backgrounded
      # verification jobs, zero diff — it only verified, never edited.
      parked_on_background_wedged?(data, result) ->
        warn_parked_on_background(data)
        failing = MapSet.new(PredicateVector.failing(data.vector))
        terminate_stuck(failing, data, nil, :parked_on_background)

      true ->
        reobserve(data, data.reobserve_interval_ms)
    end
  end

  # T49.7 (ADR-0064 d3): dispatch the DEMONSTRATOR for one pin-blocked scenario
  # predicate. Reuses the same dispatch helpers as the fixer — workspace prep, the
  # harness seam, token/dispatch accounting, action recording, re-observe — but the
  # work is `Kazi.Scenario.Demonstrator.demonstrate/3` (mint the pin, then the
  # born-reproducible acceptance gate: keep the pin ONLY if it validates AND replays
  # green, else discard). The write lease is role-scoped (T49.6): the demonstrator
  # may write ONLY its pin, so its read-only set is the fixer's leased paths minus
  # the pin it is minting.
  @spec dispatch_demonstrator(Action.t(), Data.t()) :: :gen_statem.event_handler_result(atom())
  defp dispatch_demonstrator(%Action{params: %{predicate: predicate}} = action, %Data{} = data) do
    prepare_workspace(data)
    before = demonstrator_snapshot(data)

    {outcome, info} =
      Kazi.Scenario.Demonstrator.demonstrate(predicate, %{workspace: data.workspace},
        harness: data.harness,
        adapter_opts: dispatch_adapter_opts(data)
      )

    # A write outside the pin is a flagged, role-scoped gaming event (ADR-0064 d3).
    data = flag_demonstrator_writes(data, before)

    # The demonstration is an ordinary harness dispatch: it counts against the token
    # + dispatch budgets like any other (the economy envelope tags the spend).
    data = accumulate_tokens(data, info[:harness])
    data = accumulate_dispatches(data)

    # The code (well, the pin) changed under us: any prior land/deploy is stale.
    data = record_action(data, action, landed?: false, deployed?: false)
    data = log_dispatch(data, action)
    data = record_demonstration_outcome(data, outcome)

    # T49.8 (ADR-0064 d4): two consecutive failed demonstrations with no
    # intervening code change means re-demonstrating is futile — terminate `:stuck`
    # with `:capability_unreachable` rather than looping (or draining the budget).
    # Checked HERE, at the end of the dispatch, so it fires before the next tick's
    # budget gate — the same fail-fast placement + priority as the permission-denied
    # wedge, so `:capability_unreachable` wins over `:over_budget`.
    if capability_unreachable?(data) do
      failing = MapSet.new(PredicateVector.failing(data.vector))
      terminate_stuck(failing, data, capability_reasons(predicate, info), :capability_unreachable)
    else
      reobserve(data, data.reobserve_interval_ms)
    end
  end

  # An accepted demonstration resets the counter; a rejected/errored one advances
  # it. A fixer dispatch (`dispatch_agent`) also resets it — that is the
  # "intervening workspace change" that makes the next demonstration worth trying.
  defp record_demonstration_outcome(%Data{} = data, :accepted),
    do: %Data{data | consecutive_failed_demos: 0}

  defp record_demonstration_outcome(%Data{} = data, _rejected_or_error),
    do: %Data{data | consecutive_failed_demos: data.consecutive_failed_demos + 1}

  defp capability_unreachable?(%Data{consecutive_failed_demos: n}), do: n >= 2

  defp capability_reasons(%Predicate{id: id}, info) do
    %{id => Map.get(info, :reasons, [:capability_unreachable])}
  end

  # The demonstrator's read-only snapshot: the role-scoped set it must NOT write —
  # the fixer's leased paths (specs + all pins) minus the pin it is allowed to mint.
  @spec demonstrator_snapshot(Data.t()) :: %{optional(String.t()) => term()}
  defp demonstrator_snapshot(%Data{enforcement: %Enforcement{enabled: true} = enf, workspace: ws}) do
    Enforcement.digest_paths(ws, demonstrator_read_only_paths(enf))
  end

  defp demonstrator_snapshot(%Data{}), do: %{}

  @spec flag_demonstrator_writes(Data.t(), %{optional(String.t()) => term()}) :: Data.t()
  defp flag_demonstrator_writes(
         %Data{enforcement: %Enforcement{enabled: true} = enf, workspace: ws} = data,
         before
       ) do
    case Enforcement.detect_writes(ws, demonstrator_read_only_paths(enf), before) do
      [] ->
        data

      events ->
        stamped =
          Enum.map(events, fn event ->
            event
            |> Map.put(:type, :disallowed_write)
            |> Map.put(:iteration, max(data.iterations - 1, 0))
          end)

        Enum.each(stamped, fn event ->
          Logger.warning(fn ->
            "kazi.loop goal=#{data.goal.id} ENFORCEMENT demonstrator flagged disallowed " <>
              "write to #{event.path} (iteration #{event.iteration})"
          end)
        end)

        %Data{data | gaming_events: data.gaming_events ++ stamped}
    end
  end

  defp flag_demonstrator_writes(%Data{} = data, _before), do: data

  defp demonstrator_read_only_paths(%Enforcement{} = enf) do
    read_only = Map.get(Enforcement.for_role(enf, :fixer), :read_only_paths, enf.read_only_paths)
    allowed = Map.get(Enforcement.for_role(enf, :demonstrator), :allowed_write_paths, [])
    read_only -- allowed
  end

  # T54.6 (#1072) fix (b): the fingerprint of a dispatch that was never allowed to
  # act — it changed NOTHING, it COST something, and its tool calls were DENIED.
  # Mirrors the `:workspace_missing` fail-fast (T53.2): grinding further can never
  # converge, because nothing about the next iteration makes the agent permitted.
  # Waiting for the ordinary stuck window instead buys the identical no-op N times
  # (the real run this is drawn from spent $1.09 over two invocations for zero
  # changed files, lore L-0023).
  #
  # All three conjuncts matter:
  #   * denials present — the authoritative signal (the profile parses them).
  #   * no changed files — a dispatch that DID land edits despite some unrelated
  #     denial is making progress; do not kill it.
  #   * cost > 0 — proves the harness really ran, so this is a refusal rather than
  #     a stubbed/no-op dispatch in a test.
  @spec permission_denial_wedged?(Data.t()) :: boolean()
  defp permission_denial_wedged?(%Data{permission_denials: []}), do: false

  defp permission_denial_wedged?(%Data{} = data) do
    data.working_set_digest.files == [] and run_cost(data) > 0
  end

  # T68.4 (#1546): the fingerprint of a dispatch that spent its whole session and
  # ended PARKED on its own backgrounded verification jobs — it edited NOTHING this
  # dispatch, it COST something, and its final message says it is waiting on
  # background checks it launched (a full `mix test` / doc-freshness suite). Named
  # apart from `:permission_denied` (nothing was refused) and from an ordinary
  # failing-set `:stuck` (it only verified, never made an edit). Grinding cannot
  # converge a session that only verifies, so the loop fails fast after one arc.
  #
  # All three conjuncts matter:
  #   * this dispatch touched no files — a dispatch that DID land edits is making
  #     progress even if it also backgrounded a check; do not kill it. Read from
  #     THIS result (not the carried digest, which reflects the last dispatch that
  #     touched anything) so a later parked dispatch after an earlier productive
  #     one is still caught.
  #   * cost > 0 — proves the harness really ran (a refusal/park, not a stubbed
  #     no-op dispatch in a test).
  #   * the final message parks on background jobs — the authoritative signal that
  #     the session ended waiting rather than finishing its work.
  @spec parked_on_background_wedged?(Data.t(), Kazi.HarnessAdapter.result()) :: boolean()
  defp parked_on_background_wedged?(%Data{} = data, result) do
    Digest.from_result(result).files == [] and run_cost(data) > 0 and
      parked_on_background_final?(result)
  end

  # A final result message that says the session is ending while backgrounded
  # verification it launched is still running. Deliberately narrow: it must name
  # BOTH a waiting/parked posture AND a background job, so an ordinary "I ran the
  # tests, all green" report does not trip it.
  @spec parked_on_background_final?(Kazi.HarnessAdapter.result()) :: boolean()
  defp parked_on_background_final?({:ok, %{result: text}}) when is_binary(text) do
    lower = String.downcase(text)

    waiting? =
      String.contains?(lower, "waiting for") or String.contains?(lower, "waiting on") or
        String.contains?(lower, "still running") or String.contains?(lower, "once both") or
        String.contains?(lower, "once they") or String.contains?(lower, "finalize once") or
        String.contains?(lower, "report results and finalize")

    background? =
      String.contains?(lower, "background") or String.contains?(lower, "in the background") or
        (String.contains?(lower, "mix test") and String.contains?(lower, "finish")) or
        (String.contains?(lower, "check") and String.contains?(lower, "to finish"))

    waiting? and background?
  end

  defp parked_on_background_final?(_result), do: false

  # Loud, once-per-run warning on the parked-on-background wedge. It ALSO reports
  # the leftover-background-process risk: the agent's own `run_in_background` Bash
  # jobs are detached grandchildren of the harness process, so kazi does not track
  # or reap them here — a leftover `mix test` beam can keep a port/DB bound and
  # poison the NEXT observation (#1546). Reaping those detached grandchildren
  # reliably is out of scope for this fix; `kazi orphans --reap` sweeps orphaned
  # process groups after the fact.
  @spec warn_parked_on_background(Data.t()) :: :ok
  defp warn_parked_on_background(%Data{} = data) do
    Logger.warning(fn ->
      "kazi.loop goal=#{goal_id(data.goal)} a harness dispatch ended PARKED on its own " <>
        "backgrounded verification jobs with ZERO file edits (issue #1546) — it only " <>
        "verified, never edited, so grinding cannot converge; stopping :stuck " <>
        "(:parked_on_background). NOTE: any background job the agent launched (e.g. a " <>
        "full `mix test`) is a detached grandchild kazi does not reap here and may still " <>
        "be running — it can hold a port/DB and poison the next observation. Run " <>
        "`kazi orphans --reap` to sweep leftover process groups."
    end)

    :ok
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
  defp dispatch_adapter_opts(%Data{adapter_opts: adapter_opts, workspace: workspace} = data) do
    # T36.4: overlay the ESCALATED active `:context_tier` so the tier-2 graph MCP
    # gate in `DispatchSurface` sees the live tier — a run that escalated to tier ≥ 2
    # gets the graph server exposed even though the operator opt was the default 1.
    # The overlaid opts are also what the harness receives, so the dispatched
    # `:context_tier` reflects the tier the context was assembled at.
    eff = Keyword.put(adapter_opts, Tier.opt_key(), active_tier(data))

    case DispatchSurface.minimal_default(workspace, eff) do
      [] -> eff
      surface -> Keyword.merge(surface, eff)
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
  # T34.3 (ADR-0046 §2): the dispatch prompt's SECTIONS, computed once so a single
  # dispatch builds (and the per-iteration `context` counters measure) the same
  # bytes. The orientation/retrieval builders can touch the graph/repo-map, so they
  # must NOT be re-run for counting — `dispatch_agent` reuses these parts for both
  # `assemble_prompt/1` and `Counters.context/5`. Returns the rendered orientation
  # prefix (`nil` when off), the stable work-item line, the rendered working-set
  # digest note (`""` when empty), the capped evidence, and the retrieval section
  # (`nil` when off).
  @spec dispatch_prompt_parts(Action.t(), Data.t()) :: %{
          orientation: String.t() | nil,
          work_item: String.t(),
          digest: String.t(),
          evidence: String.t(),
          context_store: String.t() | nil,
          attempt_ledger: String.t() | nil,
          memory_recall: String.t() | nil,
          retrieval: String.t() | nil,
          debrief_question: String.t() | nil
        }
  defp dispatch_prompt_parts(%Action{params: params}, %Data{goal: goal} = data) do
    failing = Map.get(params, :failing, [])

    # STABLE: the work item — goal id + the failing-predicate ids. Identical across
    # iterations sharing the same failing set, so it belongs in the cacheable head.
    work_item =
      "goal=#{goal.id} fix failing predicates: #{Enum.map_join(failing, ",", &to_string/1)}"

    # VOLATILE: the failing evidence, rendered in FULL (the T4.8 cap is the single
    # governing bound) — `evidence_part/3` then either inlines it (capped) as before,
    # or, when a context store is configured AND the artifact is oversized (T35.4),
    # indexes it and returns a compact reference plus a budget-fitted snippet section.
    raw_evidence =
      inspect(Map.get(params, :evidence, %{}), limit: :infinity, printable_limit: :infinity)

    {evidence, context_store} = evidence_part(raw_evidence, failing, data)

    %{
      orientation: orientation_prefix(data),
      # T44.4 (ADR-0055 decision 4b): the controller-owned PROCESS CONTRACT — a
      # stable, versioned block of universal working rules rendered from the goal's
      # `[conventions]` config ALONE (never per-iteration state), so it is
      # byte-identical across iterations (a cacheable head). `nil` when
      # `process_contract = false`, which reverts the prompt to the pre-E44 body.
      process_contract: ProcessContract.section(goal.conventions),
      work_item: work_item,
      digest: Digest.render(data.working_set_digest),
      evidence: evidence,
      context_store: context_store,
      # ADR-0061 decision 2: the episodic ATTEMPT LEDGER section, appended after
      # evidence. `nil` unless the `:attempt_ledger` flag is on (default off,
      # config.exs) AND the fold over the recorded history/dispatch log yields at
      # least one entry — so the prompt is byte-identical to before the ledger
      # existed unless a goal both opts in and has repeated attempts to report.
      attempt_ledger: attempt_ledger_section(data),
      # ADR-0062 decision 4: the semantic-recall section, appended after the
      # attempt ledger. `nil` unless the `:memory_recall` flag is on (default
      # off, config.exs) AND the deterministic query (failing-predicate ids +
      # touched paths — NEVER model-authored) recalls at least one snippet —
      # so the prompt is byte-identical to before this slice unless a goal
      # both opts in and the corpus has something relevant to surface.
      memory_recall: memory_recall_section(failing, data),
      retrieval: retrieval_section(data),
      # T48.11 (ADR-0058 §3): the opt-in debrief question, appended LAST (the
      # most volatile-looking section, but it's actually fixed text — ordering
      # after retrieval keeps every EARLIER section's cache-stability analysis
      # unchanged). `nil` when the goal did not opt in, so `append_section/2`
      # renders nothing and the prompt is byte-identical to pre-T48.11.
      debrief_question: debrief_question(data)
    }
  end

  # T48.11: the debrief question is FIXED text (`Kazi.Harness.Debrief.question/0`
  # takes no goal-specific input), so a goal that opts in gets the SAME bytes
  # every dispatch — purely additive, and it never depends on any previously
  # persisted hypothesis (the write-only rule, ADR-0058 §3).
  @spec debrief_question(Data.t()) :: String.t() | nil
  defp debrief_question(%Data{debrief: true}), do: Debrief.question()
  defp debrief_question(%Data{debrief: false}), do: nil

  # T35.4 (ADR-0045 §3): evidence compression. Returns `{evidence_slot,
  # context_store_section}`.
  #
  # DEFAULT (no `:context_store` in adapter_opts) and sub-threshold artifacts:
  # `{"evidence: " <> truncate_evidence(raw), nil}` — BYTE-IDENTICAL to the
  # pre-T35.4 path. Only when a store is configured AND the rendered artifact
  # exceeds `@context_store_threshold` does it compress: index the full artifact
  # under a SHA-scoped label (redacted inside `ContextStore.index/3`, T35.3), put a
  # compact reference in the evidence slot (the label + byte count + a one-line
  # summary, NOT the bytes), and retrieve budget-fitted snippets for the failing
  # predicates as a separate section. Indexing/search failures degrade silently —
  # the store is an optimisation, never a precondition (graceful degradation).
  @spec evidence_part(String.t(), [Predicate.id()], Data.t()) ::
          {String.t(), String.t() | nil}
  defp evidence_part(raw_evidence, failing, %Data{adapter_opts: adapter_opts} = data) do
    case Keyword.get(adapter_opts, :context_store) do
      nil ->
        {inline_evidence(raw_evidence), nil}

      store ->
        if byte_size(raw_evidence) > @context_store_threshold do
          compress_evidence(raw_evidence, store, failing, data)
        else
          {inline_evidence(raw_evidence), nil}
        end
    end
  end

  # Redact BEFORE truncating/inlining: the loop's dispatch prompt is a separate
  # path from `Kazi.Harness.Prompt.build_prompt` (T34.3 split it into cacheable
  # sections), so it does not inherit that path's redaction — redact here too so a
  # secret in captured evidence never reaches the harness (T35.3 parity, ADR-0009
  # amendment). Redaction is a no-op on ordinary output, so the non-secret path is
  # byte-identical to before.
  defp inline_evidence(raw_evidence),
    do: "evidence: " <> Prompt.truncate_evidence(Kazi.Redaction.redact(raw_evidence))

  @spec compress_evidence(String.t(), ContextStore.t(), [Predicate.id()], Data.t()) ::
          {String.t(), String.t() | nil}
  defp compress_evidence(raw_evidence, store, failing, %Data{adapter_opts: adapter_opts} = data) do
    label = StoreLabels.run_test_log(data.goal.id, data.iterations)
    budget = Keyword.get(adapter_opts, :context_budget, @context_store_default_budget)

    # Best-effort index; a failure (missing gist, etc.) just means no compression.
    _ = ContextStore.index(label, raw_evidence, context_store: store)

    reference =
      "evidence: [indexed #{label}: #{byte_size(raw_evidence)} bytes] " <>
        evidence_summary(raw_evidence)

    {reference, context_store_section(store, budget, failing, data)}
  end

  # A one-line summary kept in the prompt alongside the reference, so the agent sees
  # WHAT was indexed without the bytes. The store section carries the ranked detail.
  # Redacted (like every other path that egresses evidence to the harness).
  @spec evidence_summary(String.t()) :: String.t()
  defp evidence_summary(raw_evidence) do
    raw_evidence
    |> Kazi.Redaction.redact()
    |> String.split("\n", parts: 2)
    |> hd()
    |> Prompt.truncate_evidence(max_bytes: 200)
  end

  # T35.4: retrieve budget-fitted snippets for the current failing predicates and
  # render them as a clearly-delimited section. Query = the failing-predicate ids
  # (the error signature). An empty result, a disabled store, or any error renders
  # NO section (the reference in the evidence slot still names the indexed artifact).
  @spec context_store_section(ContextStore.t(), non_neg_integer(), [Predicate.id()], Data.t()) ::
          String.t() | nil
  defp context_store_section(store, budget, failing, _data) do
    # `failing` is the list of failing-predicate IDS (as carried in the dispatch
    # action params), not {id, result} pairs — the ids ARE the error-signature query.
    query = Enum.map_join(failing, " ", &to_string/1)

    case ContextStore.search(query, budget, context_store: store) do
      {:ok, [_ | _] = snippets} -> render_context_store_section(snippets)
      _ -> nil
    end
  end

  @spec render_context_store_section([Kazi.ContextStore.Snippet.t()]) :: String.t()
  defp render_context_store_section(snippets) do
    "## Indexed evidence (context store)\n\n" <>
      "Budget-fitted snippets retrieved from the indexed artifacts above. " <>
      "Use the provided snippets as evidence; if you need more, request a targeted " <>
      "source/query — do not ask for whole logs or whole docs.\n\n" <>
      Enum.map_join(snippets, "\n\n", fn %Kazi.ContextStore.Snippet{text: text, source: source} ->
        case source do
          nil -> "```\n" <> text <> "\n```"
          src -> "### " <> src <> "\n```\n" <> text <> "\n```"
        end
      end)
  end

  # T34.3: join the prompt sections — byte-identical to the pre-T34.3
  # `dispatch_prompt/2`. Front-load stable→volatile: orientation → work-item →
  # digest → evidence (the digest sits BETWEEN the stable work-item and the
  # volatile evidence; it is map memory that changes only when a prior iteration
  # reports a new touched set), then the optional retrieval section last.
  @spec assemble_prompt(map()) :: String.t()
  defp assemble_prompt(%{
         orientation: orientation,
         process_contract: process_contract,
         work_item: work_item,
         digest: digest,
         evidence: evidence,
         context_store: context_store,
         attempt_ledger: attempt_ledger,
         memory_recall: memory_recall,
         retrieval: retrieval,
         debrief_question: debrief_question
       }) do
    body =
      case digest do
        "" -> work_item <> "\n" <> evidence
        note -> work_item <> "\n\n" <> note <> "\n\n" <> evidence
      end

    # T44.4: the cacheable HEAD is orientation then process-contract (both stable
    # across iterations), joined ahead of the volatile work-item→digest→evidence
    # body. Each is independently optional: nil orientation AND nil contract leave
    # the body byte-identical to the pre-E44 prompt.
    prompt =
      [orientation, process_contract, body]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    # T35.4: the indexed-evidence section sits AFTER the (now-compact) evidence slot
    # and BEFORE retrieval; nil when no artifact was compressed this iteration, so
    # the default path is unchanged.
    prompt = append_section(prompt, context_store)
    # ADR-0061 decision 2: the ATTEMPT LEDGER sits after evidence/context-store,
    # before retrieval; nil unless the flag is on and the fold is non-empty, so
    # the prompt is byte-identical to before the ledger existed by default.
    prompt = append_section(prompt, attempt_ledger)
    # ADR-0062 decision 4: the recalled-knowledge section sits after the
    # attempt ledger, before retrieval; nil unless the flag is on and the
    # corpus has a relevant snippet, so the prompt is byte-identical to before
    # this slice by default.
    prompt = append_section(prompt, memory_recall)
    prompt = append_section(prompt, retrieval)
    # T48.11 (ADR-0058 §3): the opt-in debrief question is appended LAST, after
    # retrieval; nil when the goal did not opt in, so `append_section/2` is a
    # no-op and the prompt is BYTE-IDENTICAL to the pre-T48.11 path.
    append_section(prompt, debrief_question)
  end

  @spec append_section(String.t(), String.t() | nil) :: String.t()
  defp append_section(prompt, nil), do: prompt
  defp append_section(prompt, section), do: prompt <> "\n\n" <> section

  # T34.3 (ADR-0046 §2): fold this dispatch's per-iteration `context` + `tools`
  # counters into the loop state (attached to the NEXT iteration event). The
  # context cache state compares this dispatch's orientation/retrieval prefixes to
  # the PRIOR dispatch's (carried in `last_orientation_prefix` /
  # `last_retrieval_section`) — a byte-identical prefix is a "hit" the inner
  # harness's prompt cache can reuse (T19.2). The prior prefixes are then advanced
  # to this dispatch's for the next comparison.
  #
  # T36.3 (ADR-0047 §3): the active context tier is recorded alongside the section
  # counters, so each iteration's `context` envelope reports which tier it ran at.
  #
  # Issue #978: the attempt-ledger/memory-recall FLAGS are threaded alongside
  # `parts.attempt_ledger`/`parts.memory_recall` (already nil-collapsed by
  # `attempt_ledger_section/1`/`memory_recall_section/2` for the prompt itself) so
  # `Counters.context/8` can tell "flag off" (`:off` ⇒ `nil` token field) apart from
  # "flag on but rendered nothing" (nil text ⇒ a real `0`) — the two currently
  # collapse to the same `nil` in the prompt-section value alone.
  @spec record_counters(Data.t(), map(), Kazi.HarnessAdapter.result()) :: Data.t()
  defp record_counters(%Data{} = data, parts, result) do
    context =
      Counters.context(
        parts.orientation,
        parts.evidence,
        parts.retrieval,
        data.last_orientation_prefix,
        data.last_retrieval_section,
        # T36.4: record the ESCALATED active tier this dispatch actually ran at, so
        # the per-iteration `context` envelope attributes outcomes to the live tier
        # (which may have stepped up from the base on non-progress), not the static
        # base opt.
        active_tier(data),
        memory_section_arg(attempt_ledger?(data), parts.attempt_ledger),
        memory_section_arg(memory_recall?(data), parts.memory_recall)
      )

    %Data{
      data
      | last_context: context,
        last_tools: Counters.tools(result),
        last_orientation_prefix: parts.orientation,
        last_retrieval_section: parts.retrieval,
        last_session_id: harness_session_id(result, data.last_session_id),
        last_harness_pid: harness_pid(result, data.last_harness_pid)
    }
  end

  # Issue #978: a memory layer's `Counters.context/8` argument — `:off` when the
  # layer's flag is disabled (⇒ the counter reports `nil`), else the layer's
  # rendered section text (nil-included, ⇒ a real `0` when it rendered nothing).
  @spec memory_section_arg(boolean(), String.t() | nil) :: Counters.memory_section()
  defp memory_section_arg(false, _section), do: :off
  defp memory_section_arg(true, section), do: section

  # T48.11 (ADR-0058 §3): fold this dispatch's capped debrief hypothesis list
  # into the loop state, attached to the NEXT iteration event (mirroring
  # `record_counters/3`'s context/tools carry-forward, T34.3). Disabled ⇒ always
  # `[]`, regardless of what the reply text contained — a goal that never opted
  # in never even calls `Debrief.extract_from_result/1`.
  @spec record_debrief(Data.t(), Kazi.HarnessAdapter.result()) :: Data.t()
  defp record_debrief(%Data{debrief: false} = data, _result), do: %Data{data | last_debrief: []}

  defp record_debrief(%Data{debrief: true} = data, result) do
    %Data{data | last_debrief: Debrief.extract_from_result(result)}
  end

  # The dispatch result's harness session id when the profile parsed one
  # (claude's envelope `session_id`), else keep the previously seen id — a
  # result with no envelope (a failed dispatch) must not erase it. Accepts the
  # same shapes `Counters.tools/1` does ({:ok, map} | map | anything).
  defp harness_session_id({:ok, %{} = result}, prior), do: harness_session_id(result, prior)

  defp harness_session_id(%{session_id: session_id}, _prior) when is_binary(session_id),
    do: session_id

  defp harness_session_id(_result, prior), do: prior

  # The dispatch result's harness OS pid (issue #857, ChildSupervisor's
  # pid-file side channel) when reported, else keep the previously seen one —
  # a result with no pid (a failed dispatch) must not erase it.
  defp harness_pid({:ok, %{} = result}, prior), do: harness_pid(result, prior)

  defp harness_pid(%{harness_pid: pid}, _prior) when is_binary(pid), do: pid

  defp harness_pid(_result, prior), do: prior

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
  #
  # T36.3 (ADR-0047 §2): the active context TIER also gates the prefix. Tier 0
  # (evidence-only) DROPS the cached orientation; tier ≥ 1 keeps it (still subject
  # to the T19.4 toggle above). The default tier is 1, so absent a `:context_tier`
  # opt the path is byte-identical to before — tier 1 IS "evidence + cached
  # orientation".
  @spec orientation_prefix(Data.t()) :: String.t() | nil
  defp orientation_prefix(%Data{workspace: workspace}) when not is_binary(workspace), do: nil

  defp orientation_prefix(%Data{adapter_opts: adapter_opts} = data) do
    # T36.4: the ESCALATED active tier gates the prefix, not the static base tier —
    # tier 0 drops the cached orientation; tier ≥ 1 keeps it (still subject to the
    # T19.4 toggle). Absent any escalation the active tier IS the base, so the path
    # is unchanged.
    if Tier.orientation?(active_tier(data)) and orientation_prefix?(adapter_opts),
      do: build_orientation_prefix(data),
      else: nil
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

  # ADR-0061 decision 2: the episodic ATTEMPT LEDGER section. Gated on
  # `attempt_ledger?/1` (default off, `config :kazi, :attempt_ledger`, T19.4-style
  # `:attempt_ledger` adapter-opt override); when off this is `nil` and the prompt
  # is byte-identical to before the ledger existed. When on, folds the loop's OWN
  # recorded oldest-first history + dispatch log (`Kazi.Memory.AttemptLedger`,
  # decision 1 — never model/transcript prose) and renders the bounded section
  # (decision 2); an empty fold (no dispatches yet, or none repeated) also
  # renders to `""`, which is normalised to `nil` here so `append_section/2`
  # adds nothing.
  @spec attempt_ledger_section(Data.t()) :: String.t() | nil
  defp attempt_ledger_section(%Data{} = data) do
    if attempt_ledger?(data) do
      entries = AttemptLedger.fold(ordered_history(data), Enum.reverse(data.dispatch_log))

      case AttemptLedger.render(entries, attempt_ledger_opts(data)) do
        "" -> nil
        section -> section
      end
    else
      nil
    end
  end

  # The `:attempt_ledger` flag (ADR-0061 decision 6, ADR-0060 guardrail 4):
  # an explicit `adapter_opts[:attempt_ledger]` wins; absent that, the resolved
  # app config `config :kazi, :attempt_ledger` (default `false`) decides. Mirrors
  # `orientation_prefix?/1`'s opt-then-default shape.
  @spec attempt_ledger?(Data.t()) :: boolean()
  defp attempt_ledger?(%Data{adapter_opts: adapter_opts}) do
    case Keyword.fetch(adapter_opts, :attempt_ledger) do
      {:ok, value} -> value == true
      :error -> Application.get_env(:kazi, :attempt_ledger, false) == true
    end
  end

  # Forward only the ledger-rendering opt to `Kazi.Memory.AttemptLedger.render/2`.
  defp attempt_ledger_opts(%Data{adapter_opts: adapter_opts}) do
    case Keyword.fetch(adapter_opts, :attempt_ledger_max_tokens) do
      {:ok, max_tokens} -> [max_tokens: max_tokens]
      :error -> []
    end
  end

  # ADR-0062 decision 4: the semantic-recall section. Gated on
  # `memory_recall?/1` (default off, `config :kazi, :memory_recall`, mirroring
  # `attempt_ledger?/1`); when off this is `nil` and the prompt is unchanged.
  # When on, `SemanticIndex.recall/3` runs against a query DERIVED
  # deterministically from `failing` (the dispatch's failing-predicate ids)
  # and the working-set digest's touched paths — never model-authored (the
  # same "facts only" discipline `Kazi.Memory.AttemptLedger` follows). An
  # empty recall renders `nil` too, so a goal with an empty/thin corpus adds
  # no section.
  @spec memory_recall_section([Predicate.id()], Data.t()) :: String.t() | nil
  defp memory_recall_section(failing, %Data{} = data) do
    if memory_recall?(data) do
      case SemanticIndex.recall(memory_recall_query(failing, data), memory_recall_budget(data),
             workspace: memory_recall_workspace(data),
             corpus: data.goal.memory_corpus
           ) do
        [] -> nil
        snippets -> render_memory_recall_section(snippets)
      end
    else
      nil
    end
  end

  # The `:memory_recall` flag (ADR-0062, ADR-0060 guardrail 4): an explicit
  # `adapter_opts[:memory_recall]` wins; absent that, the resolved app config
  # `config :kazi, :memory_recall` (default `false`) decides.
  @spec memory_recall?(Data.t()) :: boolean()
  defp memory_recall?(%Data{adapter_opts: adapter_opts}) do
    case Keyword.fetch(adapter_opts, :memory_recall) do
      {:ok, value} -> value == true
      :error -> Application.get_env(:kazi, :memory_recall, false) == true
    end
  end

  # The recall query: the failing-predicate ids plus the working-set digest's
  # touched paths (ADR-0062 decision 4), sorted so the query — and therefore
  # anything cached against it — is deterministic regardless of enumeration
  # order.
  @spec memory_recall_query([Predicate.id()], Data.t()) :: String.t()
  defp memory_recall_query(failing, %Data{working_set_digest: digest}) do
    ids = failing |> Enum.map(&to_string/1) |> Enum.sort()
    touched = digest.files |> Enum.sort()
    Enum.join(ids ++ touched, " ")
  end

  @default_memory_recall_max_tokens 1_500

  defp memory_recall_budget(%Data{adapter_opts: adapter_opts}) do
    Keyword.get(adapter_opts, :memory_recall_max_tokens, @default_memory_recall_max_tokens)
  end

  defp memory_recall_workspace(%Data{workspace: workspace}) when is_binary(workspace),
    do: workspace

  defp memory_recall_workspace(%Data{}), do: "."

  @spec render_memory_recall_section([SemanticIndex.snippet()]) :: String.t()
  defp render_memory_recall_section(snippets) do
    "## Recalled project knowledge (kazi memory, ADR-0062)\n\n" <>
      Enum.map_join(snippets, "\n\n", fn %{path: path, line: line, text: text} ->
        "### #{path}:#{line}\n```\n#{text}\n```"
      end)
  end

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
  #
  # T32.4 enforcement: `checker_workspace` is the cwd the checker runs in — the
  # clean detached worktree for an isolated grader, the working copy otherwise. It
  # defaults to `data.workspace`, so a caller that does not thread enforcement gets
  # the pre-T32.4 context unchanged.
  @spec provider_context(Data.t(), String.t() | nil) :: map()
  defp provider_context(%Data{} = data, checker_workspace) do
    %{
      goal: data.goal,
      scope: data.goal.scope,
      workspace: checker_workspace || data.workspace,
      landed?: data.landed?,
      deployed?: data.deployed?,
      iteration: data.iterations,
      # ADR-0081 (#1521): the controller-produced captures for THIS observe pass,
      # `%{name => result}`; a `render_proof` predicate resolves its named capture
      # here rather than from a worker-chosen workspace path.
      captures: data.captures
    }
  end

  # M6 (deep-review-001): the sliding-window floor a STANDING loop's history is
  # trimmed to — comfortably larger than any realistic stuck/regression window
  # so trimming only ever drops entries far older than either detector reads.
  @standing_history_floor 100

  # Bound `history` (newest-first) for a standing loop only; a no-op for the
  # default loop, which terminates and never accrues unbounded history. The
  # window is the larger of the configured stuck window and the floor above —
  # trimming never removes the two newest entries a fresh green->red transition
  # needs, so a NEW regression is always still caught the tick it occurs; only
  # already-stale trajectory (older than every detector's window) is dropped.
  @spec bound_history(history(), Data.t()) :: history()
  defp bound_history(history, %Data{standing: true, stuck_iterations: stuck_iterations}) do
    window = max(@standing_history_floor, stuck_iterations || 0)
    Enum.take(history, window)
  end

  defp bound_history(history, %Data{standing: _not_standing}), do: history

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
        # ADR-0080 (#1520): a tampered run is a distinct terminal outcome — it can
        # NEVER collapse to :converged, and is not an ordinary :stopped either.
        :tampered -> :tampered
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
      usage: data.usage,
      # T32.4 enforcement: the active anti-gaming guarantees + flagged gaming
      # events, so the CLI's `run --json` can report the bar was held (ADR-0042 §7).
      enforcement: enforcement_status(data),
      # i795/#795: name the quarantined ids on the terminal result — the field
      # `all_satisfied?/1`'s non-convergence is otherwise silent about.
      quarantine: MapSet.to_list(data.quarantine),
      # T48.7 (ADR-0058 decision 1): run-end economics inputs the read-model
      # projection needs beyond tokens_used/usage above — the dispatch count,
      # the active context tier, and the goal shape.
      dispatches: data.dispatches,
      context_tier: active_tier(data),
      goal_shape: goal_shape(data.goal),
      # T48.5 (ADR-0058 §4): `:unreported` if a max_tokens ceiling ever saw a
      # dispatch with no usage this run (so the ceiling could not bind), nil
      # otherwise.
      usage_fidelity: data.usage_fidelity,
      # T48.3 (ADR-0058, UC-064): the persistent failing set's last-observed
      # `:error` reason per id, when the stop was a LIVE permanent-error verdict
      # — nil for every other stop, so an operator sees WHY a live predicate is
      # named in `:stuck_failing` (a wedge, not a fixable code failure).
      stuck_reasons: data.stuck_reasons,
      # T48.4 (ADR-0058 decision 4, UC-064): the honest terminal cause class
      # alongside the outcome — nil unless this stop is one of the three named
      # mislabels (`Kazi.Loop.CauseClass`).
      cause: cause_for(state, data)
    }
    |> maybe_attach_stuck_bundle(data)
    |> maybe_attach_permission_denials(data)
    |> maybe_attach_tampered_file(data)
  end

  # ADR-0080 (#1520): on a :tampered stop, surface the offending file + the kind
  # of change (`:modified`/`:removed`/`:added`) as `tampered_file` on the terminal
  # result, so the CLI/read-model name WHICH sealed input the run was voided over.
  # Names only — never the file's contents (size + open-source-leak hygiene).
  # ABSENT on every non-tampered stop, so a normal result stays byte-identical.
  @spec maybe_attach_tampered_file(map(), Data.t()) :: map()
  defp maybe_attach_tampered_file(result, %Data{tampered_file: nil}), do: result

  defp maybe_attach_tampered_file(result, %Data{tampered_file: info}),
    do: Map.put(result, :tampered_file, info)

  # T54.6 (#1072, regression of #769): surface the denied tool calls on the TERMINAL
  # result, beside `changed_files` in the bundle. `permission_denied_tool_calls` is
  # the distilled count and `permission_denied_tools` the names — the operator's
  # answer to "it spent money and changed nothing, why?".
  #
  # ABSENT when nothing was denied, so a normal dispatch's terminal result stays
  # byte-identical to today (the task's acceptance criterion). Names only — never a
  # denial's `tool_input`, which holds the whole file a denied Write meant to write.
  @spec maybe_attach_permission_denials(map(), Data.t()) :: map()
  defp maybe_attach_permission_denials(result, %Data{permission_denials: []}), do: result

  defp maybe_attach_permission_denials(result, %Data{permission_denials: names}) do
    result
    |> Map.put(:permission_denied_tool_calls, length(names))
    |> Map.put(:permission_denied_tools, names)
  end

  # T48.4 (ADR-0058 decision 4, UC-064): the single seam that feeds
  # `Kazi.Loop.CauseClass.classify/1` from the loop's terminal state — shared by
  # `build_result/2` (the cached terminal result) and the `:snapshot` handler
  # (a live peek, where `state` may not yet be terminal — `stuck_cause`,
  # `stuck_failing`, and `budget_reason` are all nil pre-termination, so
  # `classify/1` safely returns nil rather than guessing early).
  @spec cause_for(atom(), Data.t()) :: CauseClass.t() | nil
  defp cause_for(state, %Data{} = data) do
    outcome =
      case state do
        :converged -> :converged
        :over_budget -> :over_budget
        _ -> :stopped
      end

    CauseClass.classify(%{
      outcome: outcome,
      reason: stop_reason(data),
      vector: data.vector,
      stuck_cause: data.stuck_cause,
      stuck_failing: stuck_failing_list(data.stuck_failing),
      stuck_reasons: data.stuck_reasons
    })
  end

  # T48.7 (ADR-0058 decision 1): the goal's shape — how many predicates it
  # declares and their kind breakdown — computed once at termination so the
  # read-model can group persisted run economics by "similar goal" (T48.8/T48.9)
  # without reloading the goal file. Reuses `Goal.all_predicates/1`, the same
  # source `predicate_kinds/1` reads.
  @spec goal_shape(Goal.t()) :: %{
          predicate_count: non_neg_integer(),
          kind_histogram: %{optional(Kazi.Predicate.provider_kind()) => pos_integer()}
        }
  defp goal_shape(%Goal{} = goal) do
    predicates = Goal.all_predicates(goal)

    %{
      predicate_count: length(predicates),
      kind_histogram: Enum.frequencies_by(predicates, & &1.kind)
    }
  end

  # T35.6 (ADR-0045 §5): on a stuck stop, attach a compact, bounded bundle so the
  # ADR-0035 model-ladder escalation (skill-side) hands the higher rung the bundle
  # instead of the lower rung's full transcript. Only on `:stuck` — every other
  # outcome's result is byte-identical to before.
  @spec maybe_attach_stuck_bundle(result(), Data.t()) :: result()
  defp maybe_attach_stuck_bundle(result, %Data{} = data) do
    case stop_reason(data) do
      :stuck -> Map.put(result, :stuck_bundle, build_stuck_bundle(data))
      _ -> result
    end
  end

  @spec build_stuck_bundle(Data.t()) :: StuckBundle.t()
  defp build_stuck_bundle(%Data{} = data) do
    failing_ids = stuck_failing_list(data.stuck_failing) || []

    failing =
      for id <- failing_ids do
        {id, evidence_for(data.vector, id)}
      end

    budget = Keyword.get(data.adapter_opts, :context_budget, 12_000)

    StuckBundle.assemble(
      %{
        failing: failing,
        changed_files: data.working_set_digest.files,
        snippets: stuck_snippets(data, failing_ids, budget),
        # (issue #769) `changed_files: []` PLUS a populated `permission_denials` is
        # the signature of a fully-denied dispatch — the operator's answer to "it
        # spent money and changed nothing, why?". Threaded through `assemble` (not
        # Map.put after it) so `bytes` counts it and `render/1` carries it into the
        # escalation prompt.
        permission_denials: data.permission_denials
      },
      budget: budget
    )
  end

  defp evidence_for(%PredicateVector{} = vector, id) do
    case PredicateVector.get(vector, id) do
      %PredicateResult{evidence: evidence} -> evidence
      _ -> %{}
    end
  end

  defp evidence_for(_vector, _id), do: %{}

  # Top store snippets for the error signature (the failing-predicate ids), when a
  # context store is configured; else none. Best-effort — a disabled/erroring store
  # just yields no snippets.
  defp stuck_snippets(%Data{adapter_opts: adapter_opts}, failing_ids, budget) do
    case Keyword.get(adapter_opts, :context_store) do
      nil ->
        []

      store ->
        query = Enum.map_join(failing_ids, " ", &to_string/1)

        case ContextStore.search(query, budget, context_store: store) do
          {:ok, snippets} when is_list(snippets) -> snippets
          _ -> []
        end
    end
  end

  # The terminal result's `:reason`: the budget dimension on an :over_budget stop
  # (T1.4), `:stuck` on a stuck stop (T1.5), nil otherwise.
  @spec stop_reason(Data.t()) :: Budget.reason() | :stuck | nil
  # ADR-0080 (#1520): a tampered stop names itself, ahead of the stuck/budget
  # reasons (a tamper terminates before either fires).
  defp stop_reason(%Data{tampered_file: file}) when not is_nil(file), do: :tampered
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
  # (see `stop_reason/1`). `reasons` (T48.3, ADR-0058) is the LIVE
  # permanent-error verdict's `%{id => reason}` map, or nil for every other
  # stuck stop. `cause` (T48.4, ADR-0058 decision 4) is the explicit
  # `Kazi.Loop.CauseClass` tag the CALL SITE assigns — `:error_wedged` for the
  # T48.3 live-permanent-error path, `:quarantine_blocked` for the #820
  # quarantine-only path, or `nil` (default) for the ordinary T1.5 failing-set
  # and pre-existing code `error_stuck?` (M5) call sites, which pass neither
  # extra argument and so are byte-identical to before this change.
  @spec terminate_stuck(
          StuckDetector.failing_set(),
          Data.t(),
          %{Kazi.Predicate.id() => term()} | nil,
          CauseClass.class() | nil
        ) :: :gen_statem.event_handler_result(atom())
  defp terminate_stuck(failing, %Data{} = data, reasons \\ nil, cause \\ nil) do
    data = %Data{data | stuck_failing: failing, stuck_reasons: reasons, stuck_cause: cause}
    notify_escalation(data, failing)
    notify_stuck_stop(data)
    terminate_with(:stopped, data)
  end

  # T53.2 (#1022): does `data.workspace` still exist as a usable git working
  # tree? `nil` (a workspaceless loop) is always `:ok` — nothing to probe. A
  # missing directory, or `git rev-parse` failing with the not-a-repository /
  # deleted-cwd exit-128 signature (the shape `.git/worktrees` admin data left
  # behind looks like once its checkout is gone), both count as `:missing`
  # with a one-line remedy naming the exact restore path from issue #1022.
  @spec workspace_missing_check(Data.t()) :: :ok | {:missing, String.t()}
  defp workspace_missing_check(%Data{check_workspace_liveness: false}), do: :ok
  defp workspace_missing_check(%Data{workspace: nil}), do: :ok

  defp workspace_missing_check(%Data{workspace: workspace}) do
    cond do
      not File.dir?(workspace) ->
        {:missing, workspace_missing_remedy(workspace)}

      git_worktree_gone?(workspace) ->
        {:missing, workspace_missing_remedy(workspace)}

      true ->
        :ok
    end
  end

  # `File.dir?/1` already caught the plain "directory is gone" case above; this
  # catches the narrower #1022 signature — the workspace dir still resolves at
  # the FS level (e.g. a race, or a `.git/worktrees` admin entry pointing at a
  # path some OTHER process is mid-way through deleting) but git itself can no
  # longer read its own cwd there. Deliberately NOT "not a git repository" —
  # plenty of real, live workspaces (non-git fixtures/tests) are never git
  # repos to begin with, so that alone is not evidence of a vanished worktree.
  # Never a fetch, never a network call.
  defp git_worktree_gone?(workspace) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {_out, 0} -> false
      {out, 128} -> out =~ "unable to read current working directory"
      {_out, _status} -> false
    end
  rescue
    _ -> true
  end

  # The one-line remedy surfaced in the terminal result: the `.git/worktrees`
  # admin-data restore path from issue #1022, not a re-dispatch (grinding more
  # agent iterations against a dead path fixes nothing).
  defp workspace_missing_remedy(workspace) do
    "workspace #{workspace} is gone; restore it from the source repo's " <>
      ".git/worktrees admin data (issue #1022) — do not re-dispatch against a dead path"
  end

  # T53.2 (#1022): a distinct fatal stop, reusing the T1.5 stuck machinery
  # (same escalation/notify/terminate path) with an explicit :workspace_missing
  # cause and its remedy carried in `stuck_reasons` — the same shape
  # `Kazi.Loop.CauseClass.format/2` already renders for `:error_wedged`.
  @spec terminate_workspace_missing(String.t(), Data.t()) ::
          :gen_statem.event_handler_result(atom())
  defp terminate_workspace_missing(remedy, %Data{} = data) do
    terminate_stuck(
      MapSet.new([:workspace]),
      data,
      %{workspace: remedy},
      :workspace_missing
    )
  end

  # ADR-0080 (#1520): a sealed input (or the goal-file) changed mid-run — the
  # acceptance contract was tampered with. A genuinely distinct terminal outcome
  # (`:tampered`), NOT a stuck :stopped: the run is VOID, never green, exit
  # non-zero, with the offending file named. `info` is the `%{path:, change:}`
  # from `Kazi.Seal.verify/1`.
  @spec terminate_tampered(%{path: String.t(), change: atom()}, Data.t()) ::
          :gen_statem.event_handler_result(atom())
  defp terminate_tampered(%{path: path, change: change} = info, %Data{} = data) do
    Logger.warning(fn ->
      "kazi.loop goal=#{goal_id(data.goal)} SEALED input #{inspect(path)} was #{change} " <>
        "mid-run (ADR-0080, #1520) — the acceptance contract was tampered with. " <>
        "Terminating :tampered (the run is VOID, never converged). If this file is " <>
        "regenerated legitimately, add it to [seal] mutable_inputs or set " <>
        "[seal] enabled = false."
    end)

    terminate_with(:tampered, %Data{data | tampered_file: info})
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
      stop_reason: :stuck,
      # T34.3 (ADR-0046 §2): carry the last dispatch's context + tool counters so
      # the stuck-stop record (which upserts the last observation's row) keeps them.
      context: data.last_context || Counters.empty_context(),
      tools: data.last_tools,
      harness_session_id: data.last_session_id,
      harness_pid: data.last_harness_pid,
      # T48.11 (ADR-0058 §3): the last dispatch's capped hypothesis list — `[]`
      # when the goal never opted in, so this key stays byte-identical to today.
      debrief: data.last_debrief
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
      iterations: rung_iterations(data),
      elapsed_ms: rung_elapsed_ms(data),
      tokens: rung_tokens(data),
      dispatches: rung_dispatches(data)
    })
  end

  # T45.7 (ADR-0056 decision 5): budget usage measured PER RUNG. When an escalation
  # ladder is active, each rung is one bounded converge (ADR-0035's bound): usage is
  # the delta since the current rung's baseline, so a fresh model gets a fresh
  # budget rather than the exhausted tail of the prior rung. With no ladder these
  # return the raw totals — byte-identical to the pre-T45.7 budget check.
  defp rung_iterations(%Data{ladder: %Ladder{iter_base: base}, iterations: n}), do: n - base
  defp rung_iterations(%Data{iterations: n}), do: n

  defp rung_dispatches(%Data{ladder: %Ladder{dispatch_base: base}, dispatches: n}), do: n - base
  defp rung_dispatches(%Data{dispatches: n}), do: n

  defp rung_tokens(%Data{ladder: %Ladder{token_base: base}} = data),
    do: budgeted_tokens(data) - base

  defp rung_tokens(%Data{} = data), do: budgeted_tokens(data)

  defp rung_elapsed_ms(%Data{ladder: %Ladder{clock_base_ms: base}, now_fn: now_fn}),
    do: max(now_fn.() - base, 0)

  defp rung_elapsed_ms(%Data{} = data), do: elapsed_ms(data)

  # =============================================================================
  # T45.7 (ADR-0056 decision 5): the model escalation ladder
  # =============================================================================

  # On a `stuck`/`over_budget` terminal verdict, advance to the next model in the
  # declared ladder (a fresh per-rung window + budget) and signal `{:escalated,
  # data}` for the caller to re-dispatch; `:halt` when no ladder is declared or the
  # ladder is exhausted (the terminal verdict then stands). kazi-core makes NO
  # model choice here — it walks exactly the declared list. `failing` is the T30.3
  # same-failing-predicate-set the rung stalled on, carried for observability.
  @spec maybe_escalate(Data.t(), MapSet.t()) :: {:escalated, Data.t()} | :halt
  defp maybe_escalate(%Data{ladder: ladder} = data, failing) do
    if Ladder.next?(ladder) do
      ladder = Ladder.advance(ladder, failing, ladder_spend(data))
      adapter_opts = Keyword.put(data.adapter_opts, :model, Ladder.current_model(ladder))
      data = %Data{data | ladder: ladder, adapter_opts: adapter_opts}

      Logger.info(fn ->
        "kazi.loop goal=#{data.goal.id} escalating to ladder rung #{ladder.rung} " <>
          "model=#{Ladder.current_model(ladder)} on failing set " <>
          "#{inspect(Enum.sort(MapSet.to_list(failing)))}"
      end)

      {:escalated, data}
    else
      :halt
    end
  end

  # The current spend snapshot the ladder re-baselines each per-rung window to.
  defp ladder_spend(%Data{} = data) do
    %{
      iterations: data.iterations,
      tokens: budgeted_tokens(data),
      dispatches: data.dispatches,
      now_ms: data.now_fn.()
    }
  end

  # The failing predicate-id set of the current vector (the same expression the
  # dispatch path uses) — the over_budget path's "same failing predicate set".
  defp current_failing_set(%Data{vector: vector}), do: MapSet.new(PredicateVector.failing(vector))

  # Pin the ladder's rung-0 model as the dispatch model when a ladder is declared
  # (the declared ladder is authoritative); a no-ladder goal keeps its opts.
  defp pin_ladder_model(adapter_opts, %Ladder{} = ladder),
    do: Keyword.put(adapter_opts, :model, Ladder.current_model(ladder))

  defp pin_ladder_model(adapter_opts, nil), do: adapter_opts

  # T34.4 (ADR-0046 #4): the token total fed to the gate, with cached reads
  # discounted. `tokens_used` is the full rolled-up total (cached reads counted
  # at full weight; surfaced unchanged as `budget_spent.tokens` for back-compat);
  # here we rebate the discounted fraction of the cached reads the usage envelope
  # accumulated, so a cache-hit-heavy run is not falsely flagged `over_budget`.
  # When no cached reads were reported the value equals `tokens_used`, so the gate
  # behaves byte-identically to the pre-T34.4 arithmetic. The GATE decision lives
  # in `Kazi.Loop.Budget.check/2` and is unchanged — only this input is reweighted.
  @spec budgeted_tokens(Data.t()) :: non_neg_integer()
  defp budgeted_tokens(%Data{budget: budget, tokens_used: raw, usage: usage}) do
    cached = Map.get(usage, :cached_input_tokens, 0)
    Budget.budgeted_tokens(raw, cached, budget.cached_read_weight)
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
    data = reeval_terminal_vector(data)
    notify_budget_stop(data)
    terminate_with(:over_budget, data)
  end

  # #790: the budget guard fires at the START of a tick, before observing
  # again — so a dispatch that finishes the remaining work but blows the
  # budget doing it would otherwise leave `data.vector` at its PRE-dispatch
  # reading (stale: reports failure even though the workspace is now green,
  # misleading escalation ladders into re-dispatching frontier models onto
  # already-green work). Re-run the predicates ONE more time here so the
  # terminal vector reflects the workspace as the loop actually leaves it.
  # Mirrors the relevant slice of `observe_tick/1` (fresh vector + prior-score
  # threading + quarantine) without its iteration/history/regression side
  # effects, since this is a terminal re-check, not another tick.
  @spec reeval_terminal_vector(Data.t()) :: Data.t()
  defp reeval_terminal_vector(%Data{} = data) do
    {vector, quarantine, streaks, clean_tree_active?} = observe_with_isolation(data)
    vector = thread_prior_scores(vector, data.vector)

    %Data{
      data
      | prev_vector: data.vector,
        vector: vector,
        quarantine: quarantine,
        quarantine_streaks: streaks,
        clean_tree_active?: clean_tree_active?
    }
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

  # T48.6 (ADR-0058) budget: count this completed :dispatch_agent action toward
  # max_dispatches. Called exactly once per dispatch, from dispatch_agent/2 only
  # — observe_tick/1 never calls this, which is what keeps max_dispatches from
  # tripping on no-op observe ticks.
  @spec accumulate_dispatches(Data.t()) :: Data.t()
  defp accumulate_dispatches(%Data{} = data) do
    %Data{data | dispatches: data.dispatches + 1}
  end

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
  # `Kazi.CLI.Usage` field names. T34.1 folded the harness's `:cost_usd`; T34.2
  # adds the per-field cached/fresh token split the profile mapped onto `:usage`
  # (`%{input_tokens: …, cached_input_tokens: …, …}`). Only the components the
  # harness actually reported are returned — an unreported field stays absent.
  # A result without either contributes nothing.
  @spec usage_components(Kazi.HarnessAdapter.result()) :: map()
  defp usage_components({:ok, %{} = result}) do
    %{}
    |> put_cost_usd(result)
    |> put_token_split(result)
  end

  defp usage_components(_), do: %{}

  defp put_cost_usd(components, %{cost_usd: cost}) when is_number(cost),
    do: Map.put(components, :cost_usd, cost)

  defp put_cost_usd(components, _result), do: components

  defp put_token_split(components, %{usage: %{} = usage}), do: Map.merge(components, usage)
  defp put_token_split(components, _result), do: components

  # T48.5 (ADR-0058 §4): when a `max_tokens` ceiling is set, a dispatch that
  # reports NO usage at all means the ceiling cannot bind — the loop's token
  # total only grows when a harness reports one (`token_estimate/1` above), so
  # an unreported run silently sits at (or near) zero forever and the ceiling
  # never trips. Warn loudly ONCE per run (not once per dispatch — repeated
  # warnings against a harness that reports no usage BY DESIGN, e.g. `claw`,
  # ADR-0022, would just be noise) and stick the run's `usage_fidelity` at
  # `:unreported` so the CLI/read-model can say so. Once flagged, later
  # dispatches (even ones that DO report usage) leave the flag set — the run
  # already proved the ceiling was unenforceable at least once.
  @spec maybe_flag_unreported_usage(Data.t(), Kazi.HarnessAdapter.result()) :: Data.t()
  defp maybe_flag_unreported_usage(%Data{budget: nil} = data, _result), do: data
  defp maybe_flag_unreported_usage(%Data{usage_fidelity: :unreported} = data, _result), do: data
  defp maybe_flag_unreported_usage(%Data{budget: %{max_tokens: nil}} = data, _result), do: data

  defp maybe_flag_unreported_usage(%Data{budget: %{max_tokens: max_tokens}} = data, result) do
    if usage_reported?(result) do
      data
    else
      Logger.warning(fn ->
        "kazi.loop goal=#{goal_id(data.goal)} max_tokens=#{max_tokens} is set but a " <>
          "harness dispatch reported no usage — the token ceiling cannot bind " <>
          "(ADR-0058 #4). Degraded usage fidelity: :unreported."
      end)

      %Data{data | usage_fidelity: :unreported}
    end
  end

  # (issue #769): retain the NAMES of this dispatch's denied tool calls on the run
  # state and warn loudly the first time any are seen. The claude profile parses
  # `:permission_denials` off the result envelope; kazi previously dropped them,
  # which is what made a fully-denied dispatch indistinguishable from "the agent
  # chose to change nothing" — an exit-0 dispatch, no file change, budget spent.
  #
  # NAMES ONLY, deliberately. A denial entry carries `tool_input`, which for a
  # denied `Write` is the ENTIRE file content the agent meant to write: putting it
  # in the bundle would blow the byte budget and risk leaking secrets into a
  # surfaced/logged artifact. "Write was denied" is the whole diagnostic signal;
  # the payload adds risk and nothing else. Deduped so a 15-iteration run does not
  # carry 15 copies of the same denied `Write`.
  @spec maybe_flag_permission_denials(Data.t(), Kazi.HarnessAdapter.result()) :: Data.t()
  defp maybe_flag_permission_denials(%Data{} = data, result) do
    case denied_tool_names(result) do
      [] ->
        data

      names ->
        if data.permission_denials == [] do
          Logger.warning(fn ->
            "kazi.loop goal=#{goal_id(data.goal)} a harness dispatch had tool call(s) DENIED " <>
              "(#{Enum.join(names, ", ")}) — the agent cannot act, so this run will change " <>
              "nothing and grind to :stuck while spending budget (issue #769). The harness " <>
              "still exited 0. Set `[harness] permission_mode` (e.g. \"auto\") in the " <>
              "goal-file, or pass --permission-mode."
          end)
        end

        %Data{data | permission_denials: Enum.uniq(data.permission_denials ++ names)}
    end
  end

  # The denied tool names on a harness result, if the profile reported any.
  @spec denied_tool_names(Kazi.HarnessAdapter.result()) :: [String.t()]
  defp denied_tool_names({:ok, %{} = result}) do
    case Map.get(result, :permission_denials) do
      denials when is_list(denials) ->
        denials
        |> Enum.map(&denial_tool_name/1)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp denied_tool_names(_result), do: []

  defp denial_tool_name(%{tool_name: name}) when is_binary(name), do: name
  defp denial_tool_name(%{"tool_name" => name}) when is_binary(name), do: name
  defp denial_tool_name(_denial), do: nil

  # Whether a harness result carries ANY usage signal the budget/economy code
  # can count: the rolled-up token estimate (`cost.tokens`, T1.4), the per-field
  # cached/fresh split (`usage`, T34.1/T34.2), or a reported per-dispatch
  # `usage_fidelity` of `:full`/`:partial` (T34.2). A profile that reports
  # NOTHING (the `claw` best-effort profile, ADR-0022 — no cost, no tokens, no
  # fidelity) or an `{:error, _}` dispatch is "no usage reported".
  @spec usage_reported?(Kazi.HarnessAdapter.result()) :: boolean()
  defp usage_reported?({:ok, %{} = result}) do
    match?(%{tokens: tokens} when is_integer(tokens), Map.get(result, :cost, %{})) or
      Map.get(result, :usage_fidelity) in [:full, :partial] or
      map_size(Map.get(result, :usage, %{})) > 0
  end

  defp usage_reported?(_result), do: false

  # T48.5: the goal id for the warning, or "unknown" if the loop somehow has no
  # goal bound yet (defensive — `dispatch_agent/2` always runs with one).
  @spec goal_id(Goal.t() | nil) :: String.t()
  defp goal_id(%Goal{id: id}), do: id
  defp goal_id(_goal), do: "unknown"

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
  # T32.4 anti-gaming enforcement: read-only lease + reported guarantees
  # =============================================================================

  # The content-hash snapshot of the read-only-leased paths, taken before a
  # dispatch. Empty (a no-op) when enforcement is off or no paths are leased.
  @spec read_only_snapshot(Data.t()) :: %{optional(String.t()) => term()}
  defp read_only_snapshot(%Data{enforcement: %Enforcement{enabled: true} = enf, workspace: ws}) do
    Enforcement.digest_paths(ws, enf.read_only_paths)
  end

  defp read_only_snapshot(%Data{}), do: %{}

  # Compare the leased paths against the pre-dispatch snapshot and append a flagged
  # gaming event for each one the agent wrote to (ADR-0042 §2). A no-op when
  # enforcement is off / nothing was leased / nothing changed.
  @spec flag_read_only_writes(Data.t(), %{optional(String.t()) => term()}) :: Data.t()
  defp flag_read_only_writes(
         %Data{enforcement: %Enforcement{enabled: true} = enf, workspace: ws} = data,
         before
       ) do
    case Enforcement.detect_writes(ws, enf.read_only_paths, before) do
      [] ->
        data

      events ->
        stamped = Enum.map(events, &Map.put(&1, :iteration, max(data.iterations - 1, 0)))

        Enum.each(stamped, fn event ->
          Logger.warning(fn ->
            "kazi.loop goal=#{data.goal.id} ENFORCEMENT flagged read-only write to " <>
              "#{event.path} (iteration #{event.iteration})"
          end)
        end)

        %Data{data | gaming_events: data.gaming_events ++ stamped}
    end
  end

  defp flag_read_only_writes(%Data{} = data, _before), do: data

  # T32.5 diff-inspection guard (ADR-0042 §5, ADVISORY). After a dispatch, scan the
  # agent's iteration diff for gaming signatures and, on a hit: (1) append each
  # flagged event to `gaming_events` (surfaced in --json, "flagged with evidence"),
  # and (2) record the UPCOMING observation index in `gaming_flagged_iterations` so
  # `code_history/1` discounts that observation's graded scores — a gamed apparent
  # improvement is not credited as progress. It NEVER blocks convergence (the
  # boolean failing-set logic is untouched) or crashes the loop (a diff-source
  # failure degrades to no diff → no events). A no-op when enforcement is off.
  #
  # The upcoming observation is index `data.iterations` (observe_tick already
  # incremented `iterations` to count the observation that SEEDED this dispatch; the
  # observation reflecting this dispatch's work is the next one). The event itself is
  # stamped with the seeding observation index (`data.iterations - 1`), matching the
  # read-only-write convention.
  @spec flag_diff_gaming(Data.t()) :: Data.t()
  defp flag_diff_gaming(%Data{enforcement: %Enforcement{enabled: true} = enf} = data) do
    diff = safe_diff(data)

    case DiffGuard.scan(diff, grader_paths: enf.read_only_paths) do
      [] ->
        data

      events ->
        seeding = max(data.iterations - 1, 0)
        stamped = Enum.map(events, &Map.put(&1, :iteration, seeding))

        Enum.each(stamped, fn event ->
          Logger.warning(fn ->
            "kazi.loop goal=#{data.goal.id} ENFORCEMENT diff-guard flagged " <>
              "#{event.signature} in #{event.file} (iteration #{event.iteration}): #{event.snippet}"
          end)
        end)

        %Data{
          data
          | gaming_events: data.gaming_events ++ stamped,
            gaming_flagged_iterations: MapSet.put(data.gaming_flagged_iterations, data.iterations)
        }
    end
  end

  defp flag_diff_gaming(%Data{} = data), do: data

  # Fetch the agent's iteration diff via the injected `diff_fn`, contained: a raising
  # or crashing diff source yields "" (no diff → no events), so the advisory guard
  # can never break the reconcile tick.
  @spec safe_diff(Data.t()) :: String.t()
  defp safe_diff(%Data{diff_fn: diff_fn, workspace: ws}) when is_function(diff_fn, 1) do
    case diff_fn.(ws) do
      diff when is_binary(diff) -> diff
      _ -> ""
    end
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  defp safe_diff(%Data{}), do: ""

  # The default diff source: the agent's uncommitted iteration changes vs HEAD. New
  # (untracked) files do not appear in `git diff HEAD`; the guard inspects edits to
  # existing files, which is where the skip/special-case/grader signatures land. A
  # non-git or missing workspace yields "" (no diff → no events).
  @spec default_diff_fn(String.t() | nil) :: String.t()
  defp default_diff_fn(workspace) when is_binary(workspace) do
    case System.cmd("git", ["-C", workspace, "diff", "HEAD"], stderr_to_stdout: true) do
      {output, 0} -> output
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp default_diff_fn(_workspace), do: ""

  # The enforcement status surfaced in snapshot/1 + the terminal result: whether
  # enforcement is active, the ACTUAL active guarantees (the configured set with
  # `:clean_tree` dropped if isolation degraded on the last observation), and the
  # flagged gaming events so far. Returns a `nil`-equivalent disabled shape when
  # enforcement is off, so the field is always present and machine-parseable.
  @spec enforcement_status(Data.t()) :: %{
          active: boolean(),
          guarantees: [atom()],
          gaming_events: [map()]
        }
  defp enforcement_status(%Data{enforcement: %Enforcement{enabled: true} = enf} = data) do
    guarantees =
      enf
      |> Enforcement.guarantee_atoms()
      |> drop_clean_tree_if_degraded(data.clean_tree_active?)

    %{active: true, guarantees: guarantees, gaming_events: data.gaming_events}
  end

  defp enforcement_status(%Data{}), do: %{active: false, guarantees: [], gaming_events: []}

  # Honest reporting (ADR-0042 §7): `:clean_tree` only appears among the active
  # guarantees when isolation was actually established on the last observation.
  defp drop_clean_tree_if_degraded(guarantees, true), do: guarantees
  defp drop_clean_tree_if_degraded(guarantees, _false), do: guarantees -- [:clean_tree]

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

  # issue #1020: runs the injected `:integrate` action's execute/2 in a
  # supervised Task bounded by `data.integrate_timeout_ms`, instead of calling
  # it in-process. A real integrator (`gh pr checks --watch`, a wedged git
  # push, ...) can hang indefinitely with no forward progress and no crash —
  # calling it directly from `handle_event/4` would block the gen_statem
  # (and the whole loop) forever, exactly the reported symptom. `Task.yield`
  # bounds the wait; on timeout the task is shut down (`Task.shutdown/2`, not
  # left to run wild) and the loop gets back an ordinary `{:error, ...}`
  # result it already knows how to record and retry from — no crash, no
  # process wedge.
  @spec run_integrate(module(), Action.t(), Action.context(), Data.t()) :: Action.result()
  defp run_integrate(integrate, action, context, %Data{integrate_timeout_ms: timeout_ms}) do
    task = Task.async(fn -> integrate.execute(action, context) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :integrate_timeout}
    end
  end

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
      # Reuse the SAME test `decide/2` uses (`all_satisfied?`) rather than
      # calling `PredicateVector.satisfied?/1` directly, so this can never drift
      # from the actual convergence gate (deep review L10).
      converged?: all_satisfied?(data.vector),
      # T1.2 regression: the green→red flags for this observation, so the runtime
      # projects them into the read-model (making the regression queryable).
      regressions: data.regressions,
      # T3.3d deploy wiring: the release ref of the artifact deployed so far this
      # run (T3.3c), so the runtime projects it into the read-model's
      # `release_ref` column (queryable via Kazi.ReadModel.release_refs/1). nil
      # until a deploy succeeds with a release ref.
      release_ref: data.release_ref,
      # T34.3 (ADR-0046 §2): the per-iteration context + tool counters from the
      # dispatch that fed this observation. `context` is always populated (kazi
      # owns the prompt — all-disabled/zero before the first dispatch); `tools` is
      # empty when the harness exposed no tool-use stream (absent ≠ zero).
      context: data.last_context || Counters.empty_context(),
      tools: data.last_tools,
      # The inner harness's session id from the latest dispatch (nil until one
      # reports it), so the runtime records it on the fleet registry row.
      harness_session_id: data.last_session_id,
      harness_pid: data.last_harness_pid,
      # T48.11 (ADR-0058 §3): the last dispatch's capped hypothesis list — `[]`
      # when the goal never opted in, so this key stays byte-identical to today.
      debrief: data.last_debrief
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
      stop_reason: reason,
      # T34.3 (ADR-0046 §2): carry the last dispatch's context + tool counters so
      # the budget-stop record is attributable too.
      context: data.last_context || Counters.empty_context(),
      tools: data.last_tools,
      harness_session_id: data.last_session_id,
      harness_pid: data.last_harness_pid,
      # T48.11 (ADR-0058 §3): the last dispatch's capped hypothesis list — `[]`
      # when the goal never opted in, so this key stays byte-identical to today.
      debrief: data.last_debrief
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
