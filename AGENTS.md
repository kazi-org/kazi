# Driving kazi (for agents)

kazi is a reconciliation controller: you declare a goal as machine-checkable
acceptance predicates, and kazi drives a coding harness in a loop until those
predicates are objectively true, stuck, or over budget. kazi is a TOOL you call,
not a harness.

## Drive kazi: MCP first, JSON-CLI fallback

PREFER the MCP server. If you speak MCP, wire kazi as an MCP server and drive its
self-describing tools -- `kazi_plan`, `kazi_approve`, `kazi_apply`, `kazi_status`,
`kazi_list_proposed` -- whose input/output schemas teach you the surface at ZERO
prose cost (ADR-0044). The installed binary serves it over stdio via the `kazi mcp`
verb; the canonical client config references that binary verb:

```json
{ "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } }
```

`kazi init --with-mcp` writes exactly this `.mcp.json` into a repo, and `mix
kazi.mcp` is the development entry point that starts the SAME server. The CLI
recipe below maps one-to-one onto these tools.

FALLBACK -- the JSON-CLI shell-out. When MCP is unavailable, drive kazi over its
`--json` CLI: parse the JSON, never the prose (ADR-0023). This file is the
condensed, harness-neutral recipe; `docs/orchestrator-recipe.md` is the full
version and the source of truth.

> Every command and flag below is real. Confirm the live surface with
> `kazi help --json` and `kazi schema` rather than trusting a stale copy.

For a CODE goal the on-ramp is two verbs: `kazi plan` authors the acceptance
predicates and `kazi apply` converges them (ADR-0031/0032). `kazi apply` IS the
reconcile loop -- you do NOT wrap it in a separate loop/qualify pass for code
work. The strategy layer above kazi is `/plan` (ADRs, use cases, the WBS, the
intent); kazi turns that intent into objective predicates and executes them.
`/tidy` stays orthogonal hygiene (git/worktree/scratch sweeping), not part of the
converge loop.

When the user says "have kazi drive this until done" (the canonical invocation
phrase), that is the request to drive kazi: author the predicates with `kazi
plan`, then converge them with `kazi apply` until they are objectively true.

## Two-tier economics (why)

Spend expensive reasoning ONCE on what "done" means -- the acceptance predicates.
Spend cheap compute on the grind of editing until they pass. kazi's objective
termination makes the split safe: the cheap implementer cannot declare victory on
plausible-but-wrong work, because truth lives in the predicates, not in the model
doing the keystrokes. You (FRONTIER model) AUTHOR predicates; a cheap harness
(`--harness claude --model <cheap-claude-id>`) RUNS the loop; kazi holds the bar
still.

The DEFAULT recipe is in-family Claude tiering (ADR-0033/0035): you are a frontier
Claude model (e.g. `claude-opus-4-8`) authoring predicates in this session, and you
grind on a CHEAP Claude model -- `claude-haiku-4-5` (step up to `claude-sonnet-5`
for harder slices) -- via `--harness claude --model <id>`. It needs only a Claude API
key: no local model, no special hardware. The cost win is BEING MEASURED -- treat it
as the intended economics, not a measured figure.

Local / BYOM is the SECONDARY privacy add-on: if code must never leave your hardware,
grind on a local model instead -- `--harness opencode --model <local-model>` (a local
Qwen/Llama via opencode). Same two-tier shape, no cloud; explicitly secondary.

## The loop: plan -> approve -> apply -> branch

```
plan --json -> (review) -> approve --json -> apply --harness claude --model <cheap-claude-id> --json [--stream]
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

### 3. converge -- `kazi apply --harness claude --model <cheap-claude-id> --json [--stream]`

Apply the approved goal with the cheap tier. The DEFAULT is in-family Claude
tiering: you authored on a frontier model, so grind on a cheap Claude model:

```sh
kazi apply <goal-file> --workspace <path> --harness claude --model claude-haiku-4-5 --json
```

SECONDARY (privacy / no-cloud): keep the grind on local hardware via opencode --
same loop, no cloud:

```sh
kazi apply <goal-file> --workspace <path> --harness opencode --model <local-model> --json
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

