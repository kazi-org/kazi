# ADR 0049: Close the approve -> apply handoff for orchestrator-driven runs

## Status
Accepted

## Date
2026-06-28

## Context
The adoption spine is `kazi plan -> kazi approve -> kazi apply`, driven entirely
over `--json` by an outer orchestrator (a coding agent or a script). The T15.9
nested-loop dogfood (orchestrator -> kazi -> a local model via opencode) drove the
full loop and surfaced a broken seam in the middle:

- `kazi plan --json` drafts a proposal and persists it (read-model), returning a
  `proposal_ref`.
- `kazi approve <ref> --json` flips the proposal to `approved` and returns a small
  status object.
- `kazi apply <goal-file> ...` requires a **goal-file on disk** -- but nothing in
  the plan/approve path ever WROTE one. The approved goal lives only in the
  read-model. So the orchestrator must RECONSTRUCT a goal-file from the predicates
  it originally supplied (or scrape one together) before it can call `apply`. That
  reconstruction is exactly the "kazi was awkward to drive as a tool" friction the
  dogfood was built to find: the loop is not closeable over `--json` alone.

Secondary frictions found in the same run, all of which make the loop harder to
drive as a clean tool:

1. `kazi plan --json --predicates <json>` (caller-drafts) **ignored** the caller's
   supplied `goal_id` and `idea`, minting a generic `caller-supplied-predicates`
   id instead. The orchestrator cannot name the goal it is authoring.
2. Under `--json`, dev/`mix run` invocations **co-mingle Phoenix/Ecto logs into
   stdout**, so an orchestrator parsing stdout must select the JSON object out of
   log lines. The released binary emits clean JSON; the contract should hold
   regardless of how kazi is invoked (stdout = the single JSON object; logs ->
   stderr).
3. The operator-facing **escript cannot author** at all (`plan`/`approve` hard-fail
   with "the read-model is unavailable; authoring requires persistence") because an
   escript cannot bundle the SQLite NIF. Authoring is only possible via the Mix
   path or the bundled release binary -- undocumented at the point of failure.

## Decision
Close the loop so `plan -> approve -> apply` is drivable end to end over `--json`
with no orchestrator-side goal-file reconstruction:

1. **`kazi apply <proposal-ref>` accepts an APPROVED proposal-ref** (in addition to
   a goal-file path). When the argument resolves to an approved proposal in the
   read-model, `apply` loads that goal directly and runs it. A non-approved or
   unknown ref is a clear error. This is the primary fix: the orchestrator carries
   the `proposal_ref` from `plan` through `approve` straight into `apply`, never
   touching the filesystem.
2. **`kazi approve <ref> --write <path>`** optionally materializes the approved
   goal as a goal-file at `<path>` (and `--json` reports the written path), for
   file-based / version-controlled workflows that WANT a goal-file artifact.
3. **`kazi plan --json --predicates` honors the caller's `goal_id` and `idea`**
   when supplied, falling back to the generated defaults only when absent.
4. **`--json` guarantees stdout is the single JSON object** regardless of env or
   entrypoint: logs are routed to stderr (or silenced) for `--json` runs across
   escript / `mix run` / release.
5. **Authoring degrades or guides on the escript**: either authoring works via an
   ephemeral/in-memory read-model so the escript can `plan`/`approve`, or the
   failure message names the supported entrypoint (release binary / Mix path) and
   the docs state it plainly. (The build/packaging deepening is tracked separately;
   this ADR requires at minimum the clear, documented guidance.)

The work is tracked in E39.

## Consequences
- Positive: the adoption spine becomes a true tool contract -- an orchestrator
  drives `plan -> approve -> apply` over `--json` with zero prose-scraping and zero
  goal-file reconstruction, which is the whole point of the JSON CLI (E15) and the
  router (E26). The dogfood that found the friction (T15.9) becomes the regression
  that guards it.
- Positive: `apply <proposal-ref>` and `approve --write` cover both the
  ref-threading and the file-artifact workflows without forcing either.
- Negative: `apply` now has two argument modes (ref vs path); the resolver must
  disambiguate unambiguously (a `prop-` prefix is the natural discriminator) and
  error clearly on a non-approved ref.
- Negative: routing `--json` logs to stderr touches the logger backend config and
  must be verified on every entrypoint, not just the one the test happens to use.
- This supersedes nothing; it deepens the E15/E23 JSON-CLI contract and the E26
  router on-ramp. The `proposal_ref` contract (ADR-0023, schema_version) is
  unchanged; `apply` simply learns to accept it.
