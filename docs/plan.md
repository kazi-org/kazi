# kazi -- Build Plan (Walking Skeleton, idea -> production)

## Context

**Problem.** Existing prose-driven Claude Code skills (brainstorm -> plan ->
apply -> verify -> qualify) can take a simple system from idea to production, but
not reliably: "done" is the agent's opinion, verification is skippable, and
parallel sessions collide. kazi replaces that with a reconciliation controller --
declare a goal as machine-checkable predicates; kazi drives a coding agent in a
loop until the predicates are objectively true, stuck, or over budget.

**This plan** builds kazi as a **walking skeleton**: thin vertical slices
end-to-end through all lifecycle phases, deepened slice by slice -- never one
whole phase at a time. The skeleton spans **idea -> production from Slice 0**:
every lifecycle phase gets its thinnest version on day one (including integrate +
deploy + verify-live), and later slices DEEPEN phases rather than add missing
ones. Start from the convergence core (the pain and the only objectively testable
part). See `docs/adr/0007-build-strategy-walking-skeleton.md`.

**Frozen design** (do not relitigate here): `docs/concept.md` + ADRs 0001-0006.
Runtime Elixir/OTP + Phoenix LiveView; coordination NATS JetStream (KV leases
CAS+TTL, event stream); local read-model SQLite/WAL; Git owns code;
harness-agnostic via subprocess adapter (`claude -p` first).

**Objectives.**
- Slice 0: a working convergence loop that takes a tiny fixture from a failing
  test to a live, verified production deployment, and cannot declare success
  while any predicate -- code OR live -- fails.
- Slice 1: trustworthy loops (regression, flake, budget, stuck-escalation,
  prod-log predicate).
- Slice 2: creation mode -- kazi can build features, not only repair them.
- Slice 3+: DEEPEN (leases, partitioning, richer deploy, maintenance, front-end,
  UI) only as a slice needs it; from Slice 2 onward kazi builds kazi.

**Non-goals.** Replacing the harness (kazi drives Claude Code/Codex, never
becomes one). Product prioritization / "what to build" (human judgment).
A vector DB in the core (deferred pluggable memory adapter). Building a lifecycle
phase because the SDLC diagram lists it (a phase is built only when a slice needs
it).

**Constraints / assumptions.** Elixir/OTP; stdlib + Phoenix/Ecto ecosystem; tests
in ExUnit; `mix format` as formatter; Podman for container builds; Cloud Run for
the deploy target; GitHub Actions for CI/CD. Slices 0-2 are bootstrapped with
existing Claude Code skills. NATS and Phoenix LiveView are not introduced until
Slice 3; deploy IS in Slice 0 (thin).

**Success metric (the bar for the whole iteration).** kazi converges a goal that
a prose brainstorm->plan->apply->verify->qualify pipeline left subtly broken,
measured by the Slice 0/Slice 1 dogfood fixtures (T0.12, T1.8), including a live
production probe.

## Discovery Summary

Greenfield repo: only `docs/` exists (concept + ADRs 0001-0007); no source yet.
Engineering work type. 21 use cases discovered, all PLANNED, mapped to slices by
priority: P0 Slice 0 (UC-001..006, UC-011, UC-015, UC-020), P1 Slice 1
(UC-007..009, UC-021), P2 Slice 2 (UC-010, UC-012), P3 Slice 3+ (UC-013..019).
Wiring status: nothing wired (no code). Reference:
`.claude/scratch/usecases-manifest.json`.

## Scope and Deliverables

In scope: Slices 0-2 in full detail; Slice 3+ as a coarse backlog to be
re-planned (self-hosted) when reached.

Out of scope: NATS/leases, graph partitioning, standing reconcilers, dashboard,
notifications, multi-env/rollback deploy until Slice 3; harness replacement;
product prioritization.

| ID | Deliverable | Owner | Acceptance |
|----|-------------|-------|------------|
| D0 | idea -> production convergence loop (Slice 0) | TBD | `kazi run <goal> --workspace <path>` takes a fixture from a failing test to a live, verified Cloud Run deployment; refuses :converged while tests OR the live probe fail; evidence in SQLite |
| D1 | Trustworthy loop (Slice 1) | TBD | regression flagged, flakes quarantined, budget+stuck escalate to human, prod-log predicate works |
| D2 | Creation mode (Slice 2) | TBD | kazi builds one small real feature from failing acceptance predicates to live; vacuous goal rejected |
| D3 | Slice 3+ backlog | TBD | each item re-planned as a self-hosted kazi goal when reached |

