# Driving kazi (for agents)

kazi is a reconciliation controller: you declare a goal as machine-checkable
acceptance predicates, and kazi drives a coding harness in a loop until those
predicates are objectively true, stuck, or over budget. kazi is a TOOL you call,
not a harness.

If you are an agent operating in this repo, drive kazi over its `--json` CLI:
parse the JSON, never the prose (ADR-0023). This file is the condensed,
harness-neutral recipe; `docs/orchestrator-recipe.md` is the full version and the
source of truth.

> Every command and flag below is real. Confirm the live surface with
> `kazi help --json` and `kazi schema` rather than trusting a stale copy.

For a CODE goal the on-ramp is two verbs: `kazi plan` authors the acceptance
predicates and `kazi apply` converges them (ADR-0031/0032). `kazi apply` IS the
reconcile loop -- you do NOT wrap it in a separate loop/qualify pass for code
work. The strategy layer above kazi is `/plan` (ADRs, use cases, the WBS, the
intent); kazi turns that intent into objective predicates and executes them.
`/tidy` stays orthogonal hygiene (git/worktree/scratch sweeping), not part of the
converge loop.

## Two-tier economics (why)

Spend expensive reasoning ONCE on what "done" means -- the acceptance predicates.
Spend cheap, local compute on the grind of editing until they pass. kazi's
objective termination makes the split safe: the cheap implementer cannot declare
victory on plausible-but-wrong work, because truth lives in the predicates, not
in the model doing the keystrokes. You (strong model) AUTHOR predicates; a cheap
harness (`--harness <cheap> --model <m>`) RUNS the loop; kazi holds the bar still.

## The loop: plan -> approve -> apply -> branch

```
plan --json -> (review) -> approve --json -> apply --harness <cheap> --json [--stream]
                                                    |
                                       parse result, branch on next_action
```

> The verbs are `kazi plan` and `kazi apply` (ADR-0032). The old verbs `run` and
> `propose` were REMOVED in v0.6.0 (T27.9): they no longer parse and now error as
> unknown commands. Use `plan`/`apply` (and `mix kazi.apply`, not `mix kazi.run`).

### 1. author predicates -- `kazi plan --json`

`plan` is the single sanctioned predicate-authoring path. Under `--json` kazi
is NON-INTERACTIVE: it never prompts or blocks on stdin. Two modes:

caller-drafts (the agent's mode -- you already reasoned about the idea, so supply
the predicates; kazi spawns NO inner model):

```sh
kazi plan --json --predicates '{
  "name": "ship a /healthz endpoint",
  "predicates": [
    {"id": "code", "provider": "test_runner", "description": "route exists and tests pass"},
    {"id": "live", "provider": "http_probe",  "description": "GET /healthz returns 200 in prod"}
  ],
  "rationale": "a health probe for the deploy target"
}'

# or pipe the payload on stdin (under --json):
echo "$PAYLOAD" | kazi plan --json
```

The payload is a `{"name", "predicates": [...], "rationale"}` object (a bare JSON
array of predicate entries is also accepted). A positional idea is OPTIONAL here.

If a `/plan` strategy doc already exists for this work, DERIVE the predicates from
its `acc:` lines rather than inventing them -- those lines ARE the predicate set.

kazi-drafts (hand kazi only a prose idea; it drafts the predicates for you):

```sh
kazi plan "a /healthz endpoint that returns 200" --json --yes
```

If the idea is underspecified, kazi-drafts emits a JSON error and exits non-zero
rather than hanging -- pass `--yes`, supply predicates, or sharpen the idea.

`plan --json` emits one object: `goal_id`, `proposal_ref` (the approve/reject
handle), `status`, `predicates`, `rationale`, and a `clarify` array of open gaps
(each `{id, prompt, recommended}` from the deterministic floor -- e.g. a missing
live-verification target). All carry `schema_version`.

Other plan flags: `--workspace <path>`, `--strict`, `--adr`.

### 2. review and approve -- `kazi approve --json`

Read the proposed `predicates` and `clarify` gaps. If a gap matters, re-run
`kazi plan` with it closed. When satisfied, approve the `proposal_ref` from step 1:

```sh
kazi approve <proposal-ref> --json
```

Emits `{schema_version, proposal_ref, status: "approved", goal_id}`. `kazi reject
<proposal-ref> --json` declines (kept for audit). Browse the queue with
`kazi list-proposed [--status proposed|approved|rejected] --json`.

