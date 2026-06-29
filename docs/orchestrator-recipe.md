# Drive kazi from an orchestrating agent (the recipe)

This is the copy-pasteable recipe for an ORCHESTRATING agent -- Claude Code
today, any capable harness tomorrow -- to drive kazi programmatically through the
whole loop: author predicates -> review -> approve -> converge -> branch on the
result. The agent parses kazi's `--json` output, never its prose (ADR-0023).

If you are a Claude Code user, the most ergonomic path is `kazi install-skill`
(E16, ADR-0024) -- it writes this recipe as a skill so the agent already knows
it. This doc is the source of truth that skill teaches, and the recipe any
non-Claude agent follows directly.

> Every command and flag below is real -- it is the surface emitted by
> `kazi help --json` and dispatched in `lib/kazi/cli.ex`. Introspect it at
> runtime (see "Runtime introspection" below) rather than trusting a stale copy.


## 1. The two-tier economics (why drive kazi at all)

kazi sits in the MIDDLE of a three-layer stack (concept ss4, ADR-0023):

```
  orchestrator agent  (strong model -- plan/design, AUTHOR predicates)
        |  drives kazi as a tool  (this recipe)
        v
      kazi             (the controller -- objective predicates + convergence loop)
        |  drives the inner harness
        v
  cheap implementer    (claw -> local Qwen, opencode, codex, ... -- the keystrokes)
```

Spend expensive reasoning ONCE on the part that needs judgment -- what "done"
means: the acceptance predicates. Spend cheap, local compute on the iterative
grind of editing until those predicates pass. kazi's objective termination makes
the split safe: the cheap implementer cannot declare victory on
plausible-but-wrong work, because truth lives in the controller, not in the model
doing the keystrokes. The strong brain sets the bar; the cheap brain reaches for
it; kazi holds the bar still.

The orchestrator owns the per-phase model policy. kazi bakes NONE of that tiering
in -- it just exposes the levers (`--harness` / `--model` / `--effort` per call,
structured output, the propose -> approve -> run state machine) and stays a pure
tool. `--effort <level>` (e.g. low / medium / high) forwards `claude --effort` --
a Claude-only token-economy lever (ADR-0047, parity-by-design: it is not forwarded
to other harnesses) -- and a goal-file can carry it as `[harness] effort = "..."`,
overridden by the CLI flag.


## 2. The agent-driven loop

```
  plan --json  ->  (review)  ->  approve --json  ->  apply --harness <cheap> --json [--stream]
                                                              |
                                                  parse result, branch on next_action
                                                              |
                          +------------------+----------------+----------------+
                          | done             | investigate    | raise_budget   |
                          v                  v                v                v
                       finished           inspect          raise budget,    (status: error)
                                          predicates       re-run           inspect, fix
```

### Step 1 -- propose predicates (`kazi plan --json`)

`plan` is the SINGLE sanctioned predicate-authoring path for an agent
(ADR-0023). It runs the deterministic clarify floor (a live-verification target +
scope) and persists a reviewable proposal. It has TWO drive modes; both go
through the same authoring path and the same floor.

**caller-drafts** -- the orchestrator already reasoned about the idea, so it
supplies the candidate predicates and kazi spawns NO inner model. This is the
orchestrator's mode (avoids the redundant "strong model -> kazi -> strong model"
re-draft). Supply the payload inline with `--predicates`, or on stdin under
`--json`:

```sh
kazi plan --json --predicates '{
  "name": "ship a /healthz endpoint",
  "predicates": [
    {"id": "code", "provider": "test_runner", "description": "the route exists and tests pass"},
    {"id": "live", "provider": "http_probe",  "description": "GET /healthz returns 200 in prod"}
  ],
  "rationale": "a health probe for the deploy target"
}'

# or pipe it on stdin (under --json):
echo "$PAYLOAD" | kazi plan --json
```

The payload is a `{"name", "predicates": [...], "rationale"}` object (a bare JSON
array of predicate entries is also accepted and wrapped for you). A positional
idea is OPTIONAL in caller-drafts mode -- the predicates carry the intent.

**kazi-drafts** -- for a human at the CLI or a thin non-model script that hands
kazi only a prose idea; kazi spawns a harness to draft the predicates:

