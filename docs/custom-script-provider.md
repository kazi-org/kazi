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
| `cmd` | string | yes | The executable. ONE executable, not a command line — use `args` for the rest. |
| `args` | array of strings | no | Arguments passed to `cmd`. Default `[]`. |
| `env` | table / pairs | no | Extra environment as `{NAME = "value"}` or `{name, value}` pairs. |
| `verdict` | string | no | `"exit_zero"` (default), `"exit_code"`, or `"json"`. See below. |
| `pass_codes` | array of integers | for `exit_code` | Exit codes that count as **pass**. |
| `fail_codes` | array of integers | no | Exit codes that count as **fail** (a code in neither list is a fail). |
| `path` | string | for `json` | A JSONPath subset over stdout to the value to compare. |
| `pass_when` | string | for `json` | The comparison the extracted number must satisfy, `"<op> <number>"`. |
| `error_codes` | array of integers | no | Exit codes that mean **the checker could not run** → `:error` (not `:fail`). |
| `evidence_format` | string | no | `"sarif"`, `"junit"`, `"json"`, or `"raw"` (default). Shapes evidence only. |
| `timeout_ms` | integer | no | Kill the command after this many ms → `:error`. |

Invalid declarations fail loudly **at load time** (an unknown verdict, a `json`
verdict missing `path`/`pass_when`, a malformed `pass_when`, an `exit_code`
verdict without `pass_codes`), not silently at dispatch.

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

## `:error` vs `:fail`

kazi distinguishes a genuine `:fail` (the predicate does not hold — real work for
the agent) from an `:error` (the checker could not run — an infra/config problem,
NOT something a fixer agent should be dispatched against). `custom_script` maps to
`:error`, never `:fail`, when:

- the binary is missing or the workspace path is invalid (`:cmd_unrunnable`);
- the exit code is one you declared in `error_codes`;
- a `json` verdict's stdout is not valid JSON, or `path` does not resolve;
- the command exceeds `timeout_ms`.

This is the same lesson Argo Rollouts encodes by separating `failureLimit` from
`consecutiveErrorLimit`: a broken evidence pipeline must never be read as a pass.

## Evidence

Every result carries the proof a fixer agent needs: `cmd`, `args`, `workspace`,
`verdict`, the `exit` code, and a truncated `output`. A `json` verdict adds
`path`, `pass_when`, and the `observed` number. Setting `evidence_format` to
`"sarif"` or `"junit"` adds a structured `findings` list (file/line/rule/message
for SARIF; failing case names for JUnit). Evidence extraction never changes the
verdict.

## Shipped recipes

Three worked examples live under [`priv/examples/`](../priv/examples/):

- `custom_script_sarif.toml` — gate on a SARIF scanner's parsed findings count.
- `custom_script_junit.toml` — a test runner gated on its exit code, with JUnit
  evidence.
- `custom_script_mutation.toml` — gate on a mutation tester's JSON score.

## See also

- ADR-0040 (`docs/adr/0040-generic-predicate-protocol-custom-script.md`) — the
  accepted decision this implements.
- `Kazi.Providers.CustomScript` — the engine.
- `Kazi.Goal.Loader` — the goal-file schema and load-time validation.
