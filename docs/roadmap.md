# kazi roadmap — where we came from, where we are, where we are going

A narrative view over the plan: the arc behind us, the work in flight, and the
horizon ahead. **This file is not authoritative** — [`docs/plan.md`](plan.md)
(+ `docs/plans/*.md`) is the checkable WBS, [`docs/adr/`](adr/README.md) holds
the decisions, and `CHANGELOG.md` records what shipped. This file exists so a
human (or a cold-starting session) can see the shape of the journey in one
screen instead of reconstructing it from 70+ ADRs and 50+ epics. E45
("plan-as-generated-view") may eventually generate a view like this from plan
data; until then it is hand-maintained under the contract at the bottom.

Last updated: **2026-07-17** (at v1.153.0, ADRs through 0073, E55 wave A
SHIPPED -- 7 tasks merged and released; waves B-D next).

## Where we came from

kazi began as a bet (ADR-0001/0002): coding agents don't need a better harness,
they need an **outer loop** — declare a goal as machine-checkable predicates and
reconcile the codebase against them until they are objectively true, stuck, or
over budget. Everything since has been that bet deepening, in roughly six
phases:

1. **Walking skeleton, idea → production (Slices 0-2).** The reconcile loop,
   goal-files, the predicate engine, `kazi init` adoption, binary distribution
   via Burrito + Homebrew, the public website, and the first dogfoods — kazi
   converging goals a prose pipeline left subtly broken. (Archived epics
   E12-E18, E24; ADRs 0001-0025.)
2. **Agent-drivable kazi.** The `--json` versioned result contract, the skill
   router (plan/apply/status/adopt), `run`/`propose` renamed to `apply`/`plan`,
   MCP server, machine-readable help/schema — kazi as a tool an orchestrating
   agent drives, which became the primary paradigm on every surface. (E15, E16,
   E26, E27, E33; ADRs 0023/0024/0031/0032/0044.)
3. **The verification workhorse.** `custom_script` as the single command-runner,
   graded ratchet predicates with structured evidence, static/coverage/property/
   mutation/CVE providers, enforcement (read-only paths, skipped-as-failed) so
   objective-done resists a grinding model. (E32; ADRs 0040-0043.)
4. **kazi owns parallelization.** The native scheduler partitions a goal-set by
   blast radius, leases partitions, executes dependency-aware predicate-graph
   waves; serial apply became the 1-partition degenerate case; fleets run DAGs
   of goal-files over reused worktrees. (E21, E23, E50; ADRs 0027/0028/0065.)
5. **Observability + economy.** The run registry, `kazi dashboard`, Mission
   Control card grid, the event river; persisted run economics, cached-vs-fresh
   token accounting, learned budgets, context-store evidence compression.
   (E34, E35, E46, E47, E48; ADRs 0046/0057/0058/0069/0070.)
6. **Self-maintenance + hygiene.** Docs land with code and no-internal-leak as
   CI gates; the plan trims itself losslessly; doc freshness runs as a kazi
   standing goal — kazi maintaining its own repo is the flagship dogfood.
   (E28-E31; ADRs 0034/0036.)

Along the way the coordination substrate ADR-0004 reserved on paper came alive:
`kazi daemon` + the session bus (E51, ADR-0067) gave concurrent operator
sessions presence, facts, and directed messages over JetStream — live across
machines on the released binary. 150 releases to date (v1.150.0); ~29 epics
fully done or archived; 73 ADRs.

## Where we are (2026-07-16)

**The current theme is teamwork.** The bus works as infrastructure and failed
as a product: delivery was never installed (the ADR-0067 hook recipe's observed
install rate was zero), the digest protected the human TTY while `--json`/MCP —
the paths agents actually read — got the full transcript, and teams needed
current *state* (roster, ownership, facts) where the bus offered only a stream.
Two teams independently rebuilt file blackboards and left. ADRs **0071-0073**
(accepted 2026-07-16) decide the fixes; **E55** (13 tasks, 4 waves) builds
them; same-day field feedback from a five-session, two-machine fleet
independently confirmed the diagnosis and added supervisor-grade gaps
(idle-vs-dead presence, directed-message delivery visibility, wake semantics).