```sh
kazi plan "a /healthz endpoint that returns 200" --json --yes
```

Under `--json` kazi is NON-INTERACTIVE: it never prompts or blocks on stdin. If
the idea is underspecified, kazi-drafts emits a JSON error and exits non-zero
rather than hanging -- pass `--yes` to draft best-effort, supply predicates
(caller-drafts), or sharpen the idea.

`propose --json` emits a single JSON object: `goal_id`, `proposal_ref` (the
approve/reject handle), `status`, `predicates`, `rationale`, and a `clarify`
array -- the deterministic floor's open gaps (each `{id, prompt, recommended}`),
so the orchestrator sees exactly what is still missing. All carry
`schema_version`.

Useful propose flags: `--workspace <path>` (where a kazi-drafts harness drafts),
`--strict` (refuse an underspecified idea non-interactively), `--adr` (also write
an ADR-lite rationale doc).

### Step 2 -- review and approve (`kazi approve --json`)

Read the proposed `predicates` and `clarify` gaps. If a gap matters (e.g. no
live-verification predicate), re-`plan` with the gap closed. When satisfied,
approve the `proposal_ref` from Step 1:

```sh
kazi approve <proposal-ref> --json
```

`approve --json` emits `{schema_version, proposal_ref, status: "approved",
goal_id}`. On success the goal is now runnable by `kazi apply`. (`kazi reject
<proposal-ref> --json` declines a proposal, kept for audit.)

Browse the queue any time with `kazi list-proposed --json` (optionally
`--status proposed|approved|rejected`); it emits `{schema_version, status_filter,
count, proposals: [...]}`.

> Note: `approve` returns the goal id; `kazi apply` takes a GOAL-FILE path, not a
> goal id. `plan`/`approve` persist the approved goal into a loadable
> goal-file -- run that file's path in Step 3.

### Step 3 -- converge (`kazi apply --harness <cheap> --json [--stream]`)

Run the approved goal with the CHEAP harness (the two-tier split):

```sh
kazi apply <goal-file> --workspace <path> --harness opencode --model local/qwen3.6 --json
```

`run --json` emits ONE terminal result object on termination (the schema below).
The exit code mirrors convergence: `0` only on `converged`, non-zero otherwise --
identical on both the human and `--json` surfaces.

For a LONG convergence, add `--stream` for a JSONL progress stream -- one
`{"event": "iteration", ...}` line per loop iteration, TERMINATED by the final
run-result object (the one line with NO `event` field). Read lines until you see
the object without an `event`; that is the terminal result you branch on:

```sh
kazi apply <goal-file> --workspace <path> --harness opencode --json --stream
```

### Step 4 -- parse the result and branch on `next_action`

`run --json` gives you both the terminal `status` and a single derived
`next_action` hint, so you never re-derive the branch from the predicate vector:

| `status`      | `next_action`  | exit | What the orchestrator does |
|---------------|----------------|------|----------------------------|
| `converged`   | `done`         | 0    | Finished. Ship / report. |
| `stuck`       | `investigate`  | != 0 | Inspect the predicate vector; the same set failed N times. |
| `over_budget` | `raise_budget` | != 0 | Raise the budget and re-run, or escalate. |
| `error`       | `investigate`  | != 0 | Pre-loop failure (vacuous goal, unknown harness); read `error`, fix. |

`next_action` is an orchestration HINT, not a kazi action -- the orchestrator
owns the policy (ADR-0023).

### Polling between steps (`kazi status <ref> --json`)

`kazi status <ref> --json` is a PURE read of the read-model (no loop runs,
nothing mutates). The `<ref>` resolves as a run's goal id first, else a
`proposal_ref`. Use it to poll where a run or proposal stands between steps:

```sh
kazi status <goal-id>      --json   # kind: "run"      -- latest iteration's vector
kazi status <proposal-ref> --json   # kind: "proposal" -- lifecycle state
```

An unknown ref is a JSON error envelope with a non-zero exit.


## 3. The versioned result schemas (pin `schema_version`)

Every `--json` object carries a `schema_version` (currently **1**). It is a
COMPATIBILITY surface: an additive change (a new field) leaves it unchanged; a
breaking change (a removed/renamed field, a changed type or meaning) bumps it.
ALL `--json` surfaces share the one number, so an orchestrator pins or checks
exactly one value.

