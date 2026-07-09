# `kazi apply --json` result contract (schema_version 2)

The single, **versioned** JSON object `kazi apply --json` emits to stdout on
termination (ADR-0023 decision 2). It is the machine surface an orchestrating
agent branches on — it parses this object, never prose. Human output stays the
default; `--json` is opt-in and additive.

The object renders the convergence loop's **own** terminal result
(`Kazi.Loop.result/0`): nothing is re-derived or re-run. One JSON object is
emitted on stdout and the process exits `0` on convergence, non-zero otherwise.
The exit code is the same on both surfaces; `--json` chooses only the output
shape.

`apply` takes either a goal-file path or an **approved** proposal's `prop-...`
ref (T39.2, ADR-0049) — the handle `plan --json` mints and `approve --json`
flips — loaded straight from the read-model, so an orchestrator never
reconstructs a goal-file. The result object is identical either way; a
non-approved or unknown ref is the standard `{"error": ..., "schema_version"}`
envelope with a non-zero exit.

## Command key (`apply`)

The verb that produces this object is **`apply`** (`kazi apply --json`). The old
verb **`run`** (`kazi run --json`) was a deprecated alias (ADR-0032) and was
**removed in v0.6.0** (T27.9): `kazi run` / `kazi propose` no longer parse. Call
`apply` (and `plan` for authoring).

## Compatibility

`schema_version` is a compatibility surface. An additive change (a new field)
leaves it unchanged; a **breaking** change (a removed/renamed field, a changed
type or meaning) bumps it. An orchestrator recipe should pin or check
`schema_version`.

Current version: **2**. (Bumped from 1 by ADR-0032: the contract's command verb
was renamed `run` -> `apply`; an orchestrator pinning the old version must
update. The result-object SHAPE is unchanged — only the producing verb and the
version differ.)

