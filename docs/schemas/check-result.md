# `kazi apply --check --json` result contract (schema_version 2)

The single, **versioned** JSON object `kazi apply <goal-file> --check --json`
emits to stdout on exit (issue #805, ADR-0026 L1). `--check` is kazi's
**observe-only** mode: it evaluates a goal's full predicate vector through the
real provider path **exactly once** and reports a terminal verdict — no
reconcile loop runs, no harness is ever dispatched, and no `[integrate]` /
`[deploy]` action ever fires. This is the surface for a merge gate or a
release-qualification check: "does the vector hold **right now**", not "grind
until it does".

## Invocation

```
kazi apply <goal-file> --workspace <path> --check [--json]
```

`--check` is read-only and safe anywhere: it never needs `--allow-primary-worktree`
or `--skip-preflight` (those exist for the executing `apply` path, T44.9). Like
every other `apply` execution mode it also accepts an **approved** proposal's
`prop-...` ref in place of a goal-file path (T39.2, ADR-0049) — the resolved
`Goal` is identical either way, so the result object below is the same shape
regardless of which one was named.

## How `--check` differs from a normal `apply` run

| | `apply` (no `--check`) | `apply --check` |
|---|---|---|
| Harness dispatch | Yes — drives the reconcile loop until converged/stuck/over_budget | **Never** — `dispatched` is always `false` |
| Observations | Many, across iterations | **Exactly one** (`Kazi.Runtime.check/2`, the same t0 observation `run/2` makes before its first dispatch) |
| All-pass vector at start | Rejected as a **vacuous goal** (`status: "error"`, `reason: "vacuous_goal"`) — nothing to build or repair | The **intended success case** — confirming an already-green vector is the whole point of a check |
| `[integrate]` / `[deploy]` | Runs on convergence | **Never** runs |
| Terminal `status` values | `converged`, `stuck`, `over_budget`, `tampered`, `error` | `pass`, `fail`, or `error` |
| Result object | [`run-result.md`](run-result.md) — `iterations`, `budget_spent`, `usage`, `economy`, ... | This document — a single flat verdict, none of the loop/economy fields apply |

The `[setup]` step (T69.12, ADR-0088) **does** run before the observation, same
as `run/2` — a check against a freshly created worktree is not a false red
because setup never ran.

## Compatibility

`schema_version` is the **same** compatibility surface `run-result.md` documents
— current version **2**. `--check --json`'s result shares the constant
(`@run_schema_version` in `lib/kazi/cli.ex`) with every other `--json` surface,
so a consumer parsing several kazi JSON surfaces with one version check does
not need a second one for `--check`. Because the version number alone does not
distinguish a check result from a loop result, **branch on `mode` and
`dispatched`**, not on `schema_version`, when a caller might see either object.

## Shape — passing check

```json
{
  "schema_version": 2,
  "goal_id": "cli-e2e",
  "mode": "check",
  "status": "pass",
  "dispatched": false,
  "predicates": [
    { "id": "code", "verdict": "pass" },
    { "id": "live", "verdict": "pass" }
  ],
  "next_action": "done"
}
```

## Shape — failing check

```json
{
  "schema_version": 2,
  "goal_id": "cli-e2e",
  "mode": "check",
  "status": "fail",
  "dispatched": false,
  "predicates": [
    { "id": "code", "verdict": "pass" },
    {
      "id": "live",
      "verdict": "fail",
      "evidence": {
        "reason": "connection refused",
        "url": "http://localhost:8080/health"
      }
    }
  ],
  "next_action": "investigate"
}
```

A predicate whose checker could not even run reports `verdict: "error"` instead
of `"fail"`, still carrying `evidence` (there is no later iteration to attach a
diagnostic to, so a check's failure report must be self-contained, issue
#1096):

```json
{
  "id": "code",
  "verdict": "error",
  "evidence": {
    "reason": "exec failed: mix test: not found"
  }
}
```

## Fields

| Field            | Type              | Meaning |
|------------------|-------------------|---------|
| `schema_version` | integer           | The contract version, shared with `run-result.md`. Bumped on a breaking change. |
| `goal_id`        | string            | The goal's id. |
| `mode`           | string            | Always the literal `"check"`. Distinguishes this object from an `apply --json` loop result and from an `--explain` schedule — the field a consumer switches on. |
| `status`         | string (enum)     | `"pass"` when the WHOLE predicate vector held at the single observation, `"fail"` otherwise. See [`status`](#status) below. |
| `dispatched`     | boolean           | Always `false`. Makes the no-execution contract explicit and machine-checkable: a caller never needs to infer "nothing ran" from the absence of loop fields. |
| `predicates`     | array of objects  | The observed predicate vector, one `{ "id", "verdict" }` per predicate — PLUS `evidence` for any predicate that did not pass. Sorted by `id` for a stable diff (same convention as `run-result.md`). See [`predicates[]`](#predicates) below. |
| `next_action`    | string (enum)     | `"done"` when `status` is `"pass"`, `"investigate"` when it is `"fail"`. Derived purely from `status`, same convention as `run-result.md`'s hint — NOT a kazi action; the orchestrator owns the policy. |

Nothing else is emitted: there is no `iterations`, `budget_spent`, `usage`,
`economy`, `next_action: "raise_budget"`, `reason`, `cause`, or any of
`run-result.md`'s other loop/economy fields — none of them apply to a single
observation.

### `status`

| Value    | Meaning |
|----------|---------|
| `"pass"` | Every predicate in the vector resolved `:pass` at the single observation (`Kazi.PredicateVector.satisfied?/1`). Exit `0`. |
| `"fail"` | At least one predicate resolved `:fail`, `:error`, or `:unknown` — any non-`:pass` verdict blocks a passing check, the same rule `run-result.md`'s `converged` uses for `unknown` (i795/#795). Exit `1`. A goal with **zero** predicates also reports `"fail"` (an empty vector is never satisfied) rather than erroring. |

Unlike `apply`'s loop, there is no `"converged"` / `"stuck"` / `"over_budget"` /
`"tampered"` here — a check has no budget to exceed and nothing to get stuck
across, because it observes exactly once.

### `predicates[]`

Each entry is `{ "id": string, "verdict": string }`, `verdict` one of `pass`,
`fail`, `error`, `unknown` (`Kazi.PredicateResult.status`) — the same verdict
vocabulary `run-result.md`'s `predicates[].verdict` documents. A predicate that
did **not** pass additionally carries `evidence`:

| Field      | Type              | Meaning |
|------------|-------------------|---------|
| `id`       | string            | The predicate's id. |
| `verdict`  | string (enum)     | `pass`, `fail`, `error`, or `unknown`. |
| `evidence` | object (optional) | Present only when `verdict` is `fail` or `error`. Absent for a passing predicate — there is nothing to investigate. |

**`evidence` here is not the same field ADR-0041 defines for `run-result.md`.**
`run-result.md`'s optional `predicates[].evidence` (the graded-result envelope)
is a curated array of LSP-`Diagnostic`-shaped objects (`{ file, line, rule,
message, ... }`) attached only to a *graded* predicate. A check's `evidence` is
the predicate's own raw `Kazi.PredicateResult.evidence` map — whatever shape
the provider stored — deep-sanitized to JSON-safe scalars (atoms become
strings, tuples and anything else `Jason` cannot encode are `inspect`ed) so an
`:error` result's evidence (which routinely carries a raw Elixir term, e.g.
`{:cmd_unrunnable, "..."}`) never crashes the encoder. There is no fixed
sub-schema for it beyond "JSON-safe map or scalar" — read it as diagnostic
detail, not a typed contract.

## Error object

`Kazi.Runtime.check/2` itself can fail **before** any observation is even
taken — an unknown predicate provider kind, or a failed `[setup]` step
(T69.12, ADR-0088). That path reuses the **exact same** error envelope
`run-result.md`'s [Error object](run-result.md#error-object) documents for a
pre-loop `apply` failure — `mode` and `dispatched` are **not** added to it:

```json
{
  "schema_version": 2,
  "goal_id": "cli-e2e",
  "status": "error",
  "error": "goal names provider kind(s) this build can't evaluate: :nonexistent_kind",
  "reason": "{:unknown_provider_kinds, [:nonexistent_kind]}",
  "next_action": "investigate"
}
```

```json
{
  "schema_version": 2,
  "goal_id": "cli-e2e",
  "status": "error",
  "error": "goal [setup] step failed before t0 observation (issue #1642): `npm ci` exit 1 — this is an environment/provisioning error, not a predicate result. Fix the setup command (or the goal's declared [setup] commands) and re-run.",
  "reason": "{:setup_failed, %{command: \"npm ci\", index: 0, reason: :exit_code, detail: \"exit 1\"}}",
  "next_action": "investigate"
}
```

Note `reason`'s rendering differs by the underlying Elixir term: a bare atom
reason (e.g. `run-result.md`'s `vacuous_goal`) renders as its bare string; a
compound reason — both of `check/2`'s own error shapes, `{:unknown_provider_kinds,
_}` and `{:setup_failed, _}`, are tuples — renders as the full `inspect/1`
text of the term, as in the two examples above. Either way `reason` is a
string, never structured JSON.

A consumer that only recognizes the passing/failing shape above must also
handle this one: when `mode` is **absent**, treat the object as the shared
run-error envelope (`status` is always `"error"` there), not as a check
result. Exit `1` in every case.

## Comparison with `apply --json`

| | `apply --check --json` (this doc) | `apply --json` (`run-result.md`) |
|---|---|---|
| Dispatches a harness | Never | Until converged/stuck/over_budget |
| `status` values | `pass`, `fail` (plus the shared `error` envelope) | `converged`, `stuck`, `over_budget`, `tampered`, `error` |
| All-pass at start | Success (`status: "pass"`) | Rejected as `vacuous_goal` (`status: "error"`) |
| Loop/economy fields (`iterations`, `budget_spent`, `usage`, `economy`, `cause`, `integration`, ...) | None — a single observation has no loop to report | Present per the rules `run-result.md` documents |
| `dispatched` field | Always present, always `false` | Not part of the contract (dispatch is implied by every non-error status) |
| `mode` field | Always `"check"` | Not part of the contract |

A reader who sees `mode: "check"` and `dispatched: false` is looking at this
document's shape; anything else parsing as `schema_version`/`status`/... with
no `mode` key is an `apply --json` loop result or its shared error envelope.
