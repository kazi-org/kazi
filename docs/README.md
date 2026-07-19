# kazi docs

kazi is the **outer/reconciliation loop for coding agents**: declare a goal as
machine-checkable acceptance predicates, and kazi drives a coding agent in a loop
until those predicates are objectively true, stuck, or over budget.

New here? **Start with the Quickstart**, then reach for the reference pages as you
need them.

## Start here (tutorial)

- **[Quickstart](quickstart.md)** — wire kazi into Claude Code (`kazi
  install-skill`) and converge one real goal end-to-end, agent-first. The fastest
  path from zero to objective "done".

## Understand the system

- **[Concept & architecture](concept.md)** — the canonical source of truth: what
  kazi is, the goal contract, the convergence loop, the coordination model, and
  the build order.
- **[Dogfood "done" methodology](dogfood-methodology.md)** — how every number in
  the [Proof gallery](https://kazi.sire.run/proof) was produced (goal, command,
  version, captured result), so each converged case is reproducible.

## Guides — drive kazi

- **[Orchestrator recipe](orchestrator-recipe.md)** — the full `--json`
  plan → approve → converge flow an orchestrating agent drives kazi through
  (the source of truth the installed skill teaches).
- **[`AGENTS.md`](../AGENTS.md)** — the harness-neutral one-page brief any coding
  agent reads to drive kazi (`kazi plan` → `kazi apply`), independent of the Claude
  Code skill.
- **[Add a harness](add-a-harness.md)** — point kazi at `opencode`, `codex`, or
  your own CLI coding agent; the harness tier table.
- **[Self-hosting: kazi builds kazi](self-hosting.md)** — kazi dogfooding itself.

## Guides — pooled / parallel runs

- **[The `acc:` → predicates bridge](acc-predicates-bridge.md)** — kazi-gated
  `/apply --pool`.
- **[Drive kazi for a pooled task](drive-kazi-pooled-task.md)** — the orchestrator
  recipe at the per-task (L2) level.
- **[Per-task model tiering in the pool](pool-model-tiering.md)** — the
  cheap-inner-loop recipe.
- **[The pool verification gate](pool-verification-gate.md)** — the kazi-gated
  merge.
- **[Per-task blast-radius lease](pool-blast-radius-lease.md)** — leasing a pooled
  run's blast radius.
- **[Claim ↔ kazi-lease compose boundary](pool-claim-lease-deadlock-safety.md)** —
  deadlock safety where `/claim` meets a kazi lease.

## Predicate providers

How to declare each kind of acceptance predicate. Every kind also self-describes
its config at runtime via `kazi schema <kind>`.

- **[`custom_script`](custom-script-provider.md)** — the generic command-runner:
  turn any CLI checker into a predicate via a declared verdict (ADR-0040).
  - **[`custom_script` recipe catalog](custom-script-recipes.md)** — off-the-shelf
    recipes (contract/perf/secret/a11y/IaC/visual), the two evidence tiers, and
    the per-tool exit-code gotchas.
- **[`ratchet`](ratchet-predicate.md)** — the no-regression mode: a metric stays
  within an allowed regression of a baseline (ADR-0041).
- **[`static`](static-predicate.md)** — analysis / type-check / lint, Dialyzer-led
  + polyglot SARIF; a baseline ratchet on new findings (ADR-0043).
- **[`coverage`](coverage-predicate.md)** — patch coverage meets a target AND
  project coverage does not regress (ADR-0043).
- **[`property`](property-predicate.md)** — property-based testing (PropCheck
  under `mix test`); the shrunk counterexample as evidence (ADR-0043).
- **[`mutation`](mutation-predicate.md)** — mutation testing: a 0-1 score gated on
  a threshold (never 100%), surviving mutants as evidence (ADR-0043).
- **[`cve`](cve-predicate.md)** — dependency vulnerability scanning: `govulncheck`
  reachability (call stack as proof) + manifest scanners ratcheted (ADR-0043).
