# Handover — 2026-07-10 overnight session (bus + hardening sweep)

For the next coordinator session, expected on a DIFFERENT machine. Everything
below is repo/GitHub state; nothing depends on the previous machine except
where explicitly flagged.

## Where things stand

- **Latest release ≥ v1.140.2.** The session bus (ADR-0067 Wave A) shipped in
  v1.138.0; the E53 hardening fixes shipped across v1.136.1–v1.140.x.
- **ADRs 0067 (session coordination bus) + 0068 (daemon single-writer
  read-model): Accepted** (PR #1035). Epics: E51 (bus — Wave A T51.1–T51.3
  DONE), E52 (outline — its T52.0 planning task is now UNBLOCKED, the daemon
  shapes it needed exist), E53 (runtime bugs — T53.1–T53.4 all DONE).
- **Shipped tonight:** `kazi daemon start|stop|status` (#1044), `kazi bus
  post|read|who|tell` over daemon-supervised NATS JetStream (goal 0025),
  mcp bus tools + `docs/session-bus.md` (#1048); integrate idempotence
  (#1037 → issue #1027 closed), worktree liveness guard (#1050 → #1022
  closed), integrate timeout + diagnostics (#1052 → #1020 closed),
  session-id capture hardening (#1055 → **#1013 left open on purpose**,
  see below). Wrap-up checkboxes + devlog: #1057.
- **T50.7 (fleet live dogfood): DONE, honestly partial** — see the
  2026-07-10 entry in `docs/devlog.md`. The fleet's scheduling/isolation/
  landing layers work on a released binary; its TEARDOWN is broken
  (issue **#1053**: crashed a member whose work had already landed,
  cascade-blocked its dependent, and deleted the `--workspace` BASE
  worktree — an ADR-0065 contract violation).

## Priorities for the next session

1. **#1053 fleet teardown** — P0 before any unattended fleet run. Until it
   lands, only ever point `--fleet --workspace` at a disposable worktree.
2. **#1013 CI watch** — the fix landed with WARN tracers on every silent
   drop point. Check main's last ~10 CI runs: quiet → close #1013; red →
   the failure log now NAMES the drop point; fix that and close.
3. **E51 Wave B** (T51.4 server-side digests, T51.5 run-lifecycle mirroring
   + starmap presence, T51.6 two-session live dogfood). Goal-files exist
   only for Wave A (0024–0026); Wave B needs its goal-files authored first
   (follow the 0020–0026 batch shape — note their `landed` predicates pin
   the NAMED task branch; keep doing that).
4. **T52.0** — expand E52 to executable fidelity (`kind: plan` task,
   deps satisfied).

## New-machine setup checklist

- Install the latest release binary directly from GitHub releases and verify
  `kazi version` matches the newest tag (the Homebrew tap has lagged before).
- The daemon needs `nats-server` on PATH (`kazi daemon start` fails with an
  install hint otherwise). Start it in the background; `kazi daemon status`
  must report ok + `nats_port` before `kazi bus` verbs work.
- The daemon/bus is per-machine state: a fresh machine starts with empty
  presence/streams. That is by design (bus ≠ memory; durable knowledge is in
  docs/).

## Operational landmines (all observed this session)

- **Dispatch-wrapper wedge:** a run can sit alive at 0% CPU with the harness
  agent gone and an orphaned poll-sleep wrapper (observed 3×). Detect via
  stderr-log mtime (>25 min silent = suspect), never via log size. Remedy:
  kill + relaunch; with `--in-place`, uncommitted agent work survives in the
  workspace tree.
- **A "crashed" fleet member may have finished its work** (#1053 shape):
  before re-grinding, check whether its task branch was pushed — hand-verify
  (goal test + full suite + format) and merge is far cheaper than a re-run.
- **CI queue variance:** one PR's required checks sat queued ~6 hours.
  Distinguish "queued" from "running" before waiting on them. Admin-merging
  past the queue/flake was operator-authorized for THIS session only — get
  fresh authorization; it is not standing policy.
- **`kazi/integrate-*` PR debris:** runs on pre-#1037 binaries minted
  duplicate integrate branches/PRs. If any appear, close + delete branches;
  the real work is on the `task/*` PRs. Should not recur on ≥ v1.136.1.
- **Caller-drafts proposals:** use provider `custom_script`, never
  `test_runner` (deprecated, warns on every load).

## Loose ends intentionally left

- Issue #1019 (mixed-version read-model writers) is open by design — its
  structural fix IS ADR-0068/E52.
- Issues #1005 (fleet surface, verify-then-close after a clean fleet run
  post-#1053), #1025 (local-load flakes), #924 (vacuous grep predicates —
  owned by ADR-0064/E49) remain open, triaged 2026-07-10.
- The previous machine still runs a kazi daemon (vsn 1.138.0) and holds an
  active cross-session coordination doc for another project; neither needs
  anything from this repo's next session.
