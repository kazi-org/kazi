# ADR 0008: Harness invocation — headless, stateless per iteration; kazi owns context

- Status: Accepted
- Date: 2026-06-21

## Context

The harness adapter (ADR-0001) drives a coding agent through a subprocess —
`claude -p` first. The Claude CLI offers session continuity (`--resume`,
`--continue`), per-session conversation memory, and other stateful features. A
natural question is whether kazi should lean on those: keep one long Claude
session per goal so the agent "remembers" its prior reasoning across iterations.

kazi is a reconciliation controller (ADR-0001): desired state is a predicate
set, actual state is predicate evaluation, the reconcile action is dispatching an
agent. A reconciler converges from **observed state**, not from hidden
conversational memory. It must also stay **harness-agnostic** (ADR-0001, R4):
Codex or any other `-p`-style tool must drop in unchanged, so the design cannot
depend on Claude-specific session semantics. And the slice-1 trust machinery
(regression, flake, budget, stuck — see the loop) exists precisely to break
loops that spiral on a bad approach; carrying a long conversation works against
that by anchoring the agent on its earlier, failed reasoning.

## Decision

**Each iteration invokes the harness as a fresh, stateless `claude -p` call.** No
`--resume`, no `--continue`, no session id is carried across iterations by
default (`Kazi.Harness.ClaudeAdapter`). The call runs with `cd:` set to the
target workspace so edits land in place, and captures exit status + output.

**Durable context lives in kazi, not in the CLI session**, in three places kazi
controls:

1. **The git workspace itself** — the agent's edits land in the real tree, so the
   next iteration re-reads the actual current code. This is the strongest, most
   portable form of memory and survives crashes, restarts, and a harness swap.
2. **kazi's read-model + in-state history** — the SQLite iteration/evidence log
   (ADR-0005) plus the loop's in-memory per-iteration predicate-vector history.
   kazi remembers the *trajectory* (what was tried, what regressed, what is
   stuck); the agent does not need to.
3. **The freshly-seeded prompt** — each call is handed only the currently-failing
   predicate evidence (see ADR-0009).

Two CLI features are adopted or held in reserve **behind the adapter seam**,
without making them load-bearing:

- **`--output-format json` (adopt soon).** Gives a structured result plus real
  token/cost usage, which feeds the budget ceiling's token dimension (today an
  estimate). Highest-value, lowest-risk enhancement.
- **`--resume` / `--continue` (optional, per-goal).** Conversational continuity
  may help multi-step *creation* work (Slice 2). If added, it is an opt-in adapter
  mode; stateless remains the default.

## Consequences

- **Determinism & replayability:** same workspace + same failing predicates →
  same prompt → reproducible behavior. No hidden cross-call state to reason about.
- **Harness-agnostic:** nothing in the wiring depends on Claude session
  semantics; the same shape drives Codex or a stub binary (tests inject a stub
  via the configurable command).
- **Escaping local minima:** fresh context each iteration is what lets the
  stuck/regression/budget guards actually break a spiral instead of letting the
  agent re-commit to a failed plan.
- **Token accounting needs `--output-format json`:** until adopted, the budget
  ceiling's token dimension is an estimate. Tracked as a near-term adapter
  enhancement.
- **No conversational continuity by default:** if a future creation workflow
  genuinely needs it, it is added as an opt-in mode, not a core dependency.

## Alternatives rejected

- **One long Claude session per goal (`--resume` everywhere).** Couples kazi to
  Claude-specific session behavior (breaks harness-neutrality), destroys
  replay/determinism, and anchors the agent on failed approaches — directly
  undermining the slice-1 trust guards.
- **Stuff prior-iteration transcripts into each prompt.** Re-creates the
  anchoring problem and grows context unboundedly for no convergence benefit; the
  workspace + failing evidence already carry the durable state.
- **A bespoke kazi memory/context store fed to the agent.** Premature; the
  deferred pluggable memory adapter (ADR-0005) is the place for trajectory memory
  if it ever earns its keep — never the foundation.
