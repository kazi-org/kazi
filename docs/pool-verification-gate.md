# The pool VERIFICATION GATE (kazi-gated `/apply --pool` merge)

This is the copy-pasteable, self-contained recipe a `/apply --pool` SESSION runs
to gate its own merge on OBJECTIVE convergence -- L1 ("verification gate") of
"kazi under `/apply --pool`" (ADR-0026). Before the session rebase-merges its
task's PR, it runs the task's acceptance predicates with `kazi apply --json` and
lands the PR **only when kazi reports `converged`**. On `stuck` / `over_budget` /
`error` it BLOCKS and ESCALATES -- it does not merge.

Git-refs only. NO NATS (NATS is required only at L3, ADR-0026 decision 3).

> Every kazi command and flag below is real -- the surface emitted by
> `kazi help --json` and dispatched in `lib/kazi/cli.ex`. Introspect it at
> runtime (`kazi help --json`, `kazi schema run`) rather than trusting a stale
> copy. This doc builds on the `acc:` bridge (`docs/acc-predicates-bridge.md`,
> T20.1) and the orchestrator recipe (`docs/orchestrator-recipe.md`, T15.8).

## Why a gate

A pooled session today decides for itself when its task is "done" -- a prose
Definition of Done enforced by trust + CI. ADR-0026 replaces that with an
objective gate: convert the task's `acc:` acceptance criteria into machine-checked
predicates, let kazi persist and run them, and land the PR only when the whole
predicate vector holds against the real world (including a live probe). This
kills the false-completion failure mode -- a session cannot merge plausible-but-
wrong work, because "done" lives in the controller, not in the session's opinion.

## The gate at a glance

```
  task's acc: line
      |  Kazi.Pool.AccBridge.acc_to_predicates/1   (T20.1, priv/scripts/acc_to_predicates.exs)
      v
  caller-drafts predicates JSON
      |  kazi plan --json --predicates   (caller-drafts; floor + persist, NO model)
      v
  kazi approve --json   ->  a runnable goal
      |  kazi apply --harness <h> --json      (the convergence gate)
      v
  decode the terminal result  ->  Kazi.Pool.Gate.decide/1
      |
      +--- status == "converged"  ->  :merge          (rebase-merge the PR)
      +--- stuck / over_budget / error  ->  {:block, reason}   (ESCALATE; do NOT merge)
```

The block-unless-converged rule is a pure function -- `Kazi.Pool.Gate.decide/1`
(in `lib/kazi/pool/gate.ex`) -- so the gate is testable in code, not just prose
(see "The decision, in code" below).

## Authoring runs on the released `kazi` binary (not the escript)

`plan` / `approve` PERSIST the proposal to the SQLite read-model, so they need
a kazi build with the native SQLite NIF. The **released `kazi` binary** (the
Burrito package, T6.2/ADR-0014) bundles it -- use plain `kazi plan` /
`kazi approve` / `kazi apply`. The dev `mix escript.build` `./kazi` CANNOT bundle a
NIF and will refuse authoring with "the read-model is unavailable; authoring
requires persistence"; from a source checkout use `mix kazi.apply <goal-file> ...`
for the RUN step and the released binary (or `iex -S mix` driving `Kazi.CLI.run/1`)
for `plan`/`approve`. The commands and JSON are identical across deliveries.

## Step 0 -- the task's `acc:` text

Take everything after `acc:` in the plan task's WBS line. Example (a real shape):

```sh
ACC='ExUnit green; the endpoint returns 200'
```

## Step 1 -- bridge the `acc:` line to a caller-drafts payload (T20.1)

`Kazi.Pool.AccBridge` is the thin, DETERMINISTIC, HERMETIC helper (pure parsing,
same input -> same output, no I/O). The runner prints the payload; `--no-start`
keeps stdout clean (the bridge needs no app boot):

```sh
mix run --no-start priv/scripts/acc_to_predicates.exs "$ACC" > /tmp/acc-predicates.json
```

For `ACC='ExUnit green; the endpoint returns 200'` this emits (verified):

```json
{
  "name": "ExUnit green",
  "predicates": [
    { "id": "acc-1-5830f9", "provider": "test_runner",
      "description": "ExUnit green",
      "config": { "cmd": "mix", "args": ["test"] } },
    { "id": "acc-2-d91a92", "provider": "http_probe",
      "description": "the endpoint returns 200",
      "config": { "expect_status": 200 } }
  ]
}
```

See `docs/acc-predicates-bridge.md` for the full clause-classification rules
(test_runner / http_probe / prod_log, and the non-fabrication fallbacks).

## Step 2 -- propose (caller-drafts) and review the floor (T15.8)

