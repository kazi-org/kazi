# `--json` signals -> skill-side escalation trigger (T30.3, ADR-0035)

> **Update (T45.7, ADR-0056 decision 5): the ladder can now live IN kazi-core as
> goal-file DATA.** ADR-0056 decision 5 *supersedes ADR-0035's decision 1 in part*:
> the escalation-ladder LOCATION moves from "skill-side only" into a declarable
> `[escalation]` goal-file block — see **"The `[escalation]` block"** below. The
> core PRINCIPLE is unchanged: kazi-core still holds NO selection policy; it walks
> exactly the model list the goal-file declares. The skill-side, count-driven
> ladder documented in the rest of this note remains valid (an orchestrator can
> still drive rungs across separate `kazi apply` invocations); the `[escalation]`
> block is the in-loop alternative that walks the ladder WITHIN one run.

## The `[escalation]` block — the ladder as goal-file DATA (T45.7, ADR-0056 d5)

Declare the ladder in the goal-file and kazi walks it inside the single run: on a
`stuck` OR `over_budget` verdict on the same failing predicate set (the T30.3
signal below), the loop RE-DISPATCHES the SAME goal at the next model in the ladder
instead of terminating — bounded by the ladder length (and an optional `max_rungs`
cap), at which point the terminal verdict stands. `converged` at any rung stops the
ladder immediately.

```toml
[escalation]
# rung 0 is the initial dispatch model; the loop steps forward on stuck/over_budget.
ladder = ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-4-8"]
max_rungs = 3   # optional; default = the ladder length
```

- **No `[escalation]` block** (or an empty `ladder`) is TODAY'S single-model
  behavior, byte-identical — no re-dispatch. A present block whose `ladder` key is
  omitted defaults to the three rungs above.
- A declared ladder is **authoritative**: rung 0 pins the initial dispatch model
  (overriding a caller `--model`), so the dispatched model sequence is exactly the
  ladder. Pin a single `--model` and omit the block to keep static tiering.
- **Each rung is one bounded converge**: the loop measures the stuck window AND the
  budget PER RUNG, so a fresh model gets a fresh window/budget rather than the
  exhausted tail of the prior rung.
- kazi-core holds **NO selection policy**: it walks exactly the declared list. It
  never decides which models are good or in what order beyond the goal-file.
- Introspect the config with `kazi schema escalation`.

This note maps the fields kazi's `--json` surface already emits to the
**escalation trigger** the skill's adaptive-tiering state machine (ADR-0035,
E30/T30.2) reads to decide *"stuck again on the same slice -> step the model up
the ladder."*

**Verdict: SUFFICIENT. No kazi-core change is needed.** kazi's existing
`apply --json` terminal result already exposes every field the skill needs to
drive a bounded `Haiku -> Sonnet -> Opus` escalation ladder. The cross-invocation
*count* ("stuck N times on this slice") is, and must remain, the **skill's own**
state-machine counter -- never kazi state. Holding that counter in kazi would be
exactly the model-selection/escalation policy ADR-0035 rejects (decision 1; the
ladder is a "skill-side state machine", decision 3). So this task ships no code
change to kazi core -- only this documented mapping.

## The escalation model (recap, ADR-0035 decision 3)

The skill owns a bounded, CAPPED ladder. Each rung is **one `kazi apply`
invocation** on the same slice/goal, dispatched with a chosen `--model`:

1. Start the slice on the cheapest capable model (e.g. Haiku).
2. Run `kazi apply --harness claude --model <current-rung> --json` on the slice.
3. Read the terminal result. If it converged, the slice is done -- reset to the
   cheap rung for the next slice.
4. If it did **not** converge (a stuck / over-budget / non-converged stop), step
   to the next model up the ladder and re-dispatch the SAME slice.
5. The ladder is capped: once it reaches the frontier model it stops escalating;
   kazi's own budget/stuck termination bounds each rung so the loop cannot run
   unboundedly.

kazi's job here is **signal sufficiency, not policy** (ADR-0035 decision 4). The
fields below are that signal.

