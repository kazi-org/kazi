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

Shipped:

- **Issue #1687 — session-start bus flood fixed** (PR #1688, merged
  2026-08-12, seat-gated). `Board.render/2` drops `attention-*` from the
  `facts`/`total_facts` window entirely (roster-gated `attention` already
  covers it) and orders `facts` by recency; new `kazi bus prune
  <topic>|--prefix <prefix>` verb (`Kazi.Bus.retract/2`) for one-shot
  backlog cleanup. Live-bus backlog prune (`--prefix attention-`) still
  pending a deliberate operator run post-CLI-upgrade.

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

**Shipped (2026-09-05, `/apply --pool`, three dispatches this day):** T69.9
(#1681 `portfolio` in `Kazi.CLI.Schema`, PR #1740, `4b53f601` -> v1.277.0),
T69.10 (#1617 `--project` flag doc, PR #1741, `437f7845` -> v1.276.1),
T71.1 (#1709 branch-identity env for isolated predicates, PR #1742,
`71443c7e` -> v1.278.0), T72.1 (scope roots + glob overlap, E72 Wave A, PR
#1746, `52d15876` -> v1.279.0), T69.14 (#1636 self-conformance fixture cut
from 13-24s to under 1.2s by landing the mock integrator's merge as a direct
`git update-ref` instead of a clone+rebase+push dance, PR #1754,
`cd3fca1f`), T66.5 (#1483 reopened -- acceptance-pinning regression tests
for the already-landed bounded-mount fix, PR #1755, `fc14347d`). T70.11
dispositioned directly (no code): closed kazi-org/kazi#1692 citing
`lib/kazi/bus/claims.ex` + ADR-0067 point 6. Plan/reality drift fixed in PR
#1752: T69.9/T69.10/T71.1/T72.1 sat unticked after their own PRs merged;
release-version citations were corrected twice more after that (T69.9 and
T69.10 were first mislabeled v1.278.0, actually v1.277.0/v1.276.1) in PR
#1752's own follow-up commit. Every PR in this list was reviewed for actual
code correctness (red->green reproduction where applicable, symmetric
provider coverage, doc-vs-code match, or a direct read confirming the fix
it depends on already exists in `lib/`), not merged on green CI alone.

**Shipped (2026-09-05, T69.12 landed same day as claimed):** T69.12 (#1642,
ADR-0088, PR #1762, `37dd6a5e` -> v1.280.0). A declared `[setup]` goal-file
block (commands + a per-command `timeout_ms`, always bounded) runs once in
the workspace immediately before the t0 predicate observation, wired into
BOTH `Kazi.Runtime.run/2` and `check/2` since both share that observation --
a scope decision beyond the literal task wording, reviewed and confirmed
correct before merge. A failing setup step returns a distinct
`{:setup_failed, _}` environment error, never a predicate verdict, mirroring
the existing `{:startup_deadline_exceeded, _}` shape (#1683). Verified
independently before merging: read `lib/kazi/setup.ex` and its
`Kazi.Runtime` call sites directly (real `sh -c` execution, no stub), ran
`mix format --check-formatted` and the three new test files locally (25
passed, matching the PR's own report), and confirmed no attribution trailer
on any commit. Issue #1642 auto-closed on merge. This is the fix that
unblocks T73.1/T70.4/T73.5 for redispatch -- do so once the local `kazi`
binary is confirmed upgraded to v1.280.0 (`kazi version`), not before.

**Shipped (2026-09-05):** T69.13 (#1649, PR #1764, `d95960b4`; no version bump
-- test/docs/plan commits only). Finding first, fix second: the worktree's
`origin/main` already carried ~95% of this task -- `Kazi.TestSupport.BusPeer`
+ a 15-verb real-discovery sweep shipped via PR #1656 six weeks earlier
(2026-07-20), but that PR said "Refs #1649" instead of "Fixes", so the issue
never auto-closed and the 2026-08-08 triage authored this task against a
still-open issue for already-shipped work -- a process gap now logged in
`docs/devlog.md` with a "Fixes", not "Refs", recommendation for issue-closing
PRs going forward. What the PR actually added: `read`/`peek` (missed
originally -- they reach `with_conn/2` only indirectly through a private
`consume/2` helper) and `retract/2` (added after the original sweep, by
PR #1687) were genuinely missing from the audit's 15-verb list; all three are
now covered against both peer states. No new defect surfaced. Verified
independently before merging: confirmed PR #1656's "Refs" wording and merge
date directly, grepped `lib/kazi/bus.ex` to confirm `read/1`/`peek/1` really
do route through `consume/2`, and ran the audit test locally (38 passed,
matching the PR). Needed one rebase to resolve an adjacent-line conflict in
`docs/plans/E69.md` against T69.12's just-merged Done note; force-pushed with
lease, re-verified clean, re-ran CI green before merging. Local `kazi`
upgraded to v1.280.0 (checksum-verified release binary) so T69.12's `[setup]`
fix is actually available for the next `--parallel` dispatch, not just
merged-but-unpulled.

**Shipped (2026-09-05, fourth dispatch complete):** T70.9 (ADR-0085, PR #1767,
`b381adc1`; release pending as of this check). `[scope]` gains
`forbidden_paths` (enforced twice: the existing `deny` guard predicate,
generalized to accept either key, plus a real landing-time refusal --
unstage-before-commit on the legacy path, whole-landing refusal on the
verify-then-ship path since the inner agent already owns that commit),
`no_integration` (forces `[integration] mode: :none` AND a direct structural
check in `Kazi.Actions.Integrate.execute/2`), and `forbidden_commands`
(best-effort transcript scan, documented as a tripwire, not a sandbox).
Closes #1695 and #1704. A real gap was found and fixed beyond the ADR's
literal text: a bare `mode: :none` goal (what `no_integration` forces) still
routes through the legacy auto-landing path today, so mode alone does not
stop a PR from landing -- confirmed by tracing `verifies_then_ships?/1`
myself before merging, not taken on faith. Needed one rebase to resolve an
`AUTHORING.md` conflict against T69.12's own new section (both merged
cleanly); ran the full 285-test claim locally (matched) plus
`mix compile --warnings-as-errors` (only the two pre-existing unrelated
`lib/kazi/cli.ex` warnings, nothing new) before merging.

This closes out the fourth dispatch: T69.12, T69.13, T70.9 all shipped,
0 stranded PRs, all claims released, all worktrees cleaned up.

**In flight (2026-09-05, fifth dispatch -- the T69.12/T70.4/T73.5/T73.1
retry):** now that T69.12 shipped, retried the three tasks blocked on it
earlier today. Landmine found: T69.12 only adds the CAPABILITY for a
goal-file to declare `[setup]` -- it does not retroactively add one to a
goal already authored before the feature existed. T70.4's and T73.5's
banked goal-files had no `[setup]` block, so simply re-running
`kazi apply --parallel` against them would have hit the identical deps wall
again. Added `[setup] commands = ["mix deps.get"]` to both goal-files,
rebased both branches onto current main (they were several days stale),
re-verified `mix compile` clean, pushed, and redispatched both via
`kazi apply --parallel` with `KAZI_APPLY_STARTUP_TIMEOUT_MS=1500000` (both
still running as of this note). T73.1's approved proposal
(`prop-t73-1-scope-shared-paths-schema-ac7d9ff0999d`) lives in the
read-model, not an editable goal-file, and `--parallel`/serial apply both
derive a fresh isolated worktree from `--workspace` regardless -- there is
no way to inject a `[setup]` step into a stored proposal today. Dispatched
it instead as a direct agent in a manually-provisioned worktree (deps
fetched by hand before dispatch), the same proven pattern as the fourth
dispatch's T69.12/T70.9/T69.13, rather than through kazi's own grind loop.
Held dispatch to these three (no fourth lane) -- host load climbed to 6.4
with these three running; adding another risked the concurrent-`mix test`
contention #1751 already documented.

**Shipped (2026-09-05): T73.1** -- `[scope].shared_paths` schema field +
`Kazi.Fleet.effective_shared_paths/1` (ADR-0087 decision 4), PR #1771,
released as v1.282.0. Direct-agent dispatch (not through kazi's own runtime)
went 4-for-4 today: T69.12, T70.9, T69.13, T73.1 all shipped this way with
zero stranded PRs. Claim released, worktree removed.

**Incident (2026-09-05): T70.4's and T73.5's `kazi apply --parallel`
redispatches both permanently wedged**, unrelated to the `[setup]` fix --
both logged `bus call unavailable ({:timeout, 300}); degrading` around
12:53, then stayed at 0% CPU with zero output growth for 30+ minutes
(confirmed stuck, not slow: file sizes static across repeated checks,
`ps` showed sleeping beam.smp processes with ~8s total CPU time accumulated
over 25+ minutes). Root cause: the shared `run.kazi.bushost` daemon had been
crash-looping (`nats-server exited (status 1)`) for 10+ hours, because an
orphaned `nats-server` process (ppid 1, zero active connections, squatting
on port 4223 since 2:21am) blocked the daemon's own supervised `nats-server`
from binding -- exactly kazi-org/kazi#1684's already-documented mechanism.
Killed the orphan; the daemon's own nats-server bound immediately and the
crash loop stopped (confirmed stable). Posted corroborating evidence to
#1684 (still open) rather than filing a duplicate; #1719 (closed today,
13:36) fixes the SIGTERM-orphan mechanism going forward but doesn't
retroactively clean up an orphan from before that fix landed, which is
what this was. Also flagged on #1684: even after the daemon healed, both
wedged `kazi apply --parallel` processes never recovered on their own --
the bus-degrade path may not unwind cleanly once a call has already timed
out, a possibly separate bug worth a look. Killed both wedged processes and
redispatched T70.4 and T73.5 as direct agents (`apply-t70-4`, `apply-t73-5`)
in their existing (already `[setup]`-fixed, rebased, deps-installed)
worktrees -- in progress as of this note.

**Shipped (2026-09-05): T70.4** -- fixed #1699 (`Kazi.Runtime.ParentMonitor`
reaping an intentionally nohup/disown-detached launcher as dead). Root cause:
`Kazi.Harness.ChildSupervisor.alive?/1` conflated `kill -0`'s ESRCH ("no such
process") with EPERM ("operation not permitted") -- a launcher reparented to
init (PID 1, root-owned) after `nohup ... & disown` reads EPERM, not death.
Fixed at the shared `alive?/1` layer (ParentMonitor's default `:alive_fn`);
verified red->green (new test fails without the fix, passes with it) and no
#1073 regression (genuine-kill test unaffected). PR #1774. Claim released,
worktree removed. Direct-agent dispatch now 5-for-5 today.

**Shipped (2026-09-05): T73.5** -- `kazi apply` gains a single_node cap
(ADR-0086/ADR-0087) for a Sire dispatcher lane running one goal per
container: `--single-node` or `KAZI_SINGLE_NODE=1`/`"true"` refuses
`--fleet` before `Kazi.Fleet.load/1` and refuses a `--parallel` goal-set
that would partition into more than one partition before
`Kazi.Scheduler.run_goals/2`, both before any load/dispatch; a one-partition
run is unaffected and its `--json` result carries the additive
`"single_node": true`. Unset, behavior is byte-identical to today. PR #1777,
released as v1.283.0. Self-caught and fixed a doc-coherence guard regression
(`Kazi.TeachCoherenceReverseTest`, #973) along the way. Claim released,
worktree removed. Direct-agent dispatch now 6-for-6 today (T69.12, T70.9,
T69.13, T73.1, T70.4, T73.5) -- the fifth dispatch is fully closed out.

**In flight (2026-09-05, sixth dispatch):** three direct agents claimed and
dispatched off current main (`882c2a25`): T73.2 (symmetric `shared_paths`
exclusion, ADR-0087 decision 4), T72.2 (nesting lint, ADR-0086 decision 2),
T69.5 (kazi-org/kazi#1684's daemon nats-server crash-loop -- the exact
incident diagnosed live during the fifth dispatch, now getting a real fix:
adopt-or-reap on bind conflict, a distinct greppable error, and a
`restart_loop` flag in `daemon status`). Plan-checkbox lag for T73.1/T70.4/
T73.5 fixed same-day via PR #1780 (a third recurrence of the T69.2/T72.1
pattern).

**Shipped (2026-09-05): T72.2** -- `Kazi.Scope.nesting_conflicts/1` (reusable,
loader-agnostic pairwise scope-root nesting/equality check) plus a new
`kazi plan lint <roadmap-file>` subcommand that refuses (exit 1) when two
roadmap goals' declared scope roots nest or are equal, naming both goal ids
and the shared root. PR #1781, `3c58fc65`, released as v1.284.0.
CLI-shape judgment call: `plan lint <roadmap>` (mirrors `plan render
<roadmap>`, matches ADR-0086 decision 2's verbatim naming and this repo's
"roadmap=validate, fleet=execute" convention) over a `Kazi.Fleet`-style
dir/manifest input -- flagged for T72.4 to reconsider if the interactive
`--tree` adapter ends up needing dir/manifest input instead. `render --tree`
(T72.4) itself untouched; the check is built standalone so that task can call
it. Verified independently before merging: read the full diff, reran the 21
new tests locally (21/21), confirmed `mix format` clean and no attribution in
any of the 3 commits, and ran the full suite twice -- the agent's own claim of
a second pre-existing failure (`Kazi.Authoring.SessionAttributionTest`) did
NOT reproduce in isolation (that test manages its own
`CLAUDE_CODE_SESSION_ID` per-case and asserts nothing about it being absent);
the full-suite run's second failure was a one-off (passed clean on immediate
rerun via `mix test --failed`, unrelated to this PR's diff). Only
`Kazi.CLI.DaemonReregisterTest` (this machine's real launchd plist, already
flagged) reproduced consistently. Claim released, worktree removed.
Direct-agent dispatch, sixth dispatch's first task closed.

**Shipped (2026-09-05): T73.2** -- symmetric `shared_paths` exclusion
(ADR-0087 decision 4). `Kazi.Partition.partition/3` gains a `:shared_paths`
option, excluded from EACH goal's raw blast radius before
`group_overlapping/1` (order-independent, verified both ways); `Kazi.Fleet.load/1`
excludes the fleet's effective `shared_paths` symmetrically before the
inferred-overlap test, so two members overlapping only on a declared hotspot
get no edge while a genuinely shared path still does. New `lease_keys` field
on both `%Partition{}` and `Kazi.Fleet.Edge`, for T73.3/T73.4 to consume.
PR #1785, `88270062`, released as v1.285.0. Judgment call flagged by the
dispatched agent and accepted as-is pending T73.3/T73.4: a hotspot-only pair
gets no `Edge` at all (the point of the exclusion), so there's nowhere on an
edge to carry that pair's `lease_keys` -- populated only where an edge exists
for another reason; may need a per-node carrier once the real consumer shape
is known. Verified independently before merging: read the full diff, reran
both new test files locally (24/24), confirmed `mix format` clean and no
attribution across both commits. Claim released, worktree removed. Also
dispatched T72.3 (Node renderer, E72's critical path -- unblocked by T72.1,
unclaimed) as a fourth concurrent lane once host load dropped back to ~3;
still in progress.

**Shipped (2026-09-05): T69.5** -- fixed kazi-org/kazi#1684 (the daemon
nats-server bind-conflict crash loop, the exact incident diagnosed live
during the fifth dispatch). `Kazi.Daemon.Nats` now classifies every
unexpected nats-server exit BEHAVIORALLY (via `lsof`/`ps`, not stderr text)
into four dispositions: foreign (unrelated process, stays fatal), incompatible
(a nats-server with a different store dir, stays fatal), orphan (our store
dir, ppid 1 -- reaped and retried, bounded to 3 auto-reaps, no fatal stop),
peer (our store dir, live parent -- adopted via connect-mode instead of a
second writer against the same JetStream dir). A distinct greppable
`nats bind conflict: ...` log line on every conflict, plus a `:persistent_term`-backed
(crash-survives-itself) rolling 60s/3-exit restart-loop window surfaced as an
additive `nats_health` field on `ping`/`kazi daemon status --json` and a
`nats: ok` / `nats: RESTART LOOP -- ...` human line. #1719's shim/death-pact
mechanism untouched. PR #1786, `62a3e7f3`, released as v1.286.0, closes
kazi-org/kazi#1684 (auto-closed on merge). Verified independently: read the
full 948-line diff, reran the new `nats_bind_conflict_test.exs` (three REAL-
process scenarios: a foreign `:gen_tcp`-listening decoy, a genuine bare-
spawned orphan nats-server with only its ppid-1 fact injected via a test
seam, and a genuinely-unrelated `kill -9`) plus
`control_test.exs`/`daemon_test.exs` locally (26/26 passed, confirmed real
nats-server process output in the log, not mocked), checked `mix format`
clean and no attribution across all 6 commits.

**Shipped (2026-09-05): T72.3** -- Node renderer, `Kazi.Plan.Render.node/3`
(ADR-0086 decision 3): pure `(goal, scope root, observe result) -> string`.
Renders the ADR-0082 "GENERATED -- DO NOT HAND-EDIT" banner (exposed from a
previously-private `Kazi.Goal.Roadmap.Render` function, reused verbatim so
both generated views share one banner source), goal id/name/scope
root/brief, every VISIBLE predicate's definition, and currently-failing
predicates with evidence -- held-out predicates (ADR-0042 section 6)
excluded from both sections. No compile-time read-model dependency, enforced
by inspecting the compiled module's `:beam_lib` imports chunk (same
technique as `Kazi.Scenario.Pin`), with a sanity test proving the mechanism
catches a real violation. PR #1791, `14643bb2`. Verified independently: read
the full diff, reran the golden-file/byte-stability/purity tests locally
(26/26 passed combined with the roadmap-render and plan-render-CLI suites),
`mix format` clean, no attribution. Direct-agent dispatch, fourth concurrent
lane of the sixth dispatch. T72.4 (--tree adapter) is next on E72's critical
path, unblocked by T72.2 + T72.3.

**Landed (2026-09-05): E-KAZI-ENTRYPOINT plan.** hq ruled (dec-0849,
founder-direct) that governed lane containers should enter through `kazi
apply <goal> --single-node --in-place` rather than `claude -p` directly.
`docs/plans/E-KAZI-ENTRYPOINT.md` merged via PR #1784, `0135c6df` (docs-only):
8 kazi-side tasks (TKE.1-TKE.8, ~22h after chief-architect's ruling
simplified TKE.3/TKE.4) plus 6 named hq/sire-side dependencies (D1-D6) for
sire-planner to mint. chief-architect RULED both judgment calls the planning
agent flagged: (1) mode B everywhere -- kazi computes the integration action
and hands it to an injectable `--integration-command` hook; it never calls
`git push`/`gh pr create`/`gh api` itself and never holds a GitHub credential
in lane mode (this also fixed TKE.6: review comments arrive via a
`review_comments` field on the lane contract, not fetched by kazi); (2)
dec-0768 (gh-none in every container) stays as-is, no founder reopen needed.
Approved hq-side as epic E7 (T7.1-T7.6, D8-D13 in hq's own plan). While
scoping hq's lane-mode JSON surface, found and confirmed two things
chief-architect needed for E7: `kazi apply --help`'s human prose is stale --
13 of `apply`'s 31 real flags (including `--single-node`) are undocumented
there, a hand-maintained-heredog-vs-generated-table drift with no existing
CI guard for flags (only commands); filed
[kazi-org/kazi#1792](https://github.com/kazi-org/kazi/issues/1792). And
TKE.7's `job_outcome` field (done/blocked/checkpointed/refused) is NOT yet
shipped -- hq will not build an interim mapping and instead blocks T7.1/T7.3
on TKE.3 + TKE.7 landing first (no calendar cost: E7's own sequencing hold
already parks those rows). Confirmed for hq: a true `--in-place` run never
adds an `integration` key to the `--json` result (traced
`land_converged_serial/6`'s short-circuit) -- T7.3 must not wait on it.
Next: mint and dispatch TKE.3 and TKE.7 as the next kazi pool rows.

**Blocked -- infra, not code, needs founder input on one item (2026-09-05):**
T70.4 (#1699 nohup/disown vs. a genuinely dead launcher,
`Kazi.Runtime.ParentMonitor`) and T70.8 (#1700 -- document the vitest `-t`
predicate hazard) both failed a SECOND time even after raising
`KAZI_APPLY_STARTUP_TIMEOUT_MS` from 300s to 25 minutes -- the real limiter
is concurrent-lane host contention, not the timeout size: T70.4's log shows
`Exqlite.Error: database is locked` / `DBConnection.OwnershipError` inside
its own `mix test` run while 3+ other full-suite-compiling sessions ran on
the same host. Filed as an update on
[kazi-org/kazi#1751](https://github.com/kazi-org/kazi/issues/1751): likely
concurrent `mix test` invocations sharing one SQLite test-DB path rather
than each getting an isolated one -- a test-isolation gap, not something a
caller-side env var fixes. T70.8's worktree
(`/Volumes/BuildOffload/kazi-worktrees/t70-8`) has substantial uncommitted
progress (the vitest `-t` fixture project + a 28-line `install_skill.ex`
diff; missing only the pinning test itself) -- do not run a fresh
`kazi apply --in-place` against it without first confirming that state
survives. T70.4's worktree is clean (nothing was ever written). Claims
released on both; redispatch again only once host load is verified low, not
on a fixed schedule.

**Update 2026-09-05 (root cause reclassified -- disentangled from host
contention):** a third dispatch (T73.1, a T70.4 retry, T73.5) hit an
IDENTICAL failure with host load confirmed low and zero concurrent
`mix test` runs, ruling out contention as the sole cause. All three were
fresh worktrees with `_build`/`deps` absent -- this is
[kazi-org/kazi#1642](https://github.com/kazi-org/kazi/issues/1642) (DECIDED
2026-08-08, option 2: an explicit `[setup]` step in the goal-file, run
before t0), already tracked as T69.12 and previously unstarted. Every
mix-backed predicate in a fresh `--parallel` worktree is unconvergeable
until T69.12 lands; the SQLite-lock finding above is a real, separate
symptom of concurrent-lane contention, not the whole story. T69.12 claimed
and dispatched this session (worktree pre-provisioned with `mix deps.get`
to work around the very gap it fixes, since a `--parallel` dispatch would
hit the same wall trying to build its own fix). T73.1 found no salvageable
work (never reached a real observation) and its throwaway worktree/branch
were removed; T70.4's and T73.5's drafted goal-files were banked and pushed
(`task/t70-4-parent-monitor-nohup-disown`, `task/t73-5`) rather than lost.
All three claims released. Do not redispatch T73.1/T70.4/T73.5 via
`kazi apply --parallel` until T69.12 merges and releases.

T70.10 (#1702, DECIDED 2026-08-30 "remove entirely"): two independent
searches (a lane's own diligence, then an independent re-check of all git
history and branches) found zero trace of the described auto-generated
roadmap-note-PR behavior anywhere in this repo's tracked history. Posted
findings on the issue rather than closing it -- reversing a maintainer's
DECIDED call isn't a task lane's or pool orchestrator's call to make.
**Needs David's or the original decider's input**: confirm where the
behavior was actually observed, or close #1702 as not-reproducible and mark
T70.10 invalidated in `docs/plans/E70.md`. **Update 2026-09-05:** routed to
`chief` for founder-card queuing (this isn't resolvable by more technical
diligence -- it needs the original decider's memory of what was observed).
Queued in `dndungu/hq`'s `docs/FOUNDER-QUEUE.md` with a standing default: if
unanswered by the next founder sync, close #1702 as not-reproducible and
mark T70.10 invalidated, per that card-resolution policy. No action needed
here until either David answers or that default fires.

Found at t0: `test/kazi/cli/daemon_reregister_test.exs:43` fails on `main`
independently of any of the above (excluded from T69.9's suite guard; needs
its own triage). Filed [kazi-org/kazi#1744](https://github.com/kazi-org/kazi/issues/1744):
a kazi lane's grinder must not self-report status into `docs/roadmap.md` --
three separate lanes across two dispatches each committed a premature or
false "rebased green" claim into this shared paragraph; all were reverted
before merge (one required rebuilding the branch from its non-roadmap
commits after a rebase-merge failure the false commit caused). Rescued
(first pass): orphaned worktree branch `task/e50-safe-concurrent-work` (3
unmerged commits + a goal file) pushed to origin, worktree left in place for
its owner. Also swept: the fully-merged
`fix/1483-mission-control-unbounded-read` worktree (PR #1605) removed, and
the fully-merged `task/t66-5-mission-control-bounded-mount-test` worktree
removed after PR #1755 landed.

**Planned (2026-09-05, ADR-0086 -> E72, 8 tasks, 5 waves):** a
per-directory `AGENTS.md` node rendered from `goal.toml` + an observe pass,
never committed, so an agent opened inside a goal's scope root reads that
goal's brief and predicates through the harness walk-up, and a dispatched
lane gets the same node embedded in its existing prompt channel. `[scope].
write_paths` (fallback `paths`) is the declared scope -- no new field -- and
feeds the ADR-0065 §3 overlap rule, so disjoint roots is what "can run in
parallel" means. Tamper protection is freshness plus auto-added ADR-0085
`forbidden_paths`, never sealing a derived file. Reviewed by two
coordinating sessions before the ADR; the fleet-repo dispatcher half is
tracked in that repo. Shipped: PR #1731 (ADR-0086 + E72, rebase-merged
2026-09-05 at `22d92b2e`). Unstarted: all of E72. **ADR-0087 (shipped, PR
#1732, rebase-merged 2026-09-05 at `93f758a9`; implementing epic E73, 7 tasks,
4 waves, planned 2026-09-05 in PR #1737, rebase-merged at `c8fdc9b9`; T73.1 depends on E72 T72.1; the sibling scheduler repo's fleet-daemon row is amended to consume the export, Attempt-scoped shared-key leases in v1):** the scheduling boundary -- kazi plans (nodes, edges, `--dag`
export, per-node render), the fleet dispatcher schedules and executes one
goal per container with fleet and partitions off via a `single_node`
contract flag, the concurrency cap lives only in the dispatcher;
`[scope].shared_paths` hotspot lease keys (Attempt-scoped across containers
in v1) and `[scope].contract` + lint. Parent-converges-on-contract held
pending evidence. Reviewed by both coordinating sessions; the paired
sibling-repo row exists and is blocked on this ADR merging. Its
implementing epic is planned after merge.

**Near term (2026-09-02, from a full open-issue triage, third pass --
E71, 1 task):** the entire open backlog is now three triage epics deep
(E69, E70, E71) plus T25.10 (#382/#372) -- 34 issues total, every one with
a plan home. E71 covers the single issue that opened since E70's write
(#1709: a `custom_script` guard/held-out predicate resolving `git
rev-parse '@{u}'` or `--abbrev-ref HEAD` is structurally unsatisfiable
inside `Kazi.Enforcement.Isolation`'s always-detached checker worktree --
distinct from, and not fixed by, the scheduler-worktree branch-identity
fixes T54.1/T70.5 already landed). Also caught this pass: **T69.2 (#1683)
was actually DONE** -- fixed and released (PR #1710/#1711, v1.275.2,
2026-08-31) -- but its checkbox sat unticked in `plans/E69.md` for a full
day; refined the plan to match reality. **Correction (checked live via
`claim.sh list`, not assumed from checkboxes):** both P0 fronts ARE
claimed, not idle -- E69 Wave A (T69.1-T69.4) and all six of E70 Wave A
(T70.1/T70.2/T70.3/T70.5/T70.14/T70.15) were claimed together by one
`/loop pool` run starting 2026-08-31T06:01 UTC. Only T69.2 (#1683) has
landed a merged fix so far; the other 9 show no merged fix ~2 days in --
consistent with either continued grinding or a stalled/dead claim (claims
are not auto-released on completion; T66.7's claim from 2026-07-19, done
since 2026-07-20, is a confirmed-stale example). Do not re-dispatch
`/apply --pool` against those specific tasks without first checking
`claim.sh holder <task>` -- if no further merges land in the next few
days, treat the claim as dead and re-dispatch then. Separately, this same
pass ran the T31.2 deterministic plan trim for the first time in over a
month: 28 fully-done, release-covered epics archived out of the live WBS
(54 epic pointers -> 26; see `docs/plan.md`'s Archived epics section).
**Update 2026-09-03:** #1705 (T70.13, bus-hook opt-in gate) closed via PR
#1706 (ADR-0084), verified independently (`gh pr view`/`gh issue view`) --
the open backlog is now **33** issues, not 34 (E69: 12 open, E70: 15 open,
E71: 1 open, T25.10: #382/#372).

**Near term (2026-08-30, from a full open-issue triage, second pass --
E70, 16 tasks, 3 waves):** E69 below is still **0/14, unstarted 22 days
after being planned** -- neither triage epic's Wave A has been picked up.
E70 covers the 18 issues opened since E69 (#1690-#1708) that never had a
plan home, including two (#1707, #1708) that opened during this same
triage's own write window and were caught by a re-check, not missed;
combined, E69 + E70 were the entire open backlog at that time (32 real
issues; E71 above adds the 34th, #1709). Wave A
also now includes #1708 (`apply --parallel` with no `--workspace` against
a workspace-less goal CRASHES THE WHOLE OTP APPLICATION -- an uncaught
`FunctionClauseError` in the scheduler's partitioner, not a clean error)
and #1707a (`kazi integrate`'s generated PR title/body lists only the <!-- verb-drift:allow: forward reference to the #1707a deliverable, unbuilt at this line's writing -->
predicates that PASSED, silently omitting any that did not converge -- a
caller reading the PR alone has no signal that part of the goal's
acceptance criteria was dropped, the same lying-surface class as the rest
of Wave A). #1707b (swift_test/xcodebuild predicates cannot execute at all
under `--parallel`'s ephemeral worktree) rides Wave B. Wave A is a P0 false-verdict cluster on `--parallel`: #1694
(`match_count` predicates report `pass` on zero matches, defeating #1690's
own recommended fix), #1703 (a `HeartbeatTicker` crash coincides with a
false `converged` report on a zero-diff branch), #1696 (a real convergence
gets reported `stuck` against a synthetic `:workspace` predicate after the
ephemeral scheduler worktree vanishes out from under it), and #1698
(scheduler partition worktrees ignore `--workspace` and always land under
`$TMPDIR` -- confirmed root cause of a live 2026-08-29/30 fleet-wide
disk-pressure incident, internal disk under 500MB free with ~88 concurrent
sessions). Wave B: the #1699 launcher-liveness fix (a `nohup`/`disown`-
backgrounded run was being reaped as "launcher gone"), #1697 orphaned-
checkout reaping, a new `[scope]` goal-file block (ADR-0085) closing both
#1695 and #1704 -- the grind loop editing files/opening PRs an
orchestrating session explicitly excluded, only in prose it never saw --
and #1705 (gate the plugin's bundled session-bus hooks behind an opt-in
independent of plugin install). Wave C: a `kazi lint` feature for three
related predicate-authoring hazards (#1690/#1693/#1701, "a shell/regex
idiom for counting matches interacts badly with a runner default"), a
vitest predicate doc fix (#1700), removing the auto-generated
roadmap-note PR entirely (#1702, decided), and the plugin-marketplace
version-lag fix (#1691). #1692 (claim `transfer` verb) was REDIRECTED, not
built here -- kazi's own code says that primitive lives outside this repo
(ADR-0067 pt 6).

**Near term (2026-08-08, from a full open-issue triage -- E69, 14 tasks, 3
waves):** resolve the entire open backlog. Wave A is the P0 pair on v1.275.0
-- the `plan --replace` false green (#1679, apply converging against a
superseded predicate set) and the #1255-class apply startup wedge
(#1683/#1680), plus the watchdog false-diagnosis de-noise (#1662). Wave B is
daemon/dashboard reliability: the orphaned-nats-server crash-restart loop
(#1684), the dashboard accept-but-silent startup block (#1685), the
mount-query-scales-with-run-history residual (#1483), the
workspace-derivation contract (#1678), and the self-conformance fixture cost
(#1636). Wave C is surface + tests: the portfolio schema registration
(#1681), the `--project` flag-doc fix (#1617), the ACCEPTED post-disposition
hook (#1682), the DECIDED explicit goal-file setup step (#1642, ADR ~0084),
and real-discovery bus tests (#1649). #382/#372 close via T25.10 (E25).
**Update 2026-08-31:** #1683 fixed and released (PR #1710/#1711, v1.275.2)
-- the only E69/E70 task to land so far, and it landed outside a
dispatched wave against this epic.

**Near term (2026-07-17, from a full open-issue triage -- 7 new epics,
E56-E62):** doc/lore/ADR hygiene (E56); predicate correctness -- serial-apply
landing routing, guard/acceptance flag round-tripping, and a disambiguated
follow-up on the vacuous-convergence class E49 was meant to close (E57); bus
reliability -- the version-skew silent dead-letter bug and CLI
discoverability gaps (E58); concurrency/multi-process safety and a CI
flake-cluster root-cause pass (E59); fleet-wide visibility -- cross-machine
run posting, ghost-row reaping, an operator-attention board, and a
kazi-native portfolio view (E60); shipping kazi as a Claude Code plugin,
CI-generated and lockstep-versioned with releases (E61); and the gherkin
RUNTIME predicate provider Sire is waiting on, plus two deferred `--parallel`
landing follow-ups (E62). E55 (the board, digest, delivery hooks) is now
FULLY COMPLETE -- every task landed, closing the original symptom (*the
operator does not have to tell a session to check the bus*).

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
