# The `cli` predicate provider

`cli` asserts that a **shipped command-line binary actually runs** the way a user
invokes it (T43.7, UC-055). It runs a command you declare in the goal-file and
gates on the **observable surface a user sees** — the exit code, and the `stdout` /
`stderr` streams.

The keystone idea: `mix test` (or any in-process test suite) proves the code
compiles and the unit paths hold; it does **not** prove the packaged binary boots
and answers `kazi version` on a real `$PATH`. Real regressions have passed the whole
test suite while the released binary crashed on its first CLI call (a `:noproc` on
the read-model, an OTP-28 stderr warning, a `RELEASE_*` environment leak). `cli`
closes that gap.

You can introspect every key at runtime with:

```
kazi schema cli
```

## Config keys

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `cmd` | string | yes | The executable. ONE executable, not a command line — use `args` for the rest. A name containing `/` resolves against the workspace; a bare name is a `$PATH` lookup. A `cmd` that resolves to no executable is an `:error`, never a silent pass. |
| `args` | array of strings | no | Arguments passed to `cmd`. Default `[]`. |
| `env` | table / pairs | no | Extra environment as `{NAME = "value"}` or `{name, value}` pairs. |
| `timeout_ms` | integer | no | Kill the command after this many ms → `:error`. |
| `assertions` | array of tables | **yes** | A **non-empty** list of checks. An empty list is a **load error** — a `cli` predicate with no assertions can never pass or fail meaningfully. |

## Assertions

Each assertion table names a `target` and how to check it.

### `exit_code`

`expected` is the integer the process exit code must equal.

```toml
[[predicate.assertions]]
target = "exit_code"
expected = 0
```

### `stdout` / `stderr`

`match` selects the matcher over that stream, and `expected` carries the operand:

| `match` | Passes when |
|---------|-------------|
| `equals` | the **whole stream** equals `expected` |
| `contains` | the stream **contains** `expected` as a substring |
| `regex` | the stream **matches** the `expected` pattern (validated at load) |
| `json_path` | the stream parses as JSON, the value at `path` is extracted, and it **equals** `expected` |

```toml
# the binary names itself on stdout
[[predicate.assertions]]
target = "stdout"
match = "contains"
expected = "kazi"

# nothing noisy on stderr — the check that catches an OTP boot warning
[[predicate.assertions]]
target = "stderr"
match = "equals"
expected = ""

# gate on the PARSED machine envelope, not a brittle substring
[[predicate.assertions]]
target = "stdout"
match = "json_path"
path = "$.schema_version"
expected = 2
```

`path` is the same focused JSONPath subset the other providers use: a leading `$`,
`.key` object segments, and `[index]` array subscripts (e.g. `"$.runs[0].id"`). A
`json_path` assertion **requires** a non-empty `path`, checked at load time.

The predicate **passes** only when **every** assertion holds. The envelope-v2
`score` is the count of assertions that passed (`direction: higher_better`), so the
controller reads "2 of 3 → 3 of 3" as progress.

## `:error` vs `:fail`

kazi distinguishes a genuine `:fail` (the predicate does not hold — real work for
the agent) from an `:error` (the checker could not run — infra, NOT something a
fixer agent should be dispatched against). `cli` maps to:

- **`:error`** when the binary could not be **launched at all** (`cmd` resolves to
  no executable, a bad workspace) or the run overran `timeout_ms`. The binary that
  cannot start is infra, never failing work.
- **`:fail`** when the binary **ran** but an assertion does not hold — including a
  `json_path` matcher over output that is not valid JSON, or a `path` that does not
  resolve. The binary answered; its output is just wrong. The evidence names the
  reason.

This is the same lesson Argo Rollouts encodes by separating `failureLimit` from
`consecutiveErrorLimit`: a broken evidence pipeline must never be read as a pass,
and an unlaunchable binary must never be read as a failing predicate.

## Stream separation

The shared command-runner seam captures a single output stream, so to keep `stdout`
and `stderr` **independently** assertable the provider pre-resolves the executable
(which is also how it produces the `:error`-on-unrunnable verdict) and runs it under
`sh -c` with `stderr` redirected to a temp file — `stdout` is captured by the
runner, `stderr` is read back from the file. Timeout and the release-env scrub still
apply because the run still goes through the shared runner.

## Evidence

Every result carries the proof a fixer needs: the resolved `cmd`, `args`,
`workspace`, the `exit` code, and the truncated `stdout` / `stderr`. A pass or fail
also carries the per-assertion `results` matrix; a fail additionally carries an
`assertion_failures` list (each `{target, match, expected, found}`). An `:error`
result carries a `reason` naming what went wrong.

## Shipped recipe

A worked example lives at
[`priv/examples/cli_provider.toml`](../priv/examples/cli_provider.toml): it asserts
the real `kazi` binary answers `kazi version` (exit 0, `"kazi"` on stdout) and
`kazi version --json` (exit 0, `$.schema_version == 2`).

```
kazi apply priv/examples/cli_provider.toml --workspace . --check
```

## See also

- `Kazi.Providers.Cli` — the provider.
- `Kazi.Goal.Loader` — the goal-file schema and load-time validation.
- [`docs/custom-script-provider.md`](custom-script-provider.md) — the generic
  command-runner, for gating on a tool's parsed findings rather than a binary's
  golden invocation.
