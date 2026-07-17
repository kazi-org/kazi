# The `custom_script` predicate provider

`custom_script` is kazi's **generic command-runner** — the sanctioned extension
point (ADR-0040). It runs a command you declare in the goal-file and maps the
result to a predicate verdict. A new kind of verification (a security scanner, a
mutation tester, a contract check, a license audit) becomes **config, not a kazi
release**.

The keystone idea: the **verdict is declared, not assumed**. "Exit code 0 means
pass" is wrong for many common tools — `govulncheck`, `semgrep`, and `trivy` all
exit `0` *with* findings under JSON/SARIF output, so a naive runner silently
passes real failures. `custom_script` makes you say how the verdict is derived,
and defaults safely.

You can introspect every key at runtime with:

```
kazi schema custom_script
```

## Config keys

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `cmd` | string | yes | The executable. ONE executable, not a command line — use `args` for the rest. A name containing `/` resolves against the workspace; a bare name resolves on `PATH`. See [How `cmd` resolves](#how-cmd-resolves). |
| `args` | array of strings | no | Arguments passed to `cmd`. Default `[]`. |
| `env` | table / pairs | no | Extra environment as `{NAME = "value"}` or `{name, value}` pairs. |
| `verdict` | string | no | `"exit_zero"` (default), `"exit_code"`, `"json"`, or `"match_count"`. See below. |
| `pass_codes` | array of integers | for `exit_code` | Exit codes that count as **pass**. |
| `fail_codes` | array of integers | no | Exit codes that count as **fail** (a code in neither list is a fail). |
| `path` | string | for `json` | A JSONPath subset over stdout to the value to compare. |
| `match_regex` | string | for `match_count` | A regex marking an output line to count. |
| `pass_when` | string | for `json`, `match_count` | The comparison the extracted/observed number must satisfy, `"<op> <number>"`. |
| `merge_stderr` | boolean | no | Fold stderr into stdout so the retained `output` is the combined stream. Default `false`. |
| `error_codes` | array of integers | no | Exit codes that mean **the checker could not run** → `:error` (not `:fail`). |
| `evidence_format` | string | no | `"sarif"`, `"junit"`, `"json"`, or `"raw"` (default). Shapes evidence only. |
| `timeout_ms` | integer | no | Kill the command after this many ms → `:error`. |

Invalid declarations fail loudly **at load time** (an unknown verdict, a `json`
verdict missing `path`/`pass_when`, a malformed `pass_when`, an `exit_code`
verdict without `pass_codes`), not silently at dispatch.

## How `cmd` resolves

`cmd` resolves with **shell semantics**, against the workspace the command runs in:

- **A name containing `/` is a path** and resolves against the workspace, so a
  checker committed in the tree it grades just works:

  ```toml
  cmd = "scripts/check.sh"   # -> <workspace>/scripts/check.sh
  ```

  The script must be executable (`chmod +x`, and a `#!` line). Evidence records
  the **resolved** absolute path, so you can see exactly what ran.

- **A bare name is a `PATH` lookup**, exactly as in a shell:

  ```toml
  cmd = "semgrep"            # -> whatever `semgrep` resolves to on PATH
  ```

  A bare name is never joined to the workspace, so a stray `./semgrep` sitting in
  the workspace cannot shadow the real tool.

A path that does not resolve to an executable file is left as written and the exec
fails — an `:error` naming what was tried (`exec failed: scripts/check.sh: not
found`), never a silent pass. The same applies to a file that exists but is not
executable, which is the usual cause of a surprising "not found".

## Verdicts

### `exit_zero` (default)

Exit `0` is `:pass`; any other exit is `:fail`. The safe baseline for a tool
whose exit code already means pass/fail (e.g. a unit-test runner).

```toml
[[predicate]]
id = "tests-green"
provider = "custom_script"
cmd = "go"
args = ["test", "./..."]
# verdict defaults to "exit_zero"
```

### `exit_code`

Map specific exit codes. Use it when a tool's "findings" exit code is not `1`
(e.g. `grype` exits `2`). A code in neither `pass_codes` nor `fail_codes` is a
fail — a gate never passes an undeclared code.

```toml
[[predicate]]
id = "no-vulns"
provider = "custom_script"
cmd = "grype"
args = ["dir:.", "--fail-on", "high"]
verdict = "exit_code"
pass_codes = [0]
fail_codes = [2]
```

### `json`

Parse stdout as JSON, extract the value at `path`, and compare it via
`pass_when`. This gates a tool on its **parsed output**, not its exit code — so a
SARIF scanner that always exits `0` is failed on its findings.

`path` is a focused JSONPath subset: a leading `$`, `.key` segments, and
`[index]` array subscripts (e.g. `"$.runs[0].results"`, `"$.summary.failures"`).
The extracted value is coerced to a number for comparison — a number is used
verbatim, and a **list uses its length**, so a `path` pointing at a findings
array compares its **count**.

`pass_when` is `"<op> <number>"` where `<op>` is one of `== != < <= > >=`.

```toml
[[predicate]]
id = "no-sarif-findings"
provider = "custom_script"
cmd = "semgrep"
args = ["--sarif", "--config", "auto", "."]
verdict = "json"
evidence_format = "sarif"
path = "$.runs[0].results"
pass_when = "== 0"
```

A JSON parse failure or a missing path is an `:error`, never a silent pass.

### `match_count`

Count the lines of the command's output that match `match_regex` and compare that
**count** via `pass_when`. This gates a tool on the **textual signal** in its
output rather than its exit code — e.g. "no `panic` lines", "at most two
deprecation warnings". `pass_when` is `"<op> <number>"` (same operators as
`json`). Set `merge_stderr = true` when the signal you count is on stderr.