## Checkable Work Breakdown

Layout: monolithic (single file); the WBS below is the single checkable source of
truth. The Waves section references task IDs only (no checkboxes) to avoid
duplicate status. Status `kind: agent` is implicit unless noted.

### E0 -- Scaffold + Slice 0 Walking Skeleton (idea -> production) (P0)

Acceptance: D0 met; T0.12 dogfood drives the fixture to a live, verified
production deployment.

- [x] T0.1 Initialize Elixir mix app `kazi` (supervision tree, `.formatter.exs`, `.gitignore`, mix.exs deps pinned)  Owner: TBD  Est: 1h  verifies: [infrastructure]  done: 2026-06-21 PR #3
- [x] T0.2 CI: GitHub Actions running `mix format --check-formatted` and `mix test`  Owner: TBD  Est: 1h  verifies: [infrastructure]  deps: [T0.1]  done: 2026-06-21 PR #4
- [x] T0.3 Core domain types AND behaviours: `Goal`, `Predicate`, `PredicateResult{status,evidence}`, `PredicateVector`, `Action`; plus the `PredicateProvider`, `HarnessAdapter`, and `Action` behaviours (contracts only) + tests  Owner: TBD  Est: 2h  verifies: [UC-001]  deps: [T0.1]  done: 2026-06-21 PR #6
- [x] T0.4 Goal loader + goal-file TOML schema + an example goal fixture (code predicates + a live predicate) + tests  Owner: TBD  Est: 2h  verifies: [UC-001]  deps: [T0.3]
- [x] T0.5 Test-runner predicate provider (runs configurable cmd in the target workspace, maps exit/output -> `PredicateResult`) + tests  Owner: TBD  Est: 2h  verifies: [UC-002]  deps: [T0.3]
- [x] T0.5b Live http_probe predicate provider (request a URL, assert status/body) + tests  Owner: TBD  Est: 1.5h  verifies: [UC-011]  deps: [T0.3]
- [x] T0.6 Harness-adapter behaviour impl: `claude -p` adapter that runs the harness IN THE TARGET WORKSPACE so edits land in place; focused prompt seeded with failing-predicate evidence; capture result. Tests use a stub binary  Owner: TBD  Est: 2h  verifies: [UC-003]  deps: [T0.3]
- [x] T0.9 SQLite read-model: Ecto SQLite3 repo + migration for iteration/evidence log; persist each iteration  Owner: TBD  Est: 2h  verifies: [UC-006]  deps: [T0.3]
- [x] T0.7 Convergence state machine (GenStateMachine) against the behaviours/test-doubles: observe -> diff -> decide-next-action -> {dispatch agent | integrate | deploy} -> re-observe; converge-and-stop  Owner: TBD  Est: 3h  verifies: [UC-004]  deps: [T0.3]
- [x] T0.10a Integrate action: land a converged fix (branch -> commit -> push -> open PR -> rebase-merge) in the target workspace + tests with a fixture repo  Owner: TBD  Est: 2.5h  verifies: [UC-020]  deps: [T0.3]
- [x] T0.10b Deploy action: trigger a release/deploy of the target (`gcloud run deploy` or GitHub Actions dispatch); return a deploy ref; tests with a stub deployer  Owner: TBD  Est: 2h  verifies: [UC-015]  deps: [T0.3]
- [x] T0.13 Deployable target fixture: a tiny containerized web service (Podman build) with one failing unit test AND a behaviour the live probe checks, plus a Cloud Run deploy workflow  Owner: TBD  Est: 2.5h  verifies: [infrastructure]  deps: [T0.1]  done: 2026-06-21 PR #5 (Go service, isolated from kazi CI)
- [ ] T0.6h Provision GCP project + Cloud Run service + deploy credentials for the fixture  Owner: TBD  Est: 2h  verifies: [infrastructure]  kind: human  blocked: Awaiting GCP project/billing setup
- [x] T0.7b Integration: wire concrete providers + adapter + integrate/deploy actions into the loop (replace test-doubles)  Owner: TBD  Est: 2h  verifies: [UC-004]  deps: [T0.5, T0.5b, T0.6, T0.7, T0.10a, T0.10b]
- [x] T0.8 Objective-termination guard: `:converged` reachable only when the FULL vector (code + live) is true; explicit test that a failing live probe blocks success  Owner: TBD  Est: 1h  verifies: [UC-005]  deps: [T0.7]
- [x] T0.10 CLI entry `kazi run <goal-file> --workspace <path>` wiring loader + loop + actions against an explicit target workspace  Owner: TBD  Est: 1.5h  verifies: [UC-004]  deps: [T0.7]
- [x] T0.11 Full-loop integration test incl. a deliberately-failing-test fixture, with deploy + probe stubbed  Owner: TBD  Est: 2h  verifies: [UC-005]  deps: [T0.7b, T0.8, T0.10]
- [ ] T0.12 Dogfood Slice 0 (idea -> production): run kazi against the deployable fixture; confirm it takes a failing test to a LIVE, verified production deployment and refuses success while tests OR the live probe fail; record result in `docs/devlog.md`  Owner: TBD  Est: 1.5h  verifies: [UC-005]  deps: [T0.11, T0.10a, T0.10b, T0.13, T0.6h]

