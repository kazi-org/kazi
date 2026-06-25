# ADR 0009: Prompt construction — a thin, deterministic evidence projection

- Status: Accepted
- Date: 2026-06-21

## Context

When kazi dispatches the agent (ADR-0001, ADR-0008), it must hand it a prompt.
Two related concerns arise: (1) how does kazi decide what to put in the prompt,
and (2) by invoking `claude -p` headlessly rather than interactively, are we
giving up the capabilities of Claude Code?

The second concern rests on a misconception worth recording. `claude -p` (print
/ headless) is **not a stripped-down agent** — it is the full Claude Code agent
(file edit/read, bash, search, multi-step planning, tool use, sub-agents, MCP),
just run non-interactively: take a prompt, do the work, print, exit. Run with
`cd:` set to the target workspace, it also picks up that repo's `CLAUDE.md`,
settings, and MCP servers for free. Headless mode is the supported automation
interface (it is what the Claude Agent SDK is built on).

## Decision

**kazi does not engineer clever prompts. It deterministically projects the
current failing state into text** (`Kazi.Harness.ClaudeAdapter.build_prompt/2`).
The prompt is a fixed template from two inputs:

- `work_item` — the goal's human intent (from the goal-file), and
- `failing` — the failing slice of the current predicate vector, as
  `{predicate_id, %PredicateResult{status, evidence}}` pairs.

It renders the work item, the instruction *"make each failing predicate pass;
change the code under test, not the checks themselves,"* and one section per
failing predicate with its real evidence (test output, exit code, HTTP
status/body diff, …). The agent receives **only the objective evidence of what is
currently wrong and what must become true.** The intelligence is the agent's;
kazi supplies grounded truth, not instructions on how to think.

**The division of labor is explicit:** Claude Code is the inner engine that does
the work and keeps all its capabilities; kazi is the outer loop Claude Code lacks
— objective predicates, observe→act→re-observe, the trust guards (regression /
flake / budget / stuck), persistence, integrate + deploy, and the refusal to
declare success until machine-checkable predicates (including the live probe)
pass. Replacing the harness is an explicit non-goal (ADR-0001); kazi *drives*
Claude Code, it does not reimplement it.

`build_prompt/2` is a pure, total, testable function and a **seam**: a goal-file
may later carry a custom template or extra per-goal context, and durable
project guidance belongs in the workspace's `CLAUDE.md` (which the agent reads
automatically) — not hard-coded into kazi.

## Consequences

- **No features are lost.** Headless `claude -p` retains the full agent toolset
  and honors the workspace's `CLAUDE.md` / settings / MCP. What is given up is
  interactive Q&A, interactive permission prompts, and (by ADR-0008)
  cross-iteration conversation memory — all intentional for an autonomous loop
  whose human sits *outside* it (concept §8).
- **Repair prompts are strong because they are grounded.** Real failure output
  beats vague instructions; the agent already has the codebase and `CLAUDE.md`.
- **Creation mode (Slice 2) carries intent in the predicates.** When repairing,
  the failing evidence is the spec; when creating, the acceptance predicates
  (failing at t0) are the spec. Richer per-goal prompt context — and optionally
  `--resume` (ADR-0008) — is where creation work can be deepened later, behind
  the same seam.
- **Permissions in headless mode** are governed by the workspace's pre-approved
  settings / permission mode, not interactive prompts; the target workspace must
  be configured to let the agent act (a deployment concern, not a prompt
  concern).

## Alternatives rejected

- **A prompt-engineering layer in kazi.** Re-introduces a moving, opinionated
  surface kazi would have to maintain and tune per model; the agent is already
  good at coding given grounded evidence. kazi's job is objective truth and
  verification, not prompt cleverness.
- **Interactive sessions for richer prompting.** Defeats autonomy and
  determinism; the human interface is deliberately off the inner loop (concept
  §8, ADR-0008).
- **Treating headless `-p` as a reason to reimplement agent capabilities in
  kazi.** That is rebuilding a harness — the explicit non-goal of ADR-0001.

## Amendment (2026-06-25): secret redaction before egress (T35.3)

The original decision said the prompt is a thin projection of *raw* failing
evidence. It did **not** address a security concern: captured evidence (test
logs, HTTP bodies, harness stderr) can contain credentials — a `DATABASE_URL`
in a failing migration log, an `Authorization` header in a flaky HTTP test —
which would then flow verbatim into a third-party harness prompt.

**Decision (amendment):** evidence rendered into the prompt is passed through a
single shared redactor, `Kazi.Redaction.redact/1`, before it reaches the harness.
The redactor replaces high-confidence secret shapes (provider token formats, PEM
private keys, JWTs, connection-string passwords, `Bearer`/`Basic` headers, and
named `password=`/`api_key=`-style values) with `[REDACTED]`, while leaving
ordinary failure output untouched so the repair signal stays legible. It is a
mitigation, not a guarantee; the durable rule remains keeping credentials out of
the workspace.

This is the **same** redactor the context store applies before indexing
(ADR-0045) — one pattern set, two egress paths (prompt + store), redacting
identically. The thin-projection decision above is otherwise unchanged: redaction
is a transform on the evidence values, not a new prompt-engineering layer.
