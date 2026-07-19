# ADR 0058: Economy feedback loop -- persisted run economics, learned budgets, behavior-first prompt improvement, and honest budget stops

## Status

Accepted

## Date

2026-07-07

## Context

An investigation of every `over_budget` run in a live operator read-model (54
finished runs) found that the budget ceiling is doing the wrong job. Of the 5
`over_budget` outcomes, 2 were intentional test fixtures and all 3 diagnosable
real cases were **mislabeled error-wedges**, not genuine budget exhaustion:

- One run fixed all failing code predicates in a single dispatch, then spun 39
  no-op observe ticks in ~71 seconds while one predicate sat in `:error`, until
  `max_iterations` tripped.
- Another run fixed all 8 code predicates in one dispatch, then burned
  iterations 1..40 in ~52 seconds against a live `http` predicate that errored
  `missing_url` on every observation -- a config error knowable at goal-load.

Structural gaps behind this:

1. The persistent-`:error` detector (`error_stuck?`, M5) is fed `code_history`,
   which drops live-kind predicate ids -- a live predicate erroring forever is
   invisible to it, and the no-work decide clause treats it as "legitimately
   pending, keep polling".
2. There is no error permanence taxonomy: `missing_url` (permanent, can never
   pass) and a probe timeout (transient) are both bare `:error`.
3. The terminal label lies: an operator seeing `over_budget` raises the budget,
   which is exactly wrong for a config error.
4. Iterations are budgeted as uniform-cost, but a no-op observe tick and a
   full agent dispatch differ by ~100x in cost.
5. A `max_tokens` ceiling is silently unbounded when the harness reports no
   usage (the loop counts unreported usage as 0; the `claw` profile reports no
   tokens by design). This violates the ADR-0046 honest-unknown discipline at
   the budget gate.
6. Budgets are hand-authored round numbers (500k-1.5M tokens) with no data
   feedback: run-end economics (`budget_spent`) exist only in the in-process
   terminal result and are never persisted, so kazi cannot learn budgets from
   history.

Separately, the operator wants kazi to improve its own dispatch prompting
(what context to provide) over time. ADR-0046 (T34.x) already records the raw
signals -- per-iteration `context` and `tools` counters, usage splits with
`usage_fidelity`, and a pure KPIs fold -- but nothing consumes them, and naive
"ask the model what it needed" self-report is confabulation-prone and a gaming
surface (cf. the T32.5 diff guard).

## Decision

Close the loop in four parts, all local-first (the shared SQLite read-model;
NO phone-home telemetry -- this is a public OSS repo):

1. **Persist run-end economics.** At terminal projection, write to the
   read-model per run: `budget_spent` (raw tokens, cached input tokens,
   cost USD, dispatch count), terminal outcome plus cause class, harness /
   model / context tier, and goal shape (predicate count and kind histogram).
   ADR-0046 honest-unknown discipline holds: unreported values persist as
   NULL, never 0.

2. **Learned budget proposals.** `kazi plan` and `kazi adopt` SUGGEST
   `[budget]` values derived from percentiles of similar past runs (grouped by
   goal shape, model, harness) with explicit provenance ("learned from N
   runs, p95 x 1.5"). Suggestions are proposals the human approves -- kazi
   never silently applies a learned budget. With no usable history, behavior
   is unchanged (no fabricated numbers).

3. **Behavior-first prompt improvement, benchmark-gated.** Three tiers, in
   trust order:
   - *Behavior* (trusted): aggregate the T34.3 `tools` counters across a
     goal's dispatches to detect repeated file-reads/searches -- measured
     rediscovery -- and emit orientation-pack / retrieval-cache CANDIDATES
     (report-only).
   - *Self-report* (hypothesis only): an opt-in post-dispatch debrief question
     ("list files/facts you needed but had to discover yourself", capped
     structured output) stored as prompt-variant hypotheses. A debrief answer
     NEVER mutates a prompt directly -- self-report is confabulation-prone and
     letting the inner agent shape its own future instructions is a gaming
     channel (same threat class as T32.5).
   - *Benchmark gate* (the only path to shipping): a prompt/context variant
     ships only when the E19/T34.7 benchmark rig shows a measured reduction in
     tokens-to-converge or iterations on the fixture set.

4. **Budget honesty.**
   - Live predicate required config is validated at goal-load: an `http`
     (or browser) predicate without its required `url` fails loudly at load,
     naming the predicate -- never at iteration 40.
   - Error reasons carry a permanence class: permanent (`missing_url`,
     `:no_provider`, missing required config) versus transient (timeouts,
     connection failures); unknown reasons default transient. A persistent
     permanent error terminates promptly as a named `:stuck` (the predicate
     and reason in the result); transient errors keep the existing bounded
     backoff polling. The persistent-error detector covers LIVE predicates,
     not just code history.
   - Terminal results carry a cause class alongside the outcome --
     genuine budget exhaustion vs `error_wedged` (with the erroring ids and
     reasons) vs quarantine-blocked -- surfaced in the CLI, read-model, and
     dashboard, so the operator's next move is never "raise the budget" on a
     config error.
   - When `max_tokens` is set and a dispatch reports no usage, the loop warns
     loudly (once per run) and records the degraded fidelity -- a ceiling that
     cannot bind must say so.
   - `max_dispatches` becomes a first-class budget dimension counting
     `:dispatch_agent` actions; observe ticks do not consume it. Existing
     `max_iterations` semantics are unchanged (back-compat).

## Consequences

Positive:

- `over_budget` stops being a catch-all: wedges stop early with a named cause,
  saving ~90 percent of the burned iterations observed in the wedge class, and
  the label an operator sees prescribes the right fix.
- Budgets become estimates grounded in history instead of guesses, with the
  provenance visible.
- Prompt/context changes become measured: behavior proposes, benchmarks
  dispose. Prompt cruft cannot accumulate unearned.
- Everything stays local and inspectable (SQLite); no telemetry consent
  problem.

Negative / accepted costs:

- A read-model schema migration and more writes at terminal projection.
- The debrief adds a small per-dispatch output cost when enabled (opt-in).
- The benchmark gate adds friction to prompt changes -- intended.
- Learned proposals are only as good as local history density; sparse history
  degrades to current behavior by design.

Extends ADR-0046 (economy accounting: envelopes, honest-unknown, KPIs) and
ADR-0041 (envelope v2 graded scores); refines ADR-0002 (budget as hard
ceiling) without relitigating it -- the ceiling stays a hard stop; this ADR
makes reaching it rare and honest. Related: ADR-0057 (dashboard surfaces the
cause class).
