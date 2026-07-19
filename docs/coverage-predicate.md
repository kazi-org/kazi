# The `coverage` predicate

`coverage` is kazi's **test-coverage gate** (ADR-0043). It asserts two things at
once:

> **patch coverage** (the lines this change touched) meets a `target`, **AND**
> **project coverage** (the whole codebase) does not regress.

It is the headline instance of the [`ratchet`](ratchet-predicate.md) mode named in
`Kazi.Ratchet`'s own docstring — it does **not** re-derive any baseline machinery.
The provider runs two `Kazi.Ratchet` comparisons:

- **patch** — against a fixed `target` (`direction: higher_better`,
  `allowed_regression: 0`). New code must be covered. This is the dimension a
  green suite still misses: project coverage can stay flat while a new, untested
  function lands.
- **project** (optional) — against a `project_baseline` so the whole codebase's
  coverage may only improve (a ratchet-as-guard, ADR-0042).

The predicate passes iff **both** dimensions pass (or `project` is omitted).
Either dimension erroring (a broken coverage tool, an unresolved baseline ref)
makes the whole predicate `:error`, never a silent pass. It reports
`score = patch coverage`, `direction: higher_better`, so the loop reads "is new
code getting more covered?" without coverage-specific knowledge. The convergence
gate is unchanged: a coverage predicate contributes only its `:pass`.

Introspect every key at runtime with:

```
kazi schema coverage
```

## Config keys

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `patch` | table | yes | A metric table emitting the PATCH coverage %. |
| `target` | number | yes | The patch-coverage floor (e.g. `80.0`). Patch below it fails. |
| `project` | table | no | A metric table emitting TOTAL project coverage %. Present → the project no-regression dimension gates too. |
| `project_baseline` | number / string | no | The project bar: `"stored"`/`"prior"` (default), a git ref, or a number. |
| `project_allowed_regression` | number | no | The tolerated project drop. Default `0` — "may only improve". |
| `store_dir` | string | no | Overrides the stored-baseline directory (defaults to the workspace `.kazi`). |

Both `patch` and `project` are **metric tables** with the same shape the
[`ratchet`](ratchet-predicate.md) metric uses:

| metric key | Type | Required | Meaning |
|------------|------|----------|---------|
| `cmd` | string | yes | The executable. ONE executable, not a command line — use `args`. |
| `args` | array of strings | no | Arguments passed to `cmd`. Default `[]`. |
| `env` | table / pairs | no | Extra environment. |
| `path` | string | no | A JSONPath subset over the command's JSON stdout. Absent means stdout *is* the number. |
| `timeout_ms` | integer | no | Kill the metric after this many ms → `:error`. |

Invalid declarations fail loudly **at load time** (a missing `patch.cmd`, a
missing `target`), not silently at dispatch.

## Example

```toml
[[predicate]]
id = "coverage"
provider = "coverage"
acceptance = true
target = 80.0

  [predicate.patch]
  cmd = "scripts/patch-coverage"
  args = ["--json"]
  path = "$.patch.percent"

  [predicate.project]
  cmd = "scripts/coverage"
  args = ["--json"]
  path = "$.totals.percent"

# project_baseline defaults to "stored": the first run seeds the bar, and the
# whole codebase's coverage may only climb from there.
project_baseline = "stored"
```

A patch that touches new code without testing it drops `patch.percent` below
`80.0` and the predicate fails — even though `mix test` is green and project
coverage is unchanged. Delete a test and project coverage drops below the stored
baseline; the project dimension fails. Both are real, recomputed comparisons, not
self-reported.

## Evidence

The result carries the proof a fixer needs: `patch_coverage`, `target`, and the
per-dimension `patch_status`; when the project dimension is present it adds
`project_coverage`, the resolved `project_baseline`, `project_regression`, and
`project_status`. An `:error` names the failing `dimension` and its `reason`.