Landed 2026-07-17 (v1.151.0-v1.153.0): **E55 wave A** — the digest render
bound on every machine path (T55.1), the opt-in hook installer with a
`kazi bus hook` entry point (T55.2), the dashboard's live roster (T55.3),
stable session identity + tell-by-name (T55.5), presence liveness with
ghost-row reaping (T55.11), the watch now-anchor fix (T54.9), and the
distribution stdout-purity pin (T54.10, fork fix merged upstream). The wave's
verification gate confirmed and fixed four cross-task union-merge bugs before
merge — the empirical case for gate-then-merge.

In flight right now:

- **E55 wave B/C** — unblocked and claimable: the board (T55.4), deliberate
  pull (T55.6), daemon-side digest (T55.7), delivery visibility (T55.12), and
  the wake-contract doc (T55.13, now that T54.9 landed).
- **E54** — reliability hardening II: the remaining execution-sweep bugs
  (partition branch lifecycle, budget-burn guards, `--json` locale).
- **E51 tail** — T51.5: runs mirror lifecycle + per-iteration progress facts
  onto the bus so a supervisor can watch a long convergence without tailing
  JSONL.

Open but quieter: E40/E41 (behavior specs + product use-case catalog), E42
(self-teaching artifact fixes), E43 (browser assertion pack), E44 (landing as
part of convergence), E45 (one-system planning), E49 (scenario pins), E52
(daemon single-writer read-model), E37 (Gemini harness profile), and residual
single tasks on E20/E25/E39.

## Where we are going

**Near term (E55 waves B-D):** the board — current facts + roster + claim
ownership read at source from `refs/claims/*` (T55.4/T55.8); deliberate pull
for oversized messages (T55.6); digest assembly server-side in the daemon
(T55.7); the hook payload that injects the board at session start and a
bounded digest at turn boundaries, silent when quiet (T55.9); delivery
visibility for directed messages (T55.12); the documented wake contract for
idle workers (T55.13); closed by a cross-machine dogfood measured against the
original symptom — *the operator does not have to tell a session to check the
bus* (T55.10).

**Mid term (open epics by pull):**
- *Verification climbs the ladder of intent:* browser assertion packs (E43),
  landing/integration as convergence (E44), capability-level scenario pins
  that demonstrate-then-pin (E49), behavior specs as the reviewable tier above
  predicates (E40/E41).
- *One system:* roadmap-scope planning and plan-as-generated-view (E45) — the
  direction in which this hand-written file gets replaced by a projection.
- *Platform depth:* the daemon as single writer for the read-model (E52), more
  harness profiles (E37), self-teaching cleanups (E42).

**Horizon (watch items, decided-not-scheduled):**
- **Bus high availability** — deferred deliberately: history survives daemon
  restarts (file-backed JetStream), convergence never depends on the bus
  (ADR-0067 pt 1); an HA coordination plane becomes an ADR when a fleet
  outgrows two machines.
- **Harness-native agent teams** — today they cover only the intra-session
  shape (one lead, one machine, spawned teammates); if the harness extends
  teams across sessions/machines, kazi's delivery profile should ride the
  native mechanism rather than compete (see E55's watch item; ADR-0001).
- **v2.0.0 removals** — the deprecated `test_runner`/`prod_log` provider names
  fold fully into `custom_script` (`docs/deprecations.md`).

## Maintenance contract

This file is updated by whichever session performs the triggering event — in
the same PR when practical:

| Trigger | Update |
|---|---|
| An epic opens or fully closes | move it between sections; refresh "in flight" |
| An ADR is accepted that changes direction | reflect it under the matching horizon/phase |
| A release ships a theme milestone | refresh the "Last updated" line + counts |
| A wave of the current theme completes | refresh "Where we are" |

Keep it one screen per section; push detail down into `plan.md`, the epic
files, and ADRs rather than growing this file. Counts and epic states are
derivable from `parse_plan.py` (`.claude/scratch/parsed-plan.json`) — regenerate
them rather than trusting memory. This file must stay leak-clean (ADR-0034): no
internal hosts, paths, or fleet/session names, ever.