**An orchestrator MUST pin or check `schema_version`.** Read it off the first
object you parse and refuse (or branch) if it is not the version you were written
against:

```sh
result=$(kazi apply "$GOAL" --workspace "$WS" --harness opencode --json)
ver=$(printf '%s' "$result" | jq -r .schema_version)
[ "$ver" = "1" ] || { echo "unexpected kazi schema_version: $ver" >&2; exit 1; }
next=$(printf '%s' "$result" | jq -r .next_action)
```

The two committed contracts:

- **`docs/schemas/run-result.md`** -- the `kazi apply --json` terminal result
  (`schema_version`, `goal_id`, `status`, `predicates` [the predicate vector of
  `{id, verdict}`], `iterations`, `budget_spent`, `next_action`, `reason`,
  `release_ref`; an `error` field when `status` is `error`). Also documents the
  `--stream` JSONL iteration event.
- **`docs/schemas/status.md`** -- the `kazi status --json` read (`kind: "run"` or
  `kind: "proposal"`, with the run's latest predicate vector or the proposal's
  lifecycle state).

A minimal `run --json` result:

```json
{
  "schema_version": 1,
  "goal_id": "cli-e2e",
  "status": "converged",
  "predicates": [
    { "id": "code", "verdict": "pass" },
    { "id": "live", "verdict": "pass" }
  ],
  "iterations": 4,
  "budget_spent": { "iterations": 4, "exceeded": null },
  "next_action": "done",
  "reason": null,
  "release_ref": "v2026.06.23-abc1234"
}
```

A predicate is `pass` only when it genuinely held against the real world,
including LIVE predicates, which pass only post-deploy. The vector -- not a single
exit code -- is what makes regression and partial progress legible.


## 4. Runtime introspection (no stale docs)

kazi self-describes, so an agent confirms the surface at runtime instead of
trusting a copy of this recipe (ADR-0024):

- **`kazi help --json`** -- the command/flag surface as a single JSON object:
  every command with its `summary`, positional `args` (with `required`), and
  `flags` (each with `name`, `type`, `description`, `aliases`). It is GENERATED
  from kazi's own command table, so it can never drift from what the parser
  accepts.
- **`kazi schema [<command>]`** -- the versioned result schema(s) for `--json`
  output, as data (field rows + an example). With a command (`apply` or `status`),
  that command's schema; with none, all of them. JSON-only by design; an unknown
  command is a JSON error with a non-zero exit.

Introspect first, then drive:

```sh
kazi help --json   | jq '.schema_version, (.commands[].name)'
kazi schema run    | jq '.schema_version, .fields[].name'
```


## 5. The richer alternative: the MCP server (`kazi mcp`)

Shelling out and parsing JSON is universal and works with any agent. For an
MCP-speaking harness there is a richer path: the kazi **MCP server** that wraps
these same commands -- plan / approve / apply / status -- as self-describing MCP
tools (tool descriptions + input/output schemas ARE the teaching). An MCP client
lists kazi's tools and drives the plan -> approve -> apply loop natively, with no
shelling or JSON parsing.

On an installed binary the server is the `kazi mcp` verb (T33.1, ADR-0044); a
source checkout can also start it with `mix kazi.mcp` (E16, ADR-0024). Both start
the SAME server, so an MCP client config is just:

```json
{ "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } }
```

It consumes the same proven JSON contract this recipe documents. For any non-MCP
agent, this recipe plus the two schemas is the complete, universal way to drive
kazi.


## See also

- `docs/concept.md` ss4 -- the three-layer positioning.
- `docs/adr/0023-harness-friendly-agent-drivable-cli.md` -- the agent-drivable
  CLI decision (the recipe shape, the two drive modes, the result contract).
- `docs/adr/0024-kazi-self-teaching-to-harnesses.md` -- self-teaching: the skill,
  `help --json` / `schema`, `AGENTS.md`, and the `kazi mcp` / `mix kazi.mcp` server.
- `docs/adr/0044-kazi-mcp-installed-subcommand.md` -- `kazi mcp` as a first-class
  installed subcommand (the installed leg of the MCP surface).
- `docs/schemas/run-result.md`, `docs/schemas/status.md` -- the committed schemas.