```toml
[[predicate]]
id = "no-5xx-in-window"
provider = "custom_script"
cmd = "fetch-logs"
args = ["--service", "api", "--minutes", "15"]
verdict = "match_count"
match_regex = " 5\\d\\d "
pass_when = "== 0"
```

An invalid or missing `match_regex`/`pass_when` is an `:error`, never a silent
pass.

## `:error` vs `:fail`

kazi distinguishes a genuine `:fail` (the predicate does not hold — real work for
the agent) from an `:error` (the checker could not run — an infra/config problem,
NOT something a fixer agent should be dispatched against). `custom_script` maps to
`:error`, never `:fail`, when:

- the binary is missing or the workspace path is invalid (`:cmd_unrunnable`);
- the exit code is one you declared in `error_codes`;
- a `json` verdict's stdout is not valid JSON, or `path` does not resolve;
- a `match_count` verdict's `match_regex` or `pass_when` is missing or malformed;
- the command exceeds `timeout_ms`.

This is the same lesson Argo Rollouts encodes by separating `failureLimit` from
`consecutiveErrorLimit`: a broken evidence pipeline must never be read as a pass.

## Evidence

Every result carries the proof a fixer agent needs: the **resolved** `cmd`, `args`,
`workspace`, `verdict`, the `exit` code, and a truncated `output`. A `json` verdict
adds `path`, `pass_when`, and the `observed` number. A `match_count` verdict adds
`match_regex`, `pass_when`, the `observed` count, and a bounded `matched_lines`
sample. Setting `evidence_format` to `"sarif"` or `"junit"` adds a structured
`findings` list (file/line/rule/message for SARIF; failing case names for JUnit).
Evidence extraction never changes the verdict.

An `:error` result additionally carries a `reason` naming what went wrong
(`{:cmd_unrunnable, _}`, `{:timeout_ms, _}`, `{:error_exit, _}`, …). `kazi apply
--check` reports that reason on both surfaces — a `reason:` line under the
predicate in the human output, and a stringified `evidence.reason` under `--json`
— so an errored check is never a bare, unactionable `error`:

```
CHECK (observe-only, nothing dispatched)  goal=my-goal
status: fail
  lint: error
    reason: exec failed: scripts/check.sh: not found
```

## Folds the bespoke command-runners (test_runner, prod_log)

`custom_script` is **the** command-runner. The two older command-runner
providers are now thin presets over this one engine and their names are
**deprecated** (removed in v2.0.0):

- `test_runner` == `custom_script` with `verdict = "exit_zero"`;
- `prod_log` == `custom_script` with a `match_count` verdict over the query output.

Both names still resolve, so existing goals keep working; the loader prints a
one-line migration hint to STDERR. See
[`docs/deprecations.md`](deprecations.md) for the near-mechanical goal-file
migration and the removal schedule.

## Shipped recipes

Three core worked examples live under [`priv/examples/`](../priv/examples/):

- `custom_script_sarif.toml` — gate on a SARIF scanner's parsed findings count.
- `custom_script_junit.toml` — a test runner gated on its exit code, with JUnit
  evidence.
- `custom_script_mutation.toml` — gate on a mutation tester's JSON score.

A fuller catalog of off-the-shelf recipes — contract/schema compat (`buf
breaking`, `oasdiff`, `pact can-i-deploy`), perf/size ratchets, secret scanning
(TruffleHog), a11y (Lighthouse), IaC/container scan (Trivy), and visual
regression — lives in [`docs/custom-script-recipes.md`](custom-script-recipes.md),
which also documents the two evidence tiers (demonstration vs presence/claim) and
the per-tool exit-code gotchas.

## See also

- ADR-0040 (`docs/adr/0040-generic-predicate-protocol-custom-script.md`) — the
  accepted decision this implements.
- `Kazi.Providers.CustomScript` — the engine.
- `Kazi.Goal.Loader` — the goal-file schema and load-time validation.
