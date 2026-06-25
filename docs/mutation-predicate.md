# The `mutation` predicate

`mutation` is kazi's **test-quality** gate (ADR-0043) — the only signal in the
catalog that measures whether your tests would actually *catch* a defect, not just
that they *executed* a line.

Mutation testing injects small faults (mutants) into the code and measures how
many the suite **kills**. The score — `killed / total` — is a 0-1 gradient of suite
strength, and the **surviving mutants** are the most actionable evidence a fixer
can get: "this exact change to this line went undetected — assert on it."

It reports the 0-1 score as `score` (`direction: higher_better`) and passes iff
`score >= threshold`. The convergence gate is unchanged: a mutation predicate
contributes only its `:pass`.

Introspect every key at runtime with:

```
kazi schema mutation
```

## The threshold is never 100%

A mutation threshold of `1.0` (100%) is **rejected at load**. A perfect mutation
score is an unrealistic, gameable target — *equivalent mutants* (mutations that do
not change behaviour) make 100% unreachable. The gate is a pragmatic floor that
**ratchets up** over time, not a demand for perfection. Declare a `threshold` of
`0.8`, raise it as the suite strengthens.

## Gated on the parsed score, not the exit code

Mutation tools commonly exit non-zero when the score is below threshold — gating
on the exit code would conflate "score too low" (real, failing work) with "the
tool could not run" (infra). So kazi reads the **parsed score** from the report and
maps a parse failure / missing path to `:error`, never a silent pass.

## Scope to changed lines

Mutating the whole tree every iteration is too slow. Scope the run to the lines the
change touched via the **tool's own flags** (e.g. `--diff` / `--since`) in `args` —
kazi drives the tool; the tool does the diff-scoping. A run with no mutants in the
changed-line scope (`killed + survived == 0`) is `:pass` with no score (nothing to
evaluate is not a quality regression).

## Config keys

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `cmd` | string | yes | The executable (ONE executable; use `args`). |
| `args` | array of strings | no | Argument list. Put the diff-scoping flag here. Default `[]`. |
| `env` | table / pairs | no | Extra environment. |
| `threshold` | number | yes | The 0-1 score floor. Must be `>= 0` **and** `< 1.0` (never 100%). |
| `score_path` | string | * | A JSONPath to a precomputed 0-1 score. |
| `killed_path` / `survived_path` | string | * | Paths to the killed / survived counts; score = `killed / (killed + survived)`. |
| `survivors_path` | string | no | A JSONPath to the surviving-mutant list (bounded evidence). |
| `merge_stderr` | boolean | no | Fold stderr into stdout. Default `false`. |
| `timeout_ms` | integer | no | Kill the run after this many ms → `:error`. |

\* Provide **either** `score_path` **or** both `killed_path` and `survived_path`.

## Example

```toml
[[predicate]]
id = "mutation-score"
provider = "mutation"
acceptance = true
cmd = "mix"
args = ["muzak", "--diff", "--format", "json"]
threshold = 0.8
killed_path = "$.summary.killed"
survived_path = "$.summary.survived"
survivors_path = "$.survivors"
```

## Evidence

Every result carries the resolved `cmd`, `args`, `workspace`, the `exit` code, the
`threshold`, the computed `score`, and a truncated `output`. When computed from
counts it adds `killed` and `survived`; with a `survivors_path` it adds a bounded
`survivors` list. An `:error` carries a `reason`.
