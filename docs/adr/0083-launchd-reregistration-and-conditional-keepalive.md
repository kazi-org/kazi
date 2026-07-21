# ADR 0083: launchd re-registration on binary upgrade, and conditional KeepAlive

## Status
Accepted (operator, 2026-07-21)

## Date
2026-07-21

## Context
Issue #1484 reported the bus daemon's launchd LaunchAgent (`run.kazi.bushost`,
T66.6/#1579) exiting 78 with zero log output. A long elimination series (issue
comments, 2026-07-19 through 2026-07-21) cleared the binary itself: symlink vs.
direct-install program path, quarantine xattr, architecture (x86_64 and
aarch64), and every burrito extraction-directory / `_metadata.json` fault
(missing, corrupt, unreadable) across both an old and a current launcher --
all recovered cleanly. **kazi never returns 78** (`daemon_error/2` returns 1;
there is no `System.halt(78)` anywhere in `lib/`).

The root cause, confirmed on the affected machine: **78 is launchd's own
`EX_CONFIG`**. The installed binary is adhoc / linker-signed
(`flags=0x20002(adhoc,linker-signed)`), so its code signature is bound to the
exact bytes. A package upgrade (Homebrew, a downloaded release, a self-update)
replaces the binary in place UNDERNEATH a LaunchAgent job that had already
pinned a Lightweight Code Requirement (LWCR) against the PREVIOUS binary --
`launchctl print` shows `needs LWCR update` -- and launchd refuses to spawn
it. Running the job's exact `ProgramArguments` by hand exits 1 (kazi's own
"already running" message), never 78: the binary is never executed. The
decisive confirming experiment: `launchctl bootout` + `bootstrap` of the SAME
plist, with NO change to the binary, flipped the job's `last exit code` from
78 to 1 and its `runs` counter from 33,035 to 2.

That `runs = 33035` is a second, separable defect: the shipped plist's
`KeepAlive: true` respawns unconditionally, at launchd's 10s minimum
throttle, forever -- including against a PERMANENTLY failing precondition
(here, a stale daemon holding the socket). No amount of respawning fixes
that; it only produces the crashloop that made the failure hard to see in
the first place.

## Decision
Two independent fixes, both in `Kazi.Daemon.LaunchAgent` (pure, deterministic
rendering/parsing -- no real launchd job is ever registered in the test
suite) plus a `kazi daemon` seam in `Kazi.CLI`:

**1. `kazi daemon reregister` (macOS-only, no-op elsewhere).** Runs
`launchctl bootout gui/$(id -u)/run.kazi.bushost` (allowed to fail -- an
unloaded job is a legitimate starting state) then
`launchctl bootstrap gui/$(id -u) <plist path>`, re-pinning the LWCR against
whatever binary is on disk NOW. `LaunchAgent.reregister_argv/2` builds the
argv purely; `LaunchAgent.parse_job_state/1` + `stale_registration?/1` parse
`launchctl print` output to DETECT the condition (`needs LWCR update`, or a
bare `last_exit_code: 78` as a decisive fallback) for a future `daemon status`
enhancement or operator script. We deliberately did NOT wire automatic
re-registration into a self-update/install path in this change (see
Consequences) -- the CLI verb is the seam; something upstream (a formula, a
self-update command, an installer) can shell out to it once one exists in
this codebase.

**2. Conditional `KeepAlive`.** The shipped launchd plist changes from
`KeepAlive: true` to `KeepAlive: {SuccessfulExit: false}` -- restart only on a
NON-zero exit -- plus an explicit `ThrottleInterval` (10s, matching launchd's
own default, made greppable) so the budget is visible in one place. The
systemd unit gets the equivalent bound: `RestartSec` plus
`StartLimitIntervalSec`/`StartLimitBurst` (systemd's native backoff-then-stop
primitive). Both templates additionally export a `KAZI_SUPERVISOR` env var
(`launchd` / `systemd`) so a running `kazi daemon start` can tell it is under
supervision -- `LaunchAgent.supervised?/1` reads it defensively (an
unrecognized or absent value is never treated as supervised).

`kazi daemon start`'s `{:error, {:already_running, vsn}}` path -- the one
behind the reported 33,035-attempt crashloop -- now exits **0** instead of 1
when `supervised?/1` is true (`Kazi.CLI`'s new `daemon_permanent_error/3`),
which is a "do not retry" signal to `KeepAlive: {SuccessfulExit: false}`. The
message is printed identically either way, on stdout/stderr exactly as
before; only the exit code changes, and ONLY under a supervisor -- a hand-run
`kazi daemon start` against an already-running daemon still exits 1, unchanged
for scripts and tests that depend on that.

## Consequences
- **78 itself is not fixed by kazi** -- it cannot be: launchd generates it
  before the binary runs. `reregister` is a REMEDY an operator or a future
  install/upgrade hook must invoke; it does not run itself. Wiring automatic
  re-registration into a self-update or Homebrew post-install step is
  explicitly out of scope here (no such hook exists in this codebase to wire
  it into today) and is left as follow-up work, cross-referenced from #1484.
- Every existing `kickstart_command/0` caller and message is unchanged;
  `reregister_command/0` is additive and clearly documents that a kickstart
  is the WRONG remedy for a stale registration (it re-runs the job under the
  same invalid LWCR).
- `KeepAlive: {SuccessfulExit: false}` is a BEHAVIOR CHANGE for every OTHER
  permanent failure this daemon can hit that still exits non-zero (e.g.
  `:nats_bin_not_found`): those still loop at the throttle interval, bounded
  but not silenced. We chose not to broaden the exit-0 treatment to every
  `daemon_error/2` call site -- only the one the live crashloop evidence
  actually named -- because turning arbitrary failures into "silent success"
  exit codes trades a noisy symptom for an invisible one. If further permanent
  conditions turn up in practice, they should each get the same explicit,
  narrow treatment `daemon_permanent_error/3` gives "already running", not a
  blanket exemption.
- macOS-only surfaces (`reregister`'s launchd calls) are guarded by
  `:os.type/0` and fully test-seamed (`inject_opts[:launchd_os]`,
  `:reregister_runner`, `:uid_fn`) so CI on Linux exercises every branch
  without a real launchd job or a real `launchctl` binary.
- #1484 can close citing this ADR + the shipped `reregister` verb + the
  conditional `KeepAlive`; the live confirmation that a NEXT in-place upgrade
  no longer produces a silent 78 crashloop is still an operator-observed
  follow-up (this ADR ships the mechanism, not a live re-run of the original
  33,035-attempt failure).