### E1 -- Slice 1: Trustworthy Loop (P1)

Acceptance: D1 met; T1.8 dogfood passes.

- [x] T1.1 Track the full predicate vector across iterations (in state + SQLite history)  Owner: TBD  Est: 1.5h  verifies: [UC-007]  deps: [T0.9]
- [x] T1.2 Regression detector: flag a predicate that went green -> red, attributed to the last dispatch  Owner: TBD  Est: 2h  verifies: [UC-007]  deps: [T1.1]
- [x] T1.3 Flake handling: re-run policy + quarantine list so a nondeterministic fail is not treated as work  Owner: TBD  Est: 2h  verifies: [UC-008]  deps: [T0.7b]
- [x] T1.4 Budget ceiling (iterations / wall-clock / token estimate) enforced as a hard stop  Owner: TBD  Est: 1.5h  verifies: [UC-009]  deps: [T0.7b]
- [x] T1.5 Stuck detector (N iterations, same failing set) + human-escalation hook  Owner: TBD  Est: 1.5h  verifies: [UC-009]  deps: [T0.7b]
- [x] T1.6 Prod-log predicate provider (query prod logs for 5xx/panics over a window) + tests  Owner: TBD  Est: 2h  verifies: [UC-021]  deps: [T0.3]
- [ ] T1.7 ExUnit tests for regression, flake, budget, stuck, prod-log  Owner: TBD  Est: 2h  verifies: [UC-007, UC-008, UC-009, UC-021]  deps: [T1.2, T1.3, T1.4, T1.5, T1.6]
- [ ] T1.8 Dogfood Slice 1: goal where the naive fix regresses another predicate; confirm detection + escalation; record in `docs/devlog.md`  Owner: TBD  Est: 1h  verifies: [UC-007]  deps: [T1.7]

### E2 -- Slice 2: Creation Mode + Self-Hosting Cutover (P2)

Acceptance: D2 met; kazi builds one real feature from acceptance predicates to live.

- [ ] T2.1 Acceptance-predicate support: goals authored as failing acceptance criteria over the http_probe provider + tests  Owner: TBD  Est: 2h  verifies: [UC-010]  deps: [T0.4]
- [ ] T2.2 Browser predicate provider (Playwright via Port) + test (golden path + 1 edge case)  Owner: TBD  Est: 2.5h  verifies: [UC-012]  deps: [T0.5]
- [ ] T2.3 Vacuous-goal guard: reject a goal whose predicates all pass at t0 (underspecified) + test  Owner: TBD  Est: 1h  verifies: [UC-010]  deps: [T0.4]
- [ ] T2.4 ExUnit tests for creation mode end-to-end  Owner: TBD  Est: 1.5h  verifies: [UC-010, UC-012]  deps: [T2.1, T2.2, T2.3]
- [ ] T2.5 Dogfood Slice 2: give kazi a small real feature as failing acceptance predicates; confirm it builds to green and live; record in `docs/devlog.md`  Owner: TBD  Est: 1.5h  verifies: [UC-010]  deps: [T2.4]
- [ ] T2.6 Self-hosting cutover: document the kazi-builds-kazi loop; author the first self-hosted kazi goal for an E3 item  Owner: TBD  Est: 1h  verifies: [infrastructure]  deps: [T2.5]

### E3 -- Slice 3+ Backlog (P3, self-hosted, coarse -- re-plan when reached)

Acceptance: each item re-planned as a kazi goal with failing acceptance
predicates before build. Intentionally low-granularity.

