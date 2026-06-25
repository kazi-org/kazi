# Deprecations and removal schedule

This document records kazi's deprecated surfaces and the concrete version in
which each is removed. A deprecated surface is kept through a written deprecation
window so existing callers are not broken mid-flight; once a surface is removed,
it is recorded here as REMOVED with the version that removed it.

## DEPRECATED provider names: `test_runner` and `prod_log`

Status: **DEPRECATED (folded onto `custom_script`); removal scheduled for
v2.0.0** (ADR-0040 decisions 1 + 7). The two bespoke command-runner providers are
now thin presets over the unified `custom_script` engine. Both names still
RESOLVE -- an existing goal-file loads and evaluates byte-identically -- so this
ships NON-BREAKING (a minor bump). When a goal still declares either name, the
loader emits a one-line migration hint to STDERR (never into `--json` stdout).

### What is deprecated (and what to use)

| Deprecated provider | Use instead                                    |
|---------------------|------------------------------------------------|
| `test_runner`       | `custom_script` with `verdict = "exit_zero"`   |
| `prod_log`          | `custom_script` with `verdict = "match_count"` |

`http_probe` and `browser` are NOT command-runners -- they keep their own
contracts and are unaffected.

### Why (rationale)

ADR-0040 makes `custom_script` THE command-runner: the sanctioned extension point
where a new verification kind is config, not a kazi release. Keeping
`test_runner` and `prod_log` as separate first-class providers would leave several
ways to "run a command" with duplicated verdict/evidence logic. They are folded
onto one engine (`Kazi.Providers.CommandRunner`) and their names deprecated so
there is a single command-runner surface. The presets exist only for the
migration window.

### Removal version

The names are removed in **v2.0.0**. Removing a public surface is a breaking
change, so it lands on the next major -- mirroring the `run`/`propose` ->
v1.0.0 pattern. Until then both names keep working as presets and the loader
prints the migration hint.

### Migration (near-mechanical goal-file edit)

`test_runner` -- rename the provider and declare the (already-default) verdict;
`cmd`/`args`/`env` are unchanged:

```toml
# before
[[predicate]]
id = "code"
provider = "test_runner"
cmd = "go"
args = ["test", "./..."]

# after
[[predicate]]
id = "code"
provider = "custom_script"
verdict = "exit_zero"
cmd = "go"
args = ["test", "./..."]
```

`prod_log` -- rename the provider and express the threshold as a `match_count`
verdict over the query output (`match_regex` selects the lines to count,
`pass_when` is the gate). `cmd`/`args`/`env` are unchanged:

```toml
# before
[[predicate]]
id = "logs"
provider = "prod_log"
cmd = "fetch-logs"
args = ["--service", "api", "--minutes", "15"]
max_5xx = 0

# after
[[predicate]]
id = "logs"
provider = "custom_script"
verdict = "match_count"
cmd = "fetch-logs"
args = ["--service", "api", "--minutes", "15"]
match_regex = " 5\\d\\d "
pass_when = "== 0"
```

Note: the `custom_script` `match_count` evidence reports the matched-line
`observed` count and a bounded `matched_lines` sample; `prod_log`'s
production-log-shaped evidence (`server_error_count`, `panic_count`,
`window_minutes`) is specific to that preset. Migrate to the generic count when
you are ready to read the generic evidence; until v2.0.0 the `prod_log` preset
keeps its richer evidence.

### Hint, not error

While deprecated, a goal using either name loads and runs unchanged; the loader
prints one advisory line per distinct deprecated provider to STDERR -- e.g.
`kazi: provider "test_runner" is deprecated (ADR-0040) and will be removed in
v2.0.0 — migrate to custom_script (verdict = "exit_zero"). See
docs/deprecations.md.` -- and never touches stdout, so a `--json` caller's
stdout stays pure JSON. At v2.0.0 the names will stop resolving and become a
load error.

See ADR-0040 (`docs/adr/0040-generic-predicate-protocol-custom-script.md`) for
the full decision and its consequences.

## REMOVED CLI verbs: `run`, `propose`, and `mix kazi.run`

Status: **REMOVED in v1.0.0** (ADR-0032). These aliases were deprecated when the
rename shipped in v0.5.0 and removed in the next release, v1.0.0 -- the removal
is a breaking change, so it landed as a major version bump. They no longer
parse: `kazi run` / `kazi propose` now produce an "unknown command" error, `mix
kazi.run` no longer exists, and the MCP server no longer advertises or dispatches
`kazi_run` / `kazi_propose`.

### What was removed (and what to use)

| Removed alias    | Use instead     |
|------------------|-----------------|
| `kazi run`       | `kazi apply`    |
| `kazi propose`   | `kazi plan`     |
| `mix kazi.run`   | `mix kazi.apply`|

### Why (rationale)

Under ADR-0032 the user-facing verbs were unified so there is exactly one name
per concept across the agent prompt, the skill router, and the CLI: `kazi plan`
authors intent and `kazi apply` converges it, matching the `/plan` and `/apply`
skills. Previously the CLI shipped `kazi run` / `kazi propose` while the
operator's workflow and the skill router (ADR-0031) used `apply` / `plan`,
leaving two names per concept and steady doc drift. ADR-0032 renamed the CLI
verbs to close that gap.

`run` and `propose` (and `mix kazi.run`) were kept as deprecated aliases for one
minor release rather than hard-removed at rename time because the agent-drivable
`--json` result contract (ADR-0023) and the already-shipped install-skill / MCP /
agent recipes (ADR-0024) are compatibility surfaces that real callers may pin. The
aliases gave those callers a window to migrate; that window (v0.5.0) has elapsed.

### Removal version

The aliases were removed in **v1.0.0** (operator decision, 2026-06-24). The verb
rename shipped in v0.5.0 with the aliases still present, so callers got a
release window to migrate before v1.0.0 removed them. As of v1.0.0:

- `kazi run` and `kazi propose` no longer parse; use `kazi apply` / `kazi plan`.
- `mix kazi.run` no longer exists; use `mix kazi.apply`.

### Migration

- Replace `kazi run <goal>` with `kazi apply <goal>` (flags unchanged).
- Replace `kazi propose <idea>` with `kazi plan <idea>` (flags unchanged).
- Replace `mix kazi.run` with `mix kazi.apply`.
- If you pin the `--json` result contract by `schema_version`, note that the
  schemas are keyed by the command names `apply`, `plan` (the old `run` / `propose`
  schema aliases were removed too — `kazi schema run` / `kazi schema propose` no
  longer resolve) (ADR-0023, ADR-0032).

Invoking a removed verb now ERRORS rather than dispatching: `kazi run <goal>`
prints an "unknown command" error (and a non-zero exit) instead of running, so a
stale script fails loudly rather than silently doing the wrong thing. There is no
longer a deprecation hint — the verb simply does not exist.

See ADR-0032 (`docs/adr/0032-rename-cli-verbs-run-apply-propose-plan.md`) for the
full decision and its consequences.