ADR-0041 (envelope v2) adds OPTIONAL per-predicate fields (`score`, `prior_score`,
`direction`, `evidence`) to `predicates[]`. These are **additive** — present only
on a graded result, absent on a boolean one — so `schema_version` stays **2** and
an orchestrator pinning v2 keeps parsing unchanged. See
[`predicates[]` — graded fields](#predicates--graded-fields-adr-0041) below.

ADR-0046 (economy accounting) adds the OPTIONAL `usage` envelope and the
`budget_spent.tokens` rollup. Both are **additive** — `usage` is present only when
the harness reported usage, and `budget_spent.tokens` is a new key on an existing
object — so `schema_version` stays **2** (the same rule as ADR-0041; bumping the
integer would break an orchestrator that pins `schema_version == 2`). An
orchestrator pinning the pre-envelope contract keeps reading `budget_spent.tokens`
(the single rolled-up total) and ignores the richer cached-vs-fresh split. See
[`usage` — economy envelope](#usage--economy-envelope-adr-0046) below.

ADR-0046 also adds the OPTIONAL `economy` object (T34.6): the run-end KPIs
**derived** from the per-iteration envelopes (cost / converged-predicate,
wall-clock / converged-predicate, iterations-to-convergence, fresh-input-avoided,
rediscovery-tool-calls-avoided, and the run's stuck flag). It is **additive** —
`status`, `stuck`, and `iterations` are always present and every derived KPI is
**omitted when unavailable** (absent ≠ zero) — so `schema_version` stays **2**. See
[`economy` — run-end KPIs](#economy--run-end-kpis-adr-0046) below.

ADR-0058 (T48.5) adds the OPTIONAL `usage_fidelity` string. **Additive** — present
only as `"unreported"` when a `max_tokens` ceiling was set but a dispatch reported
no usage the loop could count (the ceiling could never bind), absent on every
other run — so `schema_version` stays **2**.

ADR-0058 (T48.4) adds the OPTIONAL `cause` object naming the honest terminal
cause alongside `status`/`reason` — `over_budget` is not always genuine budget
exhaustion, and `stuck` is not always an ordinary failing-set stall. **Additive**
— present only when the loop classified one (`budget_exhausted` / `error_wedged`
/ `quarantine_blocked`), absent on a clean converge or a stop that is exactly
what it says it is — so `schema_version` stays **2**. See
[`cause` — honest terminal cause class](#cause--honest-terminal-cause-class-adr-0058)
below.

ADR-0065 (T50.2) adds the OPTIONAL `integration` object reporting how a
worktree-isolated serial run's converged commits landed on the base.
**Additive** — present only when a landing was attempted, absent on in-place
runs and runs with nothing integrable — so `schema_version` stays **2**. One
behavioral note an orchestrator should absorb: a `converged` result with
`integration.landed == false` exits **1** (converged-but-not-landed is not a
clean success; the work survives on the reported `task_branch`). See
[`integration` — serial landing verdict](#integration--serial-landing-verdict-adr-0065)
below.

## Shape

```json
{
  "schema_version": 2,
  "goal_id": "cli-e2e",
  "status": "converged",
  "predicates": [
    { "id": "code", "verdict": "pass" },
    { "id": "live", "verdict": "pass" }
  ],
  "iterations": 4,
  "budget_spent": { "iterations": 4, "exceeded": null, "tokens": 21900 },
  "usage": {
    "input_tokens": 1500,
    "cached_input_tokens": 18000,
    "cache_write_tokens": 0,
    "output_tokens": 2400,
    "cost_usd": 0.0123
  },
  "economy": {
    "status": "converged",
    "stuck": false,
    "iterations": 4,
    "converged_predicates": 2,
    "iterations_to_convergence": 4,
    "tokens": 21900,
    "cost_usd": 0.0123,
    "cost_per_converged_predicate": 0.00615,
    "wall_clock_s": 88.0,
    "wall_clock_per_converged_predicate": 44.0,
    "fresh_input_tokens_avoided": 18000,
    "rediscovery_tool_calls_avoided": 12
  },
  "next_action": "done",
  "reason": null,
  "release_ref": "v2026.06.23-abc1234"
}
```

A stuck run whose cause was classified (ADR-0058, T48.4) carries the additive
`cause` object alongside `status`/`reason`:

```json
{
  "status": "stuck",
  "reason": "stuck",
  "cause": {
    "class": "error_wedged",
    "ids": ["live_route"],
    "reasons": { "live_route": "missing_url" }
  }
}
```

(`usage` is present only when the harness reported usage, and each of its fields is
omitted when unreported — the example above shows a Claude run that reported no
`reasoning_tokens`.)

## Fields

| Field            | Type                | Meaning |
|------------------|---------------------|---------|
| `schema_version` | integer             | The contract version. Bumped on a breaking change. |
| `goal_id`        | string              | The goal's id. |
| `status`         | string (enum)       | The terminal status — one of `converged`, `stuck`, `over_budget`, `error`. The orchestrator's primary branch. |
| `predicates`     | array of objects    | The **predicate vector**: one `{ "id", "verdict" }` per predicate at the terminal observation, sorted by `id` for a stable diff. |
| `iterations`     | integer             | The loop's observation count. |
| `budget_spent`   | object              | What the run consumed: `{ "iterations": integer, "exceeded": string\|null, "tokens": integer }`. `exceeded` names the budget dimension only when `status` is `over_budget`, else `null`. `tokens` is the single rolled-up token total — cached reads counted at full weight (ADR-0046 back-compat); the cached-vs-fresh split lives in `usage`. NOTE: the `max_tokens` *ceiling check* discounts cached reads by the goal's `cached_read_weight` (T34.4, ADR-0046 #4), so a cache-hit-heavy run is not falsely flagged `over_budget` even though `tokens` reports the un-discounted total. |
| `usage`          | object (optional)   | ADR-0046 economy envelope. **Additive, optional** — present only when the harness reported usage. See [`usage` — economy envelope](#usage--economy-envelope-adr-0046). |
| `usage_fidelity` | string (optional)   | T48.5 (ADR-0058 §4): **Additive, optional** — present ONLY as `"unreported"` when a `max_tokens` ceiling was set on this goal but at least one dispatch reported no usage the loop could count (e.g. the `claw` profile, ADR-0022, reports none by design), so the ceiling could never bind. Absent on every other run — an orchestrator sees this key only when its token budget is not actually being enforced. |
| `economy`        | object              | ADR-0046 run-end KPIs derived from the per-iteration envelopes. **Additive** — `status`/`stuck`/`iterations` always present; each derived KPI omitted when unavailable (absent ≠ zero). See [`economy` — run-end KPIs](#economy--run-end-kpis-adr-0046). |
| `context_store`  | object (optional)   | ADR-0045 context-store byte accounting, present only when the run used `--context-store`. **Additive, optional** — `{ "provider": string, "indexed_bytes": integer, "returned_bytes": integer, "saved_bytes": integer, "budget": integer }`. Absent ⇒ the store was off and the result is byte-identical to today. |
| `stuck_bundle`   | object (optional)   | ADR-0045 §5 stuck-escalation bundle, present only on a stuck stop (`status` `stopped`, `reason` `stuck`). **Additive, optional** — `{ "failing_predicates": [{ "id": string, "failure": string }], "changed_files": [string], "snippets": [{ "source": string\|null, "text": string }], "bytes": integer }`. Bounded + redacted; the escalating orchestrator hands the higher model rung this instead of the full transcript. Absent ⇒ no stuck stop. |
| `quarantine`     | array of strings (optional) | i795/#795: the predicate ids quarantined as flaky (T1.3, `Kazi.Loop.Flake`) at the terminal observation. **Additive, optional** — present only when non-empty. A quarantined predicate's status is `unknown`, never `pass`, so `status` can never be `converged` while this is present; it names WHICH predicate(s) keep a non-converged run from reporting a false positive over an `unknown` verdict. Absent ⇒ nothing was quarantined, byte-identical to today. |
| `cause`          | object (optional)   | T48.4 (ADR-0058 decision 4): the honest terminal cause class alongside `status`/`reason`. **Additive, optional** — present only when the loop classified one. See [`cause` — honest terminal cause class](#cause--honest-terminal-cause-class-adr-0058). |
| `integration`    | object (optional)   | T50.2 (ADR-0065 decision 2): how a worktree-isolated serial run's converged task-branch commits LANDED on the base. **Additive, optional** — present only when a landing was attempted. See [`integration` — serial landing verdict](#integration--serial-landing-verdict-adr-0065) below. Absent ⇒ nothing was integrable (in-place run, or no commits ahead of the base), byte-identical to before this field existed. |
| `collateral`     | array of objects (optional) | issue #860: files changed this run that sit OUTSIDE the goal's write scope, net-deletion entries first. **Additive, optional** — present only when non-empty. See [`collateral` — out-of-intent diff report](#collateral--out-of-intent-diff-report-issue-860) below. Absent ⇒ nothing collateral was found, byte-identical to before this field existed. |
| `next_action`    | string (enum)       | An orchestration **hint** — `done`, `investigate`, or `raise_budget`. NOT a kazi action; the orchestrator owns the policy (ADR-0023). |
| `reason`         | string \| null      | The loop's stop reason — the exceeded budget dimension (e.g. `max_iterations`, `wall_clock`, `token_budget`, `max_dispatches` — T48.6, ADR-0058) or `stuck`. `null` on a clean converge. |
| `release_ref`    | string \| null      | The release tag of the artifact deployed this run (T3.3c), or `null` if nothing was deployed. |
| `error`          | string              | Present **only** when `status` is `error`: a human-readable failure message (a pre-loop failure, e.g. a vacuous goal or an unknown provider/harness). |

### `status`

| Value          | Loop outcome                          | When |
|----------------|---------------------------------------|------|
| `converged`    | `:converged`                          | The whole predicate vector is satisfied (success). Exit `0`. |
| `stuck`        | `:stopped` (reason `:stuck` or other) | The loop stopped before converging — a stuck stop (T1.5: the same failing set persisted across N iterations) or any other non-converged halt (operator/await stop). Investigate. Exit non-zero. |
| `over_budget`  | `:over_budget`                        | A hard budget ceiling was hit (T1.4); `reason` / `budget_spent.exceeded` name the dimension. Exit non-zero. |
| `error`        | _(pre-loop failure)_                  | The run could not start — a vacuous goal (R3), an unknown provider/harness, or an await timeout. The object carries `error`. Exit non-zero. |

### `next_action`

A single hint derived purely from `status`, so the orchestrator never re-derives
the branch from the predicate vector:

| `status`       | `next_action`   |
|----------------|-----------------|
| `converged`    | `done`          |
| `over_budget`  | `raise_budget`  |
| `stuck`        | `investigate`   |
| `error`        | `investigate`   |

For how an orchestrator reads these fields to drive a skill-side adaptive-model
escalation ladder (start cheap, step the model up on a stuck/non-converged slice),
see [`docs/tiering-signals.md`](../tiering-signals.md) (ADR-0035). That mapping is
a pure interpretation of the fields above -- kazi adds no escalation field or
policy.

### `predicates[].verdict`

The predicate's status string at the terminal observation: `pass`, `fail`,
`error`, or `unknown` (see `Kazi.PredicateResult`). A predicate is `:pass` only
when it genuinely held against the real world (including live predicates, which
pass only post-deploy). The vector — not a single exit code — is what makes
regression and partial progress legible (ADR-0002).

**`unknown` never counts toward `converged` (i795/#795).** `status` is
`converged` only when EVERY predicate in the vector is `pass` — `unknown`
(including a quarantined-as-flaky predicate, T1.3) blocks convergence exactly
like `fail` does. A prior version of the loop silently dropped quarantined
predicates from the convergence check before evaluating it, so a run could
report `converged` while a predicate's true state was genuinely unknown; that
is the bug this fix closes. See the top-level [`quarantine`](#fields) field for
naming which predicate ids are quarantined.

### `predicates[]` — graded fields (ADR-0041)

A predicate object MAY carry four additional, **optional** fields when the
provider returns a graded (non-boolean) result. They are emitted only when
present, so a boolean predicate stays exactly `{ "id", "verdict" }`:

| Field          | Type                | Meaning |
|----------------|---------------------|---------|
| `score`        | number              | The provider's scalar for this predicate (e.g. `47` of 50 tests, mutation `0.82`, an axe-violation count). A dense gradient on top of the boolean verdict; it NEVER moves the convergence gate. |
| `prior_score`  | number              | The same predicate's `score` from the previous iteration, threaded in by the loop. With `direction` it yields the interpreted progress delta. |
| `direction`    | string (enum)       | `higher_better` or `lower_better` — which way the score improves, so a consumer reads progress without per-provider knowledge. |
| `evidence`     | array of objects    | Structured findings, each an LSP-`Diagnostic`-shaped item `{ "file", "line", "col", "rule", "level", "message", "expected", "got" }` (each subfield itself optional). Localized fix-context distilled from SARIF / JUnit / a shrunk counterexample; raw stdout stays in the provider evidence only as a truncated fallback. |

These are **additive** (ADR-0041 decision 5): `:converged` still requires the
whole vector `:pass`, and `schema_version` stays `2`. An orchestrator that ignores
them sees the unchanged boolean contract; one that reads them gets the gradient
and the localized evidence.

A graded predicate object:

```json
{
  "id": "lint",
  "verdict": "fail",
  "score": 12,
  "prior_score": 30,
  "direction": "lower_better",
  "evidence": [
    { "file": "lib/a.ex", "line": 7, "rule": "no-unused", "level": "warning", "message": "unused variable x" }
  ]
}
```

## `usage` — economy envelope (ADR-0046)

The optional `usage` object reports the run's token and cost accounting, split so
the cheap (cached-read) and expensive (fresh) token classes are visible — the
distinction the token-economy program rests on. It mirrors the Anthropic usage
envelope plus the harness's own dollar figure.

```json
"usage": {
  "input_tokens": 1500,
  "cached_input_tokens": 18000,
  "cache_write_tokens": 0,
  "output_tokens": 2400,
  "reasoning_tokens": 0,
  "cost_usd": 0.0123
}
```

| Field                 | Type    | Meaning |
|-----------------------|---------|---------|
| `input_tokens`        | integer | Fresh (uncached) prompt input tokens. |
| `cached_input_tokens` | integer | Prompt input served from the provider cache (priced far below fresh input). |
| `cache_write_tokens`  | integer | Tokens written to the provider cache this run. |
| `output_tokens`       | integer | Generated output tokens. |
| `reasoning_tokens`    | integer | Reasoning/thinking tokens, when the harness reports them separately. |
| `cost_usd`            | float   | The run's dollar cost: the harness's own reported figure when it gives one, else derived from the accounted tokens via the dated price map (T34.5). Omitted for a model the price map does not name — never a guessed cost. |

Rules:

- **Additive and optional.** `usage` is present **only** when the harness reported
  at least one component; a run with no usage omits the key entirely, and the
  object is byte-identical to the pre-envelope contract. `schema_version` stays
  **2**.
- **Absent ≠ zero (honest-unknown).** A component the harness could not report is
  **omitted**, never set to `0` — absent means *unreported*. Do not read a missing
  field as zero spend.
- **`budget_spent.tokens` is the back-compat rollup.** An orchestrator pinning the
  pre-envelope contract keeps reading the single rolled-up total there; `usage`
  carries the un-summed split. The two are consistent but serve different readers.
- **`cost_usd` — harness figure first, then a dated price map, else omitted (T34.5).**
  When the harness reports its own dollar figure (Claude's `total_cost_usd`), that
  is authoritative and used verbatim. Otherwise — a harness that reports tokens but
  no dollars — kazi derives the cost from the accounted tokens using a single,
  dated price table (`Kazi.Economy.PriceMap`), pricing each token class
  independently (fresh input, cached read, cache write, output, reasoning). The
  price table lives in **one place**, is stamped with the date it was compiled
  against the providers' published pricing (`Kazi.Economy.PriceMap.as_of/0`), and
  is the only source of per-token prices in the codebase. For a model the table
  does **not** name, `cost_usd` is **omitted** entirely — the tokens are still
  reported, but kazi never guesses a dollar figure (ADR-0046 honest-unknown). To
  add or reprice a model, edit the entry and `@as_of` together — a CI/compile-time
  guard keeps the priced token classes in lockstep with this envelope's fields.

T34.1 defines this envelope and its additive wiring; T34.2 maps each provider's
raw usage onto these fields. The Anthropic (`:claude`) usage object maps as
`input_tokens`/`output_tokens` verbatim, `cache_creation_input_tokens →
cache_write_tokens`, and `cache_read_input_tokens → cached_input_tokens`; the
`:codex` profile reports the cached/fresh split natively. Each profile also
records a `usage_fidelity` marker (`:full` / `:partial` / `:none`) on its own
parse — an INTERNAL parse-confidence signal that is **not** surfaced in the
`--json` result (the `usage` object carries only the reported token/cost fields).
A field the provider did not report is omitted from `usage`, never zero-filled.

## `economy` — run-end KPIs (ADR-0046)

The `economy` object reports the run-end economy KPIs **derived** from the
per-iteration accounting envelopes (the `usage` split + the per-iteration
`context` / `tools` counters T34.3 records). It turns raw token totals into the
metric the operator optimizes — **cost per converged predicate**, not tokens per
run (ADR-0046 §5).

```json
"economy": {
  "status": "converged",
  "stuck": false,
  "iterations": 4,
  "converged_predicates": 2,
  "iterations_to_convergence": 4,
  "tokens": 21900,
  "cost_usd": 0.0123,
  "cost_per_converged_predicate": 0.00615,
  "wall_clock_s": 88.0,
  "wall_clock_per_converged_predicate": 44.0,
  "fresh_input_tokens_avoided": 18000,
  "rediscovery_tool_calls_avoided": 12
}
```

| Field                                | Type             | Meaning |
|--------------------------------------|------------------|---------|
| `status`                             | string           | The terminal status (mirrors the top-level `status`). Always present. |
| `stuck`                              | boolean          | Whether this run ended stuck. Always present. (The benchmark aggregates these into a `stuck_rate` per harness/model/context-tier.) |
| `iterations`                         | integer          | The loop's observation count. Always present. |
| `converged_predicates`               | integer (opt.)   | How many predicates reached `pass` at run end — the KPI denominator. |
| `iterations_to_convergence`          | integer (opt.)   | The observation at which the run converged. **Omitted** on a non-converged run (never the total). |
| `tokens`                             | integer (opt.)   | The run-aggregate token total — the sum of the `usage` envelope's token components (input + cached-input + cache-write + output + reasoning) the loop accumulated from each dispatch's parsed harness usage (T34.8). Equals `budget_spent.tokens`. **Omitted** when the harness reported no token usage (absent ≠ zero), so a real run carries a non-zero total here, never `tokens: 0`. |
| `cost_usd`                           | float (opt.)     | The run's reported dollar cost (from `usage.cost_usd`). |
| `wall_clock_s`                       | float (opt.)     | Wall-clock seconds spanned by the recorded observations. |
| `cost_per_converged_predicate`       | float (opt.)     | `cost_usd / converged_predicates`. |
| `wall_clock_per_converged_predicate` | float (opt.)     | `wall_clock_s / converged_predicates`. |
| `fresh_input_tokens_avoided`         | integer (opt.)   | Orientation/retrieval tokens served from the prompt cache (a stable-prefix `hit`) instead of re-sent as fresh input — the saving the caching work buys. |
| `rediscovery_tool_calls_avoided`     | integer (opt.)   | The decline in file/search/graph re-discovery calls below the cold first dispatch — the rediscovery a stable prefix lets later dispatches skip. |
| `harness` / `model` / `context_tier` | string (opt.)    | The breakdown labels, present only when set (a benchmark arm). |

Rules:

- **Additive.** `status`, `stuck`, and `iterations` are always present, so the
  object is never empty; `schema_version` stays **2**.
- **Absent ≠ zero (honest-unknown, ADR-0046 §6).** A KPI whose inputs were not
  reported is **omitted**, never `0`. A run whose harness reported no `cost_usd`
  has no `cost_per_converged_predicate` (not a free run); a run with no
  per-iteration `tools` stream has no `rediscovery_tool_calls_avoided` (not zero
  re-discovery). The per-iteration cache/re-discovery KPIs need the recorded
  iteration log (the default persisted run); without it only the run-aggregate
  KPIs are derivable and the rest are omitted.
- **Derived, never re-run.** Every KPI is folded from already-recorded signals
  (`Kazi.Economy.KPIs`); kazi runs nothing extra to produce them.
- **Reflects harness-reported usage on real runs (T34.8).** The `tokens` total and
  `cost_usd` are threaded from each dispatch's parsed harness usage (Claude's
  `total_cost_usd` + the per-field token split, accumulated into the run-aggregate
  `usage` envelope), so a real `kazi apply --json` run carries non-zero `tokens`
  and a real `cost_usd` straight from `economy` — a benchmark reads `$`/tokens
  from kazi's own output, no capture shim needed. `cost_usd` prefers the harness's
  own dollar figure, falling back to the dated price map (T34.5), and is omitted
  when neither is available (never guessed).

The E19/E36 benchmark (`mix kazi.bench --kpis <dir>`) folds a directory of
recorded `apply --json` results into a per-arm breakdown table
(cost/converged-predicate, stuck-rate, and the avoided-token deltas by
harness/model/context-tier), consuming **this** object — re-deriving nothing.

## `cause` — honest terminal cause class (ADR-0058)

The motivating incident (ADR-0058 §Context): every diagnosable
`over_budget` run in a live operator read-model turned out to be a
mislabeled error-wedge — a live predicate stuck in `:error` (e.g. `http_probe`
missing its required `url`) that spun every remaining iteration to
`max_iterations`. The operator's obvious next move on seeing `over_budget` —
raise the budget — changes nothing about a config error. `cause` names the
RIGHT next move instead of leaving `status`/`reason` as the only signal.

```json
"cause": {
  "class": "error_wedged",
  "ids": ["live_route"],
  "reasons": { "live_route": "missing_url" }
}
```

```json
"cause": {
  "class": "budget_exhausted",
  "ids": ["code"],
  "exhausted": "max_iterations"
}
```

| Field       | Type                | Meaning |
|-------------|---------------------|---------|
| `class`     | string (enum)       | One of `budget_exhausted`, `error_wedged`, `quarantine_blocked` (see below). |
| `ids`       | array of strings (optional) | The implicated predicate ids, sorted. Present only when non-empty. |
| `reasons`   | object (optional)   | `{ id: reason }` — the implicated ids' last-observed error reasons, as strings. Present only for `error_wedged`. |
| `exhausted` | string (optional)   | The exceeded budget dimension (`max_iterations` / `wall_clock` / `token_budget` / `max_dispatches`, T48.6). Present only for `budget_exhausted`. |

The three classes:

- **`budget_exhausted`** — a genuine `over_budget` stop: the terminal
  re-observation still shows real work `fail`ing (or nothing at all
  blocking — a live predicate legitimately still pending). Raising the
  budget, or waiting longer, really is the right move.
- **`error_wedged`** — either the T48.3 live-permanent-error stuck stop, or
  an `over_budget` stop whose terminal re-observation shows ZERO `fail` but
  at least one PERSISTENT `error` (the residual case a `stuck_iterations`
  window longer than the budget ceiling doesn't get a chance to catch).
  Raising the budget does nothing; the fix is the named predicate's config.
- **`quarantine_blocked`** — the #820 quarantine-only stuck stop: the vector
  is unsatisfied solely because every non-passing id is quarantined as
  flaky (T1.3). The fix is rehabilitation or a human, not budget.

Every other stop — a clean `converged`, an ordinary failing-set `stuck`, or
the pre-existing code `error_stuck?` (M5) `stuck` — carries **no** `cause`
(absent from the object): those are not mislabels, they are exactly what
`status`/`reason` already say. **Additive, optional** — absent ⇒
byte-identical to before this field existed. Computed by
`Kazi.Loop.CauseClass.classify/1`; persisted to the read-model's `runs` table
as `outcome_cause_class` (the `class` string) and `outcome_cause_detail`
(`ids`/`reasons`/`exhausted`, nullable JSON), and surfaced on the starmap
dashboard's drill-in panel for a finished run.

## `integration` — serial landing verdict (ADR-0065)

T50.2 (ADR-0065 decision 2): a serial run isolated into a kazi-owned task
worktree (T50.1) that converges with COMMITS on its task branch must LAND them
on the base (`--workspace`'s checked-out branch) before the ephemeral worktree
is cleaned up — the landing follows the parallel path's T21.5 semantics
(rebase-merge, conflict → re-dispatch bounded by an attempt budget, never
`git reset`/`git clean` against the caller's checkout). `integration` reports
that landing's verdict:

```json
"integration": {
  "landed": true,
  "base": "main",
  "task_branch": "kazi-partition/p-my-goal-3",
  "refs": { "branch": "kazi-partition/p-my-goal-3", "base": "main", "merge_commit": "abc123...", "local": true }
}
```

```json
"integration": {
  "landed": false,
  "base": "main",
  "task_branch": "kazi-partition/p-my-goal-3",
  "reason": "{:conflict, {:rebase_failed, \"...\"}}"
}
```

| Field         | Type              | Meaning |
|---------------|-------------------|---------|
| `landed`      | boolean           | Whether the task-branch commits landed on the base. `false` ⇒ the run exits **1** even though `status` is `converged` — a converged-but-not-landed run is not a clean success. |
| `base`        | string            | The base ref the landing targeted: the caller's checked-out branch, never a hardcoded default. |
| `task_branch` | string            | The task branch holding the converged commits. On `landed: false` this branch SURVIVES worktree cleanup in the base repo — the work is never lost; integrate it by hand or re-run. |
| `refs`        | object (optional) | The integrator's refs on success — `pr`/`merge_commit` from the remote (gh) integrator, or `merge_commit` + `local: true` from the remote-less local rebase-merge. |
| `reason`      | string (optional) | On `landed: false`: the conflict/failure detail (after the re-dispatch budget was exhausted). |

Rules:

- **Additive, optional.** Present only when a landing was attempted: the run
  was worktree-isolated (not `--in-place`, a git workspace) AND its worktree
  held commits ahead of the base. An agent that converged without committing
  lands nothing and the field is absent (the base stays byte-identical, the
  T50.1 contract).
- **Exit code.** `landed: false` downgrades the exit code to 1; `status` stays
  `converged` (the loop's verdict is honest) — branch on `integration.landed`
  to distinguish "converged and landed" from "converged, work parked on the
  surviving task branch".
- **Integrator selection.** With an `origin` remote and `gh` on PATH the
  landing is branch → push → PR → rebase-merge (the parallel path's real
  integrator); otherwise a plain LOCAL rebase-merge of the task branch onto
  the base checkout. Both are injectable seams for tests.

## `collateral` — out-of-intent diff report (issue #860)

The motivating incident: an inner agent deleted an unrelated auth-config key
while working a goal whose `[scope].paths` covered the whole platform
directory — every predicate passed, and the regression was silent until a
human eyeballed the commit stats. `collateral` is the machine-readable version
of that eyeball check: files changed during the run that sit **outside** the
goal's intended write scope, so an orchestrator (or a human) reviews a 5-line
list instead of the full diff.

A path is collateral when it changed since the run's base ref (the merge-base
with `origin/main`, falling back to the repo's root commit) AND it falls
outside scope:

- `[scope].write_paths` is declared and non-empty → any changed path **not**
  under one of those prefixes is collateral; or
- `write_paths` is absent → any changed path that **no predicate's own
  config** plausibly references (its full relative path or basename does not
  appear in any predicate's rendered config) is collateral.

```json
"collateral": [
  { "path": "ios/Runner/Info.plist", "additions": 0, "deletions": 10, "net_deletion": true },
  { "path": "docs/notes.md", "additions": 4, "deletions": 0, "net_deletion": false }
]
```

| Field          | Type              | Meaning |
|----------------|-------------------|---------|
| `path`         | string            | The changed path, repo-relative. |
| `additions`    | integer \| null   | Added lines since the base ref (`git diff --numstat`); `null` for an unmeasurable (binary) file. |
| `deletions`    | integer \| null   | Removed lines since the base ref; `null` for an unmeasurable (binary) file. |
| `net_deletion` | boolean           | `true` when `deletions > additions` — ranked **first**, since a majority/pure deletion in a file nothing referenced is the highest-signal shape of an out-of-intent regression (the motivating incident). |

Rules:

- **Additive, optional.** Present only when at least one collateral path was
  found; absent on a clean run (byte-identical to before this field existed).
- **Ordering.** Net-deletion entries first, then by deletion count descending —
  the highest-signal entries lead the list.
- **Advisory, not blocking.** `collateral` is observability only; it never
  fails a predicate or blocks convergence by itself. Pairing it with
  `[scope].deny` (`Kazi.Scope.guard_predicates/1`, `docs/how-to/scope-write-guard.md`)
  gives a HARD guarantee for the specific paths that must never move.
- Computed by `Kazi.CollateralReport.collateral/2`, over the SAME diff
  `Kazi.Providers.ScopeGuard` measures (`Kazi.ScopeDiff`) — the two features
  share one notion of "what changed this run".

## Error object

When `status` is `error` the object substitutes the run-result fields with a
failure envelope on the **same** stdout stream, so the orchestrator parses one
surface and branches on the non-zero exit:

```json
{
  "schema_version": 2,
  "goal_id": "cli-vacuous",
  "status": "error",
  "error": "goal is vacuous — every predicate already passes at t0 ...",
  "reason": "vacuous_goal",
  "next_action": "investigate"
}
```

## Streaming progress (JSONL) — `apply --json --stream` (T15.4, ADR-0023 decision 3)

`kazi apply --json --stream` emits a **JSONL
stream** instead of a single object: one JSON object **per line** per loop
iteration, **terminated** by the single result object above. Each line parses
**independently**, so an orchestrator monitors a long convergence line-by-line
without blocking — mirroring how kazi itself parses opencode/codex JSONL.

Without `--stream`, `apply --json` emits exactly the one terminal result object
(unchanged); `--stream` is opt-in and additive and only changes what precedes that
object.

### Iteration event

Each progress line is a `Kazi.Loop` observation rendered as:

```json
{ "schema_version": 2, "event": "iteration", "iteration": 1, "predicates": [ { "id": "code", "verdict": "fail" }, { "id": "live", "verdict": "fail" } ], "converged": false, "release_ref": null, "context": { "orientation_cache": "hit", "retrieval_cache": "disabled", "orientation_tokens": 412, "evidence_tokens": 38, "retrieval_tokens": 0, "attempt_ledger_tokens": null, "memory_recall_tokens": null, "tier": 1 }, "tools": { "tool_calls": 6, "file_reads": 2, "search_calls": 1, "graph_calls": 1 } }
```

| Field            | Type             | Meaning |
|------------------|------------------|---------|
| `event`          | string           | Always `"iteration"`. **Distinguishes a progress line from the terminal result object**, which carries NO `event` field. |
| `iteration`      | integer          | The 0-based observation index (matches the read-model's `iteration_index`). Non-decreasing across the stream. |
| `predicates`     | array of objects | The predicate **vector** at this observation — the same `{ "id", "verdict" }` shape (sorted by `id`) as the terminal result. |
| `converged`      | boolean          | Whether the whole vector was satisfied at this observation. |
| `release_ref`    | string \| null   | The release ref recorded so far this run (T3.3c), or `null`. |
| `context`        | object           | ADR-0046 §2 per-iteration **context** counters from the dispatch that fed this observation. See [`context` + `tools` counters](#context--tools--per-iteration-counters-adr-0046) below. |
| `tools`          | object (optional)| ADR-0046 §2 per-iteration **tool** counters. **Present only when the harness exposed a tool-use stream** — an empty/absent `tools` means the harness reported none (absent ≠ zero). |
| `schema_version` | integer          | The contract version, same as the result object. |

### `context` + `tools` — per-iteration counters (ADR-0046)

These (T34.3, ADR-0046 §2) make the stable-prefix caching claim (ADR-0010/0045)
**falsifiable**: a working orientation prefix shows the `context.orientation_cache`
flip `miss → hit` across iterations with an unchanged blast radius, while the
agent's `tools.file_reads` / `tools.search_calls` fall. They are **additive**, so
`schema_version` stays **2**. The same maps are persisted on each read-model
iteration row (the `context` / `tools` columns).

`context` is **always present** — kazi builds the prompt, so a `0` here is a real,
measured zero (e.g. orientation off ⇒ `orientation_tokens: 0`,
`orientation_cache: "disabled"`), never "unknown":

| Field                | Type    | Meaning |
|----------------------|---------|---------|
| `orientation_cache`  | string  | `"hit"` when kazi re-sent a **byte-identical** orientation prefix the inner harness's prompt cache can reuse (same blast radius, T19.2), `"miss"` on the first or a changed prefix, `"disabled"` when no orientation pack was sent (no graph/repo-map, or the prefix is off). |
| `retrieval_cache`    | string  | Same `hit`/`miss`/`disabled` verdict for the optional retrieval section. |
| `orientation_tokens` | integer | Estimated tokens (`ceil(chars / 4)`, ADR-0010) of the orientation prefix; `0` when absent. |
| `evidence_tokens`    | integer | Estimated tokens of the failing-evidence section. |
| `retrieval_tokens`   | integer | Estimated tokens of the retrieval section; `0` when absent. |
| `attempt_ledger_tokens` | integer \| null | Estimated tokens of the ADR-0061 episodic attempt-ledger section. `null` when the `:attempt_ledger` layer is off (the **default**) — distinct from `0`, which means the layer is on but rendered nothing (issue #978). |
| `memory_recall_tokens`  | integer \| null | Estimated tokens of the ADR-0062 semantic memory-recall section. `null` when the `:memory_recall` layer is off (the **default**) — distinct from `0`, which means the layer is on but rendered nothing (issue #978). |
| `tier`               | integer \| null | The active context-budget tier the dispatch assembled its context at (T36.3, ADR-0047 §3): `0` evidence-only, `1` + cached orientation (**default**), `2` + code-review-graph MCP, `3` + retrieval snippets, `4` + compact snapshot. `null` for the no-dispatch baseline. Selected per dispatch via the `:context_tier` adapter opt. |

The **first** observation has no preceding dispatch, so it reports the
all-`disabled` / all-`0` context with `tier: null`.

The tier is a dial on how much context kazi sends the inner harness: tier 0 drops
the cached orientation prefix entirely, tier 1 (the default) keeps it, and tier 2
additionally exposes the live code-review-graph MCP server in the dispatch's
tool/MCP surface. The ladder is **defined** here but its escalation policy is
benchmark-gated (ADR-0047 forbids shipping a guessed ladder as proven); recording
the active tier per iteration is what lets the E19/E34 benchmark attribute
convergence/stuck outcomes to it.

`tools` is parsed from the harness result's tool-use stream and is present **only
when the harness exposes one** (honest-unknown, ADR-0046 §6). When present, every
bucket is reported (an unused category is a real `0`); when absent, the agent's
tool usage is **unreported**, not zero. Claude's default `--output-format json`
envelope carries no per-tool breakdown, so `tools` is typically absent for the
`:claude` harness; a richer envelope (assistant `tool_use` blocks) populates it.

| Field          | Type    | Meaning |
|----------------|---------|---------|
| `tool_calls`   | integer | Total tool invocations the agent made this dispatch. |
| `file_reads`   | integer | File-read tool calls (e.g. `Read`). |
| `search_calls` | integer | Search/grep tool calls (e.g. `Grep`/`Glob`) — the "rediscovery" calls a stable prefix should reduce. |
| `graph_calls`  | integer | Code-graph / semantic-navigation tool calls (the code-review-graph MCP surface). |

### Frontier-complete event (`apply --parallel --json --stream`, issue #936)

Under `kazi apply --parallel --json --stream` against a goal whose predicates
are organized into `needs`-DAG groups (ADR-0028), the stream additionally emits
one `frontier_complete` line at each **wave boundary** — the moment every group
in a topological frontier has reached a terminal state, and **before** any
group of the next frontier dispatches. A goal with no groups / no `needs`-DAG
(the flat `--parallel` path) emits none of these — there are no frontiers to
report, only the terminal collective result.

```json
{ "schema_version": 2, "event": "frontier_complete", "frontier": 0, "groups": [ { "id": "a", "status": "converged" }, { "id": "b", "status": "converged" } ] }
```

| Field            | Type             | Meaning |
|------------------|------------------|---------|
| `event`          | string           | Always `"frontier_complete"`. Distinguishes this marker from an `"iteration"` progress line and from the terminal result object (no `event`). |
| `frontier`       | integer          | The 0-based topological frontier index that just settled (same layering as `kazi apply --explain`). |
| `groups`         | array of objects | The frontier's members, `{ "id", "status" }`, in declared order — `status` is each group's terminal `Kazi.Scheduler.DepScheduler` outcome (`"converged"` / `"stuck"` / `"over_budget"` / `"stopped"` / `"crashed"` / `"blocked"`). |
| `schema_version` | integer          | The contract version, same as the result object. |

This is a reporting marker, not a barrier: a later frontier still dispatches the
instant its OWN `needs` are satisfied (pipelining is unchanged, ADR-0028), so
`frontier_complete(N)` precedes frontier `N+1`'s dispatch only insofar as
frontier `N+1`'s groups actually `needs` frontier `N`'s members.

### Stream shape

```
{ "event": "iteration", "iteration": 0, ... }   ← one per observation
{ "event": "iteration", "iteration": 1, ... }
...
{ "event": "frontier_complete", "frontier": 0, ... }   ← --parallel only, at each needs-DAG wave boundary
...
{ "schema_version": 2, "status": "converged", ... }   ← the terminal result object (no "event"), the stream terminator
```

The consumer reads lines until it sees the object **without** an `event` field —
that is the terminal `apply --json` result documented above, carrying the final
`status` / `next_action` / `budget_spent` the orchestrator branches on.