- [ ] T3.1 NATS JetStream resource leases (KV CAS + per-key TTL) + presence/intent subjects  Owner: TBD  Est: TBD  verifies: [UC-013]  blocked-by: [T2.6]
- [ ] T3.2 Graph-aware blast-radius partitioning via code-review-graph  Owner: TBD  Est: TBD  verifies: [UC-014]  blocked-by: [T3.1]
- [ ] T3.3 Deepen the deploy action: multi-env, rollback, release tagging  Owner: TBD  Est: TBD  verifies: [UC-015]  blocked-by: [T2.6]
- [ ] T3.4 Standing/continuous reconciler mode (maintenance goals that run forever)  Owner: TBD  Est: TBD  verifies: [UC-016]  blocked-by: [T2.6]
- [ ] T3.5 Idea -> acceptance-predicate authoring front-end (agent proposes, human approves)  Owner: TBD  Est: TBD  verifies: [UC-017]  blocked-by: [T2.6]
- [ ] T3.6 Phoenix LiveView dashboard (goal board, presence, lease map, history)  Owner: TBD  Est: TBD  verifies: [UC-018]  blocked-by: [T3.1]
- [ ] T3.7 Telegram goal-in / ping-out  Owner: TBD  Est: TBD  verifies: [UC-019]  blocked-by: [T2.6]

## Parallel Work

Behaviours-first (T0.3 defines the provider/adapter/action contracts) lets the
providers, the adapter, the actions, and the loop all build in parallel against
contracts; the only hard serialization is the state machine spine and final
wiring (T0.7b).

| Track | Tasks | Notes |
|-------|-------|-------|
| A: Domain + behaviours | T0.3 | unblocks all of Slice 0 |
| B: Providers | T0.4, T0.5, T0.5b, T0.9 | build against behaviours |
| C: Adapter + actions | T0.6, T0.10a, T0.10b | build against behaviours |
| D: Loop core | T0.7, T0.8, T0.10 | state machine spine |
| E: Target fixture + infra | T0.13, T0.6h (human) | deploy target |
| F: Integration + validation | T0.7b, T0.11, T0.12 | converge tracks |

### Waves

Waves reference task IDs; toggle the single checkbox in the WBS above. Run
`T0.6h` (human, GCP setup) out-of-band starting at Wave 2; T0.12 waits on it.

- **Wave 1 (1 agent):** T0.1
- **Wave 2 (3 agents):** T0.2, T0.3, T0.13   (kick off T0.6h human in parallel)
- **Wave 3 (8 agents):** T0.4, T0.5, T0.5b, T0.6, T0.9, T0.7, T0.10a, T0.10b
- **Wave 4 (3 agents):** T0.7b, T0.8, T0.10
- **Wave 5 (1 agent):** T0.11
- **Wave 6 (1 agent):** T0.12   (gated on T0.6h + T0.13)
- **Wave 7 (5 agents):** T1.1, T1.3, T1.4, T1.5, T1.6   (T1.2 after T1.1)
- **Wave 8 (2 agents):** T1.2, T1.7   -> then T1.8 dogfood
- **Wave 9 (3 agents):** T2.1, T2.2, T2.3   -> then T2.4 tests, T2.5 dogfood, T2.6 cutover

Slice 3+ (E3) is re-planned per item when reached; no fixed waves.

## Timeline and Milestones

| Milestone | Exit criteria | Depends on |
|-----------|---------------|------------|
| M0 Skeleton reaches production | T0.1-T0.12 done; D0 acceptance (live verified deploy) | -- |
| M1 Loop is trustworthy | T1.1-T1.8 done; D1 acceptance | M0 |
| M2 kazi can create + self-host | T2.1-T2.6 done; D2 acceptance | M1 |
| M3 Deepening underway | first E3 item built as a self-hosted kazi goal | M2 |

## Risk Register

| ID | Risk | Impact | Likelihood | Mitigation |
|----|------|--------|------------|------------|
| R1 | Loop oscillates (fix A breaks B) forever | High | High | Slice 1 regression detector + budget/stuck escalation (T1.2, T1.4, T1.5) |
| R2 | Flaky predicates poison the loop | High | Med | Re-run/quarantine (T1.3) before counting a fail as work |
| R3 | Vacuous goal "converges" having built nothing | High | Med | Vacuous-goal guard (T2.3); creation goals must have a predicate failing at t0 |
| R4 | `claude -p` interface drift breaks the adapter | Med | Med | Adapter behind a behaviour (T0.3/T0.6); stub binary in tests; harness-agnostic by design |
| R5 | Scope creep into a full SDLC platform | High | Med | ADR-0007: build a phase only when a slice needs it; convergence/maintenance is the defensible core |
| R6 | Self-hosting too early (kazi cannot yet build itself) | Med | Med | Cutover gated at T2.6; Slices 0-2 bootstrapped with existing skills |
| R7 | GCP/Cloud Run setup blocks the Slice 0 dogfood | Med | Med | T0.6h is `kind: human`, started at Wave 2; deploy action behind a stub (T0.10b) so all other E0 tasks proceed without it |