- **[`swift_test`](swift-test-predicate.md)** — Swift/XCTest suite verdicts read
  from an Xcode `.xcresult` bundle, gated on the parsed pass/fail/zero-tests
  counts rather than the exit code (issue #1406).
- **[`no_stubs`](no-stubs-predicate.md)** — the zero-stub gate: fail when the
  diff-vs-base adds a stub/placeholder marker to a production (non-test) file, with
  file:line evidence (T44.6).
- **[`docs_updated`](docs-updated-predicate.md)** — the docs-land-with-code gate:
  fail when a user-facing surface change ships without a docs update or a
  `[no-docs]` marker (T44.8, ADR-0034).
- **[`cli`](cli-provider.md)** — a golden invocation of a shipped binary: run a
  declared command and assert on the exit code + stdout/stderr (T43.7, UC-055).
- **[`scenario`](scenario-predicate.md)** — replay a pinned Gherkin Scenario by
  delegating to a surface provider; passes only on a green replay (ADR-0064).
- **[`gherkin`](gherkin-provider.md)** — reconcile a whole `.feature` at run time:
  one `[[predicate]]` expands at goal-load into one sub-predicate per Scenario
  (per Examples row for an outline), each reading its verdict from a shared BDD
  runner's cucumber-json, run once per feature per pass and ingested natively
  (ADR-0071). The runtime sibling of the author-time `spec import` (ADR-0064).
  Introspect every key with `kazi schema gherkin`.
- **[`plan_expanded`](schemas/roadmap.md)** — the read-model-only "phase has been
  planned" gate (exists + floor-passed + approved); makes planning a convergeable
  goal via outline phases (E45/T45.3).
- **[`oss_hygiene`](oss-hygiene-predicate.md)** — the internal-leak guard as a
  predicate: scan the diff's added lines for private IPs / home paths /
  configurable codenames (E29/ADR-0034, T44.7).
- **[`spec_coverage`](spec-coverage-predicate.md)** — manifest coverage: every
  scanned surface element is referenced by ≥1 Scenario across the product's
  `.feature` specs; a `:fail` names each undocumented element (T41.3, ADR-0050/0054).
- **[`render_proof` + capture recipes](capture-recipes.md)** — controller-owned
  `[[capture]]` screenshots so a UI goal proves pixels, not file presence: the
  controller runs the recipe each observe pass into a run-keyed evidence store the
  worker cannot write, and `render_proof` fails a blank/crash frame (ADR-0081).
- **[`visual_judge`](visual-judge-predicate.md)** — pinned strong-model judgment
  of a capture against a hashed rubric + optional sealed reference: itemized
  pass/fail (critique-as-red-detail), never a beauty score (T68.8, #1522).
- **[Live providers](live-providers.md)** — `http_probe` sustained health,
  `:metrics` (RED / SLO burn-rate), and the synthetic-journey monitor (ADR-0043).
- **[Browser assertions](browser-assertions.md)** — the full `browser` predicate
  `assertions[].type` reference (`console_clean`, `a11y`, `visual`,
  `form_validation`, … 13 types) with examples, matching `kazi schema browser`
  (E43/UC-056).
- **[The context store (Gist provider)](context-store.md)** — budget-fitted
  retrieval over heavy text artifacts; the `gist` CLI adapter, `KAZI_GIST_DSN`
  persistence, and graceful degradation when `gist` is absent.

## Reference

- **[`--json` result schemas](schemas/run-result.md)** — the versioned terminal
  result for `kazi apply`. Pin `schema_version`.
  - [`status` schema](schemas/status.md) — the `kazi status --json` read.
  - [Collective result schema](schemas/collective-result.md) — the parallel /
    multi-goal result.
- **[Run-economics history (`kazi economy`)](economy.md)** — persisted
  run-end economics (ADR-0058) aggregated into p50/p95 percentiles by goal
  shape/model/harness; the grouping T48.9's learned budget proposals reuse.
- **Convergence cost/token table (T60.5, #1070)** — the human-readable
  (non-`--json`) terminal report on `kazi apply` convergence/budget-exhaustion
  now prints a per-goal table (iterations, cost, predicates pass/total) plus a
  token breakdown line (input/output/cached/cache_write), one row per goal for
  both single-goal `apply` and `apply --fleet`. Sourced from the SAME
  `Kazi.Economy.KPIs`/harness-reported usage data `--json`'s `economy`/`usage`
  objects already carry — purely additive terminal UX, `--json` output is
  unaffected. Skipped when the harness reported no usage at all
  (honest-unknown, never a fabricated `$0.00` row).
- **Orphaned dispatch reaping (`kazi orphans`)** — lists every run whose
  recorded harness child process is STILL alive (a dispatch that outlived its
  controller, issue #1073/#857); read-only by default, `--reap` sends TERM then
  KILL to each orphaned process group, `--json` for the machine surface. The
  primary guard is automatic: `Kazi.Runtime.ParentMonitor` watches the burrito
  launcher and halts the BEAM if it is killed, so the existing per-dispatch
  watchdog reaps `claude` even when the terminal (not the BEAM) receives the
  signal. `orphans` is the manual sweep for pids that predate that guard.
- **Portfolio sitrep (`kazi portfolio`)** — the answer to "where are we / how is
  it going?" (E64, #1427; v1 was T60.4/#1160). The output opens with ONE headline
  line of counts and integer percentages across the five buckets — **done**,
  **in-progress**, **blocked**, **todo**, **planned** — e.g. `done 62% (13) |
  in-progress 14% (3) | blocked 10% (2) | todo 10% (2) | planned 5% (1)`. The
  buckets map to objective sources (ADR-0011), nothing hand-set: **planned** =
  proposals awaiting approval; **todo** = approved proposals with no registered
  run yet (ready to dispatch); **in-progress** = registry runs with a fresh
  heartbeat; **blocked** = runs that are stuck, over budget, or waiting on an
  unconverged/poisoned roadmap-DAG dependency (`DagSnapshot`'s `:blocked`, the
  same computation Mission Control's roadmap mode folds); **done** = terminal
  converged. Percentages use largest-remainder rounding and always sum to 100; an
  empty portfolio prints `nothing tracked yet`, never a divide-by-zero. Each
  bucket then renders a bounded summary — its top-3 one-liners plus `+N more` —
  and **every blocked entry names its blocker** (the persistently-red predicate
  slice, the iterations/cap, or the dep id). Pass `--full` to restore the
  complete per-bucket ledger. "How is it going" is answered as honest **rate**
  data — predicates green/total and red→green movement over recent iterations
  (in-progress entries append e.g. `preds 5/8, +2 this run`, plus a fleet-wide
  rate line) — and is **NEVER a projected date or ETA** (ADR-0046): kazi reports
  what it objectively knows, and a schedule is not one of those things. Composed
  ONLY from kazi's own surfaces (`Kazi.Portfolio`) — proposals, the run registry,
  the attention queue (ADR-0057), the roadmap DAG, and the cross-machine bus facts
  T60.1's `Kazi.Runtime.BusMirror` posts; local runs are grouped by repo,
  proposals and cross-machine runs reported fleet-wide. `--json` gains `totals`,
  `todo`, `blocked` (with causes), and `rate` additively next to the v1 keys;
  `schema_version` stays 2, so v1 consumers are byte-unaffected.
- **[`--json` signals → skill-side escalation](tiering-signals.md)** — how the
  structured output triggers adaptive model tiering.
- **[Deprecations & removal schedule](deprecations.md)** — removed verbs and the
  versions that removed them.
- **[OSS contribution gates](oss-gates.md)** — the docs-with-code and no-leak
  gates every change clears.
- **[Doc-freshness predicate set](doc-freshness.md)** — the runnable checks that
  keep these docs from drifting.

## Essays & growth

- **[Essays](essays/README.md)** — one evergreen deep-dive per significant
  shipped feature, held fresh by a kazi standing goal
  (`essays/essays.goal.toml`): coverage and staleness are machine-checked, so
  the tier cannot silently rot.
- **[Growth strategy](marketing/strategy.md)** — the public, research-grounded
  plan for kazi's adoption, with a two-page
  [executive summary](marketing/strategy-summary.md), the
  [launch plan](marketing/launch-plan.md), the ready-to-paste
  [launch kit](marketing/launch-kit.md), and the
  [operator task list](marketing/operator-tasks.md).

## Decision records

- **[ADRs](adr/README.md)** — the frozen architecture decisions. To change a
  decision, write a superseding ADR; do not relitigate one in passing.

## Knowledge tiers

These are append-only / live working records, not user-facing guides:

- **[plan.md](plan.md)** — the live build plan (the WBS unit of execution).
- **[devlog.md](devlog.md)** — append-only session history and findings.
- **[lore.md](lore.md)** — invariants and landmines.
- **[research/](research/)** — research syntheses that feed the plan.
