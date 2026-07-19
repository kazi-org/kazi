# The `no_stubs` predicate

`no_stubs` is kazi's **zero-stub** gate (T44.6): a deterministic diff scanner that
fails when a run introduces a stub, placeholder, or hardcoded-return marker into
**production** code.

Every reconcile run already asks an agent to *not* leave stubs behind — but "don't stub"
is prose the controller cannot check. `no_stubs` turns that policy into an
**objective predicate** a goal-file can declare, so the loop gates on it the same
way it gates on tests: a production-reachable marker keeps the vector unsatisfied
until the agent replaces it with real code.

## What it checks

The "tool" is `git diff <base>`; the finding is a marker on an **added** line:

- **Only added lines.** A pure deletion or a context line carries no marker, so the
  scan never fails on a pre-existing stub the diff did not introduce. It reads the
  same tested unified-diff parser the anti-gaming diff guard uses
  (`Kazi.Enforcement.DiffGuard`), tracking each added line to its new-file line
  number.
- **Only non-test files.** Stubs, mocks, and fakes are legitimate in tests. A path
  under a `test/` directory or ending `_test.exs`/`_test.ex` is exempt, plus any
  `exclude` prefixes the goal declares.
- **The markers** (default, case-insensitive): `stub`, `mock`, `fake`, `dummy`,
  `placeholder`, `todo`, `fixme`, `notimplemented`. Matched at a left word boundary,
  so `MockServer` / `stub_line` are caught. Override with `patterns`.

Any production-reachable hit is `:fail` with `file:line` evidence (the marker plus
the offending snippet); a clean diff is `:pass`. `score` is the hit count
(`direction: lower_better`). A non-git workspace is an `:error` (the scan could not
run), never a false `:pass`.

## Config

Introspect every key at runtime with:

```
kazi schema no_stubs
```

| Key        | Type            | Default | Meaning |
|------------|-----------------|---------|---------|
| `patterns` | array of string | the eight markers above | The stub markers to scan for (case-insensitive). |
| `base`     | string          | merge-base with `origin/main`, else the root commit, else the empty tree | The base ref to diff against. |
| `exclude`  | array of string | none | Extra path PREFIXES to exempt beyond the built-in test-file rule. |

## Example

```toml
id = "no-stubs-gate"
name = "No stubs in production code"

[[predicate]]
id = "no-stubs"
provider = "no_stubs"
description = "the diff introduces no stub/placeholder/hardcoded-return marker in a production file"
```

See `priv/examples/no_stubs.toml`. The convergence gate is unchanged: a `no_stubs`
predicate contributes only its `:pass`.