Feed the payload to `kazi plan --json --predicates` -- the SINGLE sanctioned
authoring path (ADR-0023). caller-drafts means kazi spawns **NO inner model**: it
applies the deterministic clarify FLOOR (flags a missing live-verification target
+ scope), persists the proposal, and returns the `proposal_ref` + the open
`clarify` gaps.

```sh
kazi plan --json --predicates "$(cat /tmp/acc-predicates.json)"
# ...or pipe it on stdin (kazi reads stdin under --json):
mix run --no-start priv/scripts/acc_to_predicates.exs "$ACC" | kazi plan --json
```

`propose --json` emits one object: `goal_id`, `proposal_ref` (the approve handle),
`status`, `predicates`, `rationale`, and a `clarify` array (each
`{id, prompt, recommended}`). Read the floor:

```sh
DRAFT=$(kazi plan --json --predicates "$(cat /tmp/acc-predicates.json)")
PROPOSAL_REF=$(printf '%s' "$DRAFT" | jq -r .proposal_ref)
printf '%s' "$DRAFT" | jq '.clarify'    # the open gaps the floor surfaced
```

If `clarify` flags a missing live-verification target, sharpen the `acc:` (name
the deployed URL, or add a prod-log clause), re-bridge, and re-propose. The gate
is only HONEST with a live predicate (ADR-0002, ADR-0026): a task that is "merge-
able" must have a predicate that passes only post-deploy.

## Step 3 -- approve, then run as the gate (T15.8)

```sh
kazi approve "$PROPOSAL_REF" --json
```

`approve --json` emits `{schema_version, proposal_ref, status: "approved",
goal_id}`. The approved goal is now runnable.

> `kazi apply` takes a GOAL-FILE path (positional), NOT `--goal <id>`. From a source
> checkout the cleanest gate is to run the SAME predicates the session authored:
> keep the bridged predicates in a goal-file the session controls and run that
> file. Minimal goal-file for the example above (`gate.goal.toml`):
>
> ```toml
> id = "gate-<task-id>"
> name = "<task-id> verification gate"
>
> [budget]
> max_iterations = 10
>
> [scope]
> workspace = "."
>
> [[predicate]]
> id = "code"
> provider = "test_runner"
> description = "ExUnit green"
> cmd = "mix test"
>
> [[predicate]]
> id = "live"
> provider = "http_probe"
> description = "the endpoint returns 200 in prod"
> url = "https://<deployed-service>/<path>"
> expect_status = 200
> ```
>
> (`plan`/`approve` give you the reviewed FLOOR -- the live-target check -- on
> the same predicates; the goal-file is what `apply` loads. A `kazi plan
> --from-acc` flag that fuses the approved goal directly is a deliberate
> follow-up, T20.2+.)

Run it as the merge gate (released binary, or `mix kazi.apply` from source):

```sh
RESULT=$(kazi apply gate.goal.toml --workspace . --harness claude --json)
# from a source checkout:
# RESULT=$(mix kazi.apply gate.goal.toml --workspace . --harness claude --json)
```

`run --json` emits ONE terminal result object on termination (the schema in
`docs/schemas/run-result.md`). The exit code mirrors convergence: `0` only on
`converged`, non-zero otherwise. For a LONG convergence add `--stream` -- a JSONL
progress stream terminated by the same final object (the one line with NO `event`
field); read lines until you see it, then branch on that object.

## Step 4 -- parse the result and BLOCK unless `converged`

Pin `schema_version`, then branch on `status`. **Merge only on `converged`; on
`stuck` / `over_budget` / `error`, escalate and do NOT merge.**

```sh
# Pin the contract version first (refuse an unpinned result).
VER=$(printf '%s' "$RESULT" | jq -r .schema_version)
[ "$VER" = "1" ] || { echo "GATE BLOCK: unexpected kazi schema_version $VER -- do NOT merge" >&2; exit 1; }

STATUS=$(printf '%s' "$RESULT" | jq -r .status)
NEXT=$(printf '%s' "$RESULT"   | jq -r .next_action)

case "$STATUS" in
  converged)
    echo "GATE PASS: kazi converged -- safe to rebase-merge."
    ;;                                  # proceed to rebase-merge the PR
  stuck)
    echo "GATE BLOCK (next_action=$NEXT): the same predicate set failed across iterations." >&2
    printf '%s' "$RESULT" | jq '.predicates'   # inspect the failing vector
    exit 1 ;;                           # ESCALATE -- investigate; do NOT merge
  over_budget)
    DIM=$(printf '%s' "$RESULT" | jq -r '.budget_spent.exceeded')
    echo "GATE BLOCK (next_action=$NEXT): budget dimension '$DIM' exhausted." >&2
    exit 1 ;;                           # raise the budget + re-run, or escalate
  error|*)
    echo "GATE BLOCK (next_action=$NEXT): $(printf '%s' "$RESULT" | jq -r '.error // .status')" >&2
    exit 1 ;;                           # pre-loop failure -- fix the goal/harness
esac
```