## Operating Procedure

Definition of done (all must hold): ExUnit tests written and green for the change;
`mix format --check-formatted` clean; PR merged to main via rebase with CI green;
for any user-facing/production surface, deployed to Cloud Run and verified live
there (a live probe passes), not staging-only; reported honestly (state what was
observed in production). Make many small focused commits; never commit files from
different directories in one commit. Add tests with every implementation task
(API/http_probe test for any endpoint, Playwright test for any UI).

## Progress Log

### 2026-06-21 -- Change Summary (revision 2)
- Revised the plan to make Slice 0 reach production (idea -> production walking
  skeleton). Added integrate (T0.10a, UC-020), deploy (T0.10b, UC-015), live
  http_probe (T0.5b, UC-011), and a deployable target fixture (T0.13) plus the
  GCP human task (T0.6h). State machine now decides non-agent actions
  (integrate/deploy), not just agent dispatch (T0.7).
- Fixed parallelism: behaviours defined first (T0.3) so providers/adapter/actions/
  loop build in parallel; added wiring task T0.7b. Wave 3 now saturates 8 agents.
- Fixed duplicate checkboxes: Waves reference task IDs only; the WBS is the single
  checkable source of truth.
- Closed under-specs: goal-file TOML schema + fixture (T0.4); target workspace as
  an explicit CLI arg (T0.10); fix lands via the integrate action (T0.10a).
- Amended `docs/adr/0007-build-strategy-walking-skeleton.md` (skeleton spans idea
  -> production; later slices deepen). Updated `docs/concept.md` build order.
  Updated `.claude/scratch/usecases-manifest.json` (added UC-020, UC-021; moved
  UC-011, UC-015 to Slice 0).
- No code yet. Next: Wave 1 (T0.1 scaffold), then drive E0 to M0.

