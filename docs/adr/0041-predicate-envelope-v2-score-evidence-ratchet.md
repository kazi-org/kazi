# ADR 0041: Predicate envelope v2 — graded score, structured evidence, and a first-class ratchet mode

## Status
Accepted

## Date
2026-06-24

## Refines
ADR-0002 (the goal contract / `{pass, evidence}` provider result). This ADR enriches
the provider RESULT shape (not the goal contract's intent) and adds a predicate MODE.
The convergence gate is unchanged: `:converged` still requires the whole vector
`:pass`.

## Context

Predicate results today are effectively boolean (`:pass | :fail | :error | :unknown`)
with provider-shaped evidence, much of it raw stdout. The research note
(`docs/research/predicate-verification-landscape.md`) finds two framework changes
that improve EVERY checker — existing, new, and user-written — more than any single
new provider:

1. **Boolean is a sparse reward.** A flat pass/fail tells the agent WHETHER it is
   done, not whether the last edit moved CLOSER. This is the RL sparse-vs-dense-reward
   result (Ng/Harada/Russell 1999 potential-based shaping; HER, Andrychowicz 2017),
   and SWE-bench independently reinvented partial credit ("Fix Rate" = fraction of
   FAIL_TO_PASS tests fixed) because the binary Resolved Rate "obscures meaningful
   partial progress." Most checkers ALREADY compute a scalar (47/50 tests, mutation
   0.82, coverage 81%, Lighthouse 0-100, axe violation count) — kazi discards it.

2. **Raw stdout is poor fix-context.** A checker returning 5KB of log is far worse
   for an automated fixer than one returning the failing test name + `file:line` +
   expected-vs-got. The reference shapes are SARIF (static findings), JUnit XML
   (test results), and the LSP `Diagnostic` (any line-localized finding).

A third observation unifies several would-be providers: coverage, perf, binary/bundle
size, and lint-finding-count are all the SAME predicate — `signal vs baseline within
an allowed regression`. Google ("coverage is guidance, not a goal") and Codecov
("patch > project") both warn absolute thresholds block the walking skeleton and are
gameable via the denominator. The ratchet should be built once, not per provider.

## Decision

1. **Provider results carry `{pass, score, prior_score, direction, evidence[]}`.**
   `score` is an optional float (provider-defined meaning); `direction` is
   `:higher_better | :lower_better` so the controller knows which way is progress
   WITHOUT hardcoding per-provider knowledge (mutation score is higher-better; a
   lint-finding count is lower-better). `prior_score` is the same predicate's score
   from the previous iteration (the controller threads it). `evidence[]` is a list of
   structured items. Boolean predicates set `score = nil` and behave exactly as today
   — fully back-compatible.

2. **The score feeds progress detection, never the convergence gate.** `:converged`
   still requires every predicate `:pass` (ADR-0002 / the objective-termination
   guard is untouched). The score delta (interpreted via `direction`) is a SIGNAL the
   loop uses to classify an iteration as progressing / stalled / regressed, and that
   the stuck-detector (T1.5) and the ADR-0035 skill escalation consume. A score that
   improves but has not crossed the threshold is "progressing," not "done."

3. **Evidence items adopt a standard envelope.** An evidence item is
   `{file, line, col, rule, level, message, expected, got}` (LSP-Diagnostic-shaped);
   providers map SARIF / JUnit XML / shrunk-counterexample data onto it. Raw stdout is
   kept only as a truncated fallback. This is shared with the `custom_script` parser
   (ADR-0040).

4. **Add a `ratchet` predicate mode.** A predicate may declare
   `mode = "ratchet"` with `metric`, `baseline` (a git ref or stored prior value),
   and `allowed_regression`. It passes iff `signal - baseline <= allowed_regression`,
   and reports `score = signal`. Coverage, perf, and size predicates are instances of
   this one mode. The baseline-comparison machinery (resolve baseline, diff-scope,
   store the new value) is built once and reused. The ratchet doubles as an
   anti-gaming guard (coverage/test-count may only improve — ADR-0042).

5. **`schema_version` bumps NON-BREAKINGLY (a minor bump); the JSON result contract
   documents `score`/`prior_score`/`direction`/structured `evidence`.** The fields are
   ADDITIVE and optional — absent fields default to today's shape — so this is a
   compatible minor bump, NOT a v2.0.0 trigger and not a break for an orchestrator
   pinning the contract. The self-conformance test (T15.7) and the `--json` emitter are
   updated.

## Consequences

- The stuck-detector and the ADR-0035 escalation get a real gradient instead of a
  boolean, so "the loop is making slow progress" is distinguishable from "the loop is
  stuck" — fewer false escalations, fewer missed ones.
- Fixer agents get localized, minimal, actionable evidence — fewer iterations to fix.
- Coverage/perf/size stop being three bespoke providers and become three configs of
  one ratchet mode (ADR-0043 leans on this).
- Risk: a misleading score (a proxy the agent can inflate without improving the true
  goal — e.g. assertion-free tests lifting line coverage) re-introduces reward
  hacking through the gradient. Mitigation: prefer scores that resist gaming (mutation
  score over raw line coverage) and keep the THRESHOLD measuring the true goal; the
  gate, not the gradient, is authoritative. Cross-references ADR-0042.
- Risk: envelope mapping is per-provider work. Bounded — three shapes (SARIF / JUnit /
  LSP) cover nearly everything; the `custom_script` parser is shared.

## Alternatives rejected

- **Keep boolean-only.** Simplest, but throws away the gradient the controller needs
  and the structured evidence the fixer needs — the two cheapest wins in the research.
- **Scalarize the whole vector into one number.** Hides which predicate regressed and
  invites trading a passing predicate for a failing one. kazi already tracks a
  per-predicate VECTOR (ADR-0002); the score is PER-PREDICATE, and Pareto-style "no
  predicate worse, at least one better" stays the progress rule.
- **Make `score` mandatory.** Many predicates are honestly boolean (a secret either
  leaked or it didn't); forcing a score invents noise. `score` is optional.
