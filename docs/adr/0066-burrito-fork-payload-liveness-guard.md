# ADR 0066: Fork burrito for a payload liveness guard

## Status
Accepted

## Date
2026-07-09

## Context

Burrito (the single-binary packager, ADR-0014) extracts its payload to a
versioned install dir (`~/Library/Application Support/.burrito/kazi_erts-<erts>_<vsn>`
on macOS) on first run, and on EVERY launch runs a maintenance pass
(`src/wrapper.zig` -> `do_clean_old_versions`) that deletes all same-app
install dirs with an older semver -- unconditionally, with no liveness check
and no opt-out.

On a machine running several concurrent kazi processes (the exact fleet shape
E50/ADR-0065 is built for), this is fatal during release windows: the first
invocation of a new version deletes the payload of every older-version process
still running. Those processes don't die immediately -- the BEAM lazily loads
some ERTS modules (`io_lib_pretty` loads on the first pretty-print, i.e. the
first time the run formats an error) -- so they crash minutes-to-hours later
with:

```
{error,[{io_lib_pretty,nofile}]} ... io_lib:test_modules_loaded/3
DEFAULT FORMATTER CRASHED
Kernel pid terminated (application_controller)
```

Eight releases shipped on 2026-07-09 alone; two in-flight `kazi apply` runs
were killed this way (issue #1018), initially misdiagnosed as OOM because the
crashes coincided with memory pressure. The wrapper honors
`KAZI_INSTALL_DIR` as a per-process install-prefix override, which works as a
manual workaround but silently costs a ~12MB re-extract per run and requires
every launcher to remember it.

## Decision

Fork burrito to `kazi-org/burrito` (branch `payload-liveness-guard`, based on
the v1.5.0 tag kazi already ships) and pin kazi's mix.exs to the fork by
commit ref. The patch, proposed upstream as well:

1. **Liveness pidfiles.** Before the wrapper execs the runtime, it records its
   PID at `<install_dir>/.burrito_live/<pid>`. The exec preserves the PID, so
   the pidfile stays accurate for the app's whole lifetime. Stale pidfiles
   (dead PIDs, checked via `kill(pid, 0)`; EPERM counts as alive) are pruned
   opportunistically.
2. **Cleanup skips live installs.** `do_clean_old_versions` skips any install
   dir whose `.burrito_live/` contains a live PID, logging
   `Skipped cleanup of older version (vX): still in use by a running process`.
3. **Escape hatch.** `BURRITO_NO_CLEAN_OLD=1` skips the cleanup pass entirely.
4. **Windows keeps upstream behavior** (no cheap liveness probe there; in-use
   executables are protected by mandatory file locking anyway).

The patch is covered by `zig test` blocks in `src/maintenance.zig`
(own-pid alive, EPERM-alive, live-pidfile-blocks / stale-pidfile-prunes /
garbage-name-ignored) and compiles clean under Zig 0.15.2, the version the
release workflow pins.

## Consequences

- In-flight kazi runs survive release windows; the crash class in issue
  #1018 is closed at the mechanism rather than by asking every operator to
  set `KAZI_INSTALL_DIR`.
- kazi now tracks a git fork rather than the hex package: upstream burrito
  releases stop arriving automatically, and the fork must be rebased when we
  want them. Mitigation: the same patch is submitted upstream; when it lands
  in a burrito release, revert to the hex dep and delete the fork branch
  (tracked in issue #1018).
- Old install dirs can now outlive their processes until the next launch's
  prune pass (pidfile removed only when a cleanup pass or re-launch observes
  the dead PID). Disk cost is bounded: one ~40MB payload per still-referenced
  version.
- PID reuse can keep a dead install alive spuriously in rare cases; the
  next cleanup pass after the recycled PID exits reclaims it. Deleting too
  little, late, is the correct failure direction here -- the previous behavior
  deleted too much, immediately.