### 2026-06-21 -- Wave progress (pool)
- Wave 1 DONE: T0.1 Elixir OTP scaffold merged (PR #3, `bc4ba8b`). Verified on main:
  `mix compile --warnings-as-errors` clean, `mix format --check-formatted` clean,
  `mix test` 2 passed. Toolchain: Elixir 1.20.1 / Erlang OTP 29 (Homebrew).
- Next: Wave 2 (T0.2 CI, T0.3 domain types+behaviours, T0.13 deployable fixture);
  kick off T0.6h (human, GCP) out-of-band.
- Wave 2 DONE: T0.2 (PR #4, CI green on PR + main), T0.3 (PR #6, core types +
  PredicateProvider/HarnessAdapter/Action behaviours, +Budget/+Scope helpers),
  T0.13 (PR #5, Go convergence fixture under fixtures/deploy-target/, isolated).
  Verified on main: compile clean (warnings-as-errors), format clean, 68 tests
  pass (18 doctests, 50 tests), CI green.
- Next: Wave 3 (8 agents): T0.4, T0.5, T0.5b, T0.6, T0.9, T0.7, T0.10a, T0.10b
  (all build against T0.3 behaviours). Reminder: T0.6h human task still open.
- Wave 3 DONE (all 8 merged, CI green): T0.4 goal loader+TOML (#11), T0.5
  test-runner provider (#7), T0.5b http_probe provider (#8), T0.6 claude -p
  adapter (#9), T0.9 SQLite read-model (#13), T0.7 convergence :gen_statem loop
  (#14), T0.10a integrate action (#12), T0.10b deploy action (#10). Verified on
  main: compile clean (warnings-as-errors, 21 lib files), format clean, 130 tests
  pass (18 doctests, 112 tests). Deps added additively: toml, ecto_sql,
  ecto_sqlite3, jason. Providers/adapter/actions implement the T0.3 behaviours;
  loop is real :gen_statem (no hex dep). Components built against contracts/doubles
  — not yet assembled (that is T0.7b).
- Next: Wave 4: T0.7b (wire real components into the loop), T0.8 (objective-
  termination guard) in parallel; then T0.10 (CLI) after T0.7b so the CLI wires
  the real runtime (avoids a stubbed CLI). T0.6h (human GCP) still gates T0.12.
- Wave 4A DONE: T0.8 termination guard (#15) + T0.7b runtime wiring (#16), CI
  green, loop.ex changes composed cleanly (T0.7b additive on T0.8's guard).
  Verified on main: compile clean, format clean, 135 tests (18 doctests, 117).
  Guard: `Kazi.PredicateVector.satisfied?/1` is the only path to :converged
  (live predicate blocks success). Runtime: `Kazi.Runtime.run/2` wires real
  providers (`:tests`→TestRunner, `:http_probe`→HttpProbe), claude adapter,
  integrate+deploy actions, and per-iteration SQLite persistence. End-to-end
  wire check PASS: example goal kinds covered by runtime dispatch.
- Wave 4B: T0.10 CLI `kazi run <goal-file> --workspace <path>` over Kazi.Runtime.
  Then Wave 5 (T0.11 full-loop integration test), Wave 6 (T0.12 dogfood, gated on
  human T0.6h). T0.6h (GCP) STILL OPEN — blocks T0.12 only.
- Wave 4B DONE: T0.10 CLI (#17), CI green. `mix kazi.run` + an escript `kazi`
  (main_module Kazi.CLI). Exercised: --help; exit codes (usage→2, bad goal→1,
  help→0); example goal loads. Escript can't bundle the SQLite NIF → degrades to
  no-persistence with a warning (use `mix kazi.run` for persistence). 148 tests
  on main (18 doctests, 130 tests). WAVE 4 COMPLETE.
- Next: Wave 5 (T0.11 full-loop integration test, deploy+probe stubbed) — single
  agent. Then Wave 6 T0.12 dogfood is BLOCKED on human T0.6h (GCP/Cloud Run) +
  real harness; the autonomous loop drives everything through T0.11.
- Wave 5 DONE: T0.11 full-loop integration test (#18), CI green. test/kazi/
  full_loop_test.exs drives real Runtime→Loop→providers→actions→SQLite with
  harness/deploy/probe stubbed; hermetic (no Go, no network); proves the T0.8
  live-gate (no converge while live probe red). 150 tests on main. SLICE 0 (E0)
  CODE-COMPLETE — only T0.12 dogfood remains, BLOCKED on human T0.6h (GCP).
- Slice 1 (E1) started while T0.12 waits on the human: T1.1 (vector history) +
  T1.6 (prod-log provider) dispatched first (no mutual conflict); loop-touching
  T1.2/T1.3/T1.4/T1.5 sequenced after T1.1 to avoid loop.ex contention. T0.11 is
  the regression guard for all Slice-1 loop changes.
- Slice 1 COMPONENTS DONE: T1.1 history (#19), T1.6 prod-log (#20), T1.3 flake/
  quarantine (#21), T1.4 budget ceiling (#22), T1.5 stuck+escalation (#23), T1.2
  regression detector (#24). All four loop detectors (Budget, Flake, Stuck,
  Regression) compose in loop.ex via keep-both merges (verified: no silent
  revert; snapshot exposes quarantine/budget_reason/regressions). 266 tests on
  main (33 doctests, 233 tests), CI green.
- Next: T1.7 (cross-cutting ExUnit tests for all Slice-1 features), then T1.8
  (hermetic Slice-1 dogfood: naive fix regresses another predicate -> detect +
  escalate; record in devlog). Slice 1 completes fully autonomously (no GCP).

### 2026-06-21 -- Change Summary (revision 1)
- Created the initial walking-skeleton plan (E0-E3, use-case manifest, ADR-0007).

## Hand-off Notes

- Read `docs/concept.md` and ADRs 0001-0007 before starting; the design is frozen
  there and must not be relitigated in the plan.
- Slices 0-2 are built with the existing Claude Code skills. From T2.6 onward,
  build E3 items as kazi goals (failing acceptance predicates) -- kazi builds kazi.
- Slice 0 spans idea -> production: the dogfood (T0.12) must reach a LIVE verified
  Cloud Run deployment, not just green tests.
- T0.6h (GCP/Cloud Run provisioning) is the one human task and gates T0.12; start
  it early. The deploy action is behind a stub (T0.10b) so the rest of E0 proceeds
  without it.
- NATS and Phoenix LiveView are NOT dependencies until Slice 3.

## Appendix

- Concept and architecture: `docs/concept.md`
- Decisions: `docs/adr/0001`..`0007`
- Use-case manifest: `.claude/scratch/usecases-manifest.json`