## The signal: `kazi apply --json` terminal result

Per invocation the skill dispatches, it reads the single terminal result object
(`docs/schemas/run-result.md`, `schema_version` 2). The escalation-relevant
fields:

| Field | Type | Role in the escalation trigger |
|-------|------|--------------------------------|
| `goal_id` | string | **Identifies the slice.** Stable across the successive invocations the skill makes on one slice, so the skill keys its rung counter by `goal_id`. |
| `status` | enum: `converged` / `stuck` / `over_budget` / `error` | **The primary branch.** `converged` -> slice done, reset ladder. `stuck` or `over_budget` -> this rung did NOT converge -> the skill increments its rung counter and escalates. `error` -> a misconfig (vacuous goal / unknown harness), not a stuck slice; the skill fixes the goal, it does not escalate the model. |
| `next_action` | enum: `done` / `investigate` / `raise_budget` | The derived hint the skill branches on without re-deriving from the vector. `done` = converged (stop). `investigate` = stuck/non-converged (escalate the model). `raise_budget` = over_budget (the slice needs more budget; the skill may raise budget AND/OR step the model up). |
| `predicates[]` | array of `{id, verdict}` | **Confirms it is the SAME slice still failing.** The failing-predicate set (the entries whose `verdict` is `fail` / `error` / `unknown`) lets the skill verify the next rung is escalating against the same unmet predicates -- not a new slice -- and detect partial progress (the failing set shrinking across rungs) vs a hard plateau (the same failing set every rung). |
| `reason` | string \| null | Disambiguates `stuck` (the loop's same failing set persisted across N observations within the run, T1.5) from a budget dimension (`max_iterations` / `wall_clock` / `token_budget` / `max_dispatches` — T48.6, ADR-0058). |
| `budget_spent` | `{iterations, exceeded}` | `exceeded` names the budget dimension on an `over_budget` stop, so the skill can choose between "raise budget on the same model" and "step the model up". |
| `schema_version` | integer | The contract version the skill pins/checks before parsing (currently `2`). |

## The trigger, in one line

> On a `kazi apply --json` result for the slice's `goal_id` whose `status` is
> **`stuck`** or **`over_budget`** (equivalently `next_action` is `investigate`
> or `raise_budget`) -- i.e. NOT `converged` and NOT `error` -- with the same
> failing `predicates[]` set still unmet, the skill increments its per-`goal_id`
> rung counter and re-dispatches the SAME slice with the next `--model` up the
> capped ladder. On `converged` (`next_action: done`) it resets the ladder.

The "N times" in *"stuck on this slice N times"* is the skill's **own** counter
across the invocations it makes. kazi reports the per-invocation verdict; the
skill counts the rungs. This split is the ADR-0035 boundary: state in kazi
(reported), policy in the skill (the ladder and the count).

## Optional: `--stream` for within-run progress

`kazi apply --json --stream` additionally emits a JSONL `event: "iteration"`
line per loop observation before the terminal result
(`docs/schemas/run-result.md`, "Streaming progress"). Each carries the
per-iteration `predicates[]` vector and `converged`, so a skill that wants to
escalate *before* a rung fully terminates can watch the within-run trajectory
(e.g. the same failing set across every streamed observation = no progress this
rung). This is strictly additive: the terminal `status` already suffices for the
ladder; `--stream` only lets the skill react earlier.

## Why no field was added

The escalation trigger is fully expressible from the existing
`status` + `next_action` + `predicates[]` + `goal_id` (with `reason` /
`budget_spent` for the budget variant). The only thing kazi would need to add to
make the skill's job "easier" is a *cross-invocation* per-slice stuck **counter**
-- but that counter IS the orchestration policy ADR-0035 places in the skill, not
in kazi. Adding it would make kazi opinionated about escalation (ADR-0035
decision 1 / "Alternatives rejected": auto-tiering inside kazi). So per ADR-0035
decision 4 the default -- and correct -- outcome holds: **no kazi-core change.**
