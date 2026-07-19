# The `static` predicate provider

`static` is kazi's **static-analysis / type-check / lint** predicate (ADR-0043).
It is the cheapest, most deterministic check in the catalog: it runs every
iteration and catches defects on paths the tests never execute.

It **leads with Dialyzer** — kazi-native, with effectively zero false positives,
so failing directly on any finding is safe — and **generalizes to the polyglot
SARIF tools** (`tsc`, `mypy`, `golangci-lint`, Semgrep, …) in the *same* provider.
A `format` selects how the analyzer's stdout is read into structured,
`file:line`-localized findings.

Two things make it trustworthy:

- **The verdict is gated on the parsed findings, never the exit code.** A SARIF
  tool that exits `0` *with* findings is still failed — the "exit 0 means pass"
  hazard ADR-0040 designs out. A tool that could not run at all (missing binary,
  bad PLT) is an `:error`, never a `:fail`.
- **The baseline ratchet fails only on NEW findings.** For polyglot tools that
  carry pre-existing debt, you set a `baseline`; kazi hands the finding *count* to
  the shared ratchet machinery (`Kazi.Ratchet`, the same one `ratchet` uses) so
  the predicate ignores pre-existing findings and fails only when the count rises.
  Security/lint debt can only shrink, never block on what was already there.

It reports `score = finding count` with `direction = lower_better`, so the loop
reads the gradient (am I removing findings?) without per-provider knowledge. The
convergence gate is unchanged: a `static` predicate contributes only its `:pass`.

Introspect every key at runtime with:

```
kazi schema static
```

## Config keys

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `cmd` | string | yes | The analyzer executable. ONE executable, not a command line — use `args`. |
| `args` | array of strings | no | Arguments passed to `cmd`. Default `[]`. |
| `env` | table / pairs | no | Extra environment as `{NAME = "value"}` or `{name, value}` pairs. |
| `format` | string | no | How findings are read from stdout: `"dialyzer"` (default) or `"sarif"`. |
| `baseline` | number / string | no | **Absent** → zero-findings gate. A number, `"stored"`/`"prior"`, or a git ref → the ratchet gate (fails only on NEW findings). |
| `allowed_regression` | number | no | Ratchet mode: how many NEW findings are tolerated. Default `0`. |
| `merge_stderr` | boolean | no | Fold the analyzer's stderr into stdout for parsing/evidence. Default `false`. |
| `error_codes` | array of integers | no | Exit codes that mean the analyzer could not run → `:error`, checked before findings are read. |
| `timeout_ms` | integer | no | Kill the analyzer after this many ms → `:error`. |

Invalid declarations fail loudly **at load time** (a missing `cmd`, an unknown
`format`, an invalid `baseline`, a non-numeric `allowed_regression`), not silently
at dispatch.

## The two gate modes

### Zero-findings (no `baseline`) — the Dialyzer mode

```toml
[[predicate]]
id = "no-dialyzer-warnings"
provider = "static"
cmd = "mix"
args = ["dialyzer", "--format", "short"]
# format defaults to "dialyzer"
```

`:pass` iff the analyzer reports **no** findings, else `:fail`. Dialyzer's
zero-false-positive output makes failing on any finding the right default. Each
finding becomes a localized evidence item (`file:line[:col]`, the warning tag as
`rule`, the message).

### Baseline ratchet — fail only on NEW findings

For a polyglot SAST tool with pre-existing debt, gate on *new* findings instead:

```toml
[[predicate]]
id = "no-new-type-errors"
provider = "static"
cmd = "tsc"
args = ["--noEmit"]          # emit SARIF via your wrapper, or use a SARIF-capable tool
format = "sarif"
baseline = "stored"          # or a number, or a git ref like "main"
allowed_regression = 0
```

The finding *count* is compared against the baseline with `direction =
lower_better`:

- **A number** — a fixed finding budget. The count may not exceed it.
- **`"stored"` / `"prior"`** — the count's own last passing value, persisted in
  `<workspace>/.kazi/ratchets.json` (overridable via `context.ratchet_store_dir`,
  the same store the `ratchet` provider uses, so the anti-gaming work relocates
  both at once). The **first** run *seeds* the baseline (passes, records the
  count); on a later pass the floor **tightens** down (a removed finding cannot
  silently creep back); a fail leaves it untouched.
- **A git ref** (`"main"`, `"HEAD~1"`, a tag/SHA) — the analyzer is **re-run** at
  that ref in a throwaway detached worktree and its findings counted, so "no new
  findings vs `main`" is a real, recomputed comparison.

`allowed_regression` is the new-finding budget (default `0` — no new findings).

## Errors vs failures

`static` distinguishes a genuine `:fail` (findings present / new findings) from an
`:error` (the checker could not run): a missing analyzer binary, a declared
`error_code`, a timeout, or — for `format = "sarif"` — a SARIF parse failure is an
`:error`, so a broken analysis pipeline is never read as a pass. The exit code
otherwise does **not** decide the verdict; the parsed findings do.

## Evidence

The result carries `diagnostics` — the `file:line:col` / `rule` / `level` /
`message` findings a fixer needs (capped to a sample; the exact total is in
`findings_count`) — plus an `evidence` map with the resolved `cmd`, `args`,
`workspace`, `format`, the `findings_count`, the `exit` code, and a truncated
`output`. The ratchet gate adds the resolved `baseline`, `regression`,
`new_findings`, `allowed_regression`, `direction`, `baseline_source`
(`literal` / `stored` / `git_ref` / `seed`), and whether a new baseline was
`stored`.

## Worked examples

- [`priv/examples/static_dialyzer.toml`](../priv/examples/static_dialyzer.toml) —
  the Dialyzer zero-findings gate.
- [`priv/examples/static_sarif.toml`](../priv/examples/static_sarif.toml) — a
  SARIF tool ratcheted against its stored baseline (fail only on new findings).

## See also

- `kazi schema static` — the machine-readable key reference.
- [`docs/ratchet-predicate.md`](ratchet-predicate.md) — the underlying
  no-regression machinery `static` reuses for the baseline gate.
- [`docs/custom-script-provider.md`](custom-script-provider.md) — the generic
  command-runner for any other CLI checker.
- ADR-0043 — which checkers ship first-class, and in what order.
