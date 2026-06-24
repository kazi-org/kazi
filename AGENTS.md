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

## Two-tier economics (why)

Spend expensive reasoning ONCE on what "done" means -- the acceptance predicates.
Spend cheap, local compute on the grind of editing until they pass. kazi's
objective termination makes the split safe: the cheap implementer cannot declare
victory on plausible-but-wrong work, because truth lives in the predicates, not
in the model doing the keystrokes. You (strong model) AUTHOR predicates; a cheap
harness (`--harness <cheap> --model <m>`) RUNS the loop; kazi holds the bar still.

## The loop: propose -> approve -> run -> branch

```
propose --json -> (review) -> approve --json -> run --harness <cheap> --json [--stream]
                                                       |
                                          parse result, branch on next_action
```

### 1. propose predicates -- `kazi propose --json`

`propose` is the single sanctioned predicate-authoring path. Under `--json` kazi
is NON-INTERACTIVE: it never prompts or blocks on stdin. Two modes:

caller-drafts (the agent's mode -- you already reasoned about the idea, so supply
the predicates; kazi spawns NO inner model):

```sh
kazi propose --json --predicates '{
  "name": "ship a /healthz endpoint",
  "predicates": [
    {"id": "code", "provider": "test_runner", "description": "route exists and tests pass"},
    {"id": "live", "provider": "http_probe",  "description": "GET /healthz returns 200 in prod"}
  ],
  "rationale": "a health probe for the deploy target"
}'

# or pipe the payload on stdin (under --json):
echo "$PAYLOAD" | kazi propose --json
```

The payload is a `{"name", "predicates": [...], "rationale"}` object (a bare JSON
array of predicate entries is also accepted). A positional idea is OPTIONAL here.

kazi-drafts (hand kazi only a prose idea; it drafts the predicates for you):

```sh
kazi propose "a /healthz endpoint that returns 200" --json --yes
```

If the idea is underspecified, kazi-drafts emits a JSON error and exits non-zero
rather than hanging -- pass `--yes`, supply predicates, or sharpen the idea.

`propose --json` emits one object: `goal_id`, `proposal_ref` (the approve/reject
handle), `status`, `predicates`, `rationale`, and a `clarify` array of open gaps
(each `{id, prompt, recommended}` from the deterministic floor -- e.g. a missing
live-verification target). All carry `schema_version`.

Other propose flags: `--workspace <path>`, `--strict`, `--adr`.

### 2. review and approve -- `kazi approve --json`

Read the proposed `predicates` and `clarify` gaps. If a gap matters, re-`propose`
with it closed. When satisfied, approve the `proposal_ref` from step 1:

```sh
kazi approve <proposal-ref> --json
```

Emits `{schema_version, proposal_ref, status: "approved", goal_id}`. `kazi reject
<proposal-ref> --json` declines (kept for audit). Browse the queue with
`kazi list-proposed [--status proposed|approved|rejected] --json`.

> `approve` returns a goal id, but `kazi run` takes a GOAL-FILE path, not the id.
> propose/approve persist the approved goal into a loadable goal-file; run that
> file's path in step 3.

### 3. converge -- `kazi run --harness <cheap> --json [--stream]`

Run the approved goal with the cheap harness:

```sh
kazi run <goal-file> --workspace <path> --harness opencode --model dgx/qwen3.6 --json
```

Emits ONE terminal result object. Exit code mirrors convergence: `0` only on
`converged`, non-zero otherwise (same on the human and `--json` surfaces).

For a long convergence add `--stream` for a JSONL progress stream -- one
`{"event": "iteration", ...}` line per loop iteration, TERMINATED by the final
result object (the one line with NO `event` field). Read lines until you see the
object without an `event`; that is the terminal result you branch on.

### 4. parse and branch on `next_action`

`run --json` gives the terminal `status` plus a derived `next_action` hint, so you
never re-derive the branch from the predicate vector:

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

Every `--json` object carries `schema_version` (currently **1**) -- one shared
compatibility number across all surfaces. An additive change leaves it unchanged;
a breaking change bumps it. Read it off the first object you parse and refuse (or
branch) if it is not the version you were written against:

```sh
result=$(kazi run "$GOAL" --workspace "$WS" --harness opencode --json)
ver=$(printf '%s' "$result" | jq -r .schema_version)
[ "$ver" = "1" ] || { echo "unexpected kazi schema_version: $ver" >&2; exit 1; }
next=$(printf '%s' "$result" | jq -r .next_action)
```

A predicate is `pass` only when it genuinely held against the real world,
including LIVE predicates, which pass only post-deploy. The vector -- not a single
exit code -- makes regression and partial progress legible.

## Runtime introspection (no stale docs)

kazi self-describes; confirm the surface at runtime instead of trusting this copy:

```sh
kazi help --json            # the command/flag surface (generated from kazi's command table)
kazi schema [run|status]    # the versioned --json result schema(s) as data
```

`kazi help --json` lists every command with its `summary`, positional `args`, and
`flags` (`name`, `type`, `description`, `aliases`). `kazi schema` emits the
versioned result schemas; both are JSON.

## See also

- `docs/orchestrator-recipe.md` -- the full recipe (source of truth).
- `docs/schemas/run-result.md`, `docs/schemas/status.md` -- the committed schemas.
- `docs/adr/0023-harness-friendly-agent-drivable-cli.md` -- the agent-drivable CLI.
- `docs/adr/0024-kazi-self-teaching-to-harnesses.md` -- self-teaching surfaces.
