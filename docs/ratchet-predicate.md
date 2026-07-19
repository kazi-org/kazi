# The `ratchet` predicate mode

`ratchet` is kazi's **no-regression** predicate mode (ADR-0041). It asserts that a
metric stays within an allowed regression of a baseline:

> the predicate **passes iff the metric moved no more than `allowed_regression`
> in the worsening direction.**

The insight it builds on: coverage, performance, and binary/bundle size are the
**same** predicate — `signal vs baseline within an allowed regression`. Rather
than ship three bespoke providers, kazi builds the baseline-comparison machinery
**once** (`Kazi.Ratchet`) and exposes it as one mode whose differences are pure
config. `ratchet` reports `score = signal`, so the loop reads the gradient (am I
getting closer?) without per-provider knowledge — the dense reward of envelope v2
(ADR-0041). The convergence gate is unchanged: a ratchet still contributes only
its `:pass`.

You can introspect every key at runtime with:

```
kazi schema ratchet
```

## Config keys

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `metric` | table | yes | How to produce the signal — see below. |
| `baseline` | number / string | yes | The bar: a fixed number, `"stored"`/`"prior"`, or a git ref. |
| `direction` | string | yes | `"higher_better"` (coverage, mutation score) or `"lower_better"` (size, latency, lint count). |
| `allowed_regression` | number | no | The tolerated worsening. Default `0` — "may only improve". |

The `metric` table declares the command that emits the number:

| `metric` key | Type | Required | Meaning |
|--------------|------|----------|---------|
| `cmd` | string | yes | The executable. ONE executable, not a command line — use `args`. |
| `args` | array of strings | no | Arguments passed to `cmd`. Default `[]`. |
| `env` | table / pairs | no | Extra environment as `{NAME = "value"}` or `{name, value}` pairs. |
| `path` | string | no | A JSONPath subset over the command's JSON stdout. **Absent** means stdout *is* the number. A list value uses its **length** (a findings array compares its count). |
| `timeout_ms` | integer | no | Kill the metric after this many ms → `:error`. |

Invalid declarations fail loudly **at load time** (a missing `metric.cmd`, an
unknown `direction`, a missing `baseline`, a non-numeric `allowed_regression`),
not silently at dispatch.

## Direction and the regression rule

`direction` is what makes one rule serve both shapes. The **regression** (how much
the metric worsened) is computed relative to the baseline:

- `higher_better` — worsening is **down**, so regression is `baseline - signal`.
- `lower_better` — worsening is **up**, so regression is `signal - baseline`.

The predicate passes iff `regression <= allowed_regression`. A negative regression
is an improvement and always passes.

## Baseline sources

`baseline` selects how the bar is resolved.

### A fixed number — an absolute threshold

```toml
baseline = 80.0
direction = "higher_better"
```

The simplest case: the metric must be at least `80.0` (with `allowed_regression =
0`). Never persisted — the bar is whatever you wrote.

### `"stored"` — the metric's own prior value (a true ratchet)

```toml
baseline = "stored"
direction = "higher_better"
allowed_regression = 0.0
```

The bar is the metric's last passing value, persisted between runs in
`<workspace>/.kazi/ratchets.json` (overridable). The **first** run has no stored
value: it **seeds** the baseline (passes, records the signal) so the next run has
something to compare against. On a pass the stored baseline **tightens** toward
the improving side (`max` for higher-better, `min` for lower-better), so once a
better value is reached it cannot silently slip back. A fail leaves the stored
baseline untouched — the agent must climb back to it. This is the anti-gaming
guard substrate ADR-0042 builds on: coverage and test-count may only improve.

### A git ref — recomputed against another commit

```toml
baseline = "main"        # or "HEAD~1", "origin/main", a tag/SHA
direction = "lower_better"
```

The metric is **recomputed** against that ref in a throwaway detached worktree, so
"no larger than it is on `main`" is a real, recomputed comparison rather than a
hand-maintained number. An unresolvable ref is an `:error`, never a silent pass.

## Worked examples

### Coverage may not regress (`higher_better`, stored)

```toml
id = "ratchet-coverage"

[[predicate]]
id = "coverage-no-regression"
provider = "ratchet"
baseline = "stored"
direction = "higher_better"
allowed_regression = 0.0
metric = { cmd = "scripts/coverage", args = ["--json"], path = "$.totals.percent" }
```

Shipped as [`priv/examples/ratchet_coverage.toml`](../priv/examples/ratchet_coverage.toml).

### Binary size may not grow vs `main` (`lower_better`, git ref)

```toml
id = "ratchet-size"

[[predicate]]
id = "size-no-regression"
provider = "ratchet"
baseline = "main"
direction = "lower_better"
allowed_regression = 1024            # a 1 KiB growth budget
metric = { cmd = "scripts/artifact-size" }   # prints the byte size to stdout
```

Shipped as [`priv/examples/ratchet_size.toml`](../priv/examples/ratchet_size.toml).

## Errors vs failures

A ratchet distinguishes a genuine `:fail` (the metric regressed) from an `:error`
(the checker could not run): a missing metric binary, a non-zero metric exit, a
JSON parse failure, an unresolved path, or an unresolvable git ref is an `:error`,
so a broken measurement pipeline is never read as a pass.

## Evidence

The result carries the proof a fixer needs: the `signal`, the resolved `baseline`,
the direction-interpreted `regression`, the `allowed_regression`, the `direction`,
the `baseline_source` (`literal` / `stored` / `git_ref` / `seed`), and whether a
new baseline was `stored`.

## See also

- `kazi schema ratchet` — the machine-readable key reference.
- [`docs/custom-script-provider.md`](custom-script-provider.md) — the generic
  command-runner for absolute (non-ratcheting) verdicts.
- ADR-0041 — the envelope-v2 / score / ratchet decision.
