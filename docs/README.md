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

## Guides — drive kazi

- **[Orchestrator recipe](orchestrator-recipe.md)** — the full `--json`
  propose → approve → converge flow an orchestrating agent drives kazi through
  (the source of truth the installed skill teaches).
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

## Reference

- **[`--json` result schemas](schemas/run-result.md)** — the versioned terminal
  result for `kazi apply`. Pin `schema_version`.
  - [`status` schema](schemas/status.md) — the `kazi status --json` read.
  - [Collective result schema](schemas/collective-result.md) — the parallel /
    multi-goal result.
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
