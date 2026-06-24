# Deprecations and removal schedule

This document records kazi's deprecated surfaces and the concrete version in
which each is removed. A deprecated surface still works, prints a one-line hint
to stderr (never into `--json` stdout), and is kept through a written
deprecation window so existing callers are not broken mid-flight.

## Deprecated CLI verbs: `run`, `propose`, and `mix kazi.run`

Status: deprecated (ADR-0032). Removed in **v0.6.0** (the minor after the
rename ships in v0.5.0).

### What is deprecated

| Deprecated alias | Use instead     |
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

`run` and `propose` (and `mix kazi.run`) were kept as deprecated aliases rather
than hard-removed because the agent-drivable `--json` result contract (ADR-0023)
and the already-shipped install-skill / MCP / agent recipes (ADR-0024) are
compatibility surfaces that real callers may pin. The aliases give those callers
a window to migrate; they dispatch to the same code and print a one-line stderr
hint when used.

### Removal version

The aliases are scheduled for removal in **v0.6.0** (operator decision,
2026-06-24). The verb rename itself ships in v0.5.0 with the aliases still
present, so callers get a full minor-release window to migrate before v0.6.0
removes them. After v0.6.0:

- `kazi run` and `kazi propose` no longer parse; use `kazi apply` / `kazi plan`.
- `mix kazi.run` is removed; use `mix kazi.apply`.

### Migration

- Replace `kazi run <goal>` with `kazi apply <goal>` (flags unchanged).
- Replace `kazi propose <idea>` with `kazi plan <idea>` (flags unchanged).
- Replace `mix kazi.run` with `mix kazi.apply`.
- If you pin the `--json` result contract by `schema_version`, note that the
  schemas are keyed by the new command names (`apply`, `plan`); the old names are
  documented as deprecated aliases (ADR-0023, ADR-0032).

The runtime hint already points the way: invoking a deprecated alias prints
`note: \`kazi run\` is deprecated; use \`kazi apply\` (removed in v0.6.0)` to
stderr (and the analogous line for `propose` / `mix kazi.run`).

See ADR-0032 (`docs/adr/0032-rename-cli-verbs-run-apply-propose-plan.md`) for the
full decision and its consequences.