The branch table (from `docs/schemas/run-result.md`, verified against the CLI):

| `status`      | `next_action`  | exit | Gate decision |
|---------------|----------------|------|---------------|
| `converged`   | `done`         | 0    | **MERGE** -- the whole vector held, incl. the live probe. |
| `stuck`       | `investigate`  | != 0 | **BLOCK** -- same set failed N times; inspect the vector, escalate. |
| `over_budget` | `raise_budget` | != 0 | **BLOCK** -- budget ceiling hit; raise + re-run, or escalate. |
| `error`       | `investigate`  | != 0 | **BLOCK** -- pre-loop failure (vacuous goal, unknown harness); fix. |

The gate FAILS CLOSED: the only path to merge is an explicit `converged` at the
pinned version. An unexpected `schema_version`, a missing/unknown `status`, or a
malformed result all BLOCK -- a result the gate cannot positively read as
`converged` is never mistaken for a pass.

## The decision, in code (`Kazi.Pool.Gate`)

The block-unless-converged logic is a tested pure function so the gate is more
than prose. `Kazi.Pool.Gate.decide/1` takes a DECODED `kazi apply --json` result
and returns `:merge` or `{:block, reason}` (the `reason` is the copy-pasteable
line a session reports on the PR):

```elixir
RESULT
|> Jason.decode!()              # the one terminal run-result line
|> Kazi.Pool.Gate.decide()
# => :merge                     # status == "converged" at schema_version 1
# => {:block, "kazi reported status=stuck (next_action=investigate): ...; do NOT merge"}
```

It is covered by `test/kazi/pool/gate_test.exs`, which asserts -- over REAL
`kazi apply --json` JSON fixtures (the exact shapes `cli_run_json_test.exs` checks)
-- that a NON-converged result (`stuck` / `over_budget` / `error`) BLOCKS with a
clear reason, a `converged` one returns `:merge`, and the gate fails closed on an
unexpected `schema_version` / missing `status` / non-object input.

## Acceptance (how this gate is demonstrated)

- **A converged task passes.** A `run --json` result with `status: "converged"`
  (schema_version 1) -> `Kazi.Pool.Gate.decide/1` returns `:merge` and the shell
  gate proceeds to rebase-merge. (Fixture: `@converged_json` in the gate test.)
- **A NON-converged task is BLOCKED with a clear reason.** A `stuck` result
  (`{"status":"stuck","next_action":"investigate","reason":"stuck", ...}`) ->
  `{:block, "kazi reported status=stuck (next_action=investigate): the same
  predicate set failed across iterations -- investigate the failing predicates;
  do NOT merge"}`; the shell gate exits non-zero and does NOT merge. `over_budget`
  and `error` block the same way with their own reasons. (Fixtures: `@stuck_json`,
  `@over_budget_json`, `@error_json`.)
- **Every command verified against `kazi help --json`.** `plan`
  (`--json`/`--predicates`), `approve` (`--json`), `run <goal-file>`
  (`--workspace`/`--harness`/`--model`/`--json`/`--stream`), and `status`
  (`--json`) are exactly the surface the command table emits.

## Scope (what this is NOT)

- L1 only -- the verification gate. The objective-done loop (L2, T20.4), blast-
  radius leasing (L3, NATS), and shared observability (L4) are later ADR-0026
  layers.
- It composes BELOW `/claim`: `/claim` selects the task (git-ref lock); this gate
  decides whether the claimed task's PR may merge. Neither replaces the other
  (ADR-0026 decision 1).
- The opt-in `/apply --verify-with-kazi` gate that wires this into the GLOBAL
  `/apply` skill is a separate cross-repo task (T20.3); it must stay in sync with
  kazi via `kazi help --json`.

## See also

- `docs/adr/0026-kazi-under-apply-pool.md` -- the L1 gate decision.
- `docs/acc-predicates-bridge.md` -- the `acc:` -> predicates bridge (T20.1).
- `docs/orchestrator-recipe.md` -- the full propose -> approve -> run recipe (T15.8).
- `docs/schemas/run-result.md` -- the `status` / `next_action` fields to branch on.
- `lib/kazi/pool/gate.ex`, `test/kazi/pool/gate_test.exs` -- the tested decision.
