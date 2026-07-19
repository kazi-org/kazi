defmodule Kazi.Runtime do
  @moduledoc """
  Assembles the real Slice-0 components into a running convergence loop (T0.7b,
  UC-004) — the wiring the CLI (T0.10) calls to drive a loaded `Kazi.Goal` to
  convergence.

  `Kazi.Loop` depends only on behaviours; it never names a concrete provider,
  harness, or action (see its `start_link/1` opts). This module is where the
  *concrete* Slice-0 implementations are bound to those seams:

    * **predicate → provider dispatch** — each predicate's `kind` is mapped to its
      real provider module (`:tests` → `Kazi.Providers.TestRunner`, `:http_probe`
      → `Kazi.Providers.HttpProbe`), and the loop evaluates a predicate through
      that provider's real `evaluate/2` callback (concept §3, ADR-0002);
    * **harness** — the real `Kazi.Harness.ClaudeAdapter` (drives `claude -p` in
      the workspace, ADR-0001);
    * **integrate / deploy** — the real `Kazi.Actions.Integrate` and
      `Kazi.Actions.Deploy` (T0.10a / T0.10b);
    * **persistence** — each observed iteration is projected into the SQLite
      read-model via `Kazi.ReadModel.record_iteration/1` (T0.9), wired through the
      loop's side-effect-only `:on_iteration` seam.

  Nothing here is a stub: it is the genuine production wiring (zero-stub policy).
  Tests exercise it end-to-end by pointing the *injectable seams the underlying
  modules already expose* at local stubs — the harness binary
  (`:harness_command`), the integrator (`context.integrator`), and the deploy
  command (`context.deploy_cmd`) — never by swapping a fake module in here.

  ## Entry point

      {:ok, goal} = Kazi.Goal.Loader.load("goal.toml")
      {:ok, result} = Kazi.Runtime.run(goal, workspace: "/path/to/target")

  `run/2` starts the loop, blocks until it reaches a terminal state, and returns
  the loop's `t:Kazi.Loop.result/0` (`:converged` | `:stopped` | `:over_budget`,
  the last carrying the exceeded budget dimension as `:reason`, T1.4). The result
  also carries `:release_ref` (T3.3d) — the release ref of the artifact deployed
  during the run (T3.3c tagging), or `nil` if nothing was deployed. Predicate
  configs may name their own provider (a goal authored against a not-yet-shipped
  provider fails loudly here, not silently at dispatch).
  """

  alias Kazi.{
    Enforcement,
    Goal,
    Loop,
    Predicate,
    PredicateResult,
    PredicateVector,
    ReadModel,
    Scope
  }

  alias Kazi.Runtime.GoalDrift

  alias Kazi.Harness.ChildSupervisor
  alias Kazi.ReadModel.{HeartbeatTicker, Iteration, RunRegistry}
  alias Kazi.Runtime.BusMirror
  alias Kazi.Runtime.ParentMonitor
  alias Kazi.Sink.Events, as: EventsSink

  require Logger

  # The concrete provider module for each predicate `kind` the Slice-0 runtime
  # can evaluate. Extending the runtime to a new provider is one entry here,
  # mirroring the loader's `provider` → `kind` table (ADR-0002).
  @provider_modules %{
    tests: Kazi.Providers.TestRunner,
    http_probe: Kazi.Providers.HttpProbe,
    prod_log: Kazi.Providers.ProdLog,
    browser: Kazi.Providers.Browser,
    # T43.7 (UC-055): the `:cli` provider — a golden invocation of a shipped
    # binary. Runs a declared command and gates on the exit code + stdout/stderr
    # matchers, the observable surface `mix test` never exercises.
    cli: Kazi.Providers.Cli,
    # T32.10 (ADR-0043): the live RED/SLO metrics provider (PromQL windowed
    # quantile + burn-rate gate). Degrades to :unknown when no endpoint is set.
    metrics: Kazi.Providers.Metrics,
    # T32.1 (ADR-0040): the generic command-runner — the sanctioned extension
    # point. A new verification kind is CONFIG (a goal-file verdict), not a kazi
    # release.
    custom_script: Kazi.Providers.CustomScript,
    # ADR-0081 (#1521): the render-proof provider — gates on a CONTROLLER-produced
    # capture being a plausible non-blank/non-crash frame, so a UI goal cannot
    # converge on file presence. Consumes `context[:captures]`.
    render_proof: Kazi.Providers.RenderProof,
    # T68.8 (#1522): pinned strong-model screenshot judgment against a hashed
    # rubric + optional sealed reference; itemized pass/fail verdict.
    visual_judge: Kazi.Providers.VisualJudge,
    # T32.3 (ADR-0041): the first-class ratchet mode — signal-vs-baseline within
    # an allowed regression. Coverage/perf/size are configs of this one provider.
    ratchet: Kazi.Providers.Ratchet,
    # T32.7 (ADR-0043): the first-class static-analysis provider — Dialyzer-led,
    # generalized to the polyglot SARIF tools, gated on parsed findings (not the
    # exit code) with a baseline ratchet on NEW findings.
    static: Kazi.Providers.Static,
    # T32.8 (ADR-0043): `:coverage` is a ratchet instance — patch coverage meets a
    # target AND project coverage does not regress (two Kazi.Ratchet comparisons).
    coverage: Kazi.Providers.Coverage,
    # T32.8 (ADR-0043): `:property` runs property-based tests (PropCheck under
    # `mix test`), scoring cases-passed/N with the shrunk counterexample as
    # evidence.
    property: Kazi.Providers.Property,
    # T32.8 (ADR-0043): `:mutation` is the test-quality signal — a 0-1 score gated
    # on a threshold (never 100%), with surviving mutants as evidence.
    mutation: Kazi.Providers.Mutation,
    # T32.8 (ADR-0043): `:cve` is dependency vuln scanning led by govulncheck
    # reachability (fail on a transitively-called vuln, call stack as proof);
    # trivy/grype/npm-audit are manifest-only, ratcheted vs a baseline.
    cve: Kazi.Providers.Cve,
    # issue #1406: `:swift_test` reads a Swift/XCTest suite's verdict from an
    # Xcode `.xcresult` bundle (via `xcresulttool`) — parsed pass/fail/zero-tests
    # counts, never the exit code.
    swift_test: Kazi.Providers.SwiftTest,
    # T44.6 (ADR-0043 shape): `:no_stubs` is a deterministic diff scanner — fail
    # when the diff-vs-base introduces a stub/placeholder/hardcoded-return marker
    # into a NON-TEST file. Productizes the zero-stub policy as a real predicate.
    no_stubs: Kazi.Providers.NoStubs,
    # T44.8 (ADR-0034): `:docs_updated` — the "docs land with code" gate. Fail when
    # the diff-vs-base touches a user-facing surface (CLI/provider/public behaviour/
    # MCP) without a matching docs change or a `[no-docs]` commit-message marker.
    docs_updated: Kazi.Providers.DocsUpdated,
    # issue #860: the scope `deny`-path guard, synthesized by
    # `Kazi.Scope.guard_predicates/1` — independent of the `[enforcement]` profile.
    scope_guard: Kazi.Providers.ScopeGuard,
    # T44.2 (ADR-0055): the `:landed` provider — the deterministic check that
    # converged work has landed to the goal's `[integration] mode` degree.
    # Synthesized by `Kazi.Goal.landed_predicate/1` at load time; evaluated
    # against the LIVE working tree (a visible, non-guard predicate) so a dirty
    # tree keeps the loop running instead of reporting a false `:converged`.
    landed: Kazi.Providers.Landed,
    # T49.3 (ADR-0064): replay a pinned Gherkin Scenario by DELEGATING to a
    # surface provider. Only a `:pinned` classification replays; the pass is the
    # delegate's green replay, never a demonstration claim.
    scenario: Kazi.Providers.Scenario,
    # T44.7 (E29/ADR-0034, UC-058): the internal-leak guard as a predicate — scan
    # the diff's added lines for private IPs / home paths / configurable codenames.
    oss_hygiene: Kazi.Providers.OssHygiene,
    # T45.3 (UC-059): "the phase <phase-ref> has been planned" — a deterministic,
    # read-model-only check (exists + floor-passed + approved). Makes planning a
    # convergeable goal.
    plan_expanded: Kazi.Providers.PlanExpanded,
    # T41.3/T41.4: manifest-coverage — every scanned surface element is referenced
    # by >=1 Scenario across the product's `.feature` specs. The goal-file-runnable
    # form of `Kazi.Reconcile.SpecCoverage`.
    spec_coverage: Kazi.Providers.SpecCoverage,
    # T62.1 (ADR-0071): the runtime `gherkin` provider — a `.feature` entry
    # expands at goal-load into one `:gherkin` sub-predicate per Scenario (per
    # Examples row for an outline). Verdict ingestion from the shared runner's
    # cucumber-json is T62.2; until then it evaluates to honest :unknown.
    gherkin: Kazi.Providers.Gherkin
  }

  # The real Slice-0 behaviour implementations bound to the loop's seams. The
  # harness adapter is no longer hard-coded here: it is resolved per run via
  # `Kazi.Harness.resolve/1` (T8.7, ADR-0016) so a goal/CLI/config can select
  # opencode or any other harness.
  @integrate Kazi.Actions.Integrate
  @deploy Kazi.Actions.Deploy

  # (issue #769) The Claude-only `--permission-mode` default. `"auto"` because a
  # headless dispatch into kazi's ephemeral partition worktree has no human to
  # accept Claude Code's trust dialog, so an unset mode denies EVERY tool call
  # while still exiting 0 — a silent, billable no-op. `"auto"` covers Bash as well
  # as edits, so a goal whose predicates require git (a `landed`/`committed`
  # check) can actually converge; `"acceptEdits"` grants edits but NOT Bash, and
  # such a goal can never pass under it. The blast radius is the throwaway
  # worktree: `apply` refuses a repo's primary worktree root by default.
  @default_permission_mode "auto"

  @typedoc "Result handed back to the caller — the loop's terminal result."
  @type result :: Loop.result()

  @doc """
  Runs `goal` to a terminal state with the real component wiring and returns the
  loop result.

  ## Options

    * `:workspace` — the target workspace path threaded to providers / harness /
      actions (where the agent edits and where code predicates are evaluated). If
      omitted, falls back to `goal.scope.workspace`.
    * `:adapter_opts` — keyword opts forwarded to the harness adapter (e.g.
      `[command: "/path/to/stub"]` in tests, model/flags in production).
    * `:workspace_opts` — keyword opts forwarded verbatim to
      `Kazi.Workspace.prepare/2`, which runs once before each agent dispatch to
      expose the `code-review-graph` MCP in the target's `.mcp.json` and refresh
      its code graph (T4.5, ADR-0010 §3). Tests inject the `:graph_cmd` seam here
      so freshness needs no real binary; empty in production (real binary).
    * `:integrator` — the PR/merge seam forwarded to the integrate action
      (`context.integrator`); defaults to the real `gh`-based integrator.
    * `:deploy_cmd` — the deploy command forwarded to the deploy action
      (`context.deploy_cmd`); defaults to real `gcloud`.
    * `:integrate_params` / `:deploy_params` — extra params merged into the
      integrate / deploy actions (e.g. the Cloud Run `service`/`project`/`region`
      the deploy action requires).

      T3.3d deploy wiring: `:deploy_params` is also how the deepened deploy
      (T3.3a-c) is driven through the runtime — it is forwarded VERBATIM to the
      `Kazi.Actions.Deploy` action, so:

        * multi-environment selection (T3.3a): pass `env:` + an `envs:` map of
          per-environment targets, e.g.
          `deploy_params: %{env: :prod, envs: %{staging: %{...}, prod: %{...}}}`;
          the action selects the env's `service`/`project`/`region`;
        * release tagging (T3.3c) happens automatically on a successful deploy;
          its release ref is surfaced in the run outcome (the result's
          `:release_ref`) and the loop snapshot, and projected to the read-model's
          `release_ref` column (queryable via `Kazi.ReadModel.release_refs/1`).
          Override the tag with `deploy_params: %{release_ref: "v1.2.3"}` (or
          inject a tagger seam with `:tag_cmd` in tests).

      Rollback (T3.3b) is a distinct `:rollback` action the deploy module also
      implements; it is invoked directly (`Kazi.Actions.Deploy.execute(...)`) with
      the same env-aware params rather than as a step of the convergence loop,
      which never rolls back a successful reconcile.
    * `:persist?` — project each iteration into the read-model (default `true`).
      Set `false` to run without touching SQLite. Also gates the fleet **run
      registry** (T46.1, ADR-0057): when persistence is on, `run/2` upserts a
      `runs` row once the loop starts, heartbeats it on every `on_iteration`
      tick (composed onto the same seam as the iteration projection), and
      records the terminal status (`"converged"` / `"stuck"` / `"over_budget"`
      / `"stopped"` / `"error"`) once the loop terminates — this is the ONLY
      place a real `kazi apply` registers itself; `Kazi.ReadModel.RunRegistry`
      has no other writer.
    * `:run_id` — the registry's `run_id` for this process (default a fresh
      `Ecto.UUID`). Passing an existing id lets a restarted process reclaim its
      own registry row (`RunRegistry.start/1` upserts on a repeat `run_id`).
    * `:proposal_ref` — session provenance part 2: when this run was started
      from an approved proposal (`kazi apply <proposal-ref>`), the proposal's
      own `proposal_ref`, copied onto the registry row at registration so a
      run traces back to the proposal (and its `session_name`) even when the
      applying session differs from the planning one. Default `nil`
      (unchanged behavior for a plain goal-file-path run).
    * `:sinks_dir` — the root directory the per-run transcript AND events sinks
      are written under, as `<sinks_dir>/<run_id>/transcript.jsonl` (T46.3,
      ADR-0057 decision 3) and `<sinks_dir>/<run_id>/events.jsonl` (T46.2,
      ADR-0057 decision 3). Defaults to the `:kazi, :sinks_dir` app config,
      falling back to `<user-home>/.kazi/runs`. Only computed/threaded when
      `:persist?` is true; an explicit `adapter_opts: [transcript_sink_path:
      ...]` always overrides the transcript path. Both paths are also recorded
      on the registry row's `transcript_sink_path` / `events_sink_path`
      columns.
    * `:transcript_cap_bytes` — overrides the transcript sink's default size
      cap (`Kazi.Sink.Transcript.default_cap_bytes/0`); forwarded to the
      harness adapter as `adapter_opts[:transcript_cap_bytes]`.
    * `:stream` — a 1-arity side-effect-only observer invoked once per observation
      with the loop's `on_iteration` payload (T15.4, ADR-0023 decision 3). Composed
      OVER the read-model projection on the SAME `on_iteration` seam, so streaming
      and persistence coexist. The CLI uses it to emit one JSONL progress event per
      iteration under `run --json --stream`. A raising observer is contained (it
      never alters convergence). Default `nil` (no streaming).
    * `:goal_ref` — the read-model `goal_ref` (default `goal.id`).
    * `:goal_source` — goal-drift-guard-1415: the goal-file PATH `goal` was
      loaded from (never a proposal ref), when the caller has one. When set,
      `run/2` fingerprints the fully-resolved predicate bar at t0 and, once the
      loop terminates, re-loads THIS SAME path and compares — a mismatch (a
      predicate added/removed/reconfigured on disk since t0) is reported via
      the result's additive `:goal_drifted` / `:goal_drift` fields (see
      `Kazi.Runtime.GoalDrift`, `docs/schemas/run-result.md`). Purely
      observational: the loop already converges against the ORIGINAL in-memory
      `goal` regardless of what happens to the file on disk, whether or not
      this option is set. Default `nil` (no drift report; byte-identical to
      before this option existed).
    * `:await_timeout` — how long `run/2` blocks for termination (default
      `:infinity`).
    * `:providers` — override the predicate-kind → provider-module map (advanced;
      defaults to the built-in Slice-0 map).
    * `:enforcement` — a `Kazi.Enforcement` profile to apply (T32.4, ADR-0042),
      overriding the goal's authored/derived profile. Omitted, the policy is
      resolved from the goal: default-on for creation-mode goals, opt-in for repair.
      Its declared ratchet guards are synthesized into the goal's guards before the
      loop observes; the profile is threaded to `Kazi.Loop` to compose clean-tree
      isolation, read-only-write flagging, and the skip→fail mapping onto the tick.
    * `:standing` — run as a standing (continuous/maintenance) reconciler (T3.4a,
      UC-016): the loop does not terminate at convergence but keeps re-observing
      on the bounded interval to hold the goal's predicates true. Forwarded to
      `Kazi.Loop.start_link/1`. T3.4d: when omitted it DEFAULTS to the goal's own
      declared `standing` field (so a goal-file `standing = true` runs standing
      without a flag); an explicit `:standing` here (the CLI `--standing` flag)
      OVERRIDES the goal-file. Default (neither set) `false` (converge-and-stop).
    * `:debrief` — opt into post-dispatch debrief capture (T48.11, ADR-0058 §3).
      Forwarded to `Kazi.Loop.start_link/1`. When omitted it DEFAULTS to the
      goal's own declared `debrief` field (`[economy] debrief = true`); an
      explicit `:debrief` here (the CLI `--debrief` flag) OVERRIDES the
      goal-file. Default (neither set) `false` (byte-identical to today).
    * any other option (`:live_kinds`, `:reobserve_interval_ms`, `:name`) is
      forwarded verbatim to `Kazi.Loop.start_link/1`.

  Returns `{:ok, result}` once the loop terminates, or `{:error, reason}` if the
  loop could not be started, a predicate names an unknown provider, or the goal is
  vacuous (`{:error, :vacuous_goal}` — see the t0 guard below).

  ## Vacuous-goal guard (T2.3, UC-010, Risk R3)

  Before entering the convergence loop, `run/2` observes the goal's FULL predicate
  vector ONCE at t0 — every predicate evaluated through its real provider, the
  same dispatch the loop uses. If the whole vector is already satisfied at t0
  (every predicate passes before kazi does anything), the goal is **vacuous /
  underspecified**: a creation or repair goal must have at least one predicate
  failing at t0, otherwise "converged" would mean kazi built and verified nothing
  (concept §"creation mode", R3). Such a goal is REJECTED with
  `{:error, :vacuous_goal}`; the loop never starts and nothing is persisted as
  converged. A goal with ≥1 failing predicate at t0 proceeds to the loop normally.
  """
  @spec run(Goal.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(%Goal{} = goal, opts \\ []) do
    workspace = Keyword.get(opts, :workspace) || goal.scope.workspace
    await_timeout = Keyword.get(opts, :await_timeout, :infinity)

    # T32.4 anti-gaming enforcement (ADR-0042): resolve the profile (default-on for
    # creation mode, opt-in for repair — `Kazi.Enforcement.resolve/1`) and SYNTHESIZE
    # its declared ratchet guards (test-count / coverage, §4) into the goal's guards
    # BEFORE the loop observes, so they gate convergence exactly like authored
    # guards. An `:enforcement` opt overrides the goal's authored/derived profile.
    enforcement = Keyword.get(opts, :enforcement) || Enforcement.resolve(goal)

    # issue #860: SYNTHESIZE the scope's `deny`-path guard the same way — it is a
    # SCOPE contract, not an anti-gaming one, so it applies regardless of whether
    # `[enforcement]` is active.
    goal = %Goal{
      goal
      | guards:
          goal.guards ++
            Enforcement.guard_predicates(enforcement) ++ Scope.guard_predicates(goal.scope)
    }

    # goal-drift-guard-1415: fingerprint the FULLY resolved predicate bar
    # (authored predicates + the synthesized guards above) the instant this run
    # commits to it — the t0 snapshot `detect_goal_drift/3` compares the on-disk
    # goal-file against once the loop terminates. `goal` itself never changes
    # for the rest of this run (the loop reads this same struct throughout), so
    # the ORIGINAL bar governs convergence regardless of what happens to the
    # file on disk — this snapshot only powers the observational report.
    t0_snapshot = GoalDrift.snapshot(goal)

    # ADR-0080 (#1520): arm the seal at the SAME t0 instant — content-hash the
    # goal-file (`:goal_source`) + every declared sealed input against the
    # workspace. The loop re-verifies this manifest before every observe pass and
    # terminates `:tampered` on the first mismatch. Empty (nothing sealed) when the
    # goal declared no `[seal]` block AND has no on-disk source, so a byte-identical
    # no-op for an in-memory goal.
    seal_manifest = Kazi.Seal.arm(goal.seal, Keyword.get(opts, :goal_source), workspace)

    with {:ok, {adapter_module, harness_opts}} <- resolve_harness(goal, opts),
         {:ok, providers} <- resolve_providers(goal, opts),
         :ok <- guard_not_vacuous(goal, providers, workspace),
         :ok <- guard_no_live_duplicate(goal, opts),
         :ok <- guard_no_workspace_collision(goal, opts, workspace) do
      # T46.1 (ADR-0057): the fleet run registry's identity for this process —
      # generated fresh unless the caller reclaims a prior id (a restarted
      # process resuming its own registry row).
      run_id = Keyword.get(opts, :run_id, Ecto.UUID.generate())
      persist? = Keyword.get(opts, :persist?, true)
      goal_ref = Keyword.get(opts, :goal_ref, goal.id)

      # T46.3 (ADR-0057 decision 3): the run's transcript sink path — nil when
      # persistence is off, matching the run registry's own persist? gate (a
      # non-persisted run touches no fleet-observability surface at all).
      transcript_sink_path = maybe_transcript_sink_path(persist?, run_id, opts)
      # T46.2 (ADR-0057 decision 3): the run's events sink path — same gate.
      events_sink_path = maybe_events_sink_path(persist?, run_id, opts)

      # Issue #857: warn loudly (stderr + this run's own events sink) if a
      # PRIOR run of the SAME goal_ref recorded a harness subprocess pid that
      # is still alive — a probable orphan (its controller crashed without
      # reaping it, #856) racing this fresh run. Observational only: never
      # blocks or alters this run's own start.
      warn_on_orphans(persist?, run_id, goal_ref, events_sink_path)

      loop_opts =
        opts
        |> Keyword.drop([
          :workspace,
          :await_timeout,
          :integrator,
          :deploy_cmd,
          :integrate_params,
          :deploy_params,
          :persist?,
          :goal_ref,
          :run_id,
          # Session provenance part 2: consumed by register_run/10 above, not
          # a Loop opt.
          :proposal_ref,
          :providers,
          :adapter_opts,
          :extra_action_context,
          # T46.3: consumed above (maybe_transcript_sink_path/3) / below
          # (build_adapter_opts/4), not a Loop opt.
          :sinks_dir,
          :transcript_cap_bytes,
          # Session identity: consumed by register_run/9 above, not a Loop opt.
          :session_name,
          # Consumed by guard_no_live_duplicate/2 above, not a Loop opt.
          :allow_duplicate_run,
          # Consumed by guard_no_workspace_collision/3 above, not a Loop opt.
          :allow_workspace_collision,
          # T15.4 (ADR-0023 decision 3): the streaming observer is consumed by
          # build_on_iteration/2 (composed over the persistence projection), not
          # a Loop opt.
          :stream,
          # T8.7 harness selection: consumed by resolve_harness/2 below, not a Loop opt.
          :harness,
          :model,
          # T36.6 harness selection: consumed by build_adapter_opts/3 below (folded
          # into adapter_opts as the claude profile's `--effort` lever), not a Loop opt.
          :effort,
          # (issue #769) harness selection: consumed by build_adapter_opts/3 below
          # (folded into adapter_opts as the claude profile's `--permission-mode`/
          # `--allowed-tools` levers), not a Loop opt.
          :permission_mode,
          :allowed_tools,
          # T3.4d standing wiring: dropped here and re-set in the merge below so
          # the loop's standing mode defaults to the goal-file's declared
          # `standing`, overridable by an explicit `:standing` opt (CLI flag).
          :standing,
          # T48.11 (ADR-0058 §3): dropped here and re-set in the merge below so
          # the loop's debrief mode defaults to the goal-file's declared
          # `debrief`, overridable by an explicit `:debrief` opt (CLI flag).
          :debrief,
          # T32.4: resolved above and re-set in the merge below as the loop's
          # `:enforcement` profile.
          :enforcement,
          # goal-drift-guard-1415: consumed after the loop terminates
          # (detect_goal_drift/2 below), never a Loop opt.
          :goal_source,
          # ADR-0081 (#1521): the injectable capture command runner is consumed by
          # build_capture_fn/4 below, not a Loop opt.
          :capture_runner
        ])
        |> Keyword.merge(
          goal: goal,
          providers: providers,
          # T8.7 (ADR-0016): the harness adapter is RESOLVED (CLI `--harness`/`--model`
          # > goal-file `[harness]` > config > default `:claude`), not hard-coded. The
          # resolved `harness_opts` (the profile, model) are merged INTO adapter_opts so
          # the prompt-construction opts (`:retriever` etc.) survive alongside them.
          harness: adapter_module,
          integrate: @integrate,
          deploy: @deploy,
          workspace: workspace,
          adapter_opts: build_adapter_opts(goal, opts, harness_opts, transcript_sink_path),
          on_iteration: build_on_iteration(goal, opts, run_id, persist?, events_sink_path),
          integrate_params: Keyword.get(opts, :integrate_params, %{}),
          deploy_params: Keyword.get(opts, :deploy_params, %{}),
          extra_action_context: build_action_context(opts, run_id, goal_ref),
          # T3.4d standing wiring: the CLI `--standing` flag (an explicit
          # `:standing` opt) wins; otherwise fall back to the goal-file's own
          # declared `standing` field. So a goal authored standing runs standing
          # with no flag, and the flag can still force it on for any goal.
          standing: Keyword.get(opts, :standing, goal.standing),
          # T48.11 (ADR-0058 §3): the CLI `--debrief` flag (an explicit
          # `:debrief` opt) wins; otherwise fall back to the goal-file's own
          # declared `debrief` field (`[economy] debrief = true`).
          debrief: Keyword.get(opts, :debrief, goal.debrief),
          # T32.4 anti-gaming enforcement (ADR-0042): thread the resolved profile so
          # the loop composes clean-tree isolation + read-only flagging + the
          # skip→fail mapping onto the reconcile tick.
          enforcement: enforcement,
          # T53.2 (#1022): every REAL `kazi apply` targets an actual checkout
          # that CAN vanish mid-run (a deleted worktree, a wiped tmp dir) — so
          # the runtime always turns on the loop's workspace-liveness precheck,
          # unlike the loop's own default (off, for fixture-path test loops).
          check_workspace_liveness: true,
          # ADR-0080 (#1520): the t0 seal manifest the loop re-verifies each observe.
          seal_manifest: seal_manifest,
          # ADR-0081 (#1521): the controller-side capture executor the loop runs at
          # the start of every observe pass — executes each `[[capture]]` recipe
          # into the run-keyed evidence store and returns the `%{name => result}`
          # map the loop threads into `context[:captures]`. A no-op closure when the
          # goal declares no captures (byte-identical to before).
          capture_fn: build_capture_fn(goal, opts, run_id, workspace)
        )

      # Issue #1013 (T53.4): register the run BEFORE starting the loop, not
      # after. `:gen_statem.start_link/3` returns once `init/1` returns, but
      # `init/1` schedules the FIRST dispatch as an internal `:next_event` —
      # processed by the newly-started loop process concurrently with
      # whatever the caller (this function) does next. Registering afterward
      # raced that first dispatch: on a slow-registration / fast-stub CI run,
      # `on_iteration`'s `record_harness_session/2` could fire and read a
      # `runs` row that did not exist yet, silently dropping the harness
      # session id for the rest of the run (see the instrumented drop point
      # in `Kazi.ReadModel.RunRegistry.record_harness_session/2`). Registering
      # first closes the race unconditionally: the row exists before the loop
      # process can possibly observe anything.
      register_run(
        persist?,
        run_id,
        workspace,
        goal_ref,
        harness_opts,
        transcript_sink_path,
        events_sink_path,
        goal,
        Keyword.get(opts, :session_name),
        Keyword.get(opts, :proposal_ref)
      )

      # T51.5 (ADR-0067 point 1): mirror the run START onto the bus, best-effort.
      # Fire-and-forget by construction -- never blocks or alters the run.
      BusMirror.started(goal_ref, run_id, Keyword.get(opts, :session_name))

      with {:ok, loop} <- Loop.start_link(loop_opts) do
        # T31: start the heartbeat ticker (a supervised periodic timer that advances
        # the heartbeat_at timestamp every ~30 seconds, independent of loop iterations).
        # This keeps healthy long-running dispatches from appearing stale in the starmap.
        _ticker = start_heartbeat_ticker(persist?, run_id)

        # Issue #857: install OS-termination-signal handlers (SIGTERM/SIGINT) so an
        # externally-killed run still records its termination in the registry before
        # the VM halts, instead of leaving a stale `running` row. No-op when
        # persistence is off (nothing to record). The handles are removed by
        # `finalize/4` on the normal terminal path.
        signal_trap = Kazi.Runtime.Finalizer.install_signal_trap(run_id, persist?)

        # Issue #1073 (regression of #857): the SIGTERM trap above and the
        # ChildSupervisor watchdog both watch the BEAM, so neither reaps a
        # dispatch tree when the burrito LAUNCHER is killed (closing a terminal).
        # ParentMonitor watches the launcher itself and halts on its death,
        # letting the existing watchdog reap `claude`. Gated to the real
        # standalone binary so a test loop never arms a self-halt (R-E54-3).
        parent_monitor = start_parent_monitor(persist?, run_id)

        result = Loop.await(loop, await_timeout)
        Loop.stop(loop)

        # T51.5 (ADR-0067 point 1): mirror the TERMINAL verdict onto the bus,
        # best-effort. Bounded-synchronous so the verdict lands before a one-shot
        # `kazi apply` process exits; swallows a downed daemon.
        BusMirror.terminal(goal_ref, run_id, Keyword.get(opts, :session_name), result)

        Kazi.Runtime.Finalizer.finalize(result, run_id, persist?, signal_trap)
        stop_parent_monitor(parent_monitor)
        finish_run(persist?, run_id, result)
        harvest_memory(persist?, run_id, goal_ref, result)

        result
        |> normalize_await()
        |> put_goal_drift(t0_snapshot, Keyword.get(opts, :goal_source))
      else
        {:error, reason} = error ->
          # Registration now happens before `Loop.start_link/1` (see the
          # comment above), so a failed start must still finish the row it
          # already created — otherwise it would be orphaned at "running"
          # forever, the exact failure mode T46.1's own registration-ordering
          # comment (now moved) warned against.
          finish_run(persist?, run_id, {:error, reason})
          error
      end
    end
  end

  @typedoc "The observe-only result of `check/2`: a status plus the observed vector."
  @type check_result :: %{status: :pass | :fail, vector: PredicateVector.t()}

  @doc """
  Observes a goal's full predicate vector EXACTLY ONCE, through the same real
  provider dispatch `run/2` uses at t0 — and returns a terminal verdict without
  ever starting the convergence loop (issue #805). No harness is dispatched, and
  no integrate/deploy action runs; this is the observe-only surface for merge
  gates (ADR-0026 L1) and release qualification, which need "does the vector
  hold right now", not a reconcile.

  Unlike `run/2`, an all-pass vector is a valid, intended outcome here (`:pass`)
  rather than the vacuous-goal rejection — confirming an already-satisfied vector
  IS the point of a check, not a misconfigured goal.

  Returns `{:ok, %{status: :pass | :fail, vector: PredicateVector.t()}}`, or
  `{:error, reason}` if the goal names a predicate kind with no registered
  provider (the same resolution error `run/2` returns).

  ## Options

  Accepts `:workspace`, `:providers`, and `:enforcement` — the same meaning as in
  `run/2`. Every other `run/2` option (harness, budget, persistence, streaming,
  deploy/integrate params, ...) is irrelevant here, since nothing is dispatched.
  """
  @spec check(Goal.t(), keyword()) :: {:ok, check_result()} | {:error, term()}
  def check(%Goal{} = goal, opts \\ []) do
    workspace = Keyword.get(opts, :workspace) || goal.scope.workspace

    # T32.4 (ADR-0042): fold the enforcement profile's guards in, same as run/2, so
    # a check reports the SAME vector a real run would gate convergence on.
    enforcement = Keyword.get(opts, :enforcement) || Enforcement.resolve(goal)

    goal = %Goal{
      goal
      | guards:
          goal.guards ++
            Enforcement.guard_predicates(enforcement) ++ Scope.guard_predicates(goal.scope)
    }

    with {:ok, providers} <- resolve_providers(goal, opts) do
      vector = observe_t0(goal, providers, workspace)
      status = if PredicateVector.satisfied?(vector), do: :pass, else: :fail
      {:ok, %{status: status, vector: vector}}
    end
  end

  @doc """
  The predicate-kind → concrete-provider map the runtime dispatches on. Exposed
  for tests / introspection; mirrors the loader's provider table (ADR-0002).
  Also used by `Kazi.Goal.Loader` to force-load a predicate's provider module
  before validating its config keys (M3 atom-safety, `String.to_existing_atom/1`):
  a provider referenced only as a module-name value here is never CODE-loaded by
  that reference alone, so a legitimate key atom declared solely inside that
  module's function bodies (e.g. `:query_url` in `Kazi.Providers.Metrics`) is
  never interned until the module is actually invoked — which never happens
  during goal *loading*, only during evaluation.
  """
  @spec provider_modules() :: %{optional(Predicate.provider_kind()) => module()}
  def provider_modules, do: @provider_modules

  # =============================================================================
  # Provider dispatch
  # =============================================================================

  # Build the provider map the loop needs, keyed by every predicate kind the goal
  # actually carries. A predicate naming a kind with no real provider is an
  # assembly error surfaced here (fail loud), not a silent no_provider at
  # dispatch time.
  defp resolve_providers(%Goal{} = goal, opts) do
    table = Keyword.get(opts, :providers, @provider_modules)

    kinds =
      goal
      |> Goal.all_predicates()
      |> Enum.map(& &1.kind)
      |> Enum.uniq()

    case Enum.reject(kinds, &Map.has_key?(table, &1)) do
      [] -> {:ok, Map.take(table, kinds)}
      unknown -> {:error, {:unknown_provider_kinds, unknown}}
    end
  end

  # =============================================================================
  # Vacuous-goal guard (T2.3, UC-010, Risk R3)
  # =============================================================================

  # Observe the goal's full predicate vector ONCE at t0 — every predicate through
  # its real provider, the same dispatch the loop performs each iteration — and
  # reject the goal as vacuous if the WHOLE vector is already satisfied before
  # kazi does anything. A creation/repair goal must have at least one predicate
  # failing at t0; an all-pass-at-t0 goal is underspecified, and letting it
  # "converge" would mean kazi built and verified nothing (R3). On rejection the
  # loop never starts, so nothing is persisted as converged.
  @spec guard_not_vacuous(Goal.t(), %{optional(Predicate.provider_kind()) => module()}, term()) ::
          :ok | {:error, :vacuous_goal}
  defp guard_not_vacuous(%Goal{} = goal, providers, workspace) do
    if goal |> observe_t0(providers, workspace) |> PredicateVector.satisfied?() do
      {:error, :vacuous_goal}
    else
      :ok
    end
  end

  # Refuse to START a run when the registry already holds a LIVE run for the
  # same goal_ref: status "running" with a FRESH heartbeat (within the same
  # staleness window `list_stale`/the dashboard use). A second concurrent apply
  # of one goal burns a second full budget and races the first's edits -- a
  # live incident had a fresh process pick up a goal another process had been
  # converging for 1.5 hours. Zombie rows never block: a dead run stops
  # heartbeating (the wall-clock ticker only beats while its process lives), so
  # it goes stale within ~90s and this guard ignores it -- no os_pid check
  # needed, and pre-os_pid rows age out the same way. Deliberate re-runs pass
  # `:allow_duplicate_run` (CLI: --allow-duplicate-run). Best-effort fail-open
  # like every registry touch: no read-model, no guard.
  defp guard_no_live_duplicate(%Goal{} = goal, opts) do
    if Keyword.get(opts, :allow_duplicate_run) == true or
         Keyword.get(opts, :persist?, true) == false do
      :ok
    else
      goal_ref = Keyword.get(opts, :goal_ref, to_string(goal.id))
      run_id = Keyword.get(opts, :run_id) || ""

      goal_ref
      |> RunRegistry.list_by_goal_ref(run_id)
      |> Enum.find(fn run -> run.status == "running" and not RunRegistry.stale?(run) end)
      |> case do
        nil -> :ok
        %ReadModel.Run{} = live -> {:error, {:duplicate_run, duplicate_info(live)}}
      end
    end
  rescue
    error ->
      Logger.warning(fn ->
        "kazi.runtime duplicate-run guard raised (failing open): #{Exception.message(error)}"
      end)

      :ok
  end

  # Refuse to START a run when the resolved workspace is already held by a LIVE
  # run for a DIFFERENT goal (T59.7, #937 Gap G). `guard_no_live_duplicate` only
  # notices a second apply of the SAME goal_ref; it does not catch N DIFFERENT
  # goals dispatched against one shared --workspace, which cross-contaminate each
  # other's commits (the cross-goal commit-bleed incidents in #937). This is the
  # guard for callers who still pass an explicit shared --workspace (the common
  # case is already obviated by the default per-run task worktree, ADR-0065).
  #
  # It reuses the SAME liveness classification the duplicate-run guard trusts
  # (`RunRegistry.list_live/0`: status "running" AND a fresh heartbeat), so a
  # stale/dead holder never blocks -- its heartbeat ages out within ~90s. Same
  # goal_ref is skipped so that case falls through to the (unchanged) duplicate
  # guard. Deliberate co-tenancy passes `:allow_workspace_collision` (CLI:
  # --allow-workspace-collision). Best-effort fail-open like every registry touch.
  defp guard_no_workspace_collision(%Goal{} = goal, opts, workspace) do
    if Keyword.get(opts, :allow_workspace_collision) == true or
         Keyword.get(opts, :persist?, true) == false or is_nil(workspace) do
      :ok
    else
      goal_ref = Keyword.get(opts, :goal_ref, to_string(goal.id))
      run_id = Keyword.get(opts, :run_id) || ""
      resolved = Path.expand(to_string(workspace))

      RunRegistry.list_live()
      |> Enum.find(fn run ->
        run.run_id != run_id and run.goal_ref != goal_ref and
          run.workspace not in [nil, ""] and Path.expand(run.workspace) == resolved
      end)
      |> case do
        nil -> :ok
        %ReadModel.Run{} = live -> {:error, {:workspace_collision, duplicate_info(live)}}
      end
    end
  rescue
    error ->
      Logger.warning(fn ->
        "kazi.runtime workspace-collision guard raised (failing open): " <>
          Exception.message(error)
      end)

      :ok
  end

  # The refusal payload: enough for the caller to find and inspect the live
  # run (or decide to override) without another registry query.
  defp duplicate_info(%ReadModel.Run{} = run) do
    %{
      run_id: run.run_id,
      goal_ref: run.goal_ref,
      workspace: run.workspace,
      session_name: run.session_name,
      heartbeat_at: run.heartbeat_at && DateTime.to_iso8601(run.heartbeat_at)
    }
  end

  # The t0 observation: evaluate every predicate the goal carries (predicates ++
  # guards) through its registered provider, building the same PredicateVector the
  # loop builds each iteration. A predicate whose kind has no provider can't be
  # asserted satisfied, so it is recorded :unknown (never :pass) — a goal can only
  # be vacuous if every predicate genuinely passes against the real world.
  @spec observe_t0(Goal.t(), %{optional(Predicate.provider_kind()) => module()}, term()) ::
          PredicateVector.t()
  defp observe_t0(%Goal{} = goal, providers, workspace) do
    context = %{
      goal: goal,
      scope: goal.scope,
      workspace: workspace,
      landed?: false,
      deployed?: false,
      iteration: 0
    }

    goal
    |> Goal.all_predicates()
    |> Enum.map(fn %Predicate{id: id, kind: kind} = predicate ->
      result =
        case Map.get(providers, kind) do
          nil -> PredicateResult.unknown()
          provider -> provider.evaluate(predicate, context)
        end

      {id, result}
    end)
    |> PredicateVector.new()
  end

  # =============================================================================
  # Harness / action context threading
  # =============================================================================

  # The harness adapter reads its command from adapter_opts (the
  # ClaudeAdapter :command seam); tests inject a stub binary the same way prod
  # passes model/flags. Anything the caller passes in :adapter_opts wins.
  #
  # T4.9c (ADR-0012): per-goal retrieval opt-in. Retrieval is OFF by default — a
  # goal that does not DECLARE a retriever (in `metadata[:retriever]`) threads NO
  # `:retriever` into adapter_opts, so `build_prompt/3` resolves the no-op default
  # and the prompt/loop are byte-identical to the pre-retrieval path (ADR-0012's
  # central constraint). A goal that declares one wires it into the dispatch path.
  # The caller's explicit `:adapter_opts` still wins (it is merged last), so a
  # test/operator can override or disable the goal-declared retriever.
  defp build_adapter_opts(%Goal{} = goal, opts, harness_opts, transcript_sink_path) do
    caller_opts = Keyword.get(opts, :adapter_opts, [])

    base =
      case goal_retriever(goal) do
        nil -> caller_opts
        retriever -> Keyword.merge([retriever: retriever], caller_opts)
      end

    # T8.7: fold the resolved harness opts (the profile, and the resolved model)
    # over the prompt-construction opts, so `:retriever`/`:context_pack` survive
    # ALONGSIDE the harness selection. A goal-file `[harness] command` override
    # (T8.6) is applied only when nothing already set `:command` (caller/test stub
    # wins), keeping it the lowest-precedence command source.
    base
    |> Keyword.merge(harness_opts)
    |> maybe_put_goal_command(goal)
    |> maybe_put_effort(goal, opts)
    |> maybe_put_permission_mode(goal, opts)
    |> maybe_put_allowed_tools(goal, opts)
    |> maybe_put_transcript_sink(transcript_sink_path, opts)
  end

  # T46.3 (ADR-0057 decision 3): thread the computed transcript sink path (nil
  # when persistence is off) into adapter_opts so `Kazi.Harness.CliAdapter` tees
  # the harness stream there. `put_new` so an explicit `adapter_opts:
  # [transcript_sink_path: ...]` from the caller (a test pointing at a fixture
  # path) always wins. `:transcript_cap_bytes` is forwarded verbatim when given.
  defp maybe_put_transcript_sink(adapter_opts, transcript_sink_path, opts) do
    adapter_opts
    |> Keyword.put_new(:transcript_sink_path, transcript_sink_path)
    |> maybe_put_transcript_cap(Keyword.get(opts, :transcript_cap_bytes))
  end

  defp maybe_put_transcript_cap(adapter_opts, nil), do: adapter_opts

  defp maybe_put_transcript_cap(adapter_opts, cap_bytes),
    do: Keyword.put_new(adapter_opts, :transcript_cap_bytes, cap_bytes)

  # T36.6 (ADR-0047): the Claude-only reasoning-effort lever. Fold `:effort` into
  # adapter_opts so the claude profile renders `--effort <level>`. Precedence is the
  # CLI `--effort` opt > the goal-file `[harness] effort`; absent both, NOTHING is
  # added so argv is byte-for-byte unchanged. Set AFTER the harness_opts merge so it
  # is not dropped; it survives `Kazi.Harness.build_adapter_opts`'s `Keyword.take`
  # because the claude profile advertises `:effort` in supported_opts. A non-Claude
  # harness drops it at that take (it is not in that profile's supported_opts).
  defp maybe_put_effort(adapter_opts, %Goal{} = goal, opts) do
    case Keyword.get(opts, :effort) || goal_harness_effort(goal) do
      effort when is_binary(effort) and effort != "" -> Keyword.put(adapter_opts, :effort, effort)
      _ -> adapter_opts
    end
  end

  defp goal_harness_effort(%Goal{harness: harness}) when is_map(harness),
    do: Map.get(harness, :effort)

  defp goal_harness_effort(%Goal{}), do: nil

  # (issue #769): the Claude-only `--permission-mode` lever, folded exactly like
  # `:effort` above (T36.6) — CLI `--permission-mode` opt > the goal-file
  # `[harness] permission_mode` > `@default_permission_mode`. It survives
  # `Kazi.Harness.build_adapter_opts`'s `Keyword.take` because the claude profile
  # advertises `:permission_mode` in supported_opts; a non-Claude harness drops it
  # at that take, so defaulting here cannot leak `--permission-mode` to opencode.
  #
  # Why this DEFAULTS rather than omitting: a headless `claude -p` against a
  # workspace that has not been through Claude Code's interactive trust dialog has
  # EVERY tool call denied — and the CLI still exits 0 with `is_error: false`, so
  # kazi saw a clean dispatch, observed no file changes, re-dispatched, and burned
  # the budget to `stuck` with the cause nowhere in its output. Omitting the flag
  # kept argv "byte-for-byte unchanged" at the cost of making the DEFAULT path the
  # broken one. kazi dispatches into an EPHEMERAL partition worktree whose path is
  # new every run, so the trust dialog can never be pre-accepted for it.
  defp maybe_put_permission_mode(adapter_opts, %Goal{} = goal, opts) do
    case Keyword.get(opts, :permission_mode) || goal_harness_permission_mode(goal) do
      mode when is_binary(mode) and mode != "" ->
        Keyword.put(adapter_opts, :permission_mode, mode)

      _ ->
        Keyword.put(adapter_opts, :permission_mode, @default_permission_mode)
    end
  end

  defp goal_harness_permission_mode(%Goal{harness: harness}) when is_map(harness),
    do: Map.get(harness, :permission_mode)

  defp goal_harness_permission_mode(%Goal{}), do: nil

  # (issue #769): the Claude-only `--allowed-tools` lever, parsed/folded exactly
  # like `:effort` above (T36.6) — CLI `--allowed-tools` opt > the goal-file
  # `[harness] allowed_tools`; absent both, nothing is added so argv is
  # byte-for-byte unchanged. The CLI flag is a comma/space-separated string; the
  # goal-file field is a TOML array; the claude profile's `normalize_tools/1`
  # accepts either shape.
  defp maybe_put_allowed_tools(adapter_opts, %Goal{} = goal, opts) do
    case Keyword.get(opts, :allowed_tools) || goal_harness_allowed_tools(goal) do
      tools when is_binary(tools) and tools != "" ->
        Keyword.put(adapter_opts, :allowed_tools, tools)

      tools when is_list(tools) and tools != [] ->
        Keyword.put(adapter_opts, :allowed_tools, tools)

      _ ->
        # T44.5 (ADR-0055): NOTHING explicit was set. If the goal declares a
        # landing mode, the agent must be allowed the git operations that mode
        # needs — otherwise the run converges its code predicates and then cannot
        # land, which is the #769 failure shape all over again (the harness is
        # refused, exits 0, and the goal reports a stall nobody can read).
        #
        # Only when an allow-list would otherwise be ABSENT: an explicit list is
        # the author's decision and is never widened behind their back (T44.5's
        # lint warns instead, so they hear about it rather than having it
        # silently overridden).
        maybe_inject_landing_tools(adapter_opts, goal, opts)
    end
  end

  # T44.5: the git/gh operations each landing mode actually performs. Derived
  # from what the mode DOES, not a blanket grant: `:commit` never pushes, so it
  # is not given push; only pr/merge touch `gh`.
  @landing_tools %{
    commit: ["Bash(git add:*)", "Bash(git commit:*)"],
    branch: ["Bash(git add:*)", "Bash(git commit:*)", "Bash(git push:*)"],
    pr: ["Bash(git add:*)", "Bash(git commit:*)", "Bash(git push:*)", "Bash(gh pr:*)"],
    merge: ["Bash(git add:*)", "Bash(git commit:*)", "Bash(git push:*)", "Bash(gh pr:*)"]
  }

  @doc false
  def landing_tools(mode), do: Map.get(@landing_tools, mode, [])

  # `mode: :none` injects NOTHING — a converge-and-stop goal is byte-identical to
  # before this change (pinned by a regression test). Non-claude harnesses are
  # untouched too: `allowed_tools` is Claude-only, and `build_adapter_opts`'s
  # Keyword.take would drop it anyway, but not injecting keeps their argv exactly
  # as it was.
  #
  # The harness is read off the RESOLVED profile already merged into
  # `adapter_opts` (`harness_id_string/1`) rather than re-deriving it from
  # flag+goal — that is the same profile the adapter actually dispatches through,
  # so this can never disagree with what really ran.
  defp maybe_inject_landing_tools(adapter_opts, %Goal{} = goal, _opts) do
    with "claude" <- harness_id_string(adapter_opts),
         mode when mode != :none <- goal_integration_mode(goal),
         [_ | _] = tools <- landing_tools(mode) do
      Keyword.put(adapter_opts, :allowed_tools, tools)
    else
      _ -> adapter_opts
    end
  end

  defp goal_integration_mode(%Goal{integration: %{mode: mode}}) when is_atom(mode), do: mode
  defp goal_integration_mode(%Goal{}), do: :none

  defp goal_harness_allowed_tools(%Goal{harness: harness}) when is_map(harness),
    do: Map.get(harness, :allowed_tools)

  defp goal_harness_allowed_tools(%Goal{}), do: nil

  defp maybe_put_goal_command(adapter_opts, %Goal{harness: %{command: cmd}})
       when is_binary(cmd) and cmd != "",
       do: Keyword.put_new(adapter_opts, :command, cmd)

  defp maybe_put_goal_command(adapter_opts, _goal), do: adapter_opts

  # T8.7 (ADR-0016): resolve which harness adapter drives this run. Precedence is
  # the CLI `--harness`/`--model` opts > the goal-file `[harness]` table (T8.6) >
  # app config > the `:claude` default — exactly the order `Kazi.Harness.resolve/1`
  # encodes. Returns `{adapter_module, harness_opts}` or surfaces an
  # `{:error, {:unknown_harness, id}}` that aborts the run with a clear message.
  defp resolve_harness(%Goal{harness: goal_harness}, opts) do
    gh = goal_harness || %{}

    Kazi.Harness.resolve(
      harness: Keyword.get(opts, :harness),
      goal_harness: Map.get(gh, :id),
      model: Keyword.get(opts, :model) || Map.get(gh, :model)
    )
  end

  # The retriever a goal DECLARES, if any, for per-goal retrieval opt-in (T4.9c).
  # Read from `goal.metadata[:retriever]` (string or atom key, since goal-file
  # metadata may carry either): a `Kazi.Retrieval` module or `{module, init_opts}`
  # tuple. Absent the key, returns `nil` — the off-by-default state.
  @spec goal_retriever(Goal.t()) :: Kazi.Retrieval.t() | nil
  defp goal_retriever(%Goal{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :retriever) || Map.get(metadata, "retriever")
  end

  defp goal_retriever(%Goal{}), do: nil

  # Static context the loop threads into every integrate/deploy action. This is
  # how the runtime points the actions' OWN injectable seams — the integrate
  # action's `:integrator` (PR/merge) and the deploy action's `:deploy_cmd` — at
  # local stubs in tests and at the real `gh`/`gcloud` defaults in production
  # (each action falls back to its real default when the key is absent).
  # `run_id`/`goal_ref` thread this run's registry identity into the integrate
  # action so its shared-workspace staging guard (T59.8, #937 Gap A4) can skip
  # this run's own row and same-goal rows when it asks the registry whether a
  # DIFFERENT live run holds the workspace.
  defp build_action_context(opts, run_id, goal_ref) do
    %{}
    |> maybe_put(:integrator, Keyword.get(opts, :integrator))
    |> maybe_put(:deploy_cmd, Keyword.get(opts, :deploy_cmd))
    |> maybe_put(:run_id, run_id)
    |> maybe_put(:goal_ref, goal_ref)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # =============================================================================
  # Persistence (read-model projection, T0.9)
  # =============================================================================

  # Build the loop's :on_iteration side-effect callback that projects each
  # observed iteration into the SQLite read-model. Returns nil when persistence
  # is disabled AND no `:stream` observer is supplied, so the loop runs without
  # the seam at all.
  #
  # T15.4 (ADR-0023 decision 3): an optional `:stream` callback is COMPOSED here
  # over the persistence projection — the loop fires ONE `on_iteration` per
  # observation, so both the read-model write and the streaming JSONL emit happen
  # on that single seam. The stream observer runs FIRST (so an event is emitted
  # even when persistence is off / fails), then the read-model projection. Both
  # are side-effect only; a raising stream callback is contained here so it never
  # alters convergence or blocks the projection.
  #
  # T46.1 (ADR-0057): the run registry's heartbeat is composed onto the SAME seam,
  # gated by the same `persist?` flag as the iteration projection — "persistence
  # off" means the run touches no read-model table, registry included.
  #
  # T46.2 (ADR-0057 decision 3): the events sink append is likewise composed onto
  # this seam, INSIDE `persist_iteration/3` — it fires only after the read-model
  # write succeeds, so a sink line and its read-model row are built from the SAME
  # inserted `Kazi.ReadModel.Iteration` struct and can never disagree.
  defp build_on_iteration(goal, opts, run_id, persist?, events_sink_path) do
    stream = Keyword.get(opts, :stream)
    goal_ref = Keyword.get(opts, :goal_ref, goal.id)
    session_name = Keyword.get(opts, :session_name)

    # The iteration side-effects, composed in a fixed order: the streaming
    # observer first, then the read-model projection, then the T51.5 bus mirror
    # LAST so a mirror post can never precede or perturb persistence. The mirror
    # is always present (detached + fully swallowed, ADR-0067 point 1), so even a
    # non-persisted fixture loop projects live progress onto the bus.
    effects =
      [
        is_function(stream, 1) && fn payload -> run_stream_observer(stream, payload) end,
        persist? &&
          fn payload ->
            RunRegistry.heartbeat(run_id)
            record_harness_session(run_id, payload)
            record_harness_pid(run_id, payload)
            persist_iteration(goal_ref, payload, events_sink_path)
            persist_debrief(run_id, goal_ref, payload)
          end,
        fn payload -> BusMirror.iteration(goal_ref, run_id, session_name, payload) end
      ]
      |> Enum.filter(&is_function(&1, 1))

    fn payload -> Enum.each(effects, & &1.(payload)) end
  end

  # Project the inner harness's session id (claude's envelope `session_id`,
  # threaded via the loop's iteration payload) onto the run row, so the
  # dashboard can offer an interactive resume. Best-effort like every registry
  # write; `record_harness_session/2` no-ops on an unchanged id.
  defp record_harness_session(run_id, %{harness_session_id: session_id})
       when is_binary(session_id) do
    RunRegistry.record_harness_session(run_id, session_id)
    :ok
  end

  defp record_harness_session(_run_id, _payload), do: :ok

  # Project the dispatched harness subprocess's OS pid (issue #857,
  # ChildSupervisor's pid-file side channel, threaded via the loop's iteration
  # payload) onto the run row, so a LATER run's orphan-on-resume check
  # (`warn_on_orphans/4`) can see it. Best-effort like every registry write;
  # `record_harness_pid/2` no-ops on an unchanged pid.
  defp record_harness_pid(run_id, %{harness_pid: pid}) when is_binary(pid) do
    RunRegistry.record_harness_pid(run_id, pid)
    :ok
  end

  defp record_harness_pid(_run_id, _payload), do: :ok

  # T15.4: run the streaming observer, contained — a raising stream callback must
  # never alter convergence or block the persistence projection that follows it.
  defp run_stream_observer(stream, payload) do
    stream.(payload)
  rescue
    error ->
      Logger.warning(fn ->
        "kazi.runtime stream observer raised: #{Exception.message(error)}"
      end)

      :ok
  end

  # Project one iteration. Best-effort: a read-model write must never stall or
  # alter convergence (the loop already contains the callback, but we also keep
  # the error local and logged rather than surfaced).
  #
  # T1.4 budget: an optional `:stop_reason` (present only on the loop's budget-stop
  # projection) is recorded as a `budget_stop` action so the exceeded dimension is
  # visible in the persisted iteration log.
  #
  # T46.2 (ADR-0057 decision 3): on a successful insert, ALSO append the same
  # inserted row to the run's events sink (`events_sink_path`, nil when
  # persistence is off) — the sink line is built from the returned
  # `Kazi.ReadModel.Iteration` struct, not re-derived from `payload`, so it can
  # never drift from what the read-model actually stored for this iteration.
  defp persist_iteration(
         goal_ref,
         %{
           iteration: index,
           vector: vector,
           converged?: converged?
         } = payload,
         events_sink_path
       ) do
    attrs =
      %{
        goal_ref: goal_ref,
        iteration_index: index,
        predicate_vector: vector,
        converged: converged?,
        # T1.2 regression: project the observation's green→red flags so they are
        # queryable from the read-model (Kazi.ReadModel.regressions/1).
        regressions: Map.get(payload, :regressions, []),
        # T34.3 (ADR-0046 §2): project the per-iteration context + tool counters so
        # the cached-vs-fresh and tool-call signals are queryable from the
        # read-model (and the E19 arms can attribute outcomes to them). Absent on a
        # pre-T34.3 payload — defaults to the empty map, which records as no-counters.
        context: Map.get(payload, :context, %{}),
        tools: Map.get(payload, :tools, %{})
      }
      # T3.3d deploy wiring: project the release ref recorded on a successful
      # deploy (T3.3c) into the read-model's `release_ref` column so the shipped
      # artifact is queryable via Kazi.ReadModel.release_refs/1.
      |> maybe_put_release_ref(Map.get(payload, :release_ref))
      |> maybe_put_budget_stop(Map.get(payload, :stop_reason))
      # T18.3: persistence is a PROJECTION of observed state, so re-projecting an
      # iteration_index must be idempotent. A terminal projection (stuck stop
      # reuses iterations-1; some budget paths re-touch the last index) otherwise
      # collides on the (goal_ref, iteration_index) unique index and the iteration
      # is logged as a failed insert. Always upsert from the runtime projection
      # (replace the row's final state); the read-model keeps its duplicate-
      # rejecting contract for direct callers.
      |> Map.put(:upsert?, true)

    case ReadModel.record_iteration(attrs) do
      {:ok, iteration} ->
        EventsSink.append(events_sink_path, iteration_event(iteration))
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          "kazi.runtime failed to persist iteration #{index} for goal=#{goal_ref}: " <>
            inspect(reason)
        end)

        :ok
    end
  end

  # T48.11 (ADR-0058 §3): project the opted-in debrief answer's capped
  # hypothesis list (folded onto the payload by `Kazi.Loop.record_debrief/2`) as
  # read-model rows. A no-op when the list is empty (disabled, or nothing
  # reported this iteration) — this is the ONLY place a debrief answer is ever
  # written; nothing reads it back into a prompt (the write-only rule).
  # Best-effort like every other registry/read-model write in this module.
  defp persist_debrief(run_id, goal_ref, %{debrief: [_ | _] = items, iteration: index}) do
    case ReadModel.record_debrief_hypotheses(%{
           goal_ref: goal_ref,
           run_id: run_id,
           iteration: index,
           items: items
         }) do
      {:ok, _hypotheses} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          "kazi.runtime failed to persist debrief hypotheses for goal=#{goal_ref}: " <>
            inspect(reason)
        end)

        :ok
    end
  end

  defp persist_debrief(_run_id, _goal_ref, _payload), do: :ok

  # The events-sink line for one iteration (T46.2): built from the read-model
  # row `record_iteration/1` just inserted, so its shape/values are exactly the
  # ones a reader would see querying the read-model for the same
  # (goal_ref, iteration_index).
  defp iteration_event(%Iteration{} = iteration) do
    %{
      "type" => "iteration",
      "goal_ref" => iteration.goal_ref,
      "iteration" => iteration.iteration_index,
      "converged" => iteration.converged,
      "predicates" => iteration.predicate_vector,
      "regressions" => iteration.regressions,
      "action_kind" => iteration.action_kind,
      "action_params" => iteration.action_params,
      "release_ref" => iteration.release_ref,
      "context" => iteration.context,
      "tools" => iteration.tools,
      "observed_at" => DateTime.to_iso8601(iteration.observed_at)
    }
  end

  # T3.3d deploy wiring: stamp the iteration with the release ref of the deployed
  # artifact (T3.3c) when present, so it lands in the read-model's `release_ref`
  # column. A nil ref (nothing deployed yet) is omitted, leaving the column NULL.
  defp maybe_put_release_ref(attrs, nil), do: attrs

  defp maybe_put_release_ref(attrs, ref) when is_binary(ref),
    do: Map.put(attrs, :release_ref, ref)

  # T1.4 budget: stamp a budget-stop iteration with the action that ended the run
  # so the persisted log names the exceeded dimension.
  defp maybe_put_budget_stop(attrs, nil), do: attrs

  defp maybe_put_budget_stop(attrs, reason) do
    Map.put(attrs, :action, Kazi.Action.new(:budget_stop, params: %{reason: reason}))
  end

  # =============================================================================
  # Transcript sink path (T46.3, ADR-0057)
  # =============================================================================

  # nil when persistence is off — a non-persisted run has no registry row to
  # point at a sink, and writes nothing under the kazi home either.
  defp maybe_transcript_sink_path(false, _run_id, _opts), do: nil

  defp maybe_transcript_sink_path(true, run_id, opts) do
    Path.join([sinks_dir(opts), run_id, "transcript.jsonl"])
  end

  # =============================================================================
  # Events sink path (T46.2, ADR-0057)
  # =============================================================================

  # Same gate/layout as the transcript sink path above, one directory over.
  defp maybe_events_sink_path(false, _run_id, _opts), do: nil

  defp maybe_events_sink_path(true, run_id, opts) do
    Path.join([sinks_dir(opts), run_id, "events.jsonl"])
  end

  # =============================================================================
  # Capture recipes / run evidence store (T68.7, ADR-0081)
  # =============================================================================

  # The controller-side capture executor the loop runs at the start of every
  # observe pass. Closes over the goal's recipes, the run id, the workspace, and
  # an injectable command runner (`:capture_runner`, default the real
  # `Kazi.Providers.CommandRunner`), keying the evidence store to the run under the
  # SAME `sinks_dir` tree the events/transcript sinks use — outside the workspace
  # the worker edits (ADR-0081 §3). A goal with no `[[capture]]` gets a no-op
  # closure, so capture execution is inert (byte-identical) unless declared.
  defp build_capture_fn(%Goal{captures: []}, _opts, _run_id, _workspace), do: fn _iter -> %{} end

  defp build_capture_fn(%Goal{captures: captures}, opts, run_id, workspace) do
    base = sinks_dir(opts)
    runner = Keyword.get(opts, :capture_runner, &Kazi.Providers.CommandRunner.run/4)

    fn iteration ->
      dir = Kazi.Sink.Captures.iteration_dir(base, run_id, iteration)
      File.mkdir_p!(dir)
      Kazi.Sink.Captures.run(captures, dir: dir, workspace: workspace, runner: runner)
    end
  end

  # The per-run sinks directory: an explicit `:sinks_dir` opt (the test-override
  # seam, mirroring `:run_id`) > the `:kazi, :sinks_dir` app config > the same
  # `<user-home>/.kazi` root the read-model DB defaults to in prod
  # (`config/runtime.exs`), under a `runs/` subdirectory.
  defp sinks_dir(opts) do
    Keyword.get(opts, :sinks_dir) ||
      Application.get_env(:kazi, :sinks_dir) ||
      Path.join([System.user_home() || File.cwd!(), ".kazi", "runs"])
  end

  # =============================================================================
  # Fleet run registry (T46.1, ADR-0057)
  # =============================================================================
  #
  # `Kazi.ReadModel.RunRegistry` has exactly ONE writer: this module. A real
  # `kazi apply` reaches every real user (the CLI, the mix task, the escript) by
  # calling `run/2`, so registering/heartbeating/finishing here — rather than in
  # the CLI layer — is what makes the registry see EVERY run regardless of entry
  # point. Best-effort throughout: a registry write must never stall or alter
  # convergence, matching the read-model projection's own contract above.

  defp register_run(
         false,
         _run_id,
         _workspace,
         _goal_ref,
         _harness_opts,
         _transcript_sink_path,
         _events_sink_path,
         _goal,
         _session_name,
         _proposal_ref
       ),
       do: :ok

  defp register_run(
         true,
         run_id,
         workspace,
         goal_ref,
         harness_opts,
         transcript_sink_path,
         events_sink_path,
         goal,
         session_name,
         proposal_ref
       ) do
    attrs = %{
      run_id: run_id,
      pid: inspect(self()),
      workspace: to_string(workspace),
      goal_ref: goal_ref,
      harness: harness_id_string(harness_opts),
      model: Keyword.get(harness_opts, :model),
      transcript_sink_path: transcript_sink_path,
      events_sink_path: events_sink_path,
      max_iterations: goal.budget.max_iterations,
      # The goal's authored display name + one-line description, so the
      # dashboard drill-in can say WHAT is being worked on.
      goal_name: goal.name,
      goal_description: goal.description,
      # The operator-assigned session label (`--session-name` /
      # KAZI_SESSION_NAME), telling concurrent runs apart on the starmap rail.
      session_name: session_name,
      # Session provenance part 2: the approved proposal this run was
      # started from (`kazi apply <proposal-ref>`), or nil for a plain
      # goal-file-path run.
      proposal_ref: proposal_ref,
      # T48.15: record the OS process id for liveness detection in run reaping.
      os_pid: to_string(System.pid()),
      # The driving agent session's OS pid (nearest `claude`-like ancestor),
      # so the dashboard can tell live-session runs from dead history.
      session_os_pid: Kazi.SessionLiveness.find_session_pid()
    }

    case RunRegistry.start(attrs) do
      {:ok, _run} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          "kazi.runtime failed to register run #{run_id} for goal=#{goal_ref}: " <>
            inspect(reason)
        end)

        :ok
    end
  end

  # The harness id (e.g. "claude") the registry displays, read off the resolved
  # profile threaded into adapter_opts (`Kazi.Harness.resolve/1`) — the SAME
  # profile the adapter itself dispatches through, so the registry can never
  # disagree with what actually ran.
  defp harness_id_string(harness_opts) do
    case Keyword.get(harness_opts, :profile) do
      %{id: id} when is_atom(id) -> Atom.to_string(id)
      _ -> nil
    end
  end

  # T31: start the heartbeat ticker process (a supervised periodic timer that
  # advances the heartbeat_at timestamp every ~30 seconds, independent of loop
  # iterations). This keeps healthy long-running dispatches from appearing stale.
  defp start_heartbeat_ticker(false, _run_id), do: nil

  defp start_heartbeat_ticker(true, run_id) do
    case HeartbeatTicker.start_link(run_id) do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        Logger.warning(fn ->
          "kazi.runtime failed to start heartbeat ticker for run #{run_id}: " <>
            inspect(reason)
        end)

        nil
    end
  end

  # Issue #1073: arm the launcher-liveness monitor ONLY for a persisted run under
  # the real standalone binary. `persist?` alone is not enough -- integration
  # tests run persisted; `burrito_standalone?/0` is the gate that keeps a
  # self-halting monitor out of every `mix test`/escript loop (R-E54-3).
  defp start_parent_monitor(persist?, run_id) do
    if persist? and burrito_standalone?() do
      case ParentMonitor.start_link(run_id: run_id) do
        {:ok, pid} ->
          pid

        {:error, reason} ->
          Logger.warning(fn ->
            "kazi.runtime failed to start parent monitor for run #{run_id}: " <> inspect(reason)
          end)

          nil
      end
    else
      nil
    end
  end

  defp stop_parent_monitor(nil), do: :ok

  defp stop_parent_monitor(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # True only when this VM is the entry process of a burrito-wrapped binary --
  # the one place the launcher can be killed independently of the BEAM. Guarded
  # with `Code.ensure_loaded?` so a build without burrito stays a no-op rather
  # than raising (mirrors `Kazi.Application.burrito_standalone?/0`).
  defp burrito_standalone? do
    Code.ensure_loaded?(Burrito.Util) and
      function_exported?(Burrito.Util, :running_standalone?, 0) and
      Burrito.Util.running_standalone?()
  end

  # =============================================================================
  # Orphan-on-resume warning (issue #857)
  # =============================================================================
  #
  # A prior run's harness subprocess can outlive that run's controller (#856's
  # abnormal-exit path predates the #857 child-supervision fix, and even after
  # it a pid that predates this deploy has no supervisor watching it). If a
  # fresh apply for the SAME goal_ref sees that prior run's recorded
  # `harness_child_pid` still alive, that is a probable orphan: an unsupervised
  # writer racing this run with a stale view of the workspace. This check is
  # purely observational (never blocks/alters this run's own start) and
  # best-effort, matching every other registry touch in this module.

  defp warn_on_orphans(false, _run_id, _goal_ref, _events_sink_path), do: :ok

  defp warn_on_orphans(true, run_id, goal_ref, events_sink_path) do
    goal_ref
    |> RunRegistry.list_by_goal_ref(run_id)
    |> Enum.filter(&orphaned?/1)
    |> Enum.each(&emit_orphan_warning(&1, events_sink_path))

    :ok
  rescue
    error ->
      Logger.warning(fn ->
        "kazi.runtime orphan-on-resume check raised: #{Exception.message(error)}"
      end)

      :ok
  end

  defp orphaned?(%ReadModel.Run{harness_child_pid: pid}) when is_binary(pid),
    do: ChildSupervisor.alive?(pid)

  defp orphaned?(%ReadModel.Run{}), do: false

  defp emit_orphan_warning(%ReadModel.Run{} = run, events_sink_path) do
    message =
      "kazi: WARNING possible orphaned harness process: prior run #{run.run_id} " <>
        "(goal=#{run.goal_ref}) recorded harness pid #{run.harness_child_pid}, which is " <>
        "still alive — its controller may have exited without reaping it; that process " <>
        "may still be mutating this workspace"

    Logger.warning(fn -> message end)
    IO.puts(:stderr, message)

    EventsSink.append(events_sink_path, %{
      type: "orphan_warning",
      prior_run_id: run.run_id,
      goal_ref: run.goal_ref,
      harness_pid: run.harness_child_pid,
      at: DateTime.to_iso8601(DateTime.utc_now())
    })

    :ok
  end

  defp finish_run(false, _run_id, _result), do: :ok

  defp finish_run(true, run_id, {:ok, %{outcome: outcome, reason: reason} = result}) do
    do_finish_run(run_id, registry_status(outcome, reason), economics_attrs(result))
  end

  defp finish_run(true, run_id, {:error, _reason}) do
    do_finish_run(run_id, "error", %{})
  end

  # ADR-0063 (Slice 3): at the SAME terminal point `finish_run/3` records the
  # run's economics, run the deterministic harvest detector over the goal's
  # own recorded facts (`Kazi.Memory.Harvest`, controller-side only -- never
  # reachable from the harness/dispatch path). Best-effort like every other
  # projection here: a harvest failure must never alter the reported outcome.
  # A no-op when persistence is off (there is no read-model to harvest from
  # or propose into) or on a `Loop.await/2` timeout.
  defp harvest_memory(false, _run_id, _goal_ref, _result), do: :ok
  defp harvest_memory(true, _run_id, _goal_ref, {:error, _reason}), do: :ok

  defp harvest_memory(true, run_id, goal_ref, {:ok, result}) do
    Kazi.Memory.Harvest.harvest(run_id, goal_ref, result)
    :ok
  rescue
    error ->
      Logger.warning(fn ->
        "kazi.runtime harvest failed for goal=#{goal_ref}: " <> Exception.message(error)
      end)

      :ok
  end

  defp do_finish_run(run_id, status, economics) do
    case RunRegistry.finish(run_id, status, economics) do
      {:ok, _run} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          "kazi.runtime failed to finish run #{run_id}: " <> inspect(reason)
        end)

        :ok
    end
  end

  # =============================================================================
  # Run-end economics projection (T48.7, ADR-0058 decision 1)
  # =============================================================================
  #
  # Maps `Kazi.Loop.result/0` onto the `RunRegistry.finish/3` economics attrs.
  # Honest-unknown (ADR-0046): when the loop's `usage` envelope is empty (no
  # dispatch this run ever reported ANY usage component — the `claw` profile
  # reports none by design, and a run with zero dispatches trivially has none
  # either), the token/cost fields persist nil, never 0. `usage` is the T34.1
  # additive envelope (only reported components present); `tokens_used` is the
  # separate legacy rolled-up total the budget gate reads and is NOT itself
  # honest-unknown (it defaults 0 on an unreported estimate) — gating on `usage`
  # being empty, not on `tokens_used == 0`, is what keeps this projection honest
  # even though the field it publishes is `tokens_used`.
  @spec economics_attrs(Kazi.Loop.result()) :: map()
  defp economics_attrs(%{usage: usage} = result) when map_size(usage) == 0 do
    Map.merge(
      %{
        budget_tokens: nil,
        budget_cached_input_tokens: nil,
        budget_cost_usd: nil,
        dispatch_count: Map.get(result, :dispatches, 0),
        context_tier: Map.get(result, :context_tier),
        predicate_count: get_in(result, [:goal_shape, :predicate_count]),
        predicate_kind_histogram: get_in(result, [:goal_shape, :kind_histogram]) || %{}
      },
      cause_attrs(result)
    )
  end

  defp economics_attrs(%{usage: usage, tokens_used: tokens_used} = result) do
    Map.merge(
      %{
        budget_tokens: tokens_used,
        budget_cached_input_tokens: Map.get(usage, :cached_input_tokens),
        budget_cost_usd: Map.get(usage, :cost_usd),
        dispatch_count: Map.get(result, :dispatches, 0),
        context_tier: Map.get(result, :context_tier),
        predicate_count: get_in(result, [:goal_shape, :predicate_count]),
        predicate_kind_histogram: get_in(result, [:goal_shape, :kind_histogram]) || %{}
      },
      cause_attrs(result)
    )
  end

  defp economics_attrs(_result), do: %{}

  # T48.4 (ADR-0058 decision 4): project the loop's `:cause` (a
  # `Kazi.Loop.CauseClass.t()` or nil) onto the two read-model columns.
  # Honest-unknown: no cause classified persists NULL for both, never a
  # zero-filled placeholder. `outcome_cause_detail`'s reasons are rendered with
  # `inspect/1` — a `Kazi.Loop.ErrorPermanence` reason can be a bare atom OR a
  # `{tag, detail}` tuple, and Ecto's `:map` (JSON) column cannot round-trip a
  # tuple, so the DETAIL is a human-readable string; the in-process
  # `result.cause` (surfaced via `--json`/snapshot) keeps the raw term.
  @spec cause_attrs(Kazi.Loop.result()) :: map()
  defp cause_attrs(%{cause: %{class: class} = cause}) when is_atom(class) do
    %{
      outcome_cause_class: Atom.to_string(class),
      outcome_cause_detail: %{
        "ids" => Enum.map(cause.ids, &to_string/1),
        "reasons" => cause_reasons_for_storage(cause.reasons),
        "exhausted" => cause.exhausted && Atom.to_string(cause.exhausted)
      }
    }
  end

  defp cause_attrs(_result), do: %{outcome_cause_class: nil, outcome_cause_detail: nil}

  defp cause_reasons_for_storage(nil), do: %{}

  defp cause_reasons_for_storage(reasons) do
    Map.new(reasons, fn {id, reason} -> {to_string(id), inspect(reason)} end)
  end

  # Maps the loop's `t:Kazi.Loop.result/0` outcome to the registry's terminal
  # status vocabulary (`Kazi.ReadModel.RunRegistry.finish/2`'s doc, mirrored by
  # `KaziWeb.MissionControlLive`'s state resolution).
  defp registry_status(:converged, _reason), do: "converged"
  defp registry_status(:over_budget, _reason), do: "over_budget"
  # ADR-0080 (#1520): a tampered run gets its own distinct terminal status — never
  # folded into "stuck"/"stopped", so the fleet surfaces it as the hard-FAIL it is.
  defp registry_status(:tampered, _reason), do: "tampered"
  defp registry_status(:stopped, :stuck), do: "stuck"
  defp registry_status(:stopped, _reason), do: "stopped"

  # =============================================================================
  # Result normalization
  # =============================================================================

  # The loop is left running after it terminates (late await/snapshot still
  # work), but run/2 owns this loop's lifecycle, so a timeout is a real error.
  defp normalize_await({:ok, result}), do: {:ok, result}
  defp normalize_await({:error, :timeout}), do: {:error, :await_timeout}

  # =============================================================================
  # Goal-drift detection (goal-drift-guard-1415)
  # =============================================================================

  # Additive report on TOP of the terminal result: whether the goal-file on disk
  # at `:goal_source` (when the caller supplied one — a real file path, never a
  # proposal ref) still matches the `t0_snapshot` this run actually converged
  # against. Never changes the outcome the loop already decided — the ORIGINAL
  # bar (`t0_snapshot`, captured before the loop started) already won by
  # construction; this only surfaces whether it was quietly moved.
  defp put_goal_drift({:ok, result}, t0_snapshot, goal_source) when is_map(result) do
    case GoalDrift.detect(t0_snapshot, goal_source) do
      :unchanged -> {:ok, result}
      {:drifted, diff} -> {:ok, Map.merge(result, %{goal_drifted: true, goal_drift: diff})}
    end
  end

  defp put_goal_drift(result, _t0_snapshot, _goal_source), do: result
end
