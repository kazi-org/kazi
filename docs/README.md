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
- **[Live providers](live-providers.md)** — `http_probe` sustained health,
  `:metrics` (RED / SLO burn-rate), and the synthetic-journey monitor (ADR-0043).
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
- **[`--json` signals → skill-side escalation](tiering-signals.md)** — how the
  structured output triggers adaptive model tiering.
- **[Deprecations & removal schedule](deprecations.md)** — removed verbs and the
  versions that removed them.
- **[OSS contribution gates](oss-gates.md)** — the docs-with-code and no-leak
  gates every change clears.
- **[Doc-freshness predicate set](doc-freshness.md)** — the runnable checks that
  keep these docs from drifting.

## Decision records

- **[ADRs](adr/README.md)** — the frozen architecture decisions. To change a
  decision, write a superseding ADR; do not relitigate one in passing.

## Knowledge tiers

These are append-only / live working records, not user-facing guides:

- **[plan.md](plan.md)** — the live build plan (the WBS unit of execution).
- **[devlog.md](devlog.md)** — append-only session history and findings.
- **[lore.md](lore.md)** — invariants and landmines.
- **[research/](research/)** — research syntheses that feed the plan.
