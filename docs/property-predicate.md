# The `property` predicate

`property` is kazi's **property-based testing** gate (ADR-0043) — PropCheck under
`mix test` (kazi-native).

A unit test asserts one example; a property asserts an **invariant** over hundreds
of generated inputs, and on a counterexample PropCheck/PropEr **shrinks** it to the
minimal failing case. That shrunk input is the single most useful piece of
fix-context a generator can hand a fixer, so this provider surfaces it as evidence.

It reports `score = cases-passed / N` (`direction: higher_better`) — the dense
gradient. A property that gets *further* before failing (more cases passed)
registers as progress even before it is green. The convergence gate is unchanged:
a property predicate contributes only its `:pass`.

Introspect every key at runtime with:

```
kazi schema property
```

## The verdict is read from the parsed output

PropEr (which PropCheck surfaces) prints a recognizable console summary:

- success — `OK: Passed 100 test(s).`
- failure — `Failed: After 3 test(s).` then the failing input, then
  `Shrinking ...(N time(s))` and the **shrunk** counterexample.

kazi maps that **parsed** summary, not the exit code alone:

| Output | Verdict | Score |
|--------|---------|-------|
| a `Failed: After N` summary | `:fail` | cases-passed / N (the shrunk counterexample is evidence) |
| exit `0`, no failure summary | `:pass` | `1.0` (every case passed) |
| non-zero exit, **no** property failure (compile error, crashed suite) | `:error` | — |

The last row is the key boundary: a broken suite is **infra**, not failing
property work, so it is `:error` (never dispatched to a fixer as if a property
broke).

## Config keys

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `cmd` | string | no | The executable. Default `"mix"`. |
| `args` | array of strings | no | Argument list. Default `["test"]`. |
| `env` | table / pairs | no | Extra environment. |
| `num_tests` | integer | no | `N` — generated cases per property, the score **denominator**. Default `100`. Must be positive. |
| `merge_stderr` | boolean | no | Fold stderr into stdout for the parsed output. Default `true`. |
| `timeout_ms` | integer | no | Kill the run after this many ms → `:error`. |

Set `num_tests` to the same `numtests` your property uses, so the score
denominator matches the run.

## Example

```toml
[[predicate]]
id = "encode-decode-roundtrips"
provider = "property"
acceptance = true
cmd = "mix"
args = ["test", "--only", "property"]
num_tests = 100
```

## Evidence

Every result carries the resolved `cmd`, `args`, `workspace`, the `exit` code, the
`num_tests`, the parsed `cases_passed`, and a truncated `output`. A failure adds
the `counterexample` — the **shrunk** minimal input that breaks the invariant. An
`:error` carries a `reason`.
