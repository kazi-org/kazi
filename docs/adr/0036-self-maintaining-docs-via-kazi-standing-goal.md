# ADR 0036: Self-maintaining docs -- plan trim + freshness as a kazi-reconciled standing goal

## Status
Accepted

## Date
2026-06-24

## Context

The plan (`docs/plan.md`) is kazi's `goal.toml`: the executable spec the
`/apply` loop reconciles against. Two failure modes degrade it as a real project
grows:

1. **Plan bloat.** Completed epics/tasks accumulate in the *live* plan. kazi's own
   `plan.md` is already 1,142 lines and monolithic. A bloated plan inflates the
   context every `/apply` dispatch carries (a direct token cost, cf. ADR-0033/0035)
   and buries the live frontier under finished work.

2. **Doc staleness.** The stable docs (`concept.md`, `lore.md`, `devlog.md`, ADRs)
   drift from a moving codebase. Stale orientation makes agents reason from wrong
   context -- the exact failure kazi's objective predicates are meant to prevent.

Existing machinery is fragmented and unreliable: `/plan` step-0 trim, `/tidy
--trim`, `/lint`, `/audit-docs`, `/ingest`, and ad-hoc coherence CI (README<->site
T9.9, skill<->CLI T16.4). All are LLM-driven, manually triggered, unenforced, and
the trim is lossy (knowledge routing is judgment-heavy with no safety net).

The insight (operator, 2026-06-24): since the plan IS the goal spec, apply kazi's
own thesis -- machine-checkable predicates + reconciliation -- to the docs
themselves. Make trim and freshness a kazi-reconciled standing goal. This is the
flagship dogfood, not scope-creep.

## Decision

Adopt a three-layer, kazi-reconciled documentation lifecycle. The trim/extraction/
freshness LOGIC lives in the skill + CI predicate layer; kazi only DRIVES it as a
goal (the core stays an unopinionated controller -- the ADR-0023/0033/0035 line).

1. **Layer 1 -- deterministic structural trim (mechanical, lossless).** A script
   (not an LLM) archives an epic out of the live plan ONLY when it is 100% `[x]`
   AND covered by a release tag. The epic block moves verbatim to an append-only,
   git-tracked ledger (`docs/plan-archive.md`, or its epic file under the split
   layout), leaving a one-line pointer in `plan.md`. Idempotent and reversible.

2. **Layer 2 -- gated knowledge extraction (LLM, propose-then-confirm).** AFTER
   Layer 1 has preserved the raw block, the LLM lifts only durable nuggets to the
   correct tier (the `/ingest` pattern). Because the archive already holds
   everything verbatim, a routing mistake never LOSES knowledge.

3. **Layer 3 -- freshness as predicates (the enforcement).** A machine-checkable
   doc-freshness predicate set, run in CI, that fails the build on drift:
   every shipped command appears in README + `help --json`; no doc names a symbol
   absent from the code; every referenced ADR exists; no `[x]` task older than the
   last release remains in the live plan; the existing README<->site (T9.9) and
   skill<->CLI (T16.4) coherence checks fold in. Start warn, ratchet to blocking
   (the E29 gate pattern).

4. **The kazi tier mapping is fixed (resolves a latent inconsistency).** The
   generic `/plan` trim assumes a `docs/design.md`; kazi has none and uses
   `concept.md` as canonical architecture. kazi's tiers are: **architecture ->
   `concept.md`**, **decisions -> `docs/adr/`**, **operations/findings ->
   `devlog.md`**, **invariants/landmines -> `lore.md`**, **raw completed plan ->
   `plan-archive.md`**. No `design.md` is introduced.

5. **The whole lifecycle is a kazi STANDING goal.** "The plan is trimmed and the
   docs are fresh" is encoded as a standing reconciliation goal kazi runs
   continuously, rather than a `/tidy` a human must remember. Layer 1 + Layer 3 are
   safe to automate (mechanical / checkable); Layer 2 keeps the human-confirm gate.

6. **kazi core gains no doc-specific logic.** The derail -- a bespoke doc engine
   inside kazi -- is rejected; the predicates/actions live in the skill + CI layer.

## Consequences

- The live plan stays small: cheaper `/apply` context (token economy) and a clear
  frontier. The archive preserves the full history, git-diff-able.
- Doc drift becomes a red build, not a slow rot; agents orient from fresh context,
  reducing wrong-context iterations (quality + productivity).
- kazi proves its thesis on its hardest target -- its own docs -- a durable,
  honest dogfood (and an on-brand growth artifact, cf. ADR-0030).
- Risk: the trim mis-judges "released" and archives in-flight work. Mitigated by
  requiring all-`[x]` AND a release tag, and by the archive being append-only +
  reversible (git).
- Risk: freshness predicates are too strict and CI thrashes. Mitigated by
  warn-then-ratchet and scoping predicates to shipped surfaces.
- Risk: an autonomous standing goal churns docs. Mitigated by objective
  convergence (predicates), Layer 2's human-confirm gate, and budget/stuck limits.

## Alternatives rejected

- **Keep the manual `/tidy` + `/plan` trim.** Status quo: unreliable, lossy,
  unenforced, never run on time. The operator reports it "not working very well."
- **Build a documentation engine into kazi core.** Derails kazi from a pure
  controller into a doc tool; rejected (logic stays in skill/CI, kazi drives).
- **Pure-LLM trim with no deterministic layer.** The lossy failure mode that makes
  the current process untrustworthy; Layer 1 must be mechanical and lossless.
- **One combined doc instead of tiers.** Loses the architecture/decision/operations
  separation that keeps each doc stable and greppable (the wiki discipline).