> `approve` returns a goal id, but `kazi apply` takes a GOAL-FILE path, not the id.
> plan/approve persist the approved goal into a loadable goal-file; apply that
> file's path in step 3.

### 3. converge -- `kazi apply --harness <cheap> --json [--stream]`

Apply the approved goal with the cheap harness:

```sh
kazi apply <goal-file> --workspace <path> --harness opencode --model local/qwen3.6 --json
```

Emits ONE terminal result object. Exit code mirrors convergence: `0` only on
`converged`, non-zero otherwise (same on the human and `--json` surfaces).

For a long convergence add `--stream` for a JSONL progress stream -- one
`{"event": "iteration", ...}` line per loop iteration, TERMINATED by the final
result object (the one line with NO `event` field). Read lines until you see the
object without an `event`; that is the terminal result you branch on.

### 4. parse and branch on `next_action`

`apply --json` gives the terminal `status` plus a derived `next_action` hint, so
you never re-derive the branch from the predicate vector:

| `status`      | `next_action`  | exit | Do |
|---------------|----------------|------|----|
| `converged`   | `done`         | 0    | Finished. Ship / report. |
| `stuck`       | `investigate`  | != 0 | Inspect the predicate vector; the same set failed N times. |
| `over_budget` | `raise_budget` | != 0 | Raise the budget and re-run, or escalate. |
| `error`       | `investigate`  | != 0 | Pre-loop failure (vacuous goal, unknown harness); read `error`, fix. |

`next_action` is a HINT -- you own the policy.

### Polling -- `kazi status <ref> --json`

`kazi status <ref> --json` is a PURE read of the read-model (no loop runs). The
`<ref>` resolves as a run's goal id first (`kind: "run"` -- latest predicate
vector), else a `proposal_ref` (`kind: "proposal"` -- lifecycle state). An unknown
ref is a JSON error with a non-zero exit.

## Pin `schema_version`

Every `--json` object carries `schema_version` (currently **2**, bumped by
ADR-0032 when the verbs unified) -- one shared compatibility number across all
surfaces. An additive change leaves it unchanged; a breaking change bumps it. Read
it off the first object you parse and refuse (or branch) if it is not the version
you were written against:

```sh
result=$(kazi apply "$GOAL" --workspace "$WS" --harness opencode --json)
ver=$(printf '%s' "$result" | jq -r .schema_version)
[ "$ver" = "2" ] || { echo "unexpected kazi schema_version: $ver" >&2; exit 1; }
next=$(printf '%s' "$result" | jq -r .next_action)
```

A predicate is `pass` only when it genuinely held against the real world,
including LIVE predicates, which pass only post-deploy. The vector -- not a single
exit code -- makes regression and partial progress legible.

## Runtime introspection (no stale docs)

kazi self-describes; confirm the surface at runtime instead of trusting this copy:

```sh
kazi help --json              # the command/flag surface (generated from kazi's command table)
kazi schema [apply|status]    # the versioned --json result schema(s) as data
```

`kazi help --json` lists every command with its `summary`, positional `args`, and
`flags` (`name`, `type`, `description`, `aliases`) -- the verbs are `apply`/`plan`
(the `run`/`propose` aliases were removed in v0.6.0, T27.9). `kazi schema` emits the
versioned result schemas; both are JSON.

## Verifying a pooled task with kazi

In an /apply --pool session, gate your task's MERGE on objective convergence
(ADR-0026 L1): bridge the task's acc line to predicates, plan/approve, then
`kazi apply --json` -- rebase-merge ONLY when `status` is `converged`; on
`stuck` / `over_budget` / `error`, escalate and do NOT merge. Full copy-pasteable
gate (git-refs only, no NATS): `docs/pool-verification-gate.md`.

## See also

- `docs/pool-verification-gate.md` -- the pre-merge verification gate (ADR-0026 L1).
- `docs/orchestrator-recipe.md` -- the full recipe (source of truth).
- `docs/schemas/run-result.md`, `docs/schemas/status.md` -- the committed schemas.
- `docs/adr/0023-harness-friendly-agent-drivable-cli.md` -- the agent-drivable CLI.
- `docs/adr/0024-kazi-self-teaching-to-harnesses.md` -- self-teaching surfaces.
- `docs/adr/0031-kazi-skill-router-subsumes-loop-apply-qualify.md` -- the router on-ramp.
- `docs/adr/0032-rename-cli-verbs-run-apply-propose-plan.md` -- the verb rename.
