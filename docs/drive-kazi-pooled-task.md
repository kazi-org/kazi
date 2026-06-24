# Drive kazi for a pooled task (the orchestrator recipe, L2)

This is the copy-pasteable recipe a pooled `/apply` session runs to drive ONE
plan task to OBJECTIVE DONE with kazi -- L2 ("objective done + convergence loop
per task") of "kazi under `/apply --pool`" (ADR-0026). The session becomes the
ORCHESTRATOR: it authors the task's predicates, hands them to kazi, and lets
kazi's convergence LOOP -- not a single pass -- decide when the task is done.

It is the "drive to done" companion to the L1 verification gate
(`docs/acc-predicates-bridge.md`, T20.2). L1 wires the `acc:` line into one
proposed goal and gates the merge on convergence; L2 is the full per-task loop a
session runs around that gate, with the guards (stuck / regression / flake /
budget) that turn a stalled task into a reported escalation instead of a silent
death.

> Every kazi command and flag below is real -- the surface emitted by
> `kazi help --json` and dispatched in `lib/kazi/cli.ex`. Introspect it at
> runtime rather than trusting a stale copy.

This doc is the POOL-TASK application of the canonical recipe. It does NOT
restate the JSON contract -- the `--json` shapes, `schema_version`, and the
`next_action` derivation live in `docs/orchestrator-recipe.md` (T15.8) and the
committed schemas (`docs/schemas/run-result.md`, `docs/schemas/status.md`). Read
those for the contract; read THIS for how a pool session applies it per task.


## 1. The one rule: merge on `converged`, not on a single pass

The single most important thing a pool session must internalize:

> kazi's loop RE-DISPATCHES an insufficient first attempt automatically. The
> session does NOT merge on the first `kazi run`. It merges ONLY when kazi
> reports `status: "converged"` (`next_action: "done"`, exit `0`).

A deliberately-insufficient first dispatch (the cheap implementer leaves a test
red, skips the live probe, or regresses a previously-green predicate) is NOT a
merge signal. The loop observes the failing predicate vector and dispatches
again, guarded by stuck / regression / flake / budget (sec. 4), until the WHOLE
vector holds against the real world (including any live predicate, which passes
only post-deploy) or a guard halts it. "Objective done, honest result" means the
session reads the terminal `status` and branches -- it never asserts done itself.

This is exactly the false-completion failure mode ADR-0026 hardens: session-
asserted done is replaced by the controller's evidence-backed `converged`.


## 2. The per-task loop

```
  claim task  (refs/claims/* -- /apply --pool, the OUTER coordination)
        |
        v
  acc: line  ->  caller-drafts predicates  (T20.1 bridge -- docs/acc-predicates-bridge.md)
        |
        v
  kazi propose --json --predicates <payload>   (floor + persist, NO model)
        |  review the clarify gaps; re-propose if a gap matters
        v
  kazi approve <proposal-ref> --json            (proposed -> approved)
        |
        v
  kazi run <goal-file> --workspace <ws> --harness <h> --json [--stream]
        |   kazi's OWN loop converges (re-dispatch on every insufficient pass)
        v
  parse the terminal result  ->  branch on next_action (sec. 3)
        |
   +----+-----------------+------------------+------------------+
   | converged            | stuck            | over_budget      | error
   v                      v                  v                  v
  merge the PR          escalate           raise budget       fix the goal,
  (objective done)      (do NOT merge)     + re-run, or       re-propose
                                           escalate
```

The CLAIM is the outer task lock; the kazi run is the inner objective-done gate.
Neither replaces the other (ADR-0026 decision 1). Blast-radius LEASING across
sessions is L3 and needs NATS; this L2 recipe is git-refs only.


### Step 0 -- claim the task (unchanged `/apply --pool`)

Claim the task id as usual (`/claim`, atomic git-ref lock). Read the task's
`acc:` line from `docs/plan.md` -- the acceptance text you will turn into
predicates.

```sh
ACC='ExUnit -- the importer yields grouped predicates; `mix format` clean; GET /healthz returns 200 in prod'
```

### Step 1 -- bridge `acc:` -> caller-drafts predicates (T20.1)

`Kazi.Pool.AccBridge` is the deterministic, hermetic helper that maps the `acc:`
clauses to a caller-drafts predicates payload. It is pure (same `acc:` -> same
payload) and is NOT a kazi subcommand; the runner exposes it:

```sh
mix run --no-start priv/scripts/acc_to_predicates.exs "$ACC" > /tmp/acc-predicates.json
```

See `docs/acc-predicates-bridge.md` for the mapping rules (which clause shapes
become `test_runner` / `http_probe` / `prod_log`, and the two non-fabrication
rules). The payload is the `{"name","predicates":[...],"rationale"}` object the
next step feeds to kazi.

### Step 2 -- propose (caller-drafts: floor + persist, NO model)

```sh
kazi propose --json --predicates "$(cat /tmp/acc-predicates.json)"
#   ...or pipe it (kazi reads stdin under --json):
mix run --no-start priv/scripts/acc_to_predicates.exs "$ACC" | kazi propose --json
```

caller-drafts is the SINGLE authoring path (ADR-0023): the session supplies the
predicates, so kazi spawns NO inner model -- it applies the deterministic clarify
FLOOR (flags a missing live-verification target + scope), persists the proposal,
and emits the draft. The result carries `goal_id`, `proposal_ref` (the approve
handle), `predicates`, `rationale`, and a `clarify` array of open gaps. (Field
shapes: `docs/orchestrator-recipe.md` section "Step 1".)

Review the `clarify` gaps. If it flags a missing live-verification target,
SHARPEN the `acc:` (name the deployed URL / add a prod-log clause) and re-bridge
-> re-propose. The gate is only honest with a live predicate (ADR-0002,
ADR-0026): without one, `converged` would never require a real deploy.

### Step 3 -- approve

```sh
kazi approve <proposal-ref> --json
```

Emits `{schema_version, proposal_ref, status: "approved", goal_id}`. The goal is
now runnable.

> Note (same as the canonical recipe): `approve` returns a goal ID, but
> `kazi run` takes a GOAL-FILE PATH, not an id. `propose`/`approve` persist the
> approved goal into a loadable goal-file -- run THAT file's path in Step 4.
> `kazi run` has no `--goal` flag; the goal-file is the positional argument.

### Step 4 -- run to convergence (the objective-done gate)

Run the approved goal-file with the chosen harness. The two-tier split lets the
session tier the inner loop to a CHEAP/local harness (ADR-0026 L2):

```sh
kazi run <goal-file> --workspace <ws> --harness opencode --model dgx/qwen3.6 --json
```

`--harness claude` (default) or `--harness opencode`; `--model` overrides the
goal-file's harness model. `run --json` emits ONE terminal result object; the
exit code mirrors convergence (`0` only on `converged`).

THIS is where kazi's loop runs -- observe the predicate vector, dispatch the
harness against the failing predicates, re-observe, integrate, deploy, re-observe
the live predicate -- iterating until convergence or a guard. The session waits
for the TERMINAL object; it does not act on intermediate state.

### Step 5 -- branch on `next_action` (sec. 3) -- merge only on `converged`.


## 3. The `next_action` branch table (pool-task actions)

`run --json` gives both the terminal `status` and a derived `next_action` hint,
so the session never re-derives the branch from the vector. The mapping of
`status` -> `next_action` -> exit is the canonical contract
(`docs/schemas/run-result.md`); below is what the POOL SESSION does for each:

| `status`      | `next_action`  | exit | Pool session action |
|---------------|----------------|------|---------------------|
| `converged`   | `done`         | 0    | MERGE the PR (rebase-merge). Objective done -- the whole vector held, incl. the live probe. Release the claim. |
| `stuck`       | `investigate`  | != 0 | Do NOT merge. The same failing set persisted N iterations (sec. 4); kazi already fired its escalation hook. ESCALATE the task (hand off / report) -- a reported `stuck`, not a silent death. |
| `over_budget` | `raise_budget` | != 0 | Do NOT merge. A budget ceiling was hit; `budget_spent.exceeded` / `reason` names the dimension. Raise the budget and re-run, or escalate. |
| `error`       | `investigate`  | != 0 | Do NOT merge. A pre-loop failure (vacuous goal, unknown harness/provider); read `error`, fix the goal/flags, re-propose. |

Only the `converged` row merges. Every other row is "do NOT merge" -- the
session keeps the claim and either re-runs (after raising budget / fixing the
goal) or escalates honestly. `next_action` is an orchestration HINT; the session
owns the policy (ADR-0023).

To re-check a run's state between steps without driving the loop, use the pure
read `kazi status <ref> --json` (`<ref>` resolves as a run goal id, else a
proposal ref) -- see `docs/orchestrator-recipe.md` section "Polling between steps".


## 4. The loop's guards (why a first pass is re-dispatched, not merged)

These are kazi's OWN loop guards (`lib/kazi/loop.ex`); the session does not
implement them -- it just reads the terminal `status` they produce. They are why
an insufficient first attempt is handled inside the loop instead of leaking out
as a false `converged`:

- **Re-dispatch (the default).** When a CODE predicate is failing, the loop
  dispatches the harness again with the failing-predicate evidence as context,
  then re-observes. A red test after the first pass is simply the next
  observation's work-list -- the loop iterates, it does not terminate. Code green
  but not landed -> integrate; landed but not deployed -> deploy; then it
  re-observes the LIVE predicate against the deployed artifact. `converged` is
  reached ONLY when the whole vector (including live) holds.

- **Stuck guard (T1.5).** If the SAME non-empty failing set (restricted to the
  CODE predicates the agent can act on -- live/quarantined excluded) persists
  across N consecutive observations, the loop has made no progress: it fires the
  human-escalation hook and stops as `status: "stuck"` (`next_action:
  "investigate"`). The session escalates rather than burning more iterations.

- **Regression guard (T1.2).** A predicate that was green and goes red
  (green->red) is detected and attributed to the dispatch in its window. The
  loop keeps reconciling the regressed predicate through the ordinary dispatch
  path -- a regression is just another unsatisfied observation, never a merge.

- **Flake guard (T1.3).** A failing predicate is re-run up to `flake_max_retries`
  times via the real provider; a result sequence classified flaky is QUARANTINED
  (recorded `unknown`, excluded from the convergence/work calculus) so a flaky
  check neither blocks nor falsely satisfies convergence. A consistently-failing
  predicate is taken as a real failure and drives a dispatch.

- **Budget guard (T1.4).** A hard ceiling (iterations / wall-clock / tokens) is
  checked once at the start of every tick BEFORE more work is dispatched.
  Crossing it stops the loop as `status: "over_budget"` with the exceeded
  dimension in `reason` / `budget_spent.exceeded` (`next_action: "raise_budget"`)
  -- the loop refuses to burn unbounded work.

Together these are why "merge on a single pass" is wrong: the first `kazi run`
either converges (every predicate genuinely holds) or halts on a guard the
session must act on. There is no path where an insufficient first attempt is
reported as done.


## 5. Streamed monitoring (`--stream`) for a long convergence

A pooled task can take many iterations (the cheap harness grinds). Add `--stream`
to follow the loop live -- a JSONL stream, one `{"event":"iteration",...}` line
per observation, TERMINATED by the single run-result object (the line with NO
`event` field), which is the one the session branches on:

```sh
kazi run <goal-file> --workspace <ws> --harness opencode --json --stream
```

Read lines until the object WITHOUT an `event` field; that is the terminal
result. A minimal monitoring loop (jq):

```sh
kazi run "$GOAL_FILE" --workspace "$WS" --harness opencode --json --stream \
| while IFS= read -r line; do
    event=$(printf '%s' "$line" | jq -r '.event // "result"')
    if [ "$event" = "iteration" ]; then
      # progress: the predicate vector at this observation
      printf '%s' "$line" | jq -c '{iteration, converged, predicates}'
    else
      # the terminal result -- branch here, merge ONLY on converged
      ver=$(printf '%s' "$line"  | jq -r '.schema_version')
      [ "$ver" = "1" ] || { echo "unexpected kazi schema_version: $ver" >&2; exit 1; }
      status=$(printf '%s' "$line" | jq -r '.status')
      next=$(printf '%s'   "$line" | jq -r '.next_action')
      echo "terminal: status=$status next_action=$next"
      case "$status" in
        converged) echo "OBJECTIVE DONE -> merge the PR" ;;
        *)         echo "NOT done ($status) -> $next; do NOT merge" ;;
      esac
    fi
  done
```

Watch the per-iteration `predicates` go red -> green across the stream: that IS
the loop re-dispatching the insufficient first attempt. The session acts only on
the terminal line. (Stream-event field shapes: `docs/schemas/run-result.md`
section "Streaming progress".)


## 6. Scope (what this recipe is NOT)

- It is L2 only -- the objective-done loop per task, on git-refs. Blast-radius
  LEASING across sessions (L3) and shared observability + direction (L4) are
  later ADR-0026 layers; L3 is the layer that adds the NATS dependency.
- It does not replace `/apply --pool` or `/claim` (ADR-0026 decision 5). kazi is
  the inner CONTROLLER beneath the session-as-orchestrator; the claim stays the
  outer task lock.
- It does not add a kazi subcommand. The `acc:` bridge is a runner script
  (`priv/scripts/acc_to_predicates.exs`), and a `/apply --verify-with-kazi` gate
  in the global skill is a deliberate follow-up.


## See also

- `docs/orchestrator-recipe.md` (T15.8) -- the CANONICAL recipe + JSON contract
  this doc applies per pool task. Read it for the `--json` field shapes,
  `schema_version`, and runtime introspection (`kazi help --json` / `schema`).
- `docs/acc-predicates-bridge.md` (T20.1/T20.2) -- the L1 verification gate and
  the `acc:` -> predicates mapping rules this recipe's Step 1 uses.
- `docs/adr/0026-kazi-under-apply-pool.md` -- the L1-L4 layering; this is L2.
- `docs/schemas/run-result.md`, `docs/schemas/status.md` -- the committed
  `--json` result + status schemas the branch table reads.
- `lib/kazi/loop.ex` -- the convergence loop + the stuck / regression / flake /
  budget guards described in sec. 4.