### Escalate-on-stuck: the bounded model ladder (ADR-0035)

Static cheap-tiering always grinds on one cheap model. The ADAPTIVE refinement
starts cheapest and steps UP only when kazi reports the SAME slice not progressing,
so you pay frontier rates only for the slices that need them. The policy lives
ENTIRELY in the skill -- kazi reports per-invocation state, YOU own the ladder and
the rung counter. kazi-core has NO model-selection logic (ADR-0035 decision 1).

The ladder is capped at the frontier and STOPS there:

```
claude-haiku-4-5  ->  claude-sonnet-5  ->  claude-opus-4-8   (STOP; do not escalate past Opus)
```

Trigger (the `--json` fields, T30.3 -- `docs/tiering-signals.md`): after each
`kazi apply --harness claude --model <rung> --json`, read the terminal result and
branch by `goal_id` (the slice id; KEY your rung counter by it -- the counter is
SKILL state, never a kazi field), `status` (`converged` -> reset; `stuck` /
`over_budget` -> step up; `error` -> fix the goal, do NOT escalate), `next_action`,
and `predicates[]` (confirm the same failing set -- same slice, same bar);
`reason` / `budget_spent.exceeded` name the budget dimension on `over_budget`.

In one line: on a result for the slice's `goal_id` whose `status` is `stuck` or
`over_budget` (NOT `converged`, NOT `error`) with the same failing `predicates[]`,
increment the per-`goal_id` rung counter and re-dispatch the SAME slice with the
next `--model` UP the ladder.

- RESET on a fresh slice: a new `goal_id` starts at rung 1 (`claude-haiku-4-5`).
- BOUNDED by kazi: escalation rides on kazi's own budget/stuck termination (each
  rung is one bounded `kazi apply`) and the ladder caps at `claude-opus-4-8`, so it
  cannot loop unboundedly -- at worst three rungs, then stop.
- DISABLE -> static tiering: pin `--model` to one rung and never step up; the recipe
  degenerates to static cheap-tiering (always `claude-haiku-4-5`).

The full copy-paste sh recipe (ladder + trigger + reset + cap) is in the installed
kazi SKILL.md ("Escalate-on-stuck") -- kept in lockstep with this section.

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
result=$(kazi apply "$GOAL" --workspace "$WS" --harness claude --model claude-haiku-4-5 --json)
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

Recap (the MCP-first path at the top of this file): an MCP-speaking harness skips
the JSON-CLI shell-out entirely. `kazi mcp` starts the MCP server over stdio
(ADR-0044) -- the same server `mix kazi.mcp` runs -- and the plan / approve / apply
/ status tools self-describe through their schemas. The canonical client config is
`{ "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } }`.

## Semantic recall (ADR-0062)

`kazi memory recall "<query>" [--budget <tokens>] [--json]` is a budgeted FTS
search over the project's git-native corpus (ADRs, `docs/lore.md`,
`docs/devlog.md`, `AGENTS.md`, `CLAUDE.md`, `README.md`) — the same recall the
loop can inject into a dispatch prompt (opt-in, `docs/memory.md`). Use it to
check what the project already knows before re-deriving an invariant a prior
run already recorded.

## Gated memory harvest and promotion (ADR-0063)

kazi detects candidate memory entries (deterministically, controller-side,
never from the harness/dispatch path) at run termination and stores them as
PROPOSALS -- never straight into the corpus. Review and promote them:

```sh
kazi memory list-proposed [--status proposed|approved|rejected] [--json]
kazi memory approve <proposal-ref> --workspace <path> [--json]   # writes into
                                                                  # docs/lore.md /
                                                                  # docs/devlog.md /
                                                                  # a drafted ADR
kazi memory reject <proposal-ref> [--json]                       # declined, audited
```

`approve` writes an ordinary working-tree edit (a `kx:<fingerprint>`
provenance trailer, ADR-0063); review the diff and land it like any other doc
change (ADR-0034) -- kazi never commits memory on its own authority.

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
