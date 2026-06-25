# Deprecations and removal schedule

This document records kazi's deprecated surfaces and the concrete version in
which each is removed. A deprecated surface is kept through a written deprecation
window so existing callers are not broken mid-flight; once a surface is removed,
it is recorded here as REMOVED with the version that removed it.

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
