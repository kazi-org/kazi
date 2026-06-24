# ADR 0033: The default "cheaper" story is in-family Claude model tiering, not local models

## Status
Accepted

## Refines
ADR-0023 (the orchestrator owns the two-tier model policy) and ADR-0030 (content
strategy). Those framed the cost win as "plan with a strong model, run the grind with
a cheap/LOCAL model (Qwen/DGX via opencode)." This ADR keeps the mechanism but
changes the DEFAULT framing to in-family Claude tiering, because the local-model
framing has near-zero reach.

## Context

kazi's cost thesis is two-tier: spend expensive reasoning ONCE on what needs judgment
(the predicates), then run the iterative grind on a cheaper model, with objective
predicates keeping the cheap model honest. So far the "cheap model" has meant a LOCAL
model (the operator runs Qwen3.6-35B on a DGX via opencode). Two problems:

1. **Reach.** Almost no engineer has a DGX or a local ollama setup. Leading the
   "cheaper" story with BYOM/local makes the headline economics inapplicable to the
   mass audience (new Claude Code users) the content rewrite (ADR-0030) targets.
2. **It barely works.** The local 35B was too slow to converge in a usable window
   (devlog T8.11). So the local story is both niche AND unproven.

The same two-tier mechanic works ENTIRELY WITHIN the Claude family, available to
anyone with a Claude API key: a frontier model (e.g. Opus) authors the predicates
ONCE; kazi then drives the N-iteration grind on a CHEAP Claude model (e.g. Haiku, or
Sonnet for harder work); the predicates gate convergence so the cheap model cannot
declare a false "done." You pay frontier rates only for planning and cheap rates for
the bulk of the work -- token economy with NO local model, NO DGX. And because Haiku/
Sonnet are far more capable than a local 35B, the cheap-grind tier is realistic, not
aspirational.

kazi already supports this shape: `--harness <h> --model <m>` per call, and the
orchestrator owns which brain runs which phase (ADR-0023). One enabling gap: the
`claude` harness profile does not currently forward `--model` (its `supported_opts`
omits `:model`), so `kazi apply --harness claude --model <cheap-claude>` cannot select
a cheaper Claude model yet.

## Decision

1. **The DEFAULT "cheaper" story is in-family Claude tiering.** Lead every cost
   message (README/site/docs, ADR-0030 content) with: chat with Claude Code -> it
   drives kazi -> easy iterations run on a CHEAP Claude model (Haiku/Sonnet), hard
   reasoning on a FRONTIER model (Opus), predicates keep it honest -- better token
   economy with no local model and no special hardware.

2. **Local / BYOM is the PRIVACY add-on, not the headline.** Keep the opencode/local
   path (Qwen, Llama, etc.) as the option for "your code never leaves your hardware,"
   explicitly secondary to the in-family tiering.

3. **Enable per-model Claude selection.** Add `:model` to the `claude` profile's
   `supported_opts` and `build_args` (append `--model <m>` to `claude -p`), so
   `kazi apply --harness claude --model <cheap-claude>` works. This is the enabler the
   content + benchmark depend on.

4. **The cheaper-proof benchmark leads with the Claude-tiering arm.** The
   multi-iteration benchmark (E19) adds, as its PRIMARY cost arm, frontier-authors ->
   kazi -> cheap-Claude-grinds vs vanilla-frontier, capturing real $ and tokens. The
   local-Qwen arm becomes secondary/optional.

5. **Honesty gate.** The claim is unproven until the benchmark (T19.7/T19.5) runs;
   until then the content frames it as the intended economics ("designed so easy
   iterations run cheap"), not a measured number. Model names in examples use real
   current ids (e.g. Opus 4.8 / Sonnet 4.6 / Haiku 4.5) and are checked against the
   claude-api reference, never invented.

## Consequences

- The "cheaper" pitch becomes applicable to ~every Claude Code user, not just DGX
  owners -- a far larger adoption surface, and the honest answer to "how do I get
  token economy without local models."
- A small enabler ships (claude `--model` passthrough) that also makes
  per-goal/per-call Claude model choice generally available.
- The benchmark design shifts: the headline cost comparison is in-family tiering, the
  most broadly relevant number; local stays as a privacy demonstration.
- Risk: cheap-Claude convergence quality on hard tasks is unproven -- the benchmark
  must report convergence RATE + correctness, not just $, so a cheaper-but-fails
  result is caught (the predicates make failure visible, which is the point).
- The privacy story is preserved, just re-ranked; no capability is dropped.

## Alternatives rejected

- **Keep leading with local/BYOM (status quo).** Niche (needs a DGX) and unproven
  (35B too slow); a poor headline for a mass-adoption rewrite.
- **Drop the cost story until proven.** The economics are the differentiator vs
  vanilla; frame as intended-and-being-measured (honesty gate) rather than omit.
- **Hardcode a per-phase Claude tier inside kazi.** ADR-0023 keeps tier policy with
  the orchestrator; kazi exposes `--model`, the agent/skill chooses. Unchanged.
