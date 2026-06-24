# ADR 0023: kazi as a harness-friendly, agent-drivable CLI

## Status
Accepted

## Date
2026-06-23

## Context

kazi drives a coding harness (claude/opencode/codex/...) as a non-interactive
subprocess and parses its output (ADR-0001, ADR-0016). The operator wants the
INVERSE to be just as good: an orchestrating agent -- claude code today, any
capable harness tomorrow -- should be able to DRIVE kazi programmatically through
the whole loop (plan -> author predicates -> converge -> validate -> release).

This puts kazi in the MIDDLE of a three-layer stack:

```
  orchestrator agent  (claude code -- HIGH reasoning: plan/design, author predicates)
        |  drives kazi as a tool
        v
      kazi             (the controller -- objective predicates + convergence loop)
        |  drives the inner harness
        v
  cheap implementer    (claw -> local Qwen3.6/DGX, opencode, ... -- the keystrokes)
```

The economic payoff: spend expensive reasoning ONCE on what needs judgment -- what
"done" means (the predicates/plan) -- and cheap local compute on the iterative
grind (editing until predicates pass), with kazi's objective termination keeping
the cheap model honest. ADR-0001 said "kazi is the outer loop, not a harness";
this EXTENDS that without contradicting it -- kazi is the outer loop FOR the coding
harness AND a well-behaved inner tool FOR the orchestrator.

The key realization: ADR-0022 defined a conformance contract for a harness kazi
can drive (non-interactive, machine-parseable stdout, correct under a non-TTY
subprocess). "Harness-friendly kazi" is that SAME contract applied to kazi itself.
kazi should satisfy the bar it imposes.

## Decision

1. **kazi self-conforms to ADR-0022.** Every command (`propose`, `run`, `status`,
   `list-proposed`, `approve`, `reject`, `init`) gains a `--json` mode that emits a
   single JSON object (or a JSONL stream for long runs) to stdout, is
   non-interactive (never prompts/blocks on stdin under `--json`/no-TTY/`--yes`),
   and returns stable exit codes. The human-readable output stays the DEFAULT;
   `--json` is the machine surface. (The `propose` clarify phase already has
   `--yes`/no-TTY, ADR-0019; this generalizes the guarantee.)

2. **A stable, versioned machine-readable result contract.**
   - `kazi run --json` emits on termination a JSON object: terminal `status`
     (`converged` / `stuck` / `over_budget` / `error`), the PREDICATE VECTOR (each
     predicate id + verdict), `iterations`, `budget_spent`, and a `next_action`
     hint the orchestrator branches on -- plus `schema_version`.
   - `kazi propose --json` emits the draft (goal id, `proposal_ref`, predicates,
     rationale, any questions asked).
   - `kazi status --json` (NEW) reports a run/proposal's current state from the
     read-model.
   The schemas are documented and versioned; a breaking change bumps
   `schema_version`.

3. **Streaming progress (JSONL) for long runs.** `kazi run --json --stream` emits
   one JSON event per iteration (iteration n, dispatched harness, predicate-vector
   delta), terminated by the final result object -- so the orchestrator monitors a
   long convergence without blocking. This MIRRORS how kazi already parses
   opencode/codex JSONL (the symmetry again).

4. **The orchestrator owns the two-tier policy; kazi stays a PURE tool.** kazi
   exposes the levers -- `--harness`/`--model` per call, structured output, the
   proposal -> approve -> run state machine -- and the orchestrator decides which
   brain for which phase. kazi does NOT bake per-phase model policy in.

   **"Author predicates with a strong model" = drive the EXISTING `kazi propose`
   path, not a parallel mechanism.** `kazi propose` (ADR-0011 / ADR-0019) IS kazi's
   predicate-authoring command: idea -> the harness drafts acceptance predicates ->
   the deterministic clarify FLOOR enforces a live-verification target + scope ->
   reviewable proposal -> approve. So the strong model is simply propose's HARNESS:
   `kazi propose "<idea>" --harness claude --json`. The orchestrating agent is just
   another SURFACE on `Kazi.Authoring` -- "the one WRITE path the operator surfaces
   share" (ADR-0011 §2) -- alongside the human CLI, Telegram, and dashboard; it must
   reuse that path (now over `--json`), never fork a second authoring mechanism.
   **`kazi propose` is the SINGLE sanctioned predicate-authoring path for an agent;
   hand-authoring a goal-file is not an anticipated agent workflow and is not
   designed for** (the operator confirmed they do not anticipate hand-authoring
   predicates). Goal-files remain a loadable artifact -- propose persists/approves
   INTO one -- but the agent's authoring entry point is always propose, so the
   clarify floor (a live-verification target + scope) and the review/approve gate
   are never bypassed. Then `kazi run --harness claw --model <local>` runs the cheap
   convergence loop.

5. **An MCP server is a deferred follow-on.** Once the JSON CLI contract is proven,
   a `kazi mcp` server can wrap the same commands as MCP tools for claude-code-
   native use. Not in this slice -- the JSON CLI is universal and smaller, and MCP
   would consume it.

## Consequences

- kazi becomes scriptable and agent-drivable end to end: the orchestrator parses
  JSON, never prose.
- kazi DOGFOODS its own conformance contract (ADR-0022) -- a strong consistency
  signal: a controller that is itself a well-behaved subprocess knows what a
  well-behaved subprocess is.
- The plan-with-strong / code-with-cheap economics are unlocked at the
  orchestration layer with NO new kazi policy.
- New surface is additive: a `--json` renderer + a versioned result schema per
  command + a streaming mode; human output is untouched.
- The result schema is a compatibility surface -- it must be versioned, and the
  orchestrator recipe should pin/check `schema_version`.
- HONEST dependency: end-to-end value still needs a capable, fast-enough inner
  harness. claw -> local Qwen is best-effort/slow (ADR-0022, devlog T8.11). The
  JSON contract makes kazi drivable regardless; convergence speed remains the inner
  harness's problem, not kazi's.

## Alternatives rejected

- **MCP-first.** Bigger and claude-code/MCP-specific; the JSON CLI is universal,
  smaller, and is what an MCP server would call anyway. MCP follows.
- **kazi bakes the per-phase model tiering in.** Orchestration policy belongs to
  the agent above; baking it in makes kazi less flexible. Rejected (kept as a
  possible convenience default later).
- **Prose output the agent screen-scrapes.** Brittle -- exactly what ADR-0022
  forbids of harnesses; kazi must not ask of an orchestrator what it refuses to
  accept from a harness.
