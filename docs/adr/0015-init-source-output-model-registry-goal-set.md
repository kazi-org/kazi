# ADR 0015: Withdraw the capability-registry adapter; a future spec importer instead

## Status
Accepted (supersedes the registry-adapter decision this ADR originally recorded)

## Date
2026-06-22

## Context

An earlier revision of this ADR (accepted the same day) decided to extend `kazi
init` with a **registry adapter + goal-set output**: consume a machine-readable
capability catalog (`capabilities.json` — one row per capability, each with a
declared test binding) and emit one goal-file per capability. It shipped briefly
(`Kazi.Adopt.Registry`, a `kazi init --registry` CLI mode, a goal-set writer).

On review, before any public release, the motivating input did not generalize.
`capabilities.json` is a **bespoke artifact of one internal product**, not a
format the wider world produces. ADR-0013's stack detection maps marker files
that *every* repo has; a registry adapter only helps the handful of projects that
already keep a hand-maintained capability catalog in this exact shape. Defining a
"minimal generic contract" did not fix that — a contract only one consumer
produces is still an audience of one. For an open-source v1, a `--registry` flag
whose input nothing public generates is a liability: "what produces these files?"
has no good public answer.

## Decision

1. **Remove the registry adapter from `kazi init`.** Delete `Kazi.Adopt.Registry`,
   the `--registry` CLI mode, the goal-set writer path, the `capabilities.json`
   fixture, and the registry tests. The original goal-set/registry decision
   recorded in this ADR is **withdrawn**.

2. **Keep what generalizes.** `kazi init <repo-dir>` (deterministic stack
   detection, ADR-0013) stays — it is universal. The goal-file *writer*
   (`Kazi.Adopt.to_toml/1`) and the `init` verb stay; they are general and used by
   the stack-detection path.

3. **Defer the multi-goal "import a spec" idea to a standard format.** If importing
   an existing machine-readable description of behavior into a kazi goal set is
   worth building, the generalizable input is a **widely-adopted spec**, not a
   bespoke catalog: an OpenAPI document (paths/operations → `http_probe`
   predicates) or Cucumber/gherkin feature files (scenarios → acceptance
   predicates). That is a different, larger feature and gets **its own ADR** when
   there is real demand. It is recorded as deferred backlog in `docs/plan.md`
   (UC-025), not built now.

## Consequences

Positive: the open-source surface ships only what generalizes; no `--registry`
flag pointing at a format nobody outside one product produces. Less code to
maintain. The adoption story stays crisp: `kazi init <repo>` for any repo,
`kazi propose "<idea>"` for new work.

Negative: projects that *do* keep a capability catalog lose the one-shot import
(they can still hand-write goal-files or use `kazi propose`). The goal-*set*
machinery (emit N goal-files) is removed with the registry, since stack detection
produces a single goal and nothing general drove a set; a future spec importer
would reintroduce it deliberately.

## Relationship to other ADRs

- Refines [ADR-0013](0013-adopt-reverse-engineer-goals.md): `kazi init` keeps its
  single deterministic source (stack detection) and single-goal output. This ADR
  reverses the second-source / goal-set extension that was briefly layered on top.
