# kazi devlog

Session findings, dogfood results, and benchmarks. Append-only; newest entries
at the top. For invariants/landmines see `docs/lore.md`; for decisions see
`docs/adr/`. This file is part of kazi memory's corpus (`docs/memory.md` --
see "Boundary: kazi memory vs. Claude Code memory vs. docs/lore.md /
docs/devlog.md"): entries here are recalled at dispatch time (ADR-0062) and
new ones can be proposed here by harvest (ADR-0063).

## 2026-07-18 — T52.9: two versions, one daemon, never blind — E52 exit-criteria live dogfood (ADR-0068)

**Type:** dogfood / live verification
**Tags:** E52, T52.9, ADR-0068, daemon, single-writer, run-registry, schema-skew, release-binary, #1019

**What.** Ran the E52 exit-criteria dogfood: stood up one daemon as the single
writer for the read-model and drove writes from two kazi versions through it,
then exercised the schema-skew handshake and the no-daemon fallback. All four
ADR-0068 exit assertions were observed to hold; the shortfalls are recorded
honestly below.

**Binary flavors (release-availability reality, per the T52.9 outcome (b)).**
The newest release at run time, **v1.235.0** (tagged 33s after PR #1461/T52.8
merged), DOES contain the full E52 write path by git ancestry — but it shipped
with **zero downloadable assets** (GoReleaser produced none at cut time), so the
"new" side could not be a released binary. Every asset-bearing release
(v1.228.0 … v1.234.0) and `main` carry an **identical migration set** (through
`20260718120000_create_run_landed_refs`), so there is **no natural schema skew
between released binaries** — the ADR-0068 premise that an older release carries
fewer migrations did not hold here. Flavors actually used:
- **new** = locally-built `MIX_ENV=prod mix release` from `main` @ `ece8142e`
  (reports vsn 1.234.0 from mix.exs but carries the full E52 set incl. the
  T52.7/T52.8 *client-side* skew checks). Driven via the release `bin/kazi eval`.
- **old** = the released **v1.234.0** `macos_x86_64` burrito asset (has the
  routed write path through T52.7; predates T52.8's client-newer check).
- The locally-installed `kazi` on `$PATH` is **1.228.0**, which predates the
  daemon write op (T52.3) entirely — it cannot be the single writer. The dogfood
  therefore ran against a from-source prod release, not the `$PATH` install.

Isolation: throwaway `KAZI_STATE_DIR` (short path — macOS caps the Unix-socket
`sun_path` at ~104 bytes; the first scratch path `:einval`'d the listener),
`KAZI_DB`, and `--nats-port 14223` (never the default). The real per-machine
daemon was never touched.

**Observed, per exit assertion.**
1. **Two versions, one daemon, no deadlock.** The new release wrote RunRegistry
   rows through the daemon socket (probe `:alive`), and the released **v1.234.0**
   binary — a genuinely different build — registered its own run
   (`session_name=v234-oldclient`, via a real `apply`) through the SAME daemon.
   The daemon stayed responsive throughout (same pid, uptime climbing; `status
   --json` answered after the concurrent writes). Final single-writer DB held
   all 3 runs from both versions. No hang, no deadlock.
2. **Duplicate-run guard + economics correct through the one writer.** The
   dup-guard live lookup (`RunRegistry.list_by_goal_ref` + liveness filter) saw
   exactly **1 live row** for the shared goal_ref while a run was open — a second
   same-goal `apply` would be refused. `finish/3` persisted economics through
   the socket: `budget_cost_usd`, `budget_tokens`, `dispatch_count` all landed.
   **Single-writer routing proven directly:** with the client's local `KAZI_DB`
   pointed at a *different empty file* while it still probed the daemon's socket,
   an insert landed in the **daemon's** DB and was **absent** from the client's
   local file — the write provably crossed the socket to the single writer.
3. **Deliberately-older client hits the explicit skew handshake, not a blind
   run.** Both directions of `SchemaSkew.classify/2`, constructed by stamping
   `kazi_schema_meta` (since released binaries share a schema):
   - *client-newer / daemon-older (T52.8):* the daemon's `status` ping reported
     `schema_vsn 20260709210000` (below the client's `20260718120000`); the new
     client emitted the exact single line *"daemon is older than this client
     (schema v20260709210000 < v20260718120000); restart it (`kazi daemon
     restart`) or continue without persistence"*, returned
     `{:error, :read_model_unavailable}`, and **wrote no row**.
   - *client-older / no-daemon (T52.7):* against a file stamped
     `20260801000000` (newer than the binary), the direct write refused with
     *"read-model schema v20260801000000 is newer than this binary
     (v20260718120000); running without persistence -- upgrade kazi"*, and
     **wrote no row**. Both are visible degrades; the run continues, never a
     silent blind write.
4. **Daemon-down degrades to today's direct-write semantics, byte-for-byte.**
   With the daemon stopped and the file stamped to the binary's own schema, the
   full `start` → `finish` lifecycle persisted **direct** (status converged,
   economics present) — the pre-E52 `Repo` path, unchanged.

**Verdict on the ADR-0068 exit criteria: MET**, with the honest caveats below.
Two versions ran through one daemon with zero deadlocks; the duplicate-run guard
and economics stayed correct through the single writer; every skew case surfaced
the explicit operator choice instead of a blind run; and rollback to no-daemon
preserved today's direct-write semantics.

**Honest gaps / deviations.**
- **New side is a from-source prod release, not a published asset** — v1.235.0
  carries the code but shipped no downloadable binaries, so a true
  released-binary-vs-released-binary run of the *full* E52 path was not possible.
  Recorded per the task's sanctioned outcome (b).
- **No natural migration skew between released binaries.** All asset-bearing
  releases and `main` share the same migration set, so `run_landed_refs` was
  already released — contra the task brief. Both skew directions were therefore
  **constructed** by stamping `kazi_schema_meta`, not by pointing two
  differently-migrated binaries at one file.
- **The skew handshake is only observable with the NEW binary as the newer
  party.** An actually-older released client (v1.228.0/v1.234.0) has no T52.8
  client-newer check, so old-client-vs-new-daemon writes through per the
  additive-within-major design — exactly as the brief anticipated. The
  "deliberately-older client" in assertion 3 is thus the new binary judged
  against an older-*stamped* daemon/file, which is the only construction the
  available binaries permit.
- **RunRegistry rows were driven via the release `bin/kazi eval` calling
  `RunRegistry.start/finish` directly** (the exact production Writer→socket
  path), plus one real `apply` on the v1.234.0 binary to prove a second genuine
  build writes through the same daemon. A full harness-driven convergence on
  both binaries was not run (no need — the load-bearing surface is the write
  path and the guard, both exercised end-to-end).

## 2026-07-18 — T62.3: Sire's `storage-store.feature` reconciles natively through the `gherkin` provider — live godog proof, per-scenario verdicts, broken-scenario isolation

**Type:** dogfood / live verification
**Tags:** gherkin, provider, ADR-0071, T62.3, #1107, release-binary, godog, cucumber

**What.** Wired the Sire project's (sire.run) executable storage-port contract
`storage-store.feature` (4 Scenarios, real SQLite store) as the live acceptance
fixture for the runtime `gherkin` provider (ADR-0071), and proved it reconciles
NATIVELY: `kazi apply --check --json` returns one verdict PER Scenario, not one
opaque feature-level result. Fixture committed under `priv/examples/gherkin/`.

**Live godog run (observed).** Sire's own runner (`scripts/storage-contract.sh`
-> `go test ./storage/`) hardcodes godog `Format: "pretty"`, so it emits an
opaque package pass/fail — no cucumber-json. To get REAL per-scenario
cucumber-json without modifying the (strictly read-only) Sire repo, I ran godog
via `go test -overlay` (go1.26.4): the overlay adds one scratch-dir test file
that reuses Sire's REAL `contractWorld` step bindings and real store, changing
only `Format` to `"cucumber"`. Nothing was written into the Sire repo. Driving
the goal-file with `runner_args` pointing at that live godog invocation, the
release binary `kazi` reconciled all 4 scenarios to `pass`:

```
storage-store-migrator__a-conflicting-transaction-rolls-back            -> pass
storage-store-migrator__a-dirty-migration-state-blocks-further-migration -> pass
storage-store-migrator__migrations-apply-up-and-roll-back-down          -> pass
storage-store-migrator__values-round-trip-through-a-committed-transaction -> pass
```

**Edge case 3 (verbatim names) — CONFIRMED, no T62.2 gap.** godog's
`--format=cucumber` reports the Feature name `"storage Store + Migrator"` and
each Scenario name (`"a conflicting transaction rolls back"`, …) EXACTLY as the
`.feature` text — matching the provider's verbatim `config[:scenario]` lookup
(ADR-0071 assumption). No keyword prefix, no outline-row renaming for a plain
Scenario. Nothing to fix.

**Broken-scenario isolation — CONFIRMED.** Flipping ONE scenario's step to
`"failed"` in a captured report reds only that scenario's sub-predicate; the
other three stay `pass` (overall `fail`). Per-scenario granularity is real, not
cosmetic.

**Release-binary atom-safety — CONFIRMED (and a stale-binary trap hit).** The
goal loaded and evaluated identically under `mix` (source) and the release
binary (no `String.to_atom/1` on report content; L-0041). Trap: the `kazi` on
`$PATH` was a directly-installed 1.221.0 file shadowing Homebrew's 1.222.0 (whose
symlink couldn't overwrite the real file); against 1.221.0 every verdict was
`unknown` (that build predates T62.2's ingestion). Upgrading the on-PATH binary
to 1.222.0 turned all four green — exactly the CLAUDE.md landmine: verify
`kazi version` matches the newest release, don't trust `brew upgrade` alone.

**What CI keeps.** `test/kazi/goal/gherkin_sire_fixture_test.exs` replays the
CAPTURED real godog cucumber-json (`storage-store.cucumber.json`) through the
loader + provider — 3 tests, green without a Go toolchain. The live godog run is
this devlog entry.

## 2026-07-17 — T57.3: re-verified #924's vacuous convergence against shipped E49 scenario predicates — the failure class is closed for goals that adopt them

**Type:** verification
**Tags:** predicate, scenario, vacuous-convergence, T57.3, #924, #1128, ADR-0064

**What #924 was.** A UI+backend+integration feature (onboarding coach
integration) terminated `converged` with every predicate passing while the
feature was largely unbuilt. The acceptance predicates were `custom_script`
greps (`grep -rqiE 'onboarding' internal/ai && go build && go test`). Two
failure modes: (1) string-stuffing — a new headline spliced into old markup
passed a copy grep though the redesigned screen never shipped; (2) vacuous match
— `grep 'onboarding'` matched only an unrelated pre-existing comment ("there is
no onboarding or Settings surface yet"); the real coach-context integration was
never built and nothing ever called the backend. `build`/`test` passed because
existing tests never covered the new behavior. The gate was: keep #924 open
until E49 Wave A (scenario predicates) shipped and the class was reproducible.
E49 is now fully shipped (ADR-0064; `docs/plans/E49.md` — all tasks `[x]` except
the `Owner: TBD` live dogfood T49.13), so that gate has passed.

**What I did.** Built a reproduction that re-authors the SAME capability two
ways and runs both through the genuine providers (no browser, no network — the
browser surface is stubbed by the shipped `test/support/stub_playwright.sh`,
exactly as `scenario_test.exs` does):
`test/kazi/regression/vacuous_convergence_scenario_test.exs`.

- **Raw `custom_script` grep (the #924 shape) still vacuously PASSES.** The
  workspace has `internal/ai/context.go` whose only "onboarding" occurrence is an
  unrelated comment (failure mode 2, verbatim in shape). `grep -rqiE 'onboarding'
  internal/ai` exits 0 → `:pass`. No real work behind it. Reproduced.
- **The same capability as a `scenario` predicate does NOT pass vacuously.**
  Authored as a tagged Gherkin Scenario bound to a pin (ADR-0064):
  - Unbuilt feature → no committed pin → classifies `:unpinned` → `:fail`
    (`pin_state: :unpinned`). There is no string to stuff and no comment to match.
  - Even a fabricated, well-formed pin (correct scenario hash, valid trace) can
    only pass by replaying green through the surface provider. The unbuilt UI
    yields a RED surface verdict → `:fail`. This is the ADR-0064 truth invariant
    a grep structurally cannot enforce.
  - Positive control: with the surface actually demonstrating the behavior
    (green stub verdict) the predicate `:pass`es (`pin_state: :pinned`). Pass is
    reachable — but its truth-maker is the surface observation, never a string.

**Result — closed, for goals that adopt scenario predicates.** By construction a
scenario predicate's pass is gated on a validated pin replaying green through a
real surface provider; string presence in unrelated content cannot satisfy it.
Both of #924's failure modes are string-match artifacts, so both are eliminated
the moment the capability is stated as a scenario predicate rather than a grep.

**What was and wasn't exercised.** Exercised: the real `CustomScript` System.cmd
path and the real `Scenario` classify → resolve → delegate → extend path, with
the browser surface stubbed at the subprocess seam. NOT exercised: a live
browser, a real end-to-end `kazi apply` loop, or the demonstrator dispatch that
mints pins (T49.4+) — this verification is about the evaluation-time truth
invariant, which is where #924's gap lived, not about pin authoring.

**The residual gap (feeds #1128).** Scenario predicates close the class only for
goals that CHOOSE to use them. A goal that stays on raw `custom_script`/`grep`
predicates is still exactly as vulnerable as #924 — the mechanism is opt-in, not
a controller-level guard-rail over all goals. That remaining case is what #1128
is really about; recommendation posted there (narrow #1128 to the
non-scenario-goal guard-rail rather than close it, and do NOT build its `kind`
field speculatively). #924 itself is left OPEN for the human to close alongside
the #1128 disposition, since the two are coupled.

## 2026-07-17 — T58.1: root-caused the bus read/write version-skew asymmetry (#1227) — writes bypass the daemon's op dispatch entirely, reads don't

**Type:** investigation
**Tags:** bus, daemon, control-socket, version-skew, T58.1, #1227

**Symptom.** A long-running bus daemon (started under an older kazi) kept
accepting `bus join`/`who`/`tell` from a newer CLI (1.172.0) — `who` showed
the session with a nonzero inbox count, senders got a successful `told
<name>` ack — but `bus read`/`bus read --peek` from that same newer CLI
failed with `error: daemon could not read the bus: unknown_op`. Net effect: a
silent dead-letter queue where senders believe delivery succeeded but the
recipient can never read any of it.

**Root cause.** The asymmetry is structural, not incidental:

- `join`/`who`/`tell` never touch the daemon's Elixir op-dispatch code at
  all. They connect directly to NATS and publish/subscribe
  (`lib/kazi/bus.ex` `tell/3` calls `with_conn` → `Gnat.pub`/`Gnat.request`
  straight to a `bus.<scope>.msg.<target>` subject). The daemon process is
  only a NATS *host* for these ops — its own code version is irrelevant to
  whether they succeed.
- `read` is different: `Kazi.Bus.read_digest/1` → `read_assembled/1` sends
  `%{"op" => "read", ...}` over the daemon's **control socket**
  (`Probe.request/3`), which is dispatched by
  `Kazi.Daemon.Control.handle/2` (`lib/kazi/daemon/control.ex`). That
  module's moduledoc confirms `read` is a T55.7/ADR-0072-d5 addition —
  added *after* the NATS-direct write paths were already stable. An older
  running daemon binary has no `handle(%{"op" => "read"}, ...)` clause
  compiled in, so it falls through to the catch-all
  `handle(_other, _opts), do: %{"ok" => false, "error" => "unknown_op"}`
  (`control.ex:51`) — a clean, well-formed reply, not a crash, which is why
  it reads as a normal (if confusing) error rather than an obvious
  version-mismatch signal.

So: writes are op-dispatch-version-blind by construction (they never call
into daemon code that could be stale); reads require the daemon's control
protocol to have kept pace. Any control-socket op added after `ping` is added
to this same class of latent skew — `read` is just the first one anyone hit.

**Fix direction for T58.2.** CLI-side proactive skew detection at connect
time, not a daemon-side reject-loud change: `Kazi.Daemon.Control.handle(%{"op"
=> "ping"}, ...)` already returns `"vsn"` (`control.ex:29-37`), and
`Kazi.Bus.read_assembled/1` already calls `Probe.probe/1` (an aliveness
check) before issuing the `read` request — the natural seam is to compare
that `vsn` against the CLI's own compiled version at connect (or immediately
before the first control-socket op past `ping`) and surface a clear "daemon
is running an older version, restart it" error *before* attempting `read`,
rather than let the daemon's generic `unknown_op` stand in for "you're
skewed." A daemon-side reject-loud change is not the right shape here: the
daemon literally cannot know it's missing an op it was never compiled with,
so the detection has to happen where both versions are visible — the CLI,
which already has `vsn()` and just received the daemon's via `ping`.

**Coordinate with E52.** T52.2 is already adding a `schema_vsn` field to the
same `ping` reply for the read-model write-seam skew check
(`SchemaSkew.classify/2`). T58.2 should EXTEND that handshake with a
bus-protocol version check alongside `schema_vsn` rather than invent a
second, parallel version-negotiation mechanism on the same daemon reply —
two independent skew checks with different semantics on one `ping` op is
itself a future #1227-class bug.

## 2026-07-17 — T60.2 finding: ghost `running` rows (#1155) — the T48.15 reaper can only abandon dead-pid runs, so no-os_pid and recycled-pid ghosts live forever

**Type:** investigation + fix
**Tags:** read-model, run-registry, reaper, sqlite, T60.2, #1155

**Symptom.** Runs permanently stuck at `status='running'` (26 ghost rows on one
machine, 9-day-stale heartbeat, zero live kazi processes; 1 on another). An
`abandoned` terminal status already exists and finalizes *some* rows (15/3 on the
two machines), so a finalizer path exists but misses these.

**Root cause.** `Kazi.ReadModel.RunReaper.reap/0` reaped a stale `running` row to
`abandoned` only when the row (a) had recorded an `os_pid` AND (b) that OS process
no longer existed (`kill -0` fails). Two ghost shapes slip through this filter
forever:

1. **No `os_pid`.** The reaper's `has_os_pid?` guard drops any row that never
   recorded a pid — a run that crashed before `RunRegistry.record_harness_pid/2`,
   or a row predating the field. This is the dominant cause of the observed
   ghosts: there is no process to probe, so the reaper skipped them entirely.
2. **Recycled `os_pid`.** A recorded pid the OS later reassigned to an unrelated,
   now-live process reads as "alive" via `kill -0`, so `process_alive?` returns
   true and the row is never reaped — a false-positive no liveness probe can catch.

The reaper was a *liveness* reaper only; it had no *time* backstop, so any row
whose liveness could not be truthfully probed sat at `running` indefinitely.

**Fix (T60.2).** `reap/1` now abandons a stale `running` row on any of three
signals: dead recorded pid (unchanged fast path); **no recorded pid** (liveness
unverifiable → abandon once stale); or **heartbeat older than
`abandon_after_seconds`** (default 24h) regardless of the pid probe (guards
against recycling). The 24h backstop sits far above any legitimate heartbeat gap,
so a genuinely-live run (fresh heartbeat, or a live pid within the window) is
never touched. The `RunReaperTicker` (5-min interval) already drives it. Pinned
by `test/kazi/read_model/run_reap_test.exs` (no-pid ghost, recycled-pid backstop,
fresh-heartbeat never-reaped, and a fixture-shape sweep leaving zero stale
`running` rows).

## 2026-07-17 — T60.6 finding: run-sink retention was NEVER WIRED (not wired-but-broken)

**Verdict: never-wired.** #1155's secondary finding (run-sink dirs far past any
plausible cap — 9,731 dirs on one machine, 35,570 dirs / 224 MB on another)
traces to the retention pass simply never being invoked, not to a broken or
too-generous cap.

**Evidence.** `Kazi.Sink.Events.sweep/2` — the age/size retention pass that drops
a run's entire `<sinks_dir>/<run_id>/` directory once aged past
`default_max_age_seconds` (7 days) or sized past `default_max_bytes` (200 MB),
while never touching a caller-supplied live run — is fully implemented and
unit-tested (`test/kazi/sink/events_sink_test.exs`). But a tree-wide grep for
callers found ZERO: every use of `Kazi.Sink.Events` in `lib/` is `.append/3`
(the write path, `runtime.ex:1036/1346`) or `.read/1` (event river, mission
control). Nothing ever called `.sweep/2`. So no sink directory was ever
reclaimed — exactly the unbounded growth #1155 measured.

**Same class as T48.15.** This is a carbon copy of the zombie-run-row bug:
`RunReaper.reap/0` shipped correct and tested but nothing called it until
`RunReaperTicker` was added to the supervision tree. `RunReaperTicker`'s own
moduledoc names the pattern. The sink retention had the identical gap.

**Fix.** New `Kazi.Sink.RetentionTicker` (sibling of `RunReaperTicker`), added to
`Kazi.Application`'s children: a supervised periodic GenServer (1 h default) that
calls `Events.sweep/2` with `live_run_ids` from `RunRegistry.list_live/0`.
Best-effort — a registry-read failure SKIPS the sweep (never risks deleting a
live run's dir), and any sweep error is logged, never raised into a run. The cap
VALUES were deliberately left untouched (the mechanism was the defect, not the
threshold); tuning them, if ever needed, is a separate change once the sweep is
observed reclaiming real sinks on a live machine.

## 2026-07-17 — T59.4 finding: #1025 and #1186 are NOT one root cause — five distinct contended resources; T59.5 must be five fixes, not a blanket timeout bump

**Type:** investigation
**Tags:** flaky-tests, test-isolation, ci, exunit, sqlite-sandbox, T59.4, #1025, #1186

**Task (acc = the finding, not the fix).** For every distinct flaky test named
across #1025 and #1186, determine whether its failure mode traces to the SAME
contended resource or a genuinely distinct one, and state whether the T59.5 fix
should be one change or several. Primary source: the two GitHub issue threads
(read in full, incl. #1186's 4 comments) plus the actual test source at HEAD
(`origin/main` @ c864897). Not a fix task — no test was changed.

**Verdict.** One shared THEME, five distinct root causes. The theme is real and
worth stating as a rule: *an `async: true` test (or an improperly-isolated
`async: false` one) must not assert on state the rest of the concurrently-running
suite shares.* But that theme decomposes into FIVE different contended resources,
each needing a different fix mechanism. There is no single defect and no single
fix. In particular, a blanket `assert_receive` timeout bump addresses only Class 1
and would leave the other four classes flaking. **T59.5 should be five
independently-landable sub-fixes, grouped by class.** (#1186's own author already
reached "two distinct isolation failures, worth splitting"; this generalizes the
split across both issues to five.)

**The nine distinct tests, classified by contended resource.**

| # | Test (file:line) | async | Asserts on | Class |
|---|---|---|---|---|
| 1 | `Kazi.Loop.WorkspacePrepTest` (`workspace_prep_test.exs:98`) | true | `assert_receive {:dispatched,true,true}, 1_000` | **1 wall-clock deadline** |
| 2 | `Kazi.EnforcementTest` (`enforcement_test.exs:419`) | true | `Loop.await(loop, 5_000)` | **1 wall-clock deadline** |
| 3 | `Kazi.Loop.ContextStoreTest` (`context_store_test.exs:75`) | true | `assert_receive {:dispatched,prompt}, 2_000` | **1 wall-clock deadline** (+ 5b secondary) |
| 4 | `Kazi.Scheduler.FrontierCompleteEventTest` (`frontier_complete_event_test.exs:51`) | true | `refute_received {:dispatched,"c",_}` — a negative at ONE instant | **2 instant-negative race** |
| 5 | `Kazi.CLIBusHookTest` (`cli_bus_hook_test.exs:58`) | false | `with_io(:stderr,…)` then `assert err == ""` | **3 global IO capture** |
| 6 | `Kazi.CLIInstallHooksTest` (`cli_install_hooks_test.exs:118`) | true | captured stderr line COUNT == 1 | **3 global IO capture** |
| 7 | `Kazi.Goal.LoaderAtomSafetyTest` (`loader_atom_safety_test.exs:55`) | true | `:erlang.system_info(:atom_count)` delta < 50 | **4 VM-global counter** |
| 8 | `Kazi.CLIPlanBudgetSuggestionTest` (`cli_plan_budget_suggestion_test.exs:90`) | false (shared-mode sandbox) | `proposed_goals` upsert → `Exqlite Database busy` | **5a read-model write lock** |
| 9 | `Kazi.Memory.SemanticIndexTest` (`semantic_index_test.exs:186`) | false | reads back a row from a DIFFERENT workspace | **5b read-model row leakage** |

**Class 1 — CPU-scheduling / wall-clock deadline too tight (tests 1, 2, 3).** The
awaited async work genuinely completes; it just arrives later than a hard-coded
short timeout when ~N ExUnit processes share a 4-core box under full-suite load.
These are message-passing / loop-convergence waits (workspace prep does real file
IO + a graph-refresh seam; the enforcement loop git-copies the tree for clean-tree
isolation and spawns an OS subprocess guard). The contended resource is the CPU
scheduler / wall clock, not any shared datum. Fix mechanism: raise these specific
load-sensitive deadlines to generous bounds (or an `assert_eventually` helper) —
NOT `Process.sleep` (re-flakes under different load), NOT a blanket global bump
(hides the next real hang). Same mechanism across all three, so one sub-fix.

**Class 2 — instantaneous negative assertion with no barrier (test 4).**
`refute_received` (no timeout) asserts "message `{:dispatched,"c",_}` has NOT
arrived at this exact instant." Any scheduling delay of a concurrent dispatch under
load violates it. Sibling of Class 1 (both are timing) but the fix is the OPPOSITE
shape: you cannot raise a deadline on a negative — you need `refute_receive` with a
bounded window or an explicit ordering barrier that proves frontier-0 settled
before sampling. Distinct mechanism → its own sub-fix.

**Class 3 — globally-captured stderr device (tests 5, 6).** Both wrap
`ExUnit.CaptureIO.with_io(:stderr, …)` / `capture_io` and assert the WHOLE captured
stream is empty (test 5) or exactly one line (test 6). `:stderr` capture swaps the
device group leader process-wide, so ANY concurrent test that logs during the window
is captured — observed intruders: a `kazi.loop workspace prep failed … :eacces`
warning and `provider "test_runner" is deprecated (ADR-0040)` deprecation lines from
other modules. **Key correction to #1186's framing: `async: false` does NOT fix
this** — test 5 (`CLIBusHookTest`) is ALREADY `async: false` and still flaked,
because the pollution comes from concurrent `async: true` tests in OTHER modules, not
from siblings in its own file. Fix mechanism: assert on THIS command's own output
(scoped capture / substring of the command's own writes), never on the global device
being empty. One shared mechanism → one sub-fix covering both.

**Class 4 — VM-global counter (test 7).** `:erlang.system_info(:atom_count)` is a
VM-wide counter; a delta measured across an async test body measures the WHOLE
suite's atom churn (observed `left: 64` — the loader minted none; neighbours did).
Note `test_helper.exs` ALREADY carries a partial mitigation (force-loading every
provider module before `ExUnit.start/1` so the one-time provider-load atom burst is
deterministic) — yet the test still flaked, so the mitigation is incomplete (other
concurrent atom sources remain). Fix mechanism: assert the invariant DIRECTLY —
`String.to_existing_atom(junk_key)` raising `ArgumentError`, which is what the test
actually means and is immune to neighbours (a SIBLING test in the same file at
`:52` already does exactly this). Distinct → its own sub-fix.

**Class 5 — shared SQLite read-model, TWO sub-mechanisms (tests 8, 9).** Global
sandbox is `:manual` (`test_helper.exs`); each test checks out and opts into shared
mode itself, so isolation quality is per-test.
- **5a write-lock BUSY (test 8):** `Exqlite Database busy` (SQLITE_BUSY) on the
  `proposed_goals` upsert in `Kazi.Authoring.persist/3`, despite `busy_timeout:
  60_000` on the pool (`config/config.exs`, present in test env — verified). SQLITE
  does NOT honor `busy_timeout` when a DEFERRED transaction (Ecto sandbox wraps each
  test in `BEGIN`) tries to UPGRADE to a writer while another connection holds the
  write lock — it returns SQLITE_BUSY immediately. Compounding suspect: every
  `plan`/`approve` call runs `ensure_read_model()` →
  `Kazi.ReadModel.Migrate.run` (Ecto migrator lock) on EVERY invocation. Candidate
  fixes for T59.5 to evaluate: `BEGIN IMMEDIATE` transaction mode for the write
  path, and/or skip the per-call migration when the schema is already current. This
  is a genuine coverage gap, not a timing assertion.
- **5b row leakage / cross-workspace read (test 9; and test 3's secondary mode):**
  `SemanticIndexTest` (`async: false`) queried the shared `Repo` and read back a row
  belonging to a DIFFERENT workspace (`left: …-45891` vs `right: …-65474`). Its
  `setup` does `Sandbox.checkout(Repo)` but sets NO `{:shared,self()}` mode and the
  indexing/query path can see rows it did not write — pointing at per-test
  transaction isolation not covering the read path (a query scoped too loosely, or a
  connection outside the sandbox allowance). `ContextStoreTest`'s second observed
  mode (`prompt =~ "## Indexed evidence"` missing at `:120`) is the same family:
  reading shared context-store/read-model state under load.

  5a and 5b share the resource (the SQLite read-model) but are different bugs
  (write-lock contention vs read isolation) with different fixes; group them as one
  read-model sub-workstream with two commits.

**Recommended T59.5 shape (five sub-fixes, all independently landable):** (1) raise
the three Class-1 load-sensitive deadlines; (2) give FrontierComplete a bounded
`refute_receive`/barrier; (3) rewrite the two stderr-capture asserts to check
own-output; (4) rewrite the atom-count assert to `String.to_existing_atom`-raises;
(5) read-model isolation — 5a write busy-tolerance (`BEGIN IMMEDIATE` / migration
caching), 5b sandbox ownership + query scoping. Do NOT weaken any real assertion:
every fix changes timing/isolation mechanics only. Acc satisfied: each distinct
test is traced to a named contended resource, and the one-vs-many question is
answered — **many (five), so T59.5 is several fixes.**

## 2026-07-17 — T39.6 re-drive: nested-loop spine PROVEN over CLEAN `--json` (zero goal-file reconstruction, zero prose-scraping); live opencode convergence an honest skip (no local model here)

**Type:** dogfood
**Tags:** orchestrator, opencode, json-cli, plan-approve-apply, workspace-isolation, wiring-proof, T39.6

**Task.** Re-drive the T15.9 nested loop (orchestrator -> kazi -> opencode -> local
model) end to end over `--json` now that the E39 friction fixes have landed —
`plan --json` (caller-drafts, named goal) -> `approve --json` -> `apply
<proposal-ref> --json --harness opencode`, parsing each result object and branching
on `next_action`, with NO goal-file reconstruction and NO stdout log-scraping.

**Live local-model arm — HONEST SKIP (sanctioned by the acc).** No local-model
endpoint is reachable in this session: `opencode` is not installed, `ollama` is not
installed, and outbound network probes are blocked. Without `opencode` the
`--harness opencode` dispatch literally cannot run, so the LIVE convergence arm was
not driven. The task acc explicitly allows this ("Requires a reachable local-model
endpoint … a wiring proof still counts if the local model is too slow"), so this is
a WIRING PROOF, not a fabricated live run.

**Binary-vs-source caveat (a real dogfooding landmine).** The `kazi` on `$PATH`
(release 1.193.0) is READ-MODEL-STALE relative to repo HEAD: its schema is
`v20260709210000` but HEAD has migrated to `v20260717170000`
(`AddDiscoveryToProposedGoals`). The stale binary therefore refuses to author
(`plan`/`approve` return the "read-model is unavailable; authoring requires
persistence" object and degrade to no-persistence). Notably its stdout STILL decoded
as exactly one JSON object with the schema warning routed to **stderr** — T39.4 holds
even on the degraded path. Drove the spine from the source `mix` build instead (which
ran the pending migration up to `v20260717170000`), mirroring the T15.9 precedent
where the brew binary was stale against a current source build.

**The loop, step by step (all over `--json`, each stdout = exactly one object):**
1. **plan (caller-drafts, named goal):** `kazi plan --json --predicates '<json>'
   --replace` with a supplied `goal_id`/`idea` -> a `proposed` proposal;
   `goal_id="hello-file-dogfood"` and `idea` were honored **verbatim** (T39.1;
   confirmed in the persisted `INSERT … proposed_goals`), `proposal_ref
   prop-hello-file-dogfood`. One object. PASS.
2. **approve:** `kazi approve <ref> --json` -> `{"status":"approved",…}`. **No
   goal-file was written** — the approved goal lives behind the ref (T39.2/T39.3).
   One object. PASS.
3. **apply BY REF (no goal-file):** `kazi apply <ref> --workspace <ws> --harness
   opencode --model <local> --check --json` -> resolved the APPROVED proposal
   directly from the ref (T39.2 — NO reconstructed goal-file), observed t0
   (`status:"fail"`, `next_action:"investigate"` — the fixture's `custom_script`
   predicate `test -f hello.txt && grep -q hello hello.txt` fails before any edit),
   and under `--check` **dispatched nothing**. One object. PASS. `--check` is the
   wiring probe that exercises ref-resolution + JSON purity + `next_action` branching
   without needing the (absent) inner model to converge.

**Convergence-enabler (T39.7) verified at the profile level.** The live convergence
blocker T15.9 found — the inner agent's edit escaping `--workspace` — is fixed:
`lib/kazi/harness/profiles/opencode.ex:77` threads `--dir <workspace>` into the
opencode argv whenever the run carries a workspace, so an inner edit WOULD land
inside the goal's workspace where the workspace-scoped predicate can see it.
`test/kazi/harness/opencode_profile_test.exs` (15 passed) pins the `--dir <workspace>`
argv. Actually observing an opencode-driven edit converge is the part gated on a live
local model, hence the honest skip above.

**Verdict: WIRING PROOF — PASS.** The full `plan -> approve -> apply <ref>` spine
drives end to end over CLEAN `--json`: every step's stdout `Jason.decode`s as exactly
one object (kazi logs on stderr), the orchestrator branched on `next_action`, and
there was ZERO goal-file reconstruction and ZERO prose/stdout scraping. **Live
opencode convergence — NOT observed here**, because no local-model endpoint is
reachable in this session (not a code defect; T39.7 already removed the workspace-
escape defect). Two friction notes for orchestrators: (a) drive authoring from a
build whose read-model schema matches HEAD — a stale release binary silently degrades
to no-persistence; (b) a *cold* `mix run` co-mingles **mix's own** compile banner on
stdout (pre-compile, or use a fresh release binary) — this is a mix artifact, not a
kazi `--json` violation (kazi's own logs correctly go to stderr, T39.4).

## 2026-07-17: T43.9 -- CLI release smoke dogfooded over the real built binary

**Type:** dogfood
**Tags:** [cli-provider, release, dogfood, stderr, adr-0014, uc-055]

**What ran.** Authored `priv/examples/cli_release_smoke.goal.toml`, a STANDING
`:cli` goal over kazi's OWN shipped binary (plus its trivially-green apply target
`priv/examples/cli_release_smoke.fixture.toml`), then ran it against a real built
binary -- NOT `mix test`, NOT `mix run`.

**Binary flavor exercised: plain `mix release` (ERTS + the bundled exqlite NIF --
the FULL read-model), invoked through its `eval` entry (`Kazi.Release.cli/1`).**
Burrito packaging was NOT feasible here: `MIX_ENV=prod mix release` assembled the
release cleanly, but the `Burrito.wrap` step aborted on a Zig version mismatch
(Burrito 1.5.0 pins `0.15.2`; the host had `0.16.0`). The plain release is the
faithful flavor for these probes anyway -- it carries the same read-model the
escript degrades, so it exercises the exact `Kazi.Repo`-start path the Homebrew
not-started crash lived in. A thin `kazi` wrapper mapped `kazi <args>` onto
`bin/kazi eval 'Kazi.Release.cli([...])'` so `cmd = "kazi"` ran the binary as a
user does.

**Positive verdict (clean binary converges the goal green).** `kazi version` ->
exit 0, `kazi 1.206.0` on stdout, EMPTY stderr; `kazi status` -> exit 0, prints
its summary; `kazi apply <fixture> --check` -> exit 0, `status: pass`. Running the
whole goal via the release binary (`apply --check --json`) returned `status:
"pass"`, all three predicates green.

**Negative control (broken binary reds the RIGHT predicate).** A wrapper that
leaks one spurious `warning:` line to stderr on every call (mimicking the OTP-28
regression class) flipped ONLY `version-boots-clean` to fail -- on its `stderr
equals ""` assertion, `found` carrying the leaked line -- exit 1, while
`status`/`apply` stayed green. Objective verdicts both directions.

**Finding: `stderr equals ""` is the wrong gate for a read-model command.** kazi
splits its streams deliberately (config/config.exs + `Kazi.CLI.run/1`): stdout is
the result, stderr is diagnostics. So `kazi status` and `kazi apply` write a
legitimate Ecto `[info] Migrations already up` line to stderr on EVERY boot -- a
blanket clean-stderr gate would red them against a perfectly healthy binary. The
gate belongs on the PURE `version` probe, which boots the same app (so it still
catches the OTP-28 boot-warning class) but touches no read-model; `status`/`apply`
are gated on exit 0 + a positive stdout signal, which is what reds a
`:noproc`/`Kazi.Repo`-not-started crash (a crash exits non-zero before printing).

**Nesting artifact (not a user bug).** When the release LAUNCHER evaluates a goal
whose `cmd = "kazi"` is a bare `$PATH` lookup, the launcher prepends its own
`bin/`+`erts/` dirs to `$PATH`, so `System.find_executable("kazi")` resolves to
`bin/kazi` (which only knows `start`/`eval`/`version`) and shadows the intended
CLI. A real user's `kazi` is the Burrito binary that takes `kazi version`
directly, so this only bites the release-evaluates-itself nesting; the full-goal
run used an absolute `cmd` (the provider bypasses `$PATH` for a path-shaped cmd)
to sidestep it.

## 2026-07-17: T55.7 -- the third bus surface silently stayed on the client-side path

**Type:** finding
**Tags:** [bus, daemon, digest, hook, adr-0072, aggregation-boundary]

**Problem:** T55.7 moves bus digest assembly into the daemon so the CLI, the
`kazi_bus_*` MCP tools, and the ADR-0076 hook all render ONE bounded digest the
daemon computed, instead of three client-side re-aggregations (ADR-0067 point 5,
"only a server can aggregate before the tokens are spent"). The first landing of
the task wired the CLI and the MCP tools to `Kazi.Bus.read_digest/1` (the
control-socket call) but left the hook -- shipped separately as T55.9 --
calling `Kazi.Bus.read/1` and then `Kazi.Bus.Digest.render/1` CLIENT-side. So
two of three surfaces went through the daemon and the third quietly did not:
the exact drift the task exists to remove survived in the one call site that
merged on its own timeline.

**Why it hid:** the acceptance test's "CLI, MCP, and hook produce identical
digests" case used a HOOK stand-in -- a helper that re-called `read_digest`
directly with a comment saying it "pins what T55.9 will inject." A stand-in for
the caller can only ever prove the entry point works; it cannot prove the real
caller was wired to it. The test was green while the shipped hook bypassed the
daemon entirely.

**Fix:** `Kazi.Bus.Hook.turn/1` now calls `read_digest/1` and renders the
digest the daemon assembled (no client-side `Digest.render`). The identical-
digest test drives the REAL `Kazi.Bus.Hook.turn/1`, and a new negative control
posts a 150-message backlog (deeper than `Bus.read`'s single batch of 100,
L-0040) and asserts the hook reports 150 -- impossible if it were still reading
one client-side batch. The obsolete `turn`-via-bare-`conn:` cases in
`hook_payload_test.exs` were removed; that path no longer exists.

**Lesson:** when one architectural move touches N call sites that merge
independently, a test that stands in for any call site can mask a site left on
the old path. Prove the boundary by driving the real caller, and add a negative
control that only the new path can satisfy.

## 2026-07-17: E42 regression proof -- the self-teaching docs no longer assume the operator's personal skills (T42.7)

**Type:** finding
**Tags:** [teach, docs, skill, adr-0052, regression-proof]

**Problem:** E42's premise (ADR-0052) was that kazi's two self-teaching artifacts
-- `AGENTS.md` and the skill `kazi install-skill` generates -- named the
OPERATOR'S PERSONAL skill library as though it were universal. A reader without
`/plan` installed cannot act on "fall back to `/plan`". This is the proof the
regression is closed, measured on the REAL artifacts rather than the source.

**Pre-fix, measured from git history (not memory):**

`lib/kazi/teach/install_skill.ex` at `5436307~1` -- **18** bare-slash tokens:

| token | count |
|---|---|
| `/plan` | 10 |
| `/loop` | 3 |
| `/qualify` | 3 |
| `/tidy` | 2 |

`AGENTS.md` before T42.1 carried **0** bare-slash tokens -- and that is the
interesting part. Its violation was `loop/qualify` ("you do NOT wrap it in a
separate loop/qualify pass"), which NAMES two personal skills while slipping any
bare-slash grep, because the `/` there is a separator rather than a command
prefix. A checker scoped to bare slashes alone would have reported AGENTS.md
clean throughout.

**Post-fix, measured on the artifacts a reader actually gets:**

Fresh-run of the RELEASED binary, `kazi install-skill`, which writes three files
(ADR-0074) to `~/.claude/skills/kazi/` -- SKILL.md, AUTHORING.md, RECIPES.md:

```
/plan: 0   /tidy: 0   /loop: 0   /qualify: 0     (installed skill, all 3 files)
/plan: 0   /tidy: 0   /loop: 0   /qualify: 0     (AGENTS.md on origin/main)
```

**Three things worth carrying forward:**

1. **Grep the installed artifact, not the cwd.** The first attempt ran
   `install-skill` inside a temp dir and grepped THAT -- zero hits, because
   install-skill writes to `~/.claude/skills/kazi/` and the temp dir was empty.
   A zero from an empty directory proves nothing. The real check greps where the
   binary actually wrote.
2. **The installed copy goes stale independently.** The skill loaded at the start
   of this session still contained "Where `/plan` and `/tidy` sit" long after the
   source was fixed -- `install-skill` is what refreshes it. Source-clean does not
   mean reader-clean.
3. **`loop/qualify` is the shape a regex cannot catch.** T42.3's guard flags
   `/<word>` tokens in prose and deliberately does NOT flag `loop/qualify`, since
   nothing distinguishes it from `and/or` without guessing. That form stays a
   review catch -- which is how it survived to be found by hand in T42.1.

**Verdict:** the regression is closed on both surfaces. The residual risk is not
bare-slash tokens (CI now guards those, T42.3) but separator-slash namings, which
only review catches.

## 2026-07-17: the wake contract works on the released binary -- a parked watch woke an idle worker with the message in hand (T55.13)

**Type:** finding
**Tags:** [bus, teamwork, wake, watch, harness]

**Problem:** Field feedback from a supervisor running a 24/7 fleet named idle
wakes the #1 structural gap: bus messages land at turn boundaries, so an IDLE
session never sees them. With no documented contract, the fleet resorted to
OS-level keystroke injection into session TTYs -- fragile, platform-specific,
and permanently outside kazi's boundary (ADR-0001). T55.13 asserts the
in-boundary contract already exists and needs teaching, not building. This is
the demonstration that it actually holds on the RELEASED binary (v1.159.0),
not just in source.

**What was observed (two sessions, released binary, daemon up):**

1. A "worker" session parked `kazi bus watch --timeout 240 --json` as a
   BACKGROUND TASK of its own harness (Claude Code), then went on doing other
   work.
2. A separate "supervisor" session ran `kazi bus tell <worker> "..." --sev
   interrupt`. Receipt: `{"id":905,"liveness":"active",...}` -- **`active`, not
   `dead-reaping`**: the parked watch process is what keeps the worker's
   presence row fresh, so a parked worker is visibly alive to its supervisor.
3. The harness re-invoked the worker session on the background task's
   completion. **Exit 0, and the finished task's output WAS the message** --
   the ADR-0072 digest, rendering the directed/interrupt message verbatim. The
   worker woke already holding what woke it: no follow-up `bus read`, no second
   call to discover the reason.
4. `kazi bus status 905` from the sending side then read `consumed`. The whole
   round trip is visible to the supervisor.

A separate run confirmed the other exit: `kazi bus watch --timeout 3` against a
quiet bus printed one line and **exited 3** -- the re-park signal, always
distinguishable from an arrival. Both halves of "arrival wakes, timeout
re-parks" therefore hold on the shipped binary.

**Wake latency was sub-second after publication; the CLI's own boot dominated.**
The tell's publish timestamp and the worker's wake were ~1s apart, while the
`kazi bus tell` invocation itself took ~18s wall-clock to publish on a heavily
oversubscribed box (load ~460 on 4 cores). The wake path is not the cost; the
released binary's cold start under load is.

**Finding worth flagging (adjacent, NOT fixed here -- presence pid identity):**
a presence row records the CALLING PROCESS's own pid (`bus.ex:1309`,
`"pid" => os_pid()`). For a session whose last bus call was a one-shot CLI
invocation, that pid is gone by the next liveness check, so it verdicts
`dead-reaping` -- observed live: a "supervisor" that had only ever run
short-lived `kazi bus` commands was reported `dead-reaping` while its harness
session was demonstrably alive. A session holding a long-lived kazi process (a
parked watch) is unaffected, which is why the worker read `active` throughout.
So the wake contract incidentally makes presence honest for parked workers,
while `idle` remains hard to reach for a session that merely *has* a live
harness but no live kazi process. Not in T55.13's scope (docs+teach, no new
surface); flagged for whoever owns presence liveness (T55.11).

**Conclusion:** the contract is real and teachable exactly as ADR-0076 framed
delivery -- the harness's own mechanics, not agent virtue. It needs two things
from a harness (run a background task; re-invoke the session on its
completion), needs T54.9's `--since now` anchor to be a sleep rather than a
poll, and needs no new kazi surface at all.

## 2026-07-17: E55 wave A -- 7 tasks, 4 gate-confirmed cross-task bugs, shipped v1.153.0

**Type:** finding
**Tags:** [bus, teamwork, pool, verification-gate, union-merge]

**Problem:** Seven pooled tasks (T55.1/2/3/5/11 + T54.9/10) built in parallel
worktrees, four of them writing the same files (cli.ex, bus.ex, mcp/server.ex,
session-bus.md). Each branch was green in isolation; the risk was the merged
interaction.

**Root cause / what the wave gate caught:** union-merging the branches produced
two CRITICAL cross-task regressions no single teammate could see -- (1) T55.5's
tell resolver fed plain maps into the filter_fresh/2 that T55.11 had retyped to
{entry, verdict} pairs, crashing every non-@ tell; (2) T55.2 and T55.11 both
added a `project:` switch (boolean vs string) and OptionParser silently
resolves duplicates to the first, making `bus who --project <dir>` unreachable.
An adversarially-verified review workflow (4 lenses, 11 agents) confirmed both
plus a pull-loop O(N^2)/ack-pending starvation in T54.9's new watch path and
fork-per-row `ps` liveness checks. A full-suite confirmation run then caught a
FOURTH class the lenses missed: a hardcoded expected-command list lost one
branch's edit in the merge -- silent-revert via test literal, invisible to
`git cherry`.

**Fix:** all four fixed on the integration branch, validated 210/210 targeted
(+ full suite) against fresh JetStream, landed by grafting each PR branch to
its exact integration-resolved content (rebase-merge per PR), fixes folded in
at the point in the sequence where the interaction first exists. Lossless
check: final main tree == gate-validated integration tree (release-please
files aside). install-hooks' flag shipped as `--local` (settings.local.json)
to break the switch collision.

**Impact:** tell-by-name, liveness roster, digest-by-default, watch now-anchor,
install-hooks, and the dashboard live roster are all on main and released
(v1.153.0). Field-reported stdout pollution did NOT reproduce (notice was
already on stderr); the real bug was once-per-launch repetition, fixed in the
burrito fork (kazi-org/burrito#1, merged) pending a pin bump. Un-shipped
residue: the fork pin bump, and CI runs without NATS_URL so the :nats bus
contract is only covered by local/dogfood runs -- worth a CI job.

## 2026-07-15: T40.7 dogfood -- `kazi spec import` on the released v1.149.0 binary caught a RELEASE-ONLY load bug every mix test missed

**Type:** finding  **Tags:** [E40, T40.2, T40.7, ADR-0050, ADR-0040, dogfood, released-binary, loader, atom-safety]

First real run of `kazi spec import` (E40/ADR-0050) against the **released
v1.149.0 binary** (not `mix`), on the committed `docs/specs/example.feature`
(4 Scenarios under one Feature).

**What worked (the happy path).** `kazi spec import docs/specs/example.feature
--into <out> --json` emitted a valid-looking goal-file: 4 `custom_script`
acceptance predicates, one per Scenario, all grouped under a single normalized
`[[group]]` (`import-a-behavior-spec-into-a-goal`), each carrying its
`feature`/`scenario`/`steps` metadata and a stable `Feature+Scenario` derived id.
`--json` returned the 4 upserted ids. Re-import was an upsert (count stayed 4,
`merged: true`), not a duplicate.

**Honest verdict on spec-derived vs. hand-authored predicates.** The generated
predicates faithfully capture the *structure and intent* -- one predicate per
scenario, grouped by feature, steps recorded for self-description, deterministic
ids. What they are NOT is *runnable*: each is a SCAFFOLD (`verdict = exit_zero`
with a placeholder `sh -c '... exit 1'`), RED until a human wires the real check.
So a spec-derived predicate matches a hand-authored one on the WHAT (which
behaviours must hold, at scenario granularity) but not on the HOW (the actual
command). This is by design (ADR-0013: scaffold, never guess) and is exactly the
gap the proposed runtime `provider="gherkin"` (#1107, Sire's ask) closes by
ingesting cucumber-json into per-scenario verdicts.

**The bug the dogfood caught (why you run the REAL binary).** `kazi lint <out>`
and `kazi apply <out>` on the released binary BOTH FAILED to load the goal:
`predicate "..." has unknown config key "scenario"`. Yet the same goal loads
cleanly under `mix` (and every ExUnit test + CI passed). Root cause: the loader's
atom-exhaustion guard (`safe_config_key/1` -> `String.to_existing_atom/1`,
lib/kazi/goal/loader.ex) only accepts a config key whose atom already exists.
The importer's `feature`/`scenario`/`steps` keys are consumed by NO provider, so
`ensure_provider_loaded/1` never interns them. Under `mix` the fuller module set
(and test code literally naming `config[:scenario]` etc.) interns the atoms,
masking the defect; in the burrito RELEASE binary no such module is loaded when a
goal loads, so the atoms don't exist and the load is rejected. Net: v1.149.0
shipped a `spec import` that produces goals `kazi apply` cannot run -- invisible
to the whole test suite.

Before the E40 migration the importer emitted `test_runner` (`:tests`), whose
provider references these keys, so the atoms existed; migrating to `custom_script`
(which does not) silently removed that interning. A pure-`mix` regression test
cannot reproduce it (mix always interns them).

**Fix.** Declare the three doc-metadata keys in the always-loaded loader
(`@gherkin_doc_keys [:feature, :scenario, :steps]`, used in `safe_config_key/1`),
so the atoms exist whenever a goal loads regardless of which optional modules the
release loaded. Bounded + fixed, so no atom-exhaustion regression (the
`loader_atom_safety_test` 200-junk-key guard still holds). A coherence test in
`gherkin_importer_test.exs` pins the importer's doc-key set so a new metadata key
can't be added without also interning it. Final confirmation against a rebuilt
release binary is pending the next release.

**Landmine (reinforces the DoD):** a goal that loads under `mix` can still fail
to load in the shipped binary when it carries config keys no loaded module
interns. Dogfood importers/loaders against the **released binary**, and prefer
provider-agnostic metadata be interned by the loader, not by whichever provider
happens to consume it.

## 2026-07-10: T50.7 live fleet dogfood -- `--fleet` on released v1.138.0, 1 landed / 1 teardown-crashed / 1 cascade-blocked

**Type:** finding  **Tags:** [fleet, ADR-0065, T50.7, dogfood, released-binary, #1053]

First real `kazi apply --fleet` run: released v1.138.0, 3 real goals (E53's
0021/0022/0023), one explicit `depends_on` edge (0021 -> 0022) plus inferred
`[scope]` overlap edges on lib/kazi/loop.ex, 3 serialized frontiers --
exactly the batch shape T50.7 prescribed.

What worked: discovery/DAG/`--explain` (schedule matched prediction), member
task worktrees off the base, pipelined frontier advancement, member 1
(worktree-liveness-guard) converged AND landed via serial landing (PR #1050),
dispatch through the claude harness per member, registry rows per member.

What broke (issue #1053): member 2's TEARDOWN crashed in
Kazi.Scheduler.Worktree.safe_cleanup/3 AFTER its work was complete and
pushed -- the member was reported `crashed` with `error: null`, its dependent
(member 3) cascade-blocked, no resume_token was carried, and the economy
rollup captured only 1 of 3 members (totals: ~10.3M tokens, 2 iterations,
~18.6 min for the reported member). Worse: the run also DELETED the
operator-provided `--workspace` BASE worktree, violating the ADR-0065/T50.1
never-mutate-the-base contract -- on a non-disposable checkout this would
have been data loss.

Recovery: member 2's pushed branch hand-verified (goal test + integrate
suites 11 passed; full suite 3139 passed; format clean) and merged (#1052);
member 3 re-run solo to convergence (PR #1055, its predicate = 30 consecutive
green runs of the previously-flaky wiring test).

Verdict: the fleet's scheduling/isolation/landing layers work end to end on
a released binary; the teardown path is the reliability gap (tracked #1053 --
cleanup outcome must be independent of member outcome, crash reasons must be
carried, and base-vs-member path handling in cleanup needs a pin).

## 2026-07-07: E48 live proof -- economy feedback loop + honest budget stops on v1.104.0

**Type:** finding  **Tags:** [economy, budget, over_budget, ADR-0058, live-verification]

**Problem/Observation:** T48.13 live-verified the E48 economy feedback loop
(UC-063/UC-064, ADR-0058) against the RELEASED `kazi` binary (`kazi version` ->
`1.104.0`), all runs against a scratch workspace outside the repo.

1. **missing_url class rejected at goal-load, not burned as `over_budget`.**
   A goal.toml with one trivially-passing `custom_script` predicate and one
   `http_probe` predicate with no `url` key, `max_iterations = 40`:
   ```
   kazi apply <scratch>/goal.toml --workspace <scratch> --json
   ```
   Output (verbatim, exit code 1, zero iterations, zero dispatches):
   ```
   {"error":"could not load goal-file <scratch>/goal.toml: http_probe predicate \"no-url-probe\" is missing required key \"url\" (a live predicate needs a url to probe)","schema_version":2}
   ```
   This is exactly the incident class ADR-0058 was written for: before the
   fix, a missing url burned all 40 iterations and finished as a bare, opaque
   `over_budget`. On v1.104.0 it never enters the loop at all -- the JSON
   error envelope names both the offending predicate id and the missing key.
   Honest gap: because T48.1 closes this at goal-LOAD, the in-loop
   `error_wedged` path (T48.3/T48.4) is no longer reachable from a goal-FILE
   for a `missing_url` case specifically -- that path's live behavior is
   pinned by loop-level ExUnit against the real provider, not by this
   goal-file proof. (Observation 2 below independently exercises the OTHER
   half of the cause taxonomy -- an ordinary stuck, correctly left
   uncaused -- so the classifier's "don't over-attribute" contract is also
   live-verified, just not the `error_wedged`/missing_url branch itself.)

2. **Economics row + cause surface on real convergent AND stuck runs.** Ran a
   tiny real goal on the claude harness (`model = "claude-haiku-4-5"`, single
   `custom_script` predicate `test -f hello.txt`, `max_iterations = 5`)
   twice against the released binary.
   - First attempt (`permission_mode` unset): the inner harness hit a
     `Write` permission denial in its own transcript ("I need permission to
     write to the workspace directory") and never created the file. The loop
     correctly did NOT grind to `over_budget` at iteration 5 -- it stopped
     EARLY (iteration 3 of 5) as a named `stuck` (`"reason":"stuck"`,
     "same failing set persisted") the moment the failing set held steady,
     exactly the honest-early-stop behavior ADR-0058 argues for, just via
     the ordinary T1.5 failing-set path rather than the missing_url path.
   - Second attempt, `[harness] permission_mode = "acceptEdits"` added (a
     documented CLI/goal-file flag, `lib/kazi/cli.ex:184` -- not a kazi bug,
     an environment precondition for headless dispatch): converged in 2
     iterations. Terminal JSON: `"status":"converged"`,
     `"usage":{"cost_usd":0.0504182,"cached_input_tokens":60232,"input_tokens":26,"output_tokens":743,"cache_write_tokens":20327}`,
     `"budget_spent":{"tokens":81328,"iterations":2,"exceeded":null}`.
   - Persisted read-model rows for both runs (`sqlite3 ~/.kazi/kazi.db
     "SELECT goal_ref,status,dispatch_count,budget_tokens,budget_cost_usd,predicate_count,outcome_cause_class FROM runs ORDER BY id DESC LIMIT 3;"`):
     ```
     t48-13-hello-convergence-2|converged|1|81328|0.0504182|1|
     t48-13-hello-convergence|stuck|2|81070|0.0815196|1|
     ```
     Both rows have non-NULL `dispatch_count`/`budget_tokens`/`budget_cost_usd`/
     `predicate_count` (the T48.7 economics columns populated from real
     harness `usage`). `outcome_cause_class` is correctly EMPTY/NULL for
     BOTH rows -- per `Kazi.Loop.CauseClass`'s moduledoc, an ordinary
     converge and an ordinary T1.5 failing-set stuck are "not mislabels,
     they are exactly what they say they are," so `nil` here is the
     honest-unknown contract working as designed, not a gap.

3. **Economy aggregate.** `kazi economy --json` after the two runs above
   groups them correctly:
   ```
   {"harness":"claude","model":"claude-haiku-4-5","goal_shape_bucket":"1-3","n":2,"n_with_usage":2,"tokens":{"p50":81070,"p95":81328},"cost_usd":{"p50":0.0504182,"p95":0.0815196},"dispatch_count":{"p50":1,"p95":2},"wall_clock_s":{"p50":18.882025,"p95":25.648338}}
   ```
   (plus four other groups from unrelated prior runs on this machine, each
   correctly reporting `n_with_usage: 0` / `unknown` p50/p95 where no `usage`
   was ever recorded). `kazi economy` (human view) renders the same numbers
   per group in plain text. The aggregate covers the T48.13 run pair exactly
   as expected.

**Root cause:** N/A (verification entry).

**Fix:** N/A.

**Impact:** the missing_url incident class is closed at goal-load on the
released binary; run economics are persisted and queryable per-run and in
aggregate; budgets can now be learned from history (T48.9). The one honest
gap: the in-loop `error_wedged` classification branch for `missing_url`
specifically is not independently exercised by a goal-file in this proof
(T48.1's load-time rejection makes it unreachable from that entry point by
design) -- its live behavior remains pinned by existing loop-level ExUnit.

## 2026-07-06 — E47 close-out: T47.3 live proof on released v1.82.1

**Type:** dogfood
**Tags:** e47, dashboard, event-river, roadmap-ref, visual-fidelity, T47.3

Observed in a real browser against the standalone released binary
(kazi 1.82.1, `kazi dashboard --bind 0.0.0.0 --roadmap <5-group needs-DAG
goal-file>`): the starmap renders the full fleet (21 landed / 11 stuck /
8 stale post-mortems) as the DESIGN's dark state-colored chips with glows,
the roadmap wave bands render from the --roadmap goal-file, /events streams
every registered run's events.jsonl newest-first with working drill-in and
transcript deep links (verified earlier same-day with 2 concurrent live
fixture runs on v1.82.0), and /dag wears the dark zoo. Visual fidelity took
kazi rounds 1-3 plus one 15-line hand-finish, arbitrated by
`kazi apply --check` (the #805 mode) reporting the full vector pass; rounds
2/3 terminating stuck-at-3 on a quarantined suite flake (instead of
spinning to 40) is the #820 fix observed working in production.

## 2026-07-06 — #819/#820 + E47 shipped; visual-fidelity finding: grep predicates pass on presence, only a browser catches "not actually used"

**Type:** finding
**Tags:** e47, dashboard, visual-fidelity, predicate-authoring, integrate, quarantine

**Problem:** Restyling the dashboard to the committed design spec
(docs/dashboard-design.md) converged on all six predicates (token hexes
present, nd-* zoo classes present, reduced-motion gated, structure regression,
suite, format) — yet the browser showed the OLD pastel light-mode pills on the
run list and a plain-text /events. The tokens and classes existed in CSS but
the markup never used them.
**Investigation:** Screenshot review against the design mockups after
convergence; grep confirmed legacy pastel hexes (#d8f5d8 #ffd9d9 #ffe0c2 ...)
still live in starmap_live.ex and dag_live.ex.
**Root cause:** Presence-greps are satisfiable by ADDING alongside instead of
REPLACING. A visual-fidelity bar needs (a) negative predicates — the legacy
styles must hit ZERO — and (b) markup-level assertions that entries render
through the new classes; and a human/browser review stays the final gate.
**Fix:** Goal sharpened with no_pastel_pills (== 0) + starmap_uses_zoo (>= 6
in HEEx, not CSS); round 2 converging at session end (see checkpoint).
**Impact:** Same session shipped: #804/#786/#787/#793/#788/#790/#805 (all
closed, live-verified), E46 complete (T46.10 proof, v1.78.0), #819 integrate
discipline + #820 quarantine exit (v1.79.x, both re-confirmed by later runs
terminating promptly instead of spinning), E47 T47.1 /events river + T47.2
--roadmap (v1.82.0, live-verified: river streams real runs, roadmap renders
wave bands). Recurring landmine: inner agents twice documented an unshipped
`kazi plan --project` flag — the T28.4 doc-accuracy gate caught both; goal
descriptions should say "do not name unshipped flags in docs".

## 2026-07-06 — E46 shipped end-to-end by kazi driving kazi; T46.10 live proof on v1.78.0; three fresh landmines

**Type:** dogfood
**Tags:** e46, dashboard, starmap, attention-queue, transcript-peek, drillin, kazi-drives-kazi, T46.10

**Task.** Execute the full E46 remainder (T46.2 events sink, T46.5 wave-band
starmap, T46.6 attention queue, T46.7 drill-in heatmap, T46.8 transcript peek,
T46.9 docs) plus a seven-issue fix chain (#804 #786 #787 #793 #788 #790 #805)
as kazi goals: caller-drafts predicates, `kazi apply` converges each, PR +
rebase-merge per change. 11 goals converged; releases v1.73.5 -> v1.78.0.

**T46.10 live proof (all observed, released v1.78.0 binary, real browser).**
Three concurrent fixture runs (one lands, one converges multi-file, one
impossible-predicate stuck) against the standalone `kazi dashboard`:
starmap showed every run with correct states (landed/converging/stuck plus
stale post-mortems from prior sessions) and live fleet counts; the attention
queue ranked a REAL stuck goal (e46-t46-9-docs-overview, predicate
events_jsonl_documented) first with a working drill-in deep link; the
drill-in heatmap rendered the 4-iteration predicates x iterations matrix
including a red->green flip column-accurate; transcript peek streamed a live
run's harness output (follow toggle) and replays finished runs through the
same code path. Screenshots in the session scratchpad; every claim above was
observed, not asserted.

**Landmine 1 — match_count counts LINES; never pair it with `grep -c`.**
A docs predicate `grep -c pattern file` + `verdict=match_count, pass_when=">= 2"`
can NEVER pass: grep -c emits ONE line (the count). kazi correctly went stuck;
the docs were actually fine. Use `grep -n` (line per match) under match_count,
and treat a stuck goal whose evidence shows the right content as a checker bug.

**Landmine 2 — integrate self-merge + add -A blast radius (issue #819).**
First live firing of the E44 integrate wiring (v1.74.0) swept every
untracked-unignored workspace file into a monolith commit and rebase-merged
its own PR (#816) seconds after opening, before CI. ~1800 machine-local files
(agent configs, a generated graph report) landed on a PUBLIC repo main; scrub
+ .gitignore hardening in #818. Also: an all-green run still converges WITHOUT
integrating (decide/2 ordering), so auto-landing only triggers when something
blocks clause 1 — T46.5 landed only because its suite predicate was
quarantined. Fix tracked in #819.

**Landmine 3 — quarantine has no exit (issue #820).** One flap of a known-flaky
test quarantined suite_green; post-#795 the unknown verdict correctly blocks
convergence, but a quarantined-then-consistently-passing predicate is never
rehabilitated and a no-work loop fast-spins (~1 tick/s) to max_iterations.
Also re-confirmed lore L-0023 the hard way: headless claude in a fresh
workspace dir denies on the trust dialog and the run goes stuck with zero
edits -- goal-file fix is `[harness] permission_mode = "bypassPermissions"`
for throwaway fixture workspaces.

## 2026-07-05 — issue #801 dogfood: kazi drove its own /dag fix end-to-end; two operator findings

**Type:** dogfood
**Tags:** dashboard, dag, standalone-boot, kazi-drives-kazi, vacuous-goal, integrate, issue-801

**Task.** `kazi dashboard` (standalone boot, T46.4) 500'd on `/dag` with no
active `apply --parallel` run — `KaziWeb.DagSource.Cache` was only supervised
by the full app tree, and `DagLive` did a raw `GenServer.call` to it (issue
#801). Fixed the kazi way: a read-only regression checker
(`test/kazi_web/live/dag_live_standalone_test.exs`, committed at t0, held via
`[enforcement] read_only_paths`) encoding graceful degradation + standalone
supervision-tree parity, three acceptance predicates (checker, full suite,
format), then `kazi apply --harness claude --model claude-sonnet-5` to
converge it. Shipped v1.73.4 (PR #802); all six dashboard routes verified 200
live on the released binary, `/dag` rendering the "No active run" empty state.

**Finding 1 — the inner agent lands work unprompted.** The sonnet-5 inner
agent committed the fix (clean conventional-commit message) AND opened PR #802
on its own initiative — no `landed` predicate in the goal. The known
"converges before :integrate, never commits" gap (2026-07-03) is therefore
stale as a *prediction* on current binaries with a capable model, though the
loop still doesn't *require* landing: keep adding a `landed` predicate when
landing must be guaranteed.

**Finding 2 — `vacuous_goal` can mean "already done", not "misauthored".**
The first run was killed externally (SIGTERM) mid-iteration after the agent
had already committed the fix; the resumed run terminated
`{"status":"error","reason":"vacuous_goal"}` because every predicate passed
at its t0. On a killed-then-resumed goal, check `git log` before re-authoring:
the R3 vacuous-goal guard firing at resume is convergence evidence in
disguise.

**Operational footnote.** A stale `kazi dashboard` process holding the port
makes a fresh boot crash `:eaddrinuse` — and a live-verify curl then silently
grades the OLD binary still listening there. Free the port (`lsof
-tnP -iTCP:<port> -sTCP:LISTEN`) before trusting route probes.

## 2026-06-28 — T15.9 nested-loop dogfood: WIRING PROVEN over `--json`; local model SUCCEEDED but its edit escaped the `--workspace` (opencode `--dir` not threaded)

**Type:** dogfood
**Tags:** orchestrator, opencode, local-model, json-cli, plan-approve-apply, workspace-isolation, T15.9

**Task.** Drive the FULL `plan -> approve -> apply` spine entirely over `--json`,
as an outer orchestrator, with a cheap locally-hosted model running kazi's inner
reconcile loop (orchestrator -> kazi -> opencode -> local model). Tiny broken
fixture: a `custom_script` predicate `sh -c "test -f hello.txt && grep -q hello
hello.txt"` (fails at t0; the inner model must create the file). Driven on a
current source build (`kazi 1.68.0`; the brew binary is stale at 1.41.1).

**Local-model arm (confirmed live).** opencode `run "<prompt>" --format json
--model <local-ollama-provider>/qwen3.6:35b-a3b-q8_0` returned proper NDJSON with
`{"type":"text","text":"OK"}` + a `step_finish` carrying token counts and
`cost: 0` (a free, locally-served model). Reachable and responsive.

**The loop, step by step (all over `--json`):**
1. **plan (caller-drafts):** `kazi plan --json --predicates '<json>'` -> a
   `proposed` proposal object, `proposal_ref prop-…2b66f3dbd894`. PASS.
2. **approve:** `kazi approve <ref> --json` -> `{"status":"approved",…}`. PASS.
3. **apply:** `kazi apply <goal-file> --workspace <ws> --harness opencode --model
   <local>/qwen3.6:35b-a3b-q8_0 --json` -> the inner loop ran: observed t0
   (predicate `code` = fail), recorded iteration 0, wired opencode (wrote
   `.kazi/context.md` orientation + `.mcp.json` into `<ws>`), and dispatched the
   local model.

**The real finding (corrected — NOT "too slow").** The local model SUCCEEDED at the
task: it created `hello.txt` containing `hello` at 17:16 (mid-run). But the file
landed in **opencode's resolved directory (the git-repo / server root = the
worktree), NOT kazi's `--workspace`** (a non-git tmp dir). kazi evaluates the
predicate IN `--workspace`, so it never saw the file, never converged, and the loop
kept re-dispatching (which looked like a stall). Root cause: kazi's opencode
profile argv is `run <prompt> --format json [--model …]` and **omits `--dir
<workspace>`** (the installed `opencode run` HAS a `--dir` flag: "directory to run
in"). `CliAdapter` does `System.cmd(... cd: workspace)`, but opencode does not honor
the launch cwd — it resolves its own project root (and `opencode` runs as a
persistent `bun server.ts` daemon the `run` attaches to), so the inner agent's
edits escape the goal's workspace. **opencode runs do NOT isolate to kazi's
`--workspace` today.**

**Verdict: WIRING PROOF — PASS** (full orchestrator -> kazi -> opencode ->
local-model spine driven over `--json`; the acc explicitly accepts a wiring proof).
**Convergence — NOT observed by kazi**, because the inner agent's correct edit
landed outside the workspace, not because the model was slow. This is a real,
fixable kazi<->opencode integration bug, captured as **T39.7** (thread `--dir
<workspace>` into the opencode profile).

**Friction logged (every point kazi was awkward to drive as a tool) -> E39
(ADR-0049, merged this session):**
1. `plan --json --predicates` IGNORED the supplied `goal_id`/`idea` (T39.1).
2. The **approve -> apply handoff is broken**: `approve` never writes a goal-file,
   `apply` requires one; the orchestrator supplied it (T39.2/T39.3).
3. `--json` via dev `mix run` CO-MINGLES Phoenix/Ecto logs into stdout (T39.4).
4. The operator **escript cannot author** (`plan`/`approve` need the SQLite NIF an
   escript can't bundle); used the Mix path (T39.5).
5. **opencode edits escape `--workspace`** (no `--dir`) — the convergence-blocker
   above (T39.7).

## 2026-06-28 — T21.9 CLOSED: leases shown LIVE in a browser (the missing clause), on released v1.68.0

**Type:** dogfood
**Tags:** dashboard, leases, native-parallel, T21.9, live-verification

**Task.** Close the last open T21.9 clause — the operator dashboard showing the
parallel run's **leases** live — after the wiring fix (PR #756, v1.68.0) made the
CLI `--parallel` path publish into `Kazi.Coordination.LeaseTable`.

**What was driven.** With the dev endpoint (`config/dev.exs`, `server: true`,
`localhost:4000`) booted IN THE SAME BEAM NODE (so the served dashboard reads the
same `LeaseTable`), a flat leased native-parallel run held two disjoint partitions
concurrently: `Kazi.Scheduler.run_goals/2` over two disjoint goals with an injected
graph source + sleeping reconcilers + the SAME lease-opts shape the CLI now injects
(`backend: Lease.Memory`, a per-run store, `lease_table: LeaseTable`). The script
confirmed `LeaseTable.list/0` held 2 leases.

**Observed LIVE (agent-browser, golden path, no console errors).** `/leases` (the
`kazi lease map`, `KaziWeb.LeaseMapLive` via the default `CoordinationSource.Native`
source) rendered the **`Active leases`** table with **two rows** — two concurrent
partition holders (`kazi.partition:09bee…:2` and `kazi.partition:7b7d…:1`), each
with its Resource (blast-radius key) + Holder. Screenshot captured. Before v1.68.0
this table was EMPTY on every native run (the CLI never injected `:lease`).

**Verdict: T21.9 DONE.** All three acc clauses now verified live: **leases** (this
run, 2026-06-28) + **>=2 concurrent reconcilers** and **per-partition convergence**
(the 2026-06-26 `/dag` dogfood, screenshots in that PR). Honest scope (L-0021): the
lease table is per-BEAM-node, so a one-shot released CLI and a separately-deployed
dashboard (different nodes) still need the NATS Transport source (Slice 3); the
same-node operator-dashboard scenario the acc describes works on v1.68.0.

## 2026-06-28 — T21.9 wiring: `kazi apply --parallel` now publishes partition leases to the dashboard (Gap 1 closed)

**Type:** finding
**Tags:** scheduler, leases, dashboard, native-parallel, cli, T21.9

**Problem.** The T21.9 dashboard dogfood (devlog 2026-06-26) closed 2 of 3 acc
clauses (≥2 concurrent reconcilers + per-partition convergence shown live) but
left **leases NOT shown** — the material miss. Root cause beyond the NATS-free
`/leases` 500 (since fixed by `CoordinationSource.Native` + `LeaseTable`, L-0021):
the CLI `--parallel` path never injected a `:lease`, so
`Kazi.Scheduler.run_goals/2` skipped `LeasedReconciler.wrap/2` and nothing was
ever recorded into the globally-readable `Kazi.Coordination.LeaseTable`. The lease
map rendered, but EMPTY, on every native run.

**Root cause.** `Kazi.CLI.run_goal_parallel/4` composed `scheduler_opts` with only
`:workspace` + `:run_opts`. With no `:lease` key, `lib/kazi/scheduler.ex` (line
~572) takes the `nil` branch and returns the bare worktree reconciler — the whole
publish seam (`LeasedReconciler` → `LeaseTable` → `CoordinationSource.Native` →
`/leases`) existed and was tested but was never engaged from the CLI.

**Fix.** `run_goal_parallel/4` now calls `maybe_put_default_lease/1`: it starts a
per-run `Kazi.Coordination.Lease.Memory` store, calls
`Kazi.Coordination.LeaseTable.ensure_started/0` (new — the Burrito standalone CLI
bypasses the app supervision tree, the same class as the existing
`PartitionSupervisor.ensure_started`/`Repo` fixes), and injects
`lease: [backend: Memory, lease_opts: [store: store], lease_table: LeaseTable]`.
Best-effort + hermetic: skipped when the caller injected its own `:reconciler`
(boundary tests drive their own seam) or `:lease`, so the parallel boundary tests
stay free of real lease/clock side effects.

**Impact.** A SAME-NODE dashboard (the dev `mix phx.server` driving an in-node
native-parallel run — exactly the T21.9/T20.8 scenario) now renders the live
partition lease map. Honest scope boundary (recorded in L-0021): a one-shot
released CLI and a separately-deployed dashboard are different BEAM nodes and share
no in-memory table, so cross-node lease visibility still needs the NATS Transport
source (Slice 3). Tests: `test/kazi/cli_run_parallel_lease_test.exs` (a real
`apply --parallel` run, no injected reconciler/lease, with a capturing provider
that observes the held lease in `LeaseTable` during reconcile) +
`ensure_started/1` cases in `test/kazi/coordination/lease_table_test.exs`.
Remaining for T21.9 closure: the browser leg — `mix phx.server` + an in-node
native-parallel run + agent-browser confirming ≥2 leases render live.

## 2026-06-28 — T25.2 hero asset: REAL recorded cast replaces the hand-drawn mockup

**Task.** T25.2: the home/README proof-of-convergence visual had to become a
genuine recording of a real reconcile run (not a mockup), and doing so also
remedies the live stale-verb bug (the old `assets/proof-loop.svg` showed the
removed `kazi run my-goal.toml`).

**What was recorded.** A minimal honest fixture, `priv/examples/hero_cast_demo/`:
a tiny Go module whose `Greet` returns the wrong word, so `go test` fails at t0,
and a goal with one `custom_script` acceptance predicate (`go test ./...`,
`verdict = exit_zero`). `kazi apply … --harness claude` (released binary v1.66.0,
macOS arm64) drove the `claude` harness to fix the greeting and converged in **2
iterations** — `iter=1 failing=["tests-pass"]` → `iter=2 failing=[]` → `CONVERGED`.
The asciicast captured genuine live timing (iter 2 lands ~27 s after iter 1 — real
harness work); `idle_time_limit: 2.0` caps the pause on playback.

**Artifacts.** Source cast `assets/proof-loop.cast` (committed, reproducible);
render `assets/proof-loop.gif` + `site/public/proof-loop.gif` (18 KB, via `agg`).
The hand-drawn `proof-loop.svg` mockups were removed. README + `index.astro` prose
and alt text were rewritten to describe what the cast actually shows (one
`tests-pass` predicate), not the old aspirational "tests + /livez over four
iterations" narrative.

**Findings / friction.**
- The released binary logs at `:debug`, so a raw `kazi apply` run buries the
  `kazi.loop` progress + `CONVERGED` summary in Ecto/SQLite SQL noise. There is no
  `--quiet`/log-level flag or env override. The committed `record.sh` de-noises
  transparently (drops the SQL/`:debug` lines, strips the timestamp prefix); every
  rendered line is verbatim kazi output.
- `svg-term-cli` crashes on Node 25 and `termtosvg`/`pipx` were unavailable, so the
  asset is a GIF (explicitly allowed by the task's "SVG/GIF"); the `.cast` is the
  text source of truth. The T29.4 verb guard scans the remaining hand-authored
  `.svg` diagrams; the binary GIF can't hide a verb because it's a real recording.

**Status.** Site builds clean and references only `proof-loop.gif`; the T29.4
`check-commands` guard passes in BLOCKING mode; Gate 5 doc-command accuracy passes.
PR/merge/release/live-verify tracked on the task.

## 2026-06-26 — T31.7 LIVE dogfood: standing doc-lifecycle goal driven on this repo (kazi-drive + tool fallback)

**Task.** T31.7: drive the E31 standing goal (`priv/examples/doc_lifecycle.goal.toml`)
against kazi itself — trim done+released epics, extract their knowledge to the tier
docs, and report the freshness-gate result honestly. Uses the RELEASED binary
(feature-complete dogfood policy).

**kazi-drive (released v1.64.2, `--harness claude`).** `kazi apply
priv/examples/doc_lifecycle.goal.toml --workspace . --harness claude --json` was run
against this repo. Because the goal declares `standing = true`, `apply` does not
self-terminate; the run was driving a real claude harness when it was stopped at the
7-minute mark. In that window kazi DID drive the harness to make real doc fixes:
- `README.md` — added five shipped commands missing from the command reference
  (`status`, `export`, `lint`, `help`, `version`). This brings predicate (a)
  commands-in-readme from FAIL → PASS and the doc-coverage ratchet 66.7% → 100.0%.
  Verified each command exists in `lib/kazi/cli.ex`. Kept.
- `.github/scripts/doc_freshness/check_b_no_dead_command_refs.sh` — added
  `oss-gates.md` to the checker's self-exclusion list, mirroring the existing
  `doc-freshness.md`/`devlog.md`/`plan.md`/`lore.md` exclusions. `oss-gates.md`
  legitimately names removed verbs (`kazi run`/`kazi propose`/`kazi frobnicate`) as
  EXAMPLES of what the guards catch, exactly like `doc-freshness.md`; the exclusion
  corrects a false positive (predicate (b) FAIL → PASS), not a real dead-command
  ref. HONEST CAVEAT: this path is in the goal's `read_only_paths` (ADR-0042
  anti-gaming). The enforcement reverts such in-flight edits at the END of a fix
  arc; the run was killed before that, so it was NOT enforcement that allowed the
  edit to survive. The operator reviewed it as a legitimate checker-completeness
  fix (consistent with the existing pattern) and chose to keep it.

The harness did NOT run the Layer-1 trim or Layer-2 extraction in that window — it
went after the README/checker predicates first. So, per the task's documented
fallback, the trim + extraction were driven via the deterministic tools directly.

**Layer-1 trim (fallback: `trim_plan.py --apply`).** Only ONE epic was trimmable:
**E16** (kazi self-teaching to harnesses — skill + MCP + machine-readable help).
`trim_plan.py` archives an epic ONLY when fully closed AND every `[x]` task's
`Done:` date ≤ the newest release tag (`v1.64.2`, 2026-06-26). E16 met both;
E12/E13/E14/E17/E18/E24 were already archived in prior runs. E16's file moved
verbatim to `docs/plans/archive/E16.md`, its WBS pointer dropped from `docs/plan.md`,
and a one-line entry recorded in `## Archived epics`. Lossless round-trip re-pinned:
`test_trim_plan.py` ALL PASS.

**Layer-2 extraction (fallback: `extract_knowledge.py --latest`, confirm gate).**
Ran against the newly-archived E16. Result: "No durable nuggets found in E16.md."
This is CORRECT, not a miss — E16's body is entirely `- [x] Tnn` plan task lines,
which the extractor's `SKIP_RE` excludes as plan bookkeeping. E16's durable
knowledge already lives in the tiers: the install-skill on-ramp evidence is in this
devlog (2026-06-25) and the stale-Homebrew-tap landmine is `docs/lore.md` L-0019.
Nothing new to lift; the archive remains the lossless backstop.
`test_extract_knowledge.py` ALL PASS.

**Freshness gate after the run.**
- (a) commands-in-readme — PASS (README fix)
- (b) no-dead-command-refs — PASS (oss-gates.md exclusion)
- (c) adr-refs-exist — PASS
- (E) readme-site-coherence (`node`) — PASS (5 canonical strings match)
- (F) skill-cli-coherence (`mix test`) — PASS (9 tests)
- doc-coverage-ratchet — 66.7% → **100.0%** (improved)
- (d) plan-trimmed — **still RED**: 154 → **148** offenders after trimming E16.
- stale-tasks-ratchet — 154 → **148** (baseline 0, still RED).

**Honest finding (the design tension this dogfood surfaced).** Predicate (d) and the
stale-tasks ratchet count EVERY done+released `- [x]` line in the live plan
regardless of whether its epic is closed (see `check_d_plan_trimmed.sh` /
`metric_stale_tasks.sh`), but `trim_plan.py` only archives FULLY-CLOSED epics
(whole-epic granularity). The bulk of the 148 remaining offenders are done tasks
inside epics that still have OPEN tasks (E19/E20/E21/E23/E25/E26/E27/E28/E29/E30/
E31/E32/E33–E38) plus undated `[x]` tasks. So (d) and the stale-tasks ratchet CANNOT
reach green by trimming alone today — they ratchet down as epics fully close, exactly
as the metric is designed to report progress. The trim and extraction are correct,
lossless, and gated; the freshness gate is GREEN on every predicate EXCEPT the two
plan-trim ratchets, which improve but legitimately stay red while active epics hold
shipped tasks. Reported honestly: kazi DROVE the harness for the README/checker
fixes; the trim + extraction were driven via the deterministic tools (documented
fallback).

## 2026-06-26 — T21.9 LIVE dashboard dogfood: reconcilers + per-partition convergence shown live; leases NOT shown (PARTIAL)

**Task.** T21.9 acc: the operator dashboard shows ≥2 concurrent partition
reconcilers + their leases + per-partition convergence, LIVE, exercised in a real
browser (agent-browser); read-only, decoupled from the loop (ADR-0011).

**Setup.** Source build (`mix deps.get && mix compile`), `mix phx.server` on
`localhost:4000` (dev endpoint, `config/dev.exs`). A native-parallel run was driven
IN THE SAME BEAM NODE so the dashboard saw it: `Kazi.Scheduler.DepScheduler.run/2`
over `priv/examples/predicate_graph_waves.toml` (3 groups: `result-contract` and
`health` at frontier 1, `streaming` `needs = ["result-contract"]` at frontier 2),
with an injected stub group-reconciler that sleeps then returns `:converged` (no
inner harness needed — the goal is to keep ≥2 reconcilers ALIVE concurrently so
leases + convergence RENDER). Under the hood each DAG group is reconciled via the
flat E21 partition path (`run_goals_flat → Kazi.Scheduler.run/2`, one reconciler
per partition).

**What the `/dag` view showed LIVE (golden path, no console errors):**
- **Frontier 1:** `Result contract` RUNNING **and** `Health endpoint` RUNNING
  simultaneously — **≥2 concurrent reconcilers** — with `Streaming endpoint`
  PENDING (`deps 0/1 converged`) and the `result-contract → streaming` `needs`
  edge rendered.
- **Pipeline:** `Health endpoint` (independent) converged while `Result contract`
  was still RUNNING and `Streaming` still PENDING — per-group convergence is
  independent.
- **Frontier 2:** once `Result contract` converged, `Streaming` flipped to RUNNING
  with `deps 1/1 converged` — the `needs` gate released on the dep's objective
  convergence.
- **Terminal:** all three CONVERGED.

Each transition was captured in a real browser (agent-browser, screenshots in the
PR description). **≥2 concurrent reconcilers + per-partition (per-group)
convergence: OBSERVED LIVE.**

**Gap 1 — leases NOT shown (the material miss).** The lease map (`/leases`,
`KaziWeb.LeaseMapLive`) defaults to `KaziWeb.CoordinationSource.Transport`, which
aggregates presence/intents/leases over the coordination TRANSPORT. In a
single-node NATS-free dev run it **500s on mount**: `(ArgumentError)
Kazi.Coordination.Transport.Memory requires a :bus handle in opts` (no bus is
configured in dev). Even with a bus, the native-parallel scheduler acquires
`Kazi.Coordination.Lease.Memory` leases in an isolated per-run store and announces
NO presence/intent on the transport, so the Transport source would surface nothing
for native-parallel partitions. **The dashboard cannot show native-parallel
partition leases today.** This is the NATS-free/single-node gap the task flagged.

**Gap 2 — the flat E21 scheduler has no dashboard surface.** `Kazi.Scheduler`
(the E21/ADR-0027 flat parallel coordinator) does **not** broadcast anything to the
dashboard — only `Kazi.Scheduler.DepScheduler` (E23/ADR-0028) broadcasts
`DagSnapshot` frames (`scheduler:dag` topic). So a pure FLAT native-parallel run
(no `needs` edges) is invisible to the dashboard; the `/dag` view is the only live
surface for concurrent reconcilers + convergence, and it requires a `needs`-DAG
goal.

**Gap 3 (caveat, not necessarily a product bug).** In headless agent-browser the
LiveView did not push diffs over websocket to an already-open page; live state was
observed via page **reload** (static mount reads `KaziWeb.DagSource.Cache.current/0`,
which holds the latest broadcast frame). The scheduler IS broadcasting on every
transition — proven by reloads showing the correct progressive state at each
frontier — but the no-reload websocket diff push was not confirmed in this headless
setup.

**Verdict: T21.9 PARTIAL — left `[ ]`.** Reconcilers + per-partition convergence
shown live in a real browser (2 of 3 acc clauses); **leases NOT shown** (wired to
NATS only; `/leases` 500s NATS-free). Closing T21.9 needs either a single-node
coordination source for the lease map (so in-memory partition leases render
NATS-free) or an explicit acc carve-out that the lease panel is NATS-only. Fixture
reused: `priv/examples/predicate_graph_waves.toml`.

## 2026-06-26 — T26.6 LIVE: the kazi skill ROUTER drives a goal end to end (plan → approve → apply) with NO legacy skills; subsumption ASSERTED

The E26/ADR-0031 closing proof: in a real session, drive a fixture goal to
**objective convergence** through the kazi skill ROUTER's verbs only —
`kazi plan` → `kazi approve` → `kazi apply` — using NO `/loop`, NO `/apply`, NO
`/qualify` (no legacy skills). Run on the **released v1.64.2 macOS binary** (checksum
`kazi_macos_aarch64.sha256` OK; `kazi version` → `1.64.2`) driving the **real claude
harness** (Claude Code 2.1.193). Workspace: a throwaway `git init` dir, the goal
file absent at t0 (CREATE mode, predicate fails at t0).

**The router flow (every step a real `kazi` verb; full JSON captured):**

1. `kazi plan "Create a file named VERSION.txt in the workspace whose contents are
   exactly the text: 1.0.0" --workspace <ws> --yes --json`
   → `{"status":"proposed","proposal_ref":"prop-create-a-file-named-version-txt-8d50dc3bd447",
   "predicates":[{"id":"version_file_exists_with_exact_content","provider":"custom_script",
   "config":{"cmd":"sh","args":["-c","test -f VERSION.txt && [ \"$(cat VERSION.txt)\" = \"1.0.0\" ]"]},
   "acceptance":true}], ...}`. **1 usable `custom_script` predicate**, canonical
   `cmd`/`args` shape — no invented `script`/`interpreter` (the T26.8 L3 prompt-schema
   fix holds live). Drafting drove a ~12 s claude session; the proposal persisted to
   the read-model.
2. `kazi list-proposed --status proposed --json` → the proposal is queued
   (`"status":"proposed"`).
3. `kazi approve prop-create-a-file-named-version-txt-8d50dc3bd447 --json` →
   `{"status":"approved", ...}` — the stored goal LOADS through approve's loader (the
   T26.8 L2/L3 fixes hold).
4. `kazi status prop-…-8d50dc3bd447 --json` →
   `{"status":"approved","kind":"proposal","goal_id":"create-a-file-named-version-txt"}`
   (the router's `status` verb reads persisted state).
5. `kazi apply version.goal.toml --workspace <ws> --harness claude --json` →
   **`{"status":"converged","predicates":[{"id":"version_file_exists_with_exact_content",
   "verdict":"pass"}],"next_action":"done"}`** in **2 iterations / 18.5 s**, economy
   `converged_predicates:1`, `cost_usd:0.116`, `tokens:39712`, enforcement active
   (`fail_on_skip`, `separate_process`), `gaming_events:[]`. Independent re-check:
   `VERSION.txt` == bytes `1.0.0\n` and `[ "$(cat VERSION.txt)" = "1.0.0" ]` exits 0
   (the drafter's rationale called this — `$( )` strips the single trailing newline,
   so exact-content holds).

**No legacy skills used.** Every action above is a first-class `kazi` CLI verb
(`plan` / `list-proposed` / `approve` / `status` / `apply`), the exact map the router
SKILL.md exposes (plan/apply/status/adopt → real CLI). `/loop`, `/apply`, `/qualify`
were not invoked at any step. The launch gate was the OBJECTIVE predicate verdict
(`pass`), not a qualify inference — the founding no-false-done thesis applied to the
operator's own on-ramp.

**SUBSUMPTION GATE (ADR-0031 decision 6) — ASSERTED.** The "`kazi apply` replaces
`/apply --pool`" claim is now made, gated as required on the E21/E23 dogfoods, which
PASSED and are re-verified live on this same v1.64.2 binary (see the entry directly
below): T21.12 (spatial parallelism — `result-contract` ∥ `health` dispatched in the
SAME millisecond, ≥2 disjoint blast-radius partitions concurrent under one
`kazi apply --parallel`, single-node, NATS-free) and T23.9 (semantic sequencing —
`streaming` waited specifically for its `needs=["result-contract"]` dep, pipelined,
objectively gated). Corroborated here on the released binary:
`kazi apply priv/examples/predicate_graph_waves.toml --explain --json` computes the
authored needs-DAG schedule — frontier 0 = two partitions `{result-contract}`,
`{health}` (concurrent); frontier 1 = `{streaming}` (gated) — `dispatched:false`,
pure planning. So for code goals the router's `kazi apply` subsumes the
loop+apply+qualify pipeline: the serial path converges a single goal to objective
done (this run), and `--parallel` runs the partitioned needs-DAG to collective
convergence (the entry below). The PR #740 release-packaging fix that made released
`--parallel` execute is bundled in v1.64.2, so the subsumption holds on the released
binary, not just in-tree.

**Honest findings (observed this session).**
- **The `[harness] command` shell-string wrapper does NOT work on the released
  binary and is not needed here.** `cli_adapter.ex` calls `System.cmd(command, args)`
  — `command` must be a single executable; a shell string like
  `bash -lc 'exec claude --dangerously-skip-permissions "$@"'` is not found
  (`:enoent`), so the harness never launches → an instant 0-token `stuck` (reproduced:
  first smoke went `stuck` in 2 s with `tokens:0`). The neighboring entry's working
  form is an executable wrapper SCRIPT file, not a flag-bearing shell string.
- **Plain `--harness claude` made real edits in this environment.** Both the
  `hello.txt` smoke (converged 2 iters / 80.6 s / $0.106, `hello.txt`==`ok`) and the
  real `VERSION.txt` apply converged with NO permission wrapper at all; kazi sets no
  `permission_mode` by default (none in `lib/`), so this is Claude Code 2.1.193's
  headless `-p` behavior in this nested session. Reported as observed; the earlier
  T30.4 "vanilla makes no edits" finding did not reproduce here for the serial
  create-mode path. The shell-string wrapper, by contrast, is strictly broken.
- **`approve` does not auto-materialize a goal-file** (unchanged from T26.8). The
  approved predicate was transcribed verbatim into `version.goal.toml` (byte-for-byte
  the drafted `cmd`/`args`) for the `apply` leg; `kazi lint` confirmed it loads. A
  future ergonomics task could let `apply` consume an approved proposal-ref directly.

**Verdict: T26.6 DONE.** The kazi skill router drove a goal end to end to objective
convergence (`VERSION.txt`==`1.0.0`, predicate `pass`) using only kazi verbs, no
legacy skills, on the released v1.64.2 binary; the subsumption claim is asserted on
the now-passing-and-live E21/E23 dogfoods (T21.12/T23.9).

## 2026-06-26 — T21.12 + T23.9 RE-VERIFIED on the FIXED released binary v1.64.2 (`--parallel` now runs end-to-end; both DONE)

Re-verification of the two parallel-scheduler dogfoods on the **released v1.64.2
macOS binary** (the bundled fix from PR #740 — see release notes: `scheduler: start
PartitionSupervisor on CLI apply --parallel path` + `partition: term-scope the
repo-map blast radius`). release-please rolled the fix INTO v1.64.2 (the release
commit `9ae2c9a` sits atop the two fix commits; tag `v1.64.2` contains
`1708f3b`/`5b21475`) rather than cutting a new patch above it, so v1.64.2 IS the
fixed binary — no separate tag was needed. Binary checksum `kazi_macos_aarch64.sha256`
verified OK; `kazi version` → `1.64.2`. Inner harness: real `claude` (Claude Code
2.1.193) via a one-line permission wrapper SCRIPT set as the goal-file `[harness]
command` (`#!/bin/bash; exec claude --dangerously-skip-permissions "$@"`). Note the
`[harness] command` override is a bare binary path passed to `System.cmd` (the
profile supplies the args), so a shell string with flags does NOT execute — it must
be an executable wrapper file. A `hello.txt` smoke converged first (2 iters,
$0.11) to confirm the wrapper grants edits. Fixture:
`priv/examples/predicate_graph_waves.toml`, run against a throwaway Go workspace
(`git init`, `go mod init`, one `main.go`), all predicates failing at t0.

**Step 1 — `--explain --json` (un-collapse, was the partitioner defect).** On the
FIXED binary frontier 0 now prints **TWO** partitions, not one:
```
frontier 0:  partition <hashA> goal_ids:["health"]
             partition <hashB> goal_ids:["result-contract"]
frontier 1:  partition <hashC> goal_ids:["streaming"]
```
The disjoint groups `result-contract` and `health` are separate blast-radius
partitions; `streaming` is gated in its own frontier behind its `needs`. This is the
exact authored needs-DAG. (On v1.64.1 this collapsed `health`+`result-contract` into
one partition.)

**Step 2 — `--parallel --json` real EXECUTION (was the `:noproc` crash).** The run
**converged, exit 0**, no `:noproc`. Group-iteration timeline from the loop log:
```
07:38:58.847  result-contract  iter=1   failing=[contract-type-defined]
07:38:58.847  health           iter=1   failing=[health-route-present]      <- SAME ms: 2 disjoint partitions CONCURRENT
07:39:19.730  result-contract  iter=2   failing=[]   (CONVERGED)
07:39:19.952  streaming        iter=1   failing=[streaming-*]               <- 0.222s AFTER result-contract converged (NOT t0)
07:39:24.103  health           iter=2   failing=[]   (CONVERGED independently)
07:39:52.626  streaming        iter=2   failing=[]   (CONVERGED)
```
Final JSON: `{"collective":"converged","blocked":[],"next_action":"done",
"schedule":[{"frontier":0,"groups":[{"group":"result-contract","state":"converged"},
{"group":"health","state":"converged"}]},{"frontier":1,"groups":[{"group":
"streaming","state":"converged"}]}]}`.

**What the timeline proves (observed, not asserted):**
- **Spatial parallelism (T21.12/ADR-0027):** `result-contract` and `health` dispatch
  in the **same millisecond** (`07:38:58.847`) — ≥2 disjoint blast-radius partitions
  converging CONCURRENTLY under ONE `kazi apply --parallel`, single-node, NATS-free,
  no external orchestrator.
- **Semantic sequencing (T23.9/ADR-0028):** `streaming` dispatches at `07:39:19.952`,
  **0.222 s after `result-contract` converged** (`07:39:19.730`) and **before
  `health` converged** (`07:39:24.103`) — so it waited SPECIFICALLY for its
  `needs=["result-contract"]` dep, pipelined per-group readiness, NOT a global wave
  barrier and NOT triggered by the unrelated `health`. Objective gate: `custom_script`
  `go test`/`grep` (ADR-0040), evidence-backed.
- **Merge:** all three real Go files landed back in the single workspace — `widget.go`
  (`type Widget struct`), `health.go` (`/healthz`), `stream.go` (a `/widgets/stream`
  handler that genuinely consumes the `Widget` type → real logical dep). The
  per-partition isolated worktrees were merged and torn down (`git worktree list` →
  only `main`).

**Verdict.** **T21.12 acc MET** — ≥2 partitions converging concurrently under one
`kazi run`, no external orchestrator, no NATS, then merged; every claim observed on
the FIXED released binary. **T23.9 acc MET** — kazi sequenced the dependent group
correctly AND parallelized the disjoint ones, gated objectively, executing the
computed needs-DAG to collective convergence ON THE RELEASED BINARY (the prior
`:noproc` blocker is gone; the earlier in-tree-only caveat no longer applies). Both
tasks DONE. Fix PR #740; released in v1.64.2. (The blocked-dep escalation contract
for T23.9 was already captured live in the prior entry's Run B.)

## 2026-06-26 — T21.12 FIX: `--parallel` PartitionSupervisor `:noproc` + partitioner collapse, both fixed

Fixes the two ship-blocking defects the T21.12 dogfood (entry below) found on the
released v1.64.1 binary. Both are repaired with small, contained changes + regression
tests; the full suite is green (2279 tests) and `mix format` is clean.

**Defect 1 — `--parallel` exits 1 with `:noproc` on the released binary (FIXED).**
Root cause: `Kazi.Application.start/2` hands straight to the CLI in the Burrito
standalone binary (`burrito_standalone?/0`) *before* the supervision tree — which
holds the named `Kazi.Scheduler.PartitionSupervisor` — is stood up. So in the
released binary that supervisor is absent and the scheduler's
`PartitionSupervisor.start_child/2` crashes with `{:noproc, {GenServer, :call,
[Kazi.Scheduler.PartitionSupervisor, ...]}}` the instant a `--parallel` run
dispatches. This is the same class as the historical "`Kazi.Repo` not started in the
burrito path" fix (`with_read_model` / `migrate_read_model`'s standalone branch).
Fix: a new `Kazi.Scheduler.PartitionSupervisor.ensure_started/1` (mirrors that
precedent) that returns the running named instance under mix/release-app
(idempotent) and starts it, process-linked to the short-lived CLI process, under the
standalone binary. The CLI parallel-apply path (`run_goal_parallel/4`) calls it
*before* dispatching. Files: `lib/kazi/scheduler/partition_supervisor.ex`,
`lib/kazi/cli.ex`. Test: `test/kazi/scheduler/partition_supervisor_test.exs`
exercises `ensure_started/1` against a fresh, not-yet-started name (simulating the
standalone path the running app tree masks) and proves `start_child/2` then works
rather than `:noproc`-ing.

**Defect 2 — disjoint groups collapse into ONE partition (FIXED).** Root cause: in a
scratch workspace there is no code-review-graph, so the blast-radius survey falls
back to `Kazi.Context.RepoMapSource`'s file-scan repo map — which is **term-blind**:
it returns the WHOLE workspace tree regardless of the evidence terms (it is meant to
be *ranked* downstream by `Kazi.Context`, not filtered). The partitioner took that
whole-tree survey as every group's blast radius, so genuinely disjoint groups
overlapped on the entire repo and merged into one partition (no spatial concurrency).
Fix: `Kazi.Partition` now SCOPES a `:repo_map`-origin survey to the paths actually
relevant to each goal's terms before taking the radius; `:graph`/`:static` surveys
are already term-scoped at the source and pass through unchanged (scoping them would
wrongly drop graph-impacted callers whose path/name need not contain the literal
term). File: `lib/kazi/partition.ex`. Tests: `test/kazi/partition_test.exs` (a
whole-tree `:repo_map` double — disjoint terms → 2 partitions, overlapping terms →
1) and `test/kazi/cli_run_schedule_explain_test.exs` (an integration `--explain
--json` over the REAL repo-map and a populated workspace, the dogfood shape: two
no-`needs` groups over disjoint files now yield TWO frontier-0 partitions). Both new
tests were confirmed to FAIL with the fix reverted.

Note (latent, not blocking T21.12): authoring explicit per-predicate
`partition_terms` is still inert — the loader routes unknown goal-file keys to
`Kazi.Predicate.config`, not a `:metadata` field, so `predicate_terms/1` never
matches and every group falls back to its group-id as its term. The dogfood relies
on that group-id fallback and now partitions correctly; making `partition_terms`
authorable is a separate enhancement. The graph path's `code-review-graph
query-graph` shell-out also targets a subcommand absent from current
code-review-graph, but it degrades to the (now term-scoped) repo-map fallback, so
partitioning is correct regardless.

**LIVE RE-VERIFY on the RELEASED binary v1.64.2 (T21.12 now PROVEN).** After PR #738
merged and release-please published v1.64.2, downloaded + checksum-verified the
macOS aarch64 binary and re-ran the dogfood — no source build, no stubs. Fixture: a
3-group `needs`-DAG in a scratch `git init` workspace (alpha, beta no-deps; gamma
`needs = ["alpha"]`), each group one `custom_script` predicate gated on a distinct
file containing `DONE`; inner harness `claude` via the proven permission wrapper
(`command` -> a `exec claude --dangerously-skip-permissions "$@"` script; confirmed
with a hello.txt smoke that converged in 2 iters). Results:
- `--explain --json`: frontier 0 = TWO disjoint partitions (`["alpha"]`, `["beta"]`),
  frontier 1 = `["gamma"]`. (On v1.64.1 the same shape collapsed to one partition.)
- `--parallel --json`: exit 0, `{"collective":"converged","next_action":"done"}`,
  schedule frontier 0 = alpha(converged) + beta(converged), frontier 1 =
  gamma(converged), `blocked: []`. **No `:noproc`.** The interleaved loop logs show
  `::alpha` and `::beta` reconciling in the SAME wall-clock window (frontier-0
  spatial concurrency) and `::gamma` dispatching only AFTER alpha converged
  (`needs` pipelining), all under ONE `kazi apply`, single-node, NATS-free, no
  external orchestrator. All three edits landed (`alpha/beta/gamma.txt` = `DONE`) —
  partitions converged and merged. The T21.12 acceptance (>=2 partitions converging
  concurrently, every claim observed) is met; T21.12 marked done.

## 2026-06-26 — T21.12 native-parallel dogfood: `--parallel` is BROKEN on the released binary (honest negative, BLOCKED)

The live dogfood for the E21/ADR-0027 native parallel scheduler (UC-037) — proving
≥2 disjoint blast-radius partitions converge **concurrently** under one `kazi apply`,
single-node and NATS-free — run against the **released v1.64.1 macOS binary** driving
the **real claude harness** (Claude Code 2.1.193). No source build, no stubs. The
proof was **not obtained**: `kazi apply --parallel` is non-functional on the released
binary, and even if it ran the partitioner collapses to one partition. Two
independent defects, both observed.

**Setup.** A scratch Go service in a throwaway `<scratch-repo>` (`git init`, `go mod
init`, one `main.go`), all predicates failing at t0. Ran the canonical fixture
`priv/examples/predicate_graph_waves.toml` (3 groups: `result-contract` ∥ `health`
disjoint, `streaming needs result-contract`) and a minimal 2-group `repair` fixture
(disjoint `alpha.go`/`beta.go`, one one-line fix each).

**Step 1 — `--explain` (compute the schedule, no dispatch): partitions COLLAPSE.**
`kazi apply <fixture> --workspace <scratch> --parallel --explain --json` printed the
two frontier-0 groups (`result-contract`, `health`) as **one** partition (a single
`partition_id`, `goal_ids: ["health","result-contract"]`), not two. Tried three
configurations — (a) the canonical fixture with no graph, (b) the same after
`code-review-graph build`, (c) a hand-built 2-file repository whose group ids match
the symbols (`alpha`/`beta`) with a graph present — **all three collapsed to one
partition**. So no spatial concurrency is even scheduled.

**Step 2 — the real run: deterministic `:noproc` crash.** `kazi apply <fixture>
--workspace <scratch> --parallel --json --harness claude` exits 1 **immediately**
(elapsed ~0s, nothing dispatched) with:

```
{"status":"error","next_action":"investigate","error":"{:noproc, {GenServer, :call,
[Kazi.Scheduler.PartitionSupervisor, {:start_child, ...}, :infinity]}}"}
```

Reproduced on **both** fixtures, every run. The `Kazi.Scheduler.PartitionSupervisor`
process is **not started** in the released burrito binary's runtime, so the
coordinator's first `start_child` fails before any partition reconciler runs. (Same
class of defect as the historical "`Kazi.Repo` not started in the burrito path" —
a process the CLI path needs is absent from the packaged supervision tree.)

**Control — the SERIAL path works.** The same 2-group `repair` fixture run WITHOUT
`--parallel` (`kazi apply ... --json --harness claude`) **converged in 2 iterations**
— both `alpha-done` and `beta-done` flipped to `pass`, cost ~$0.17. So the harness,
the read-model, and the per-goal reconciler are healthy on the released binary; the
defect is isolated to the parallel scheduler path.

**Root causes (code-confirmed against the worktree source).**
1. **`--parallel` crashes (hard blocker):** `Kazi.Scheduler.PartitionSupervisor` is
   not in the released binary's started supervision tree → `:noproc` on `start_child`.
   Nothing parallel can run until it is supervised in the CLI/burrito boot path.
2. **Partitions collapse even when run (latent):** the partitioner derives a group's
   blast-radius terms from `Kazi.Predicate.metadata.partition_terms`, but the
   `Kazi.Predicate` struct has **no `:metadata` field** (the loader routes unknown
   keys to `:config`), so `predicate_terms/1` never matches and every group falls
   back to its group-id as its only term. Those group-id terms are then surveyed
   through `Kazi.Context.RepoMapSource`, which (a) shells out to `code-review-graph
   query-graph` — a subcommand that **does not exist** in code-review-graph 2.3.1
   (only `build/update/serve/...`), so the graph path always errors and falls back to
   (b) the **file-scan repo map**, whose `files`/`symbols` lists are **term-blind**
   (they return the entire source tree regardless of the evidence terms). Identical
   radius for every group ⇒ one partition by transitive-overlap. The runbook's
   "graph stale/absent ⇒ collapse" caveat is, in practice, the only outcome
   reachable from the CLI today.

**Verdict: T21.12 BLOCKED (honest negative).** ≥2 partitions converging concurrently
was **not** observed and is **not reachable** on the released binary v1.64.1: the
`--parallel` entrypoint crashes with `:noproc` (PartitionSupervisor unstarted), and
the partitioner collapses any multi-group goal to a single partition (unauthorable
`partition_terms` + a graph shell-out to a removed subcommand + a term-blind
file-scan fallback). The parallel scheduler is well-covered by ExUnit (T21.1–T21.10
with injected stubs) but has never been exercised end-to-end through the packaged
binary — that gap is exactly what this dogfood found. Follow-ups for the operator:
(i) start `Kazi.Scheduler.PartitionSupervisor` in the CLI boot path + add a
released-binary smoke test for `--parallel`; (ii) make the graph survey term-aware
(fix the `query-graph` shell-out to match the current CLI, or filter the file-scan
fallback by terms) so disjoint groups produce disjoint radii. Task left unchecked.

## 2026-06-26 — T30.4 LIVE escalation dogfood: cheap tier converged, ladder did not climb (honest negative) + a `max_iterations=1` landmine

The live dogfood for the ADR-0035 escalate-on-stuck ladder (UC-045, UC-033),
run against the **released v1.64.1 macOS binary** driving the **real claude
harness** (Claude Code 2.1.193) — no source build, no stubs.

**Fixture (self-contained, opaque, non-gameable).** A `custom_script` goal whose
predicate runs a candidate `solution.py` and compares the **sha256** of its
printed integer to a stored digest. The hash is one-way, so the oracle yields
only pass/fail and leaks nothing — the model cannot game it by reading the
checker; it must compute the value. The problem (chosen non-memorizable, not the
famous Project-Euler bound): the sum of every `n` with `1 ≤ n < 1_000_000` that is
a palindrome simultaneously in base 10, base 2, AND base 8 (no leading zeros) —
answer `610`. Multi-step base conversion is an honest correctness trap.

**Ladder (per AGENTS.md / ADR-0035):** `claude-haiku-4-5 → claude-sonnet-4-6 →
claude-opus-4-8`, each rung one `kazi apply --harness claude --model <rung> --json`
on the same slice; escalate when `status` is `stuck`/`over_budget`.

**Released-CLI gap found before the run.** `kazi apply` exposes no
`--permission-mode`/`--allowed-tools` flag, and the goal-file `[harness]` table
accepts only `id`/`model`/`command`. With the default permission mode the inner
`claude` runs non-interactively and **applies zero edits** — a first probe ran
two Haiku iterations, spent $0.112, and wrote no file (terminal
`status: over_budget`, predicate still `fail`). To grant the inner agent the
file-edit permission the recipe assumes (the T19.7 repro used
`permission_mode: :bypassPermissions`), the run set `[harness] command` to a
one-line wrapper (`exec claude --dangerously-skip-permissions "$@"`). With that,
a trivial `hello.txt` smoke converged ($0.049). **Follow-up:** surface
`permission_mode` on the released CLI (or default it for the claude harness),
else a vanilla `kazi apply --harness claude` makes no edits and every code goal
terminates `over_budget`.

**Run A — the real escalation attempt (`max_iterations = 2` per rung).**

```
kazi apply ./goal.toml --workspace ./ws --harness claude --model claude-haiku-4-5 --json
```

Rung 1 (Haiku) terminal result: `status: converged`, predicate `pass`,
`iterations: 2`, `cost_usd: 0.0768584`, `wall_clock_s: 39.3`. The iteration
trace is `iter=1 failing=[…] → iter=2 failing=[]`: Haiku got the first dispatch
wrong, self-corrected on the second, and converged. The written `solution.py`
was independently verified to print `610` (oracle exit 0). **The ladder never
advanced past rung 1 — escalation did NOT fire, and was not needed.**

This reproduces the T19.7 / T36.5 finding on a fresh, harder, opaque-oracle
fixture via the released binary: a self-verifying inner harness (bash + the
predicate oracle across iterations) converges a within-reach slice on the
cheapest tier, so the model-escalation ladder rarely climbs in practice. A
genuine capability-driven climb was **not observed and not manufactured** — the
opaque sha256 oracle plus the honesty bar preclude staging a fake stall.

**Run B — a `max_iterations = 1` probe surfaced a loop-accounting landmine.**
Rerun with a one-dispatch budget, rung 1 (Haiku) reported `status: over_budget`,
`next_action: raise_budget`, `budget_spent.exceeded: "max_iterations"`, predicate
`fail` — i.e. exactly the ladder's escalation trigger. **But the `solution.py`
Haiku wrote in that single dispatch already printed `610` (correct).** Haiku
*solved* it; the `over_budget` is an artifact: kazi's observe→act loop needs a
**final re-observation after the last action** to record the pass, and
`max_iterations = 1` spends its only iteration on the act, terminating with the
*pre-dispatch* failing vector. **Landmine:** `max_iterations = 1` can never
converge any goal, and a one-dispatch budget over-reports "stuck". An
`over_budget`/`stuck` result must be read **together with the predicate vector /
real state**, never as standalone proof the model failed — and an escalation
recipe must give each rung at least 2 iterations (act + confirm). Escalating the
model here would have been escalating against a budget artifact, not a capability
limit, so it was not done.

**Cost (every figure from a captured `cost_usd` envelope).** Auth/permission
probes ≈ $0.21 (incl. the $0.112 no-edit probe and the $0.049 smoke); Run A
$0.0769; Run B rung 1 $0.0788. **Total observed ≈ $0.37**, far under any ceiling
(the fixture is deliberately tiny).

**Verdict (honest).** The escalation **trigger signal** is live-verified
sufficient on the released binary: a non-converged rung emits
`status`/`next_action`/`budget_spent.exceeded` + the failing `predicates[]`
exactly as ADR-0035 / T30.3 specify, and rung dispatch on the released binary
works. The **model-escalation ladder did not climb**, because the cheap tier
(Haiku) converged unaided — a truthfully-reported negative, which the T30.4
acceptance explicitly permits. The ladder's climb logic remains pinned by
T19.7's worst-case row + the `Kazi.Context.Escalation` unit tests; a live
capability-driven climb needs a slice genuinely beyond the cheap tier's reach,
which a self-verifying harness rarely yields and which was not gamed here.

## 2026-06-26 — T35.10 context-store dogfood → VERDICT: KEEP OPT-IN (do NOT promote to default)

LIVE dogfood of the `--context-store gist` store (ADR-0045 / E35) on the released
**v1.64.1** binary, driving the **claude** harness on real multi-iteration goals
in scratch git workspaces, with a real PostgreSQL-backed `gist` provider
(`gist v1.0.1`, `pg_trgm` available, a local Postgres in a container). Every
number below is OBSERVED from `apply --json` or `context --json`, not asserted.

**Headline: the integrated store path did not engage on any real `apply` run, so
the run-result `indexed→returned` ratio is unobservable on the shipped binary.**
The promote bar (a measured ratio from the released binary) is therefore not met.

### What was run (4 real `apply` runs, claude harness, scratch workspaces)

Two goals, each run WITH and WITHOUT `--context-store gist --context-budget 6000`.
The checkers are `custom_script` predicates that print an ~11.4 KB failure log
until a marker file is created; the harness creates the marker and converges.

| run | store | status | iters | converged preds | cost_usd | cost/conv-pred | tokens | `context_store` object |
|---|---|---|---|---|---|---|---|---|
| 1-pred converge | off | converged | 2 | 1 | 0.1554 | 0.1554 | 61705 | **absent** |
| 1-pred converge | gist | converged | 2 | 1 | 0.0728 | 0.0728 | 64066 | **absent** |
| 2-pred converge | off | converged | 2 | 2 | 0.1398 | 0.0699 | 78692 | **absent** |
| 2-pred converge | gist | converged | 2 | 2 | 0.2309 | 0.1155 | 76825 | **absent** |

- **No `context_store` object** appears in `apply --json` on ANY store run.
- **Zero rows** were written to the gist Postgres DB during these runs (sources
  count stayed 0 after a `TRUNCATE`), even though the 2-predicate run's combined
  failing evidence inspects to **8411 bytes** — above the `@context_store_threshold`
  of 5120 that should trigger `compress_evidence/4` (`lib/kazi/loop.ex`). The store
  branch never executed.
- The with/without cost spread (0.0728↔0.2309) is **claude prompt-cache
  nondeterminism** (cached-read tokens varied run-to-run), NOT a store effect — the
  store did not run, so there is no real cost delta to attribute to it.

### The one signal that IS real: the provider budget-fits when called directly

Exercising the same provider through `kazi context index|search` (the T35.7 wrapper)
DOES persist and retrieve. Indexed the 11444-byte log (3 chunks), then searched:

| query | budget | returned bytes | ratio | reduction |
|---|---|---|---|---|
| "assertion failed marker" | 2000 / 6000 | 691 | 16.6:1 | 94.0% |
| "BUILD FAILURE LOG assertion" | 2000 / 6000 | 229 | 50.0:1 | 98.0% |
| "stack frame module" | 2000 / 6000 | 0 | n/a | lexical miss (0 results) |

So the gist provider's budget-fitting is real (94–98% reduction on a matching
query) but **query-sensitive** — the returned bytes are the matching chunk(s), well
under budget, and some queries return nothing. This is provider behavior, not the
integrated-loop measurement the task requires.

### Two structural gaps found (root causes, observed)

1. **`gist stats` reports zeros regardless of DB contents.** The installed gist
   build's `stats` (CLI) returns per-process/in-memory counters — `Bytes indexed: 0`,
   `Sources: 0` even immediately after a successful `index` that demonstrably wrote
   rows. kazi's `context_store` accounting object parses `gist stats`
   (`Kazi.ContextStore.GistCLI.stats/1` → `attach_context_store_stats/2` in
   `lib/kazi/cli.ex`), so even on a run where the loop DID index, the run-result
   `indexed_bytes/returned_bytes/saved_bytes` would read 0/0/0. The accounting
   surface is blind on this gist build.
2. **Evidence cap (4000) < store threshold (5120).** Every evidence provider caps
   its `:output` at `@output_limit = 4_000` (`custom_script`, `static`, `mutation`,
   `property`, `cve`), below the loop's `@context_store_threshold = 5_120`. A single
   failing predicate can therefore never cross the threshold; only a multi-predicate
   failing set can — and even the 8411-byte 2-predicate case did not engage the
   store on v1.64.1 (see headline). v1.64.1 DOES contain the T35.5 wiring
   (`19bb14d`, confirmed `git merge-base --is-ancestor`), so this is a real
   behavioral gap, not a missing release.

### Verdict — KEEP OPT-IN; do NOT promote to default

The ADR-0046 bar is "every number observed, not asserted." On the released binary
the integrated store produces **no observable `indexed→returned` ratio** (no
`context_store` object; nothing indexed during real `apply` runs), and the
accounting that would surface it (`gist stats`) reports zeros. There is no measured
ratio to "hold," so promotion to default is unjustified — a default-on store that
silently never engages is strictly worse than an honest opt-in. The store also
requires external Postgres + gist setup, which on its own argues against default-on.
The only positive evidence is provider-level budget-fitting (94–98% on one
artifact), which is real but not the loop measurement.

Recommended follow-ups (not done here; this task is measure + verdict only):
diagnose why `apply --context-store gist` does not engage the store on a
threshold-crossing run (no `context_store` object emitted, zero rows indexed);
lower `@context_store_threshold` below the 4000 provider cap (or raise the cap) so a
single oversized predicate can engage; and replace the per-process `gist stats`
read with DB-backed accounting so the run-result ratio is observable.

## 2026-06-25 — T16.6 LIVE: the installed kazi skill drives a goal end to end (plan → approve → apply) on released v1.46.2

The closing live proof for T16.6 (UC-034): a Claude Code user who runs
`kazi install-skill` gets a skill that drives kazi to convergence with **no
further instruction**. Exercised against the **released v1.46.2 macOS binary**
driving the **real claude harness** — no source build, no stubs.

**Step 1 — install the skill (non-invasive).** `kazi install-skill --dir
<scratch>` writes exactly ONE file, `SKILL.md`, into the target dir (the `--dir`
flag is the documented test/scratch injection point; default is the global
skills dir, left untouched here).

**Step 2 — verify the installed skill teaches the CURRENT surface.** Read the
generated `SKILL.md` and cross-checked every `kazi <cmd>` it names against `kazi
help --json`:
- It routes the four current verbs — `plan` (author predicates), `apply`
  (the reconcile loop), `status` (read state), `adopt` → `kazi init` — plus
  `approve` / `reject` / `list-proposed`, all REAL commands.
- It explicitly states the legacy verbs `run`/`propose` were REMOVED and to use
  `apply`/`plan`; it does NOT instruct the agent to run a removed verb as a live
  command.
- It carries the full `plan → approve → apply` recipe, the two-tier economics,
  the escalation ladder, and a "confirm the live surface with `kazi help --json`"
  instruction — enough for an agent to drive a goal with no other guidance.
  VERDICT: the skill content is correct and current.
- One drift FINDING (not in the skill file): the `install-skill` **stdout
  banner** the binary prints after writing still reads "propose --json → approve
  --json → run --harness <cheap>" — the removed verbs. Cosmetic (an agent reads
  `SKILL.md`, not the banner), but it should be updated to `plan → approve →
  apply` for honesty. Logged for a follow-up.

**Step 3 — drive a fixture goal following ONLY the skill's flow.**
1. `kazi plan "create a file named hello.txt … exact contents … Hello, kazi!"
   --workspace <ws> --yes --json` → drafted a proposal
   (`prop-create-a-file-named-hello-txt-…`) with **1 usable `custom_script`
   predicate**: `cmd="sh"`, `args=["-c","printf 'Hello, kazi!\n' | diff -
   hello.txt"]`, `verdict=exit_zero`. The prose on-ramp parsed cleanly — NO
   "proposal is not valid JSON" error (the T26.8 fix is live on v1.46.2).
2. `kazi approve <ref> --json` → `{"status":"approved"}`.
3. Transcribed the approved predicate verbatim into a create-mode goal-file
   (`mode="create"`, the predicate byte-for-byte), then `kazi apply <goal-file>
   --workspace <ws> --harness claude --json` → **`status: converged`** in **2
   iterations / 16.2s**, predicate `verdict: pass`. Workspace artifact
   `hello.txt` == bytes `Hello, kazi!\n` (13 bytes), exactly the predicate.
   `economy`: 1 converged predicate, $0.17, 39,079 tokens.
4. `kazi status create-a-file-named-hello-txt --json` → `kind:run,
   converged:true` — the read-model reflects the run. All four skill verbs
   exercised green.

**Verdict: the dogfood PASSES for a user on the released binary.** T16.6 → `[x]`.

**Two honest caveats.**
1. A freshly-installed skill registers for a NEW Claude Code session; this
   verification followed the skill's documented flow with the released v1.46.2
   binary by hand, which is the faithful equivalent of an agent reading that
   skill and driving the same commands — not a screenshot of a separate session.
2. **The stale Homebrew tap is the residual gate for `brew install` users.**
   `brew install kazi-org/tap/kazi` currently ships **1.41.1**, which has the
   BROKEN prose on-ramp (the `kazi plan` JSON-parse bug fixed in T26.8 and
   shipped in v1.46.x). So a brew-install user who runs `install-skill` and
   follows the skill TODAY fails at the very first step (`plan`) until the tap
   is bumped to ≥1.46.2. The skill itself is correct and version-agnostic; the
   gate is the packaged binary, not the skill. Bumping the tap on release is the
   outstanding fix (see `docs/lore.md` L-0019).

Note: T16.6's plan-line acceptance text predates the verb rename and reads
"propose → approve → run"; the real, current flow is **plan → approve → apply**
(`kazi help --json`), which is what was driven here.

## 2026-06-26 — T26.8 LIVE VERIFIED: the full `plan → approve → apply` on-ramp converges on released v1.46.2

The closing live proof for T26.8. Both code fixes (L2 harness-parse PR #634/v1.46.1,
L3 drafting-prompt schema PR #638/v1.46.2) were exercised end to end against the
**released v1.46.2 macOS binary** driving the **real claude harness** — no source
build, no stubs.

**The chain.**
1. `kazi plan "Create a file named status.txt in the workspace whose contents are
   exactly the text: ready" --yes --json` → drafted a proposal
   (`prop-create-a-file-named-status-txt-…`) with **1 usable `custom_script`
   predicate** whose config keys are the canonical `cmd` / `args` / `verdict` /
   `pass_codes` — `cmd="sh"`, `args=["-c","test -f status.txt && printf '%s' ready |
   cmp -s - status.txt"]`. No invented `script`/`interpreter`. (Pre-fix this returned
   "proposal has no predicates".)
2. `kazi approve <ref>` → `{"status":"approved"}` — the goal LOADS through the same
   loader `approve` uses. (Pre-L3-fix this failed: `requires a non-empty string "cmd"`.)
3. `kazi apply <goal-file> --harness claude` → **`status: converged`** in **2
   iterations / 14.9s**, predicate `verdict: pass`, and `status.txt` == bytes `ready`
   (5 bytes, no trailing newline). `economy`: 1 converged predicate, $0.159, 39,947
   tokens.

**One honest gap noted (not a T26.8 blocker).** `approve` does NOT auto-materialize a
goal-file; the operator captures the approved predicates "as a file you can version
and re-run" (README's documented step — `approve`'s own output says "The goal is now
runnable: kazi apply <goal-file>"). For this verify the goal-file was the approved
predicate transcribed verbatim (byte-for-byte the drafted `cmd` config), so the
chain proven is faithful. A future ergonomics task could let `kazi apply` consume an
approved proposal-ref directly (or have `approve --out goal.toml` write the file),
removing the manual transcription. Filed as an observation, not part of T26.8.

T26.8 is now `[x]`. This unblocks T16.6 (Claude Code drives kazi via the skill) and
T26.6 (live subsumption gate), both of which depended on a working prose on-ramp.

## 2026-06-25 — T26.8 layer 2: the drafted custom_script config SHAPE blocks `approve` (invented `script`, not `cmd`)

PR #634 fixed the harness PARSE layer (claude's stderr warning broke the envelope —
see the entry below). A LIVE run on the RELEASED v1.46.1 binary then exposed the
NEXT layer of the same "drafted-proposal SHAPE" bug — one step past parsing.

**The live symptom.** On v1.46.1, `kazi plan "Create a file named greeting.txt …
contents exactly: hello world" --yes --json` now SUCCEEDS at drafting and returns a
proposal with a predicate (the parse fix works). But `kazi approve <ref>` then FAILS:

    could not approve …: the stored goal no longer loads: "custom_script predicate
    \"greeting_file_exists_with_exact_contents\" requires a non-empty string \"cmd\""

**Root cause.** The drafting harness (claude), told only the provider NAMES, GUESSES
each predicate's `config` shape — and guesses wrong. It drafted a `custom_script`
config with an INVENTED shell-script shape:
`{"script": "<bash>", "interpreter": "bash", "working_dir": ".", "expected_exit_code": 0}`.
But kazi's REAL `custom_script` schema (what `kazi schema custom_script` prints,
sourced from `Kazi.Predicate.Schema`) requires `cmd` (ONE executable) plus optional
`args`/`verdict`/`env`/… — there is NO `script`/`interpreter`/`working_dir`/
`expected_exit_code`. So every drafted `custom_script` predicate is structurally
invalid and the on-ramp dies at `approve` (the loader validates `cmd` at load).
The captured fixture `test/fixtures/harness/claude_authoring_draft_stdout.txt` shows
this exact invented shape across all three of its `custom_script` predicates.

**The fix (option (a): pin the prompt).** `Kazi.Authoring.build_prompt/2` now EMBEDS
the authoritative per-provider config contract, rendered straight from
`Kazi.Predicate.Schema` (the SAME single source `kazi schema <provider>` prints — no
hand-duplicated field list to drift). Each documented provider gets its required/
optional keys (required marked `*required*`) plus the schema's own example config,
and `custom_script` gets an explicit pin: MUST use `cmd` (put a shell line in
`cmd:"sh", args:["-c","<line>"]`), MUST NOT use `script`/`interpreter`/`working_dir`/
`expected_exit_code`. Prompt-first (not decoder-aliasing) so the harness emits VALID
configs at the source. Confirmed: a drafted `custom_script` predicate using `cmd` now
LOADS through the same loader `approve` uses (no "requires a non-empty string cmd").

**Tests.** `authoring_test.exs`: a `cmd`-shaped `custom_script` parse → serialize →
`Loader.from_map` LOADS (Tier-0); a stub draft in the fixed shape `propose`s and the
persisted goal LOADS end-to-end (Tier-2); `build_prompt/2` output contains the
`custom_script` contract (`cmd … *required*`) and forbids `script`. Full suite green.

**Remaining gate.** Live re-verify on the RELEASED binary — `kazi plan "<idea>"` →
`kazi approve <ref>` → `kazi apply` converges — is a POST-RELEASE step (this fix must
merge + release first). T26.8 stays `[ ]` until that live chain is observed.

## 2026-06-25 — T26.8 ROOT CAUSE found by live capture: claude's stderr warning broke the envelope parse, not the proposal shape

Built kazi from source and drove ONE real `claude -p --output-format json` authoring
draft (idea: "a CLI tool that prints the current git branch name") to capture the
exact bytes, instead of guessing the shape. The capture overturns the prior
hypothesis (PR #623 assumed a proposal-SHAPE problem and added `goal`/`proposal`/
`spec` wrapper-key parsing). The real bug is one layer DOWN, in the harness adapter.

**What real claude returns.** The adapter result map was
`%{exit: 0, command: "claude", output: <stdout>, workspace: "."}` — NO `:result`,
NO `:tokens`, NO `:cost_usd`. The `output` was:

1. a leading line on STDERR — `Warning: no stdin data received in 3s, proceeding
   without it. ...` (claude waits 3s for stdin under `System.cmd`, then warns), which
   the adapter merges into stdout via `cmd_opts`'s `stderr_to_stdout: true`; then
2. the normal `{"type":"result", ..., "result":"<the proposal JSON as a string>", ...,
   "usage":{...}, "total_cost_usd":...}` envelope.

**Why authoring failed.** `Kazi.Harness.Profiles.Claude.parse/1` did
`Jason.decode(output)` on the WHOLE stdout. The warning prefix made that decode fail,
so `parse/1` returned `%{}` and the adapter merged NOTHING — dropping `:result`,
`:tokens`, `:cost_usd`, `:usage` on every run that hit the warning. With no `:result`,
authoring's `proposal_payload/1` fell back to the raw `:output`, whose first-`{`..last-`}`
span is the OUTER envelope object (`type`/`result`/`usage` keys) — no top-level
`predicates` — so `build_predicates` reported "proposal has no predicates". PR #623's
wrapper keys never matched because the real wrapper key is `result` and its value is a
JSON STRING, not a nested map. This also explains why `kazi apply` "works" while
`kazi plan` doesn't: apply re-runs predicates to judge done and lets the budget fall
back to a token ESTIMATE (ADR-0008), so the dropped `:result`/token fields are
invisible there; authoring is the only path that needs the structured `:result`.

**The fix (one line of behavior).** `Claude.parse/1` now narrows to the JSON object
span (first `{` .. last `}`) BEFORE `Jason.decode`, so a stderr-noise-prefixed
envelope still parses. A clean envelope is byte-identical (the span IS the whole
object — golden conformance unchanged); output with no braces or genuinely malformed
JSON still degrades to `%{}`. This restores `:result` (→ authoring builds the goal)
AND `:tokens`/`:cost_usd` (→ token/cost accounting, silently broken before whenever the
warning appeared). No change to the authoring parser or the drafting prompt was needed;
PR #623's speculative wrapper-key code is left in place as harmless defense-in-depth.

**Verified against real bytes (source build).** The captured stdout is checked in as
`test/fixtures/harness/claude_authoring_draft_stdout.txt`. Re-running the fixed
`Profile.parse(:claude, <real bytes>)` yields `:result` + `:tokens` + `:cost_usd`, and
`Kazi.Authoring.parse_proposal/2` on the recovered `:result` builds **6 acceptance
predicates** (`custom_script`×3, `test_runner`, `coverage`, `static`) — the
`custom_script` predicates survive (the E32 provider map, already fixed in PR #623 by
delegating to `Loader.provider_kinds/0`, is confirmed correct). Tests:
`conformance_test.exs` pins the noise-prefixed real-envelope parse;
`authoring_test.exs` drives `propose/2` through a stub returning the real adapter
result and asserts ≥1 predicate incl. `custom_script`.

**Remaining gate.** Live verify on the RELEASED binary — the full `kazi plan "<idea>"`
→ `kazi approve <ref>` → `kazi apply` chain — is a POST-RELEASE step (this fix must
merge + release first). Pre-merge verification was done against the source build on
real claude bytes as above.

## 2026-06-25 — LIVE dogfood frontier is headless-unblockable; T26.8 prose-drafting still broken live

A headless `/apply --pool` session checked whether the remaining LIVE dogfood tasks
are operator-only or actually drivable from a non-interactive session, using the
`claude` CLI harness (v2.1.193) + the RELEASED binary `kazi v1.45.0` (downloaded
from the GH release, sha-verified) + agent-browser.

**Core enabler PROVEN (real reconcile).** Authored a minimal create-mode goal — one
`custom_script` predicate, `bash -c 'test -f hello.txt && [ "$(cat hello.txt)" = ok ]'`,
`verdict = exit_zero`, failing at t0 (no file). `kazi apply <goal> --workspace <ws>
--harness claude --json` converged in **2 iterations / 15.3s**: iter1 vector `fail`
(exit 1) → claude harness created `hello.txt` → iter2 `pass` (exit 0) →
`{"status":"converged","iterations":2,...}`, `enforcement.active=true`,
`gaming_events=[]`. `hello.txt` verified = `6f6b` (`ok`, 2 bytes, no newline). So the
goal-file → claude → objective-true loop runs fully headless on the released binary.
That unblocks the goal-file dogfoods (T20.11, T21.12, T23.9, T30.4, T31.7, T32.11,
T35.10) and — with the LiveView feature built + agent-browser — the dashboard tasks
(T20.8, T21.9) and the live-site leg of T25.10.

**T26.8 LIVE FINDING — the prose on-ramp is still broken.** Drove `kazi plan "<idea>"`
on v1.45.0 (which contains PR #623). `--json` returns a STRUCTURED clarification
request (`missing: live-target, scope` — progress over the old raw parse error), but
`--yes` best-effort STILL returns `{"error":"... proposal has no predicates"}`. So
PR #623's robust-to-multiple-shapes parser does NOT match what real claude actually
emits — exactly the risk the fixer flagged (it had no live capture and guessed). The
real fix per the original T26.8 recipe: source build + a temporary `IO.inspect` in
`Kazi.Authoring.drive_harness` (authoring.ex:405) to capture ONE raw claude draft,
then parse THAT shape (or pin it via the drafting prompt). T26.8 stays `[ ]`; it also
blocks T16.6/T26.6. Plan updated (master Progress Log + E26.md T26.8 note) so other
sessions claim the now-unblocked dogfoods and avoid re-deferring them as "operator-only".

## 2026-06-25 — Doc-lifecycle encoded as a kazi standing goal (T31.6 / ADR-0036)

Shipped `priv/examples/doc_lifecycle.goal.toml`: the ADR-0036 documentation
lifecycle expressed as a committed kazi STANDING goal-file kazi can reconcile,
built ENTIRELY on the E32 generic providers — no bespoke predicate engine and no
doc-specific code in kazi core (the ADR-0036 reject held).

Predicate composition: six doc-freshness checks are `custom_script` predicates
(ADR-0040) WRAPPING the T31.4 scripts — `check_a/b/c/d` plus the subsumed (E)
README↔site and (F) skill↔CLI coherence checks — each with `verdict = "exit_zero"`
since the checker's exit code already means pass/fail. Two GRADIENTS are `ratchet`
predicates (ADR-0041 envelope-v2): a doc-coverage ratchet (% commands documented,
`higher_better`, baseline `stored`) and a stale-`[x]`-task count ratchet (to `0`,
`lower_better`). The two ratchet metrics are thin new wrapper scripts
(`metric_doc_coverage.sh`, `metric_stale_tasks.sh`) reading the SAME command
surface / offender set as predicates (a)/(d), each printing one bare number to
stdout. An `[enforcement]` block (ADR-0042) marks the checkers + lifecycle tools
`read_only_paths` so an agent can't edit a grader to fake a green.

Landmine re-confirmed (L-0012 sibling): a bare relative `cmd` like
`.github/scripts/...sh` is NOT runnable — `System.cmd` resolves the executable
against PATH, not the workspace, so it fails `:enoent`. Fix: `cmd = "bash"`,
checker in `args` (bash resolves the script arg against `--workspace`). Verified
empirically before settling the format.

Validation (headless bar = load + predicate-eval, no live multi-minute reconcile):
`test/kazi/goal/doc_lifecycle_goal_test.exs` pins load-as-standing, the 6+2 kind
composition (no other kinds), zero-stub (every wrapper points at a real script),
and a real `:pass`/`:fail` (never `:error`) eval. Manual full-vector eval today:
`adr-refs-exist`, `readme-site-coherence`, `skill-cli-coherence`, and
`doc-coverage-ratchet` (score 66.7) PASS; `plan-trimmed`, `commands-in-readme`,
`no-dead-command-refs`, and `stale-tasks-ratchet` (score 121) FAIL — exactly the
drift on main today that the live dogfood (T31.7) drives to green. Layers wired:
1 (trim, auto) + 3 (freshness, auto) auto, 2 (extract, human-confirm) keeps its
gate.

## 2026-06-25 — Gated knowledge extraction shipped (T31.3 / ADR-0036 Layer 2)

Shipped `.github/scripts/extract_knowledge.py` + `test_extract_knowledge.py`, the
Layer-2 propose-then-confirm pass that composes AFTER T31.2's `trim_plan.py`.
Once `trim_plan.py --apply` archives a fully-done, released epic verbatim under
`docs/plans/archive/`, `extract_knowledge.py --latest` (or `--epic <file>`) reads
that archived block, finds the durable nuggets, and routes each to its tier per the
ADR-0036 map: invariant/landmine -> `lore.md` (next `L-NNNN`), finding/benchmark ->
`devlog.md` (dated, newest-first), decision -> a NEW `docs/adr/NNNN-*.md` with
`Status: Proposed`, architecture -> `concept.md` (NOT design.md). Nuggets are found
by explicit `Nugget(<class>):` annotations, class hashtags, or a keyword heuristic.

Two invariants make it the safe LLM-shaped step: it NEVER writes to or removes from
the archive (so the archive is the lossless backstop — a mis-route loses no
knowledge), and it dry-runs by default, printing the routing for review; `--apply`
is the human-confirm gate. Each written edit carries a `kx:<sig>` provenance marker,
so re-running is idempotent. Wired the fixture test into `oss-gates.yml` alongside
`test_trim_plan.py` (report-only; CI never auto-writes docs). Together T31.2 (trim,
lossless, mechanical) + T31.3 (extract, gated, lossless backstop) are Layers 1+2 of
the ADR-0036 doc lifecycle; T31.6 will drive both as a kazi standing goal.

## 2026-06-25 — T26.8: `kazi plan` drafted-proposal SHAPE made robust + E32 providers mapped (PR #623, live-verify deferred)

Worked T26.8 under `/apply --pool` (headless). The on-ramp step-1 blocker after
T26.7: a drafted proposal PARSES, but `build_predicates` reported "proposal has no
predicates" because the predicate array wasn't at the documented top level.

**Diagnosis (two distinct gaps).**
  1. *Shape.* `parse_proposal/2` read only the top-level plural `"predicates"` key.
     Real claude routinely returns the goal nested under a wrapper
     (`{"goal": {…}}` / `"proposal"` / `"spec"`) or as a goal-file-shaped object
     using the singular `"predicate"` array — so `Map.get(map, "predicates")` was
     `nil` and `build_predicates(nil)` → "proposal has no predicates".
  2. *Provider catalog.* Authoring kept its OWN 4-entry `@provider_kinds`
     (`test_runner`/`http_probe`/`prod_log`/`browser`) that omitted the entire E32
     catalog, so a drafted/caller predicate naming `custom_script` (or `static`,
     `ratchet`, `metrics`, `coverage`, `property`, `mutation`, `cve`) was dropped by
     `provider_kind/1` → "no usable predicate in proposal".

**Approach: robust-to-multiple-shapes (NOT a live-captured shape).** Headless, so a
multi-minute live `claude` capture wasn't reliable; per the task's sanctioned
fallback the parser was made robust to the plausible shapes (a durable fix
regardless of which exact shape claude emits):
  - `unwrap_proposal/1` descends into a single `goal`/`proposal`/`spec` wrapper when
    the top level carries no predicate array;
  - `extract_predicates/1` accepts both the plural `"predicates"` and the goal-file
    singular `"predicate"` array;
  - `predicate_config_source/1` takes config from a nested `"config"` map, else
    collects the non-reserved sibling keys (the goal-file convention) so that
    shape's config survives;
  - provider mapping now defers to `Kazi.Goal.Loader.provider_kinds/0` — newly
    exposed as the single source of truth — so the loader's full catalog is
    recognised and the two catalogs cannot drift again. Malformed input still
    errors cleanly.

**Validation.** `mix compile --warnings-as-errors` + `mix format --check-formatted`
clean; `authoring_test.exs` 38 passed (6 new fixtures: wrapper-nested,
goal-file-singular with sibling config, custom_script survival, wrapped+modern
combo); full suite 2240 passed (the lone foreground failure was the known
timing-flaky `Scheduler.SupervisionTest`, greens on re-run).

**REMAINING GATE (why T26.8 stays `[ ]`).** The acceptance still requires LIVE
verification on the released binary — `kazi plan "<idea>"` → `kazi approve <ref>` →
`kazi apply` converges (the full chain, which also unblocks T27.8). A headless agent
cannot cut a release or drive a live multi-minute claude session, so that leg is
DEFERRED to a live session. The code/tests/docs landed; the live verify did not.

## 2026-06-25 — Session handover: release/tap pipeline fixed live; `kazi plan` drafting half-fixed (T26.7 done, T26.8 next)

Long `/apply --pool` + operator-directed session. Shipped + verified live this session:

- **E32 wave** (predicate catalog / evidence-v2): T32.1b through T32.10 shipped + released; plan marked.
- **Docs/site reframed to the human -> Claude -> kazi -> Claude on-ramp**: README, website (live), `concept.md` Section 0, the GitHub repo description, and the page `<title>`/OG meta -- all lead with the benefit ("you never run kazi yourself; Claude does"); "the outer/reconciliation loop for coding agents" demoted to an under-the-hood note (kept for SEO/coherence). Fixed 9 Astro newline-stripping spacing bugs (the `Afterkazi` class -- text on one line + an inline `<code>`/`<strong>` on the next loses the space; fix with an explicit `{" "}`). Removed the unexplained Context7 analogy from user-facing copy. All verified on https://kazi.sire.run.
- **RELEASE/TAP PIPELINE fixed end to end (the headline).** Root cause: the Burrito binary boots the CLI before supervising `Kazi.Repo`, and `migrate_read_model` (standalone branch) used `Ecto.Migrator.with_repo` -- migrate-then-STOP -- so the read-model was never left running. Every read-model command crashed the binary ("could not lookup Ecto repo Kazi.Repo because it was not started"): `kazi status`/`list-proposed`/`approve` AND the `kazi mcp` `kazi_status` tool. The T33.4 MCP release-smoke calls `kazi_status` BEFORE asset upload, so it failed on EVERY release since the smoke landed -> 0 binaries since v1.20.0 -> `brew install` frozen at the broken 1.20.0. Fix: PR #613 (start + KEEP the repo running in the standalone branch), released v1.41.1; the chain self-healed (build smoke passed, `tap-bump` auto-pushed the formula -- `HOMEBREW_TAP_TOKEN` was configured all along; the chain had been FAILING on the smoke, not skipping). Also added PR #611 (a `workflow_dispatch` manual build trigger as a recovery hatch). `brew upgrade` -> 1.41.x VERIFIED: `status`/`list-proposed`/`mcp` no longer crash.
- **`kazi plan` drafting -- JSON layer (T26.7, PR #617):** `decode_proposal/1` now extracts the JSON object from fenced/prose harness output before `Jason.decode`. Merged + 2 Tier-2 tests.

**OPEN THREAD -> T26.8 (epic E26).** `kazi plan "<idea>"` still fails end to end: after T26.7 the harness output PARSES but has no usable top-level `predicates` array ("proposal has no predicates"). `kazi apply <goal-file>` works; only prose-idea DRAFTING is broken. Next-step recipe:
  1. Capture ONE raw `claude` draft. It drives a MULTI-MINUTE claude session, so do NOT cap at 3 min (the diagnostic timed out) -- use a >=10-min timeout or a background run. Tee the harness result with a temporary `IO.inspect` in `Kazi.Authoring.drive_harness` (lib/kazi/authoring.ex:405; REVERT after).
  2. Compare claude's actual shape against the expected `{name, predicates:[{id, provider, description, config}], rationale}` (`build_prompt/2`, authoring.ex:366).
  3. Fix the smaller of: tighten the drafting PROMPT to pin the shape, or make `build_predicates`/`decode_proposal` accept what claude emits.
  4. Also map the E32 providers (`custom_script`/`:static`/...) into authoring `provider_kind` (currently omitted -> a drafted predicate naming one is silently dropped).
  5. Verify LIVE on the released binary: `kazi plan "<idea>"` -> `kazi approve <ref>` -> `kazi apply` converges (this also unblocks T27.8's blocked plan->approve leg).

Durable details are in memory: `kazi-plan-drafting-broken`, `homebrew-tap-stale-readmodel-crash`, `adoption-docs-consolidated-e25`.

## 2026-06-25 — context-tier + tool-surface benchmark (T36.5): surface ON is a real ~2× token win; the tier knob is net-neutral on a within-reach fixture

The two inner-harness knobs ADR-0047 gave kazi — the context TIER
(`Kazi.Context.Tier` 0–4: how MUCH context a dispatch assembles, T36.3) and the
tool-SURFACE (`Kazi.Harness.DispatchSurface` `:minimal`/on vs `:ambient`/off: how
many tool/MCP schemas the harness loads, T36.2) — measured LIVE so the defaults
are set from data, not a guess (T36.5, ADR-0047; verifies UC-033). Four arms run
the REAL `Kazi.Runtime.run` loop over ONE tiny self-contained fixture (a
`custom_script` predicate: `solution.py` must print the sum of the first 10 primes
= 129; a stub prints `0` and fails at t0), driving a cheap model (Haiku 4.5)
through a capture shim that tees each inner `claude --output-format json` envelope
for its real `total_cost_usd`/`usage`:

  * **t0-on** — tier 0 (evidence only, no orientation), surface minimal.
  * **t1-on** — tier 1 (+ cached orientation, the DEFAULT), surface minimal.
  * **t1-off** — tier 1, surface **ambient** (the pre-T36.2 full tool/MCP set).
  * **t2-on** — tier 2 (+ live graph MCP), surface minimal.

**Verdict.** Two clear, opposite results:

1. **Tool-surface ON (the `:minimal` T36.2 default) is a real, mechanism-grounded
   token win — NOT net-neutral.** Surface-off (ambient) cost **~2× the tokens and
   ~40% more $** than surface-on for the same one-dispatch convergence: the saving
   is entirely in the CACHED input the harness re-sends every turn (t1-on 90,984
   cached vs t1-off 182,279 cached; output 1,406 vs 1,245 and turns 8 vs 7 are
   ~equal — so the delta is the loaded tool/MCP schema set, not agent flailing).
   **KEEP surface `:minimal` (on) as the default.**
2. **The context-tier knob is net-neutral on a within-reach fixture.** Tier 0/1/2
   all converged in ONE dispatch at $0.0489–$0.0545 — inside the run-to-run noise
   floor. On a tiny scratch workspace the tier-1 orientation pack was only ~49
   tokens and the tier-2 graph MCP server was empty (no graph DB), so the tier had
   nothing to bite on. This reproduces the T19.7 finding (a self-verifying inner
   harness converges most within-reach slices in one dispatch on EVERY tier).
   **KEEP tier 1 as the default** (evidence + the cached orientation pack — the
   safe knee); the tier ladder earns its keep only on a fixture beyond the cheap
   tier's reach, which is exactly what the T36.4 escalate-on-non-progress ladder
   (gated, not reflexive) is for.

**The tier × surface table** (generated by the new `mix kazi.bench --tier-surface`
wiring from the recorded live run — `$`/tokens from each captured `claude`
envelope's `total_cost_usd`/`usage`; convergence/correctness from each arm's
terminal result; the predicate IS the correctness oracle, so a cheaper-but-WRONG
arm would show `Correct = no`):

| Arm | Tier | Surface | Dispatches | Tokens | Cost (USD) | Cost/conv-pred | Converged | Correct | Stuck |
|---|---|---|---|---|---|---|---|---|---|
| t0-on | 0 | on | 1 | 90811 | 0.0530 | 0.0530 | yes | yes | no |
| t1-on | 1 | on | 1 | 92424 | 0.0545 | 0.0545 | yes | yes | no |
| t1-off | 1 | off | 1 | 183559 | 0.0768 | 0.0768 | yes | yes | no |
| t2-on | 2 | on | 1 | 71983 | 0.0489 | 0.0489 | yes | yes | no |

(Cost = the summed `total_cost_usd` of the arm's captured envelope; there is one
converged predicate, so cost/conv-pred = cost. All four arms converged and were
correct — the check script independently verifies the output is 129.)

**Default recommendation set FROM this data.** Surface `:minimal` (on) stays the
default — a measured ~2× cached-token / ~40% cost win with no convergence penalty.
Tier `1` stays the default — net-neutral on a within-reach slice, so there is no
data-driven reason to move it; escalation (T36.4) handles the beyond-reach case.
No default was changed by this run; both shipped defaults are now data-backed.

**Run scale + ACTUAL cost incurred.** A minimal, representative LIVE run — NOT a
full tier-0..4 × surface-on/off matrix: ONE fixture, 4 arms (tiers 0/1/2 at
surface-on + tier-1 at surface-off — the two cleanly-variable axes), one dispatch
each, plus a feasibility probe and one de-risking smoke run. **Total real spend ≈
$0.42** (probe $0.028; a first smoke run that burned $0.104 fighting a missing
permission mode before I added `permission_mode: :bypassPermissions`; a clean
smoke $0.052; the 4 measured arms $0.0530 + $0.0545 + $0.0768 + $0.0489 = $0.233).
Far under the authorized ceiling. Every measured `$` traces to a captured envelope.

**Honest caveats (the limits of this run):**

1. **The ambient ABSOLUTE number depends on the operator's local config.** The
   surface-off arm loads the full configured tool/MCP schema set, so t1-off's
   182k-token figure scales with how many MCP servers the operator has configured.
   The robust, mechanism-grounded finding is the DIRECTION and roughly-2× MAGNITUDE
   (minimal ≪ ambient because ambient re-sends every irrelevant schema each turn),
   not the exact multiple — which only gets larger with a richer ambient.
2. **Tiers 3–4 were NOT measured live.** Their content sources (retrieval snippets,
   compact repo snapshot) are scaffolded but not yet wired (T36.3 left them as
   named seams), so a live tier-3/4 arm would assemble the same context as tier 2
   on this fixture — nothing new to measure. Marked out of scope here, honestly,
   rather than run as a fake distinct arm.
3. **A within-reach fixture cannot stress the tier ladder.** As in T19.7, every
   tier converged in one dispatch, so the tier knob's value (and the T36.4
   escalation) is invisible here by construction. Demonstrating a live tier CLIMB
   needs a slice genuinely beyond the cheap tier's reach on a real codebase — the
   documented next step; manufacturing a failure cheaply was not attempted (it
   would be gamed).

**Harness wiring added (T36.5).** `Kazi.Bench.tier_surface_arm/3` +
`tier_surface_report/1` + `render_tier_surface_table/1` (pure: fold each arm's
captured envelopes for real `$`/tokens + its terminal result for
convergence/correctness/stuck + the cost/converged-predicate ratio, parsing
tier/surface from the `t<tier>-<on|off>` label) and a
`mix kazi.bench --tier-surface <dir>` mode that aggregates the recorded arms (each
arm = `<arm>.result.json` + captured `<arm>.NNN.json` envelopes), sorted by
(tier, surface). Plus `Kazi.Harness.DispatchSurface`: a `:dispatch_surface,
:ambient` OFF switch (the surface-off arm + an operator escape hatch) and
`surface_mode/1` to label it. Bench + dispatch-surface unit suites green;
`mix format` clean; hermetic fixtures under `test/fixtures/bench/tier_surface/`.

**Reproduce.** Drive the four arms with `Kazi.Runtime.run(goal, harness: :claude,
model: "claude-haiku-4-5", adapter_opts: [context_tier: <0|1|2>, dispatch_surface:
<:minimal|:ambient>, permission_mode: :bypassPermissions, command: <capture-shim>])`
over a tiny `custom_script` fixture in a scratch workspace, capturing each inner
`claude --output-format json` envelope (a thin `claude` shim on `PATH` that tees
the envelope), then `mix kazi.bench --tier-surface <dir>`.

## 2026-06-25 — in-family tiering cost benchmark (T19.7): static-cheap wins; escalation collapses to the cheap tier (best case)

The LIVE in-family cost proof T34.7 left open (ADR-0033/0035; verifies UC-043,
UC-045, UC-033). Three tiering arms run over ONE tiny self-contained fixture (a
`custom_script` predicate: `solution.py` must print the sum of the first 10 primes
= 129; a stub fails at t0), driving the real `kazi apply --harness claude --model
<id>` path, with each inner `claude --output-format json` envelope captured for its
real `total_cost_usd`/`usage`:

  * **A — vanilla-frontier**: a frontier model (Opus 4.8) grinds the whole goal.
  * **B — static-cheap**: a cheap Claude model (Haiku 4.5) grinds predicates a
    frontier model authored once (ADR-0033 static tiering).
  * **C — escalating**: start cheapest (Haiku), climb Haiku→Sonnet→Opus ONLY on a
    kazi-reported non-converged/stuck signal (ADR-0035; the ladder is an
    orchestrator-side state machine, not kazi-core).

**Verdict.** In-family tiering is real and cheaper, with a sharp caveat: on a
slice the cheap tier can converge, **static-cheap is ~3× cheaper than
vanilla-frontier for the same correct result, and the escalating arm collapses to
the cheap tier — never paying frontier rates** (the best case ADR-0035 predicts).
But escalation is NOT free insurance: when it has to climb the full ladder it
costs MORE than just starting on the frontier (the net-negative risk ADR-0035
flags, now measured). Escalation pays off only when the cheap tier's failure is
cheap relative to the frontier work it saves — so the stuck-threshold must be
tight, and the default should be the cheapest *capable* tier, not reflexive
climbing.

**Run scale + ACTUAL cost incurred.** A minimal, representative LIVE run — NOT
exhaustive: ONE fixture, the canonical 3 arms + one constructed worst-case, plus 3
cheap feasibility probes. **Total real spend ≈ $0.53** (4 captured live-arm
envelopes = $0.4099; 3 probes ≈ $0.12, one de-risk Haiku run's cost uncaptured
but ~$0.05 by comparison). Far under the authorized ceiling — the fixture is
deliberately tiny so each dispatch is a small edit. Every $ below traces to a
captured envelope.

**The tiering table** (generated by the new `mix kazi.bench --tiering` wiring from
the recorded run — `$`/tokens from each captured `claude` envelope's
`total_cost_usd`/`usage`; convergence + correctness from each arm's
`kazi apply --json`):

| Arm | Model(s) | Dispatches | Tokens | Cost (USD) | Converged | Correct |
|---|---|---|---|---|---|---|
| vanilla-frontier | claude-opus-4-8 | 1 | 83720 | 0.1619 | yes | yes |
| static-cheap | claude-haiku-4-5 | 1 | 91770 | 0.0536 | yes | yes |
| escalating (observed) | claude-haiku-4-5 | 1 | 90557 | 0.0527 | yes | yes |
| escalating-worstcase* | claude-haiku-4-5 → claude-sonnet-4-6 → claude-opus-4-8 | 3 | 264642 | 0.3572 | yes | yes |

\* *constructed* from the real per-model envelopes (Haiku $0.0527 + Sonnet $0.1417
+ Opus $0.1619): what the escalating arm WOULD cost if a slice forced it up the
full ladder. The live escalating arm never climbed — Haiku converged on rung 1, so
it cost the cheap-tier rate. The worst-case row makes the "always-escalates-to-
frontier" outcome visible per the acceptance: at **$0.3572 it is 2.2× MORE than
vanilla-frontier's $0.1619.**

**Per-dispatch single-model cost on this slice:** Haiku **$0.0527** · Sonnet
**$0.1417** · Opus **$0.1619**. Haiku is ~3× cheaper than Opus. Sonnet ≈ Opus here
because the per-dispatch FIXED overhead — Claude Code re-injects a ~70k-token
cached system prompt every dispatch (cache-read + cache-creation), priced per the
model's own cached/write rate — dominates a tiny slice's tokens. The tier gap
widens on larger slices with more generated output; on trivial slices it compresses.

**Convergence + correctness.** All three live arms converged and were **correct**:
the `custom_script` predicate IS the machine-checkable correctness oracle (the
check script independently verifies the output is 129), so a cheaper-but-WRONG
result would show `Correct = no`, never a false done. The new wiring's unit suite
pins exactly that with a `static-fails` arm (converged=no, correct=no) and a
converged-but-failing-predicate case (correct=no).

**Honest findings (the caveats that matter more than the headline):**

1. **A self-verifying agentic inner harness converges most within-reach slices in
   ONE dispatch — on EVERY tier.** With bash + the check script as an oracle (the
   workspace grants edit/bash), even Haiku writes, runs, and self-corrects inside a
   single `claude -p` dispatch, so kazi never observes "stuck" and escalation never
   fires. This is why the escalating arm collapsed to Haiku. Stressing a live ladder
   CLIMB needs a slice genuinely beyond the cheap tier's reach (a documented next
   step); manufacturing a failure cheaply was not attempted (it would be gamed). The
   ladder's climb logic is instead pinned by the escalating-worstcase row (real
   per-model envelopes) + the `Kazi.Context.Escalation` unit tests.
2. **kazi's `--json` `economy` omitted `cost_usd` and reported `tokens: 0` on these
   runs.** `Kazi.Harness.Profiles.Claude.parse/1` DOES parse `total_cost_usd`, but
   the run-aggregate economy did not surface it — so the benchmark sourced real `$`
   from the inner `claude` envelope directly via a capture shim (the bench's
   documented design), not from kazi's economy. Wiring the harness's
   `total_cost_usd` through to kazi's economy envelope is a worthwhile follow-up
   (it would let `--kpis` carry real cost without a shim).
3. **Local-Qwen privacy arm (secondary):** the BYOM/privacy comparison
   (`--harness opencode --model local/qwen3.6`, ADR-0033's privacy add-on, demoted
   below the in-family default) is noted as the secondary axis only — **NOT run**
   here (no local model). It trades $ for on-prem privacy, not for raw cost.

**Harness wiring added (T19.7).** `Kazi.Bench.tiering_arm/3` +
`tiering_report/1` + `render_tiering_table/1` (pure: fold each arm's captured
envelopes + terminal result into the `$`/tokens/dispatches/convergence/correctness
row) and a `mix kazi.bench --tiering <dir>` mode that aggregates the recorded
arms (each arm = `<arm>.result.json` + captured `<arm>.NNN.json` envelopes) into
the table above. 22 bench tests green (`mix test test/kazi/bench_test.exs
test/mix/tasks/kazi_bench_test.exs`); `mix format` clean; fixtures under
`test/fixtures/bench/tiering/`.

**Reproduce.** Drive the three arms with `kazi apply --harness claude --model
<claude-opus-4-8|claude-haiku-4-5|claude-sonnet-4-6>` over a tiny `custom_script`
fixture in a scratch workspace, capturing each inner `claude --output-format json`
envelope (a thin `claude` shim on `PATH` that tees the envelope), then
`mix kazi.bench --tiering <dir>`.

## 2026-06-25 — economy benchmark A/B/C (T34.7): KEEP the stable-prefix wiring

The multi-iteration economy benchmark the single-dispatch T15.9 run could not
settle (devlog 2026-06-24 "token benchmark (T15.9)"), now run through the T19.4
harness (`mix kazi.bench`) and the T34.6 economy KPIs (`--kpis`), ADR-0046. The
open question this closes: across iterations, does the T19.1 orientation prefix +
T19.2 stable-head discipline pay for itself, or should that wiring be reverted?

**Verdict: KEEP.** The stable-prefix wiring stays. It is grounded in real
evidence + the shipped mechanism; the one quantity still unmeasured live is the
*magnitude* of the multi-iteration win (see "Honesty" below).

**Run scale + cost actually incurred.** ZERO live Claude dispatches, ZERO API
spend. I ran only the harness's two deterministic OFFLINE replay paths
(`--captures`, `--kpis`) over the recorded fixtures, and the bench + economy unit
suite (46 tests, green). I did NOT hand-orchestrate a live 3-arm convergence — see
"What a full live run still needs". The budget guardrail (T34.7 brief) explicitly
permits an honest, mechanism-grounded verdict over silently burning budget.

**The A/B/C tables (`mix kazi.bench`).** Reproduced end-to-end from the recorded
fixtures under `test/fixtures/bench/`:

Token + cost + iteration table (`--captures test/fixtures/bench/captures`):

| Arm | Iters | Input | Output | Cache-create | Cache-read | Total | Cost (USD) |
|-----|-------|-------|--------|--------------|------------|-------|------------|
| A — vanilla `claude -p`        | 1 | 12972 | 1116 | 24236  | 288183 | 326507 | 0.4790 |
| B — kazi, NO prefix (pre-T19.1) | 3 | 12900 | 1200 | 287500 | 0      | 301600 | 0.4800 |
| C — kazi, WITH prefix (default) | 3 | 6600  | 1170 | 96000  | 191000 | 294770 | 0.2380 |

Economy-KPI breakdown (`--kpis test/fixtures/bench/kpi_runs`, T34.6/ADR-0046):

| Tier (arm) | Runs | Stuck | Conv | Cost/conv-pred | Wall/conv-pred (s) | Iters-to-conv | Fresh-input-avoided | Rediscovery-avoided |
|------------|------|-------|------|----------------|--------------------|---------------|---------------------|---------------------|
| B | 1 | 0.00 | 1.00 | 0.090000 | 44.0 | 4.0 | 0     | 0  |
| C | 2 | 0.50 | 0.50 | 0.035000 | 30.0 | 3.0 | 70000 | 32 |

**Provenance of every cell — zero fabrication.** Arm A's row is a REAL recorded
`claude --output-format json` envelope from the live T15.9 single-dispatch run
(cost 0.4790; in 12972 / out 1116 / cache-read 288183 — identical to the T15.9
table). Arms **B and C are SYNTHETIC, illustrative fixtures** committed to exercise
the aggregation pipeline; they are NOT a fresh live measurement and must not be read
as one. The KPI fixtures are likewise synthetic (the C tier even carries a stuck run
to exercise the stuck-rate path, hence Conv 0.50). So the tables demonstrate the
**measurement pipeline is correct and ready**; they do not by themselves prove the
verdict. The verdict rests on the real evidence + mechanism below.

**Why KEEP — the real evidence + shipped mechanism.**
1. **It cannot hurt (REAL, measured).** T15.9's live single-dispatch A/B showed the
   prefix adds **~0% token overhead (+0.5%, +$0.0001)**. The orientation prefix is
   purely additive; when there is no graph/repo-map the pack is empty and the prompt
   is **byte-identical to the pre-T19.1 path** (`loop.ex:1690`). No regression risk.
2. **The baseline IS cacheable (REAL, measured).** T15.9's arm-A envelope carries
   **288,183 cache-read tokens** — the ~290k static head (system prompt + tools +
   workspace) is already server-cached with a 5-min TTL.
3. **The wiring is the precondition for reusing that cache (SHIPPED mechanism).**
   kazi drives `claude -p` as a subprocess and sets **no `cache_control`** — the
   ONLY lever it has is a deterministic **byte-stable prefix** (`loop.ex:1696`).
   T19.1/T19.2 front-load the prompt stable→volatile (orientation pack → work-item
   → digest → volatile evidence) and carry the head byte-identical across
   same-blast-radius iterations (`last_orientation_prefix`, `loop.ex:1906/1919`).
   Without this wiring, iterations 2..N re-send that ~290k head as FRESH input (cache
   miss); with it, they hit `claude -p`'s own prompt cache as cache-read. Since the
   head is the dominant cost component and is provably cacheable (point 2), keeping
   it stable is the difference between re-paying vs reusing it every iteration 2..N.
   This is exactly the structural asymmetry the synthetic fixtures encode (arm B
   cache-read 0 / cache-create 287500; arm C cache-read 191000 / fresh-input-avoided
   70000; cost/conv-pred 0.035 vs 0.090).

So the wiring demonstrably adds ~0% tax (can't hurt), is purely additive/backward
-compatible, and is the necessary precondition for the multi-iteration cache reuse
the real arm-A envelope proves is available. Reverting it would forfeit that reuse
for no measured token saving. **KEEP.**

**Honesty — what is NOT yet proven.** The *magnitude* of the multi-iteration win —
the live arm-B-vs-arm-C delta in cost/converged-predicate — has **not** been
measured against a live model. The repo's only B/C numbers are synthetic fixtures.
The verdict on the keep/revert axis is clear and defensible (KEEP); the headline
"X% cheaper across iterations" number remains UNMEASURED and must not be published
until the live run lands.

**What a full live run still needs (T19.5 path).** `mix kazi.bench`'s LIVE path is
intentionally not wired — it prints a notice and defers to a maintainer
(`kazi.bench.ex:106`). A real 3-arm multi-iteration run requires, OUT OF BAND of the
mix task: (a) a **≥3-dispatch fixture** (a goal kazi cannot converge in one shot) in
a real git repo with workspace permissions granted (not `/tmp` — opencode rejects
scratch dirs, T8.11); (b) a **tee wrapper** on `PATH` capturing each per-dispatch
`claude --output-format json` envelope (kazi persists none); (c) three runs — arm A
`claude -p`; arm B `mix kazi.apply` with `orientation_prefix: false`; arm C the
default — collecting envelopes + each run's `apply --json` `economy` object; (d)
feeding those into `--captures` / `--kpis`. Estimated footprint ~10 live dispatches
(3 arms × ≥3 iters) at ~$0.40–0.50 each ≈ **$5–15**, plus per-arm convergence loops
that can run several minutes and have hung before (T15.9 arm C hung ~6 min). That
orchestration + hang risk, not the dollar cost, is why it is a deliberate
maintainer step and was not run autonomously here.

**Bottom line.** KEEP the stable-prefix wiring. Proven ~0% single-dispatch tax +
purely-additive/backward-compatible + the real arm-A envelope proves the ~290k head
is cacheable and the wiring is the only lever to reuse it across iterations. The
multi-iteration savings *magnitude* is the single number still owed by a live T19.5
run; until then it stays unpublished. Subsumes/unblocks T19.5.

## 2026-06-25 -- Live site shipped two stale-command (vaporware) bugs that no CI gate caught

**What happened.** A `/loop /apply --pool` session shipped E25 content (T25.1/T25.5/T25.6
-> PR #454; T25.8 -> PR #459), deployed to GitHub Pages, and verified live at
https://kazi.sire.run. During live verification it found two deprecated/removed `kazi`
verbs still rendered in production:
1. The Install section of `site/src/pages/index.astro` (step 2) shows the REMOVED
   `kazi propose` -> `kazi approve` proposal flow (the current verbs are `kazi plan` /
   `kazi apply`; `propose` is a deprecated alias).
2. `proof-loop.svg` (the hero proof asset) shows `kazi run my-goal.toml` -- the removed
   `run` verb. An `.svg` is XML text, so a text grep over `site/` reaches it.

**Root cause (why it shipped unguarded).** The repo has two coherence gates, and NEITHER
covers the site's command accuracy: T9.9 (`site/scripts/check-coherence.mjs`) only diffs
a small set of canonical STRINGS between README and site; T16.4 only scans
`SKILL.md`/`AGENTS.md` against the CLI. So a stale `kazi <verb>` anywhere in `site/`
passes CI. Remediation existed in the plan only as dep-gated rewrites (T25.4/T25.10/T22.7)
and the verb-rename sweep T27.6; none had run, so the drift went live.

**Action.** Added T29.4 (a standing site command-accuracy CI guard, warn-then-block) to
close the gap, and annotated T27.6 (the ready, direct fix for bug #1) and T25.2 (owns bug
#2 via asset replacement) as confirmed-live. Lesson: a canonical-STRING coherence check is
not a command-ACCURACY check; the no-vaporware guarantee needs a verb-level scan over every
published surface (README + docs + site + rendered assets), not just the strings under test.

## 2026-06-24 -- Content-marketing research: how fast-growing OSS AI tools won stars (motivates ADR-0030 / E25)

Two sourced deep-research passes (~15 tools + the agent-native/MCP tier + HN launch
data) into what the fastest-growing OSS AI dev tools put in their README/site/docs
and how they won stars. Distilled into ADR-0030 + planned as E25. Key findings:

- **kazi's closest analogs are agent-FACING tools the user doesn't operate:**
  **Serena** ("The IDE for Your Coding Agent" / "Give your agent the tools it has
  been asking for"; testimonials authored BY the agents), **Context7** ("Up-to-date
  docs for any prompt"; invocation IS the marketing -- append "use context7"; ~55-58K
  stars, fastest in set), and **Astral's Ruff/uv** (benchmark chart as hero, a
  falsifiable "10-100x" number).
- **Content patterns correlated with star growth:** (1) a category-defining one-liner
  in line 1, in the human's noun not the protocol's; (2) lead with a VISUAL that
  proves the claim (speed tools -> benchmark chart; agent tools -> a transcript of
  the agent using it); (3) ONE recurring earned-media engine (Aider's leaderboard,
  Astral's benchmark) beats scattered effort; (4) a theatrical falsifiable number;
  (5) borrowed credibility / borrowed category; (6) two-layer proof (lean README,
  proof-heavy site); (7) friction-to-first-use = one copy-paste command/config.
- **Agent-tool positioning (kazi's hardest problem):** name the human's noun not
  "MCP server"/"controller"; "give your agent X" (benefit through the agent); lead
  with the agent's CURRENT pain then show it fixed (Context7's before/after, the
  most-copied device); show the agent USING the tool; make the invocation a
  memorable phrase.
- **Launch mechanics (HN-sourced, high confidence):** HN is the highest-leverage
  channel; title formula `<Name> - <plain capability>, <differentiator>` (Aider 432
  pts, uv 647, Tabby "self-hosted Copilot" 627, Zed open-sourcing 1576). Time to a
  wave (OpenHands rode Devin; Cursor rode Sonnet 3.5; the agent category rode MCP's
  OpenAI/Google adoption). Ship 1 release/day with "something significant" (Marsh's
  Ruff playbook). Reddit/Product Hunt returned NO falsifiable data -- unproven, not
  disproven.
- **Highest-leverage asset:** a visual that proves the core claim above the install
  command; for kazi = an asciinema/transcript of claude -> kazi -> harness with
  predicates flipping false -> true. Evidence: Astral's chart drove Ruff to 5K stars
  in <5mo; Serena's agent-voiced demo to ~25.7K; Context7's "use context7" to ~55K.
- **Honest risks:** (#1) "done" is harder to make falsifiable than "fast" -- if it
  can't be a number a skeptic reproduces in 60s, the hook misfires; the dogfood
  leaderboard is the mitigation. Category-education tax on "reconciliation
  controller" -> use a borrowed frame ("CI for coding agents"). AI tool fatigue +
  crowded harness field -> be unmistakably a different LAYER (verification), not
  another harness. Host-ecosystem dependence (Claude Code/MCP) -> keep multi-harness.
  Stars != adoption (fake-stars ~5x weaker, a liability) -> instrument downloads /
  time-to-second-PR. Maintainer attrition is the empirical #1 OSS killer.
- Full per-tool table + sources (raw READMEs + HN item IDs + the MCP-adoption and
  fake-stars papers) are in the session research; the durable distillation is
  ADR-0030.

## 2026-06-24 — E18 shipped: the four benchmark bugs fixed + clean re-verify (T18.5)

Fixed all four defects the token benchmark surfaced (2026-06-24 entry below), each
with a regression test; full suite green (1353 passed), `mix format` +
`--warnings-as-errors` clean.

- **T18.1** (stale example): `priv/examples/{deploy_target,standing_maintenance,
  grouped_taxonomy}.toml` used a whole command line in `cmd` (`"go test ./..."`),
  which `System.cmd/3` runs as one binary -> `{:cmd_unrunnable, :enoent}`. Split into
  `cmd` + `args`. New guard `examples_runnable_test` loads every
  `priv/examples/*.toml` and asserts each `:tests` predicate's `cmd` is a single
  whitespace-free token with a list `args` (L-0012).
- **T18.2** (read-model crash): `ReadModel.serialize_vector/1` stored evidence
  verbatim; an `:error` result's tuple reason + atom keys failed the Ecto `:map`
  cast so `record_iteration/1` raised and the iteration was lost. Added a recursive
  `sanitize_evidence/1` (stringify keys, keep JSON scalars, stringify atoms, inspect
  tuples/structs); idempotent on already-sanitized maps (L-0010).
- **T18.3** (duplicate-index persist): persistence is a PROJECTION of observed
  state, so re-projecting an `iteration_index` must be idempotent. The runtime now
  always upserts from `persist_iteration` (on_conflict replace, conflict_target the
  unique pair); the stuck-stop projection (reuses `iterations-1`) and budget paths
  no longer collide on `iterations_goal_ref_iteration_index_index`. The read-model
  keeps its duplicate-rejecting contract for direct callers (L-0011).
- **T18.4** (over-budget CaseClauseError): already fixed by T15.3 (`cli.ex` has the
  `:over_budget` clause). Added a regression test: an unconvergeable goal
  (`max_iterations=1`, no-op harness) exits 1 + reports `over_budget` on both human
  and `--json`, raises nothing, and logs no persistence collision.
- **T18.5** (re-verify): a real `mix kazi.run` on a broken Go fixture (healthBody
  `not-ok`, NATS-free, in-memory read-model) converged in 2 iterations -- the agent
  applied the one-line fix, the upsert (`ON CONFLICT DO UPDATE`) fired, and the run
  was CLEAN: zero `failed to persist`, zero `has already been taken`, zero `:map`
  cast errors, no raise. The exact symptoms from the benchmark are gone.

## 2026-06-24 — E13 reconciliation dogfood (T13.6): kazi's own A \ I, importer demo, external-service-is-Go reality check

Ran the E13 intended-vs-actual pipeline (ADR-0021) end to end as a USAGE
exercise — no lib changes, the E13 modules are done. Two parts ran for real, one
is an honest limitation. Reproduce with `priv/scripts/t13_6_dogfood.exs`
(`mix run priv/scripts/t13_6_dogfood.exs`).

### 1. Scanner + coverage on an Elixir target kazi CAN handle: kazi itself

`Kazi.Reconcile.SurfaceScanner.scan/2` over kazi's own `lib/` (the workspace
root) found **290 public-surface elements**: 289 `:exported_function` + 1
`:mix_task` (`mix kazi.run`). (Reflection / string-dispatch entry points are
invisible to the static scan — ADR-0021's documented approximation, `docs/lore.md`
L-0006 — so 290 is a floor, not the whole truth.)

I then ran `Kazi.Reconcile.Coverage.check/3` with a REAL, representative intended
set `I`: the self-hosted goal `priv/goals/e3-t3.4-standing-reconciler.toml` (its
two `test_runner` predicates — an acceptance test + the full-suite guard). Result:

| metric | value |
|---|---|
| status | `:fail` |
| surface `A` | 290 |
| owned | 2 |
| allowed (allow-list) | 0 |
| **unowned (`A \ I`)** | **288** |

A few example unowned (candidate dead/undocumented) elements:

- `Kazi.Actions.Deploy.execute/2` (`lib/kazi/actions/deploy.ex`)
- `Kazi.Actions.Integrate.execute/2` (`lib/kazi/actions/integrate.ex`)
- `Kazi.Adopt.adopt/2` (`lib/kazi/adopt.ex:380`)
- `Kazi.Authoring.Clarify.candidate_prompt/1` (`lib/kazi/authoring/clarify.ex`)
- `Kazi.Application.start/2` (`lib/kazi/application.ex`)

Unowned, bucketed by top-level module (top of the list): `Kazi.Loop` 45,
`Kazi.Harness` 25, `Kazi.ReadModel` 25, `Kazi.Authoring` 21,
`Kazi.Coordination` 21, `Kazi.Context` 17, `Kazi.Reconcile` 17, `Kazi.Goal` 14.

### Honest read of the result: this number is a measurement of THIS goal, not "288 dead functions"

`A \ I = 288` is real but must be read as ADR-0021 frames it: it is the surface
NOT owned by the *chosen* intended set. The standing-reconciler goal's `I` is two
generic `mix test` predicates — it intends "the suite passes", not "these 290
symbols exist". So nearly the whole surface is correctly *unowned by that goal*.
The pipeline did exactly what it should; the 288 is "surface this particular goal
does not justify", a candidate list for a human, NOT a dead-code verdict. A real
dead-code pass needs an `I` authored to OWN the live surface (an OpenAPI/gherkin
import for an HTTP project, or hand-written acceptance predicates per capability),
plus an allow-list for the legitimately un-predicated (`Application.start/2`,
internal helpers).

The matcher is also demonstrably APPROXIMATE (as documented), and the dogfood
exposed both directions of noise in the 2 "owned" matches:

- `mix kazi.run` — owned only because the predicate's `cmd: "mix"` substring-
  matches the task identifier. Coincidental, not real ownership.
- `Kazi.ReadModel.latest_iteration/1` — owned only because the token `"test"`
  (from `args: ["test"]`) is a substring of "la**test**_iteration". A textbook
  false positive: `String.contains?("latest_iteration", "test") == true`.

So even the 2 "owned" are spurious; against this goal the honest A \ I is
effectively all 290. This is the intended-vs-actual loop working AND a fair
illustration of why ADR-0021 mandates "warn, don't auto-delete" + an allow-list:
the substring matcher trades false positives (acceptable) to avoid false
negatives (trust-eroding), and a coverage `:fail` is a review queue, not a
delete list.

### 2. OpenApiImporter demonstration (the importer path works)

`Kazi.Reconcile.OpenApiImporter.import_map/2` over the committed T13.1 fixture
(`test/fixtures/reconcile/petstore.openapi.json`) produced a create-mode goal
map: **6 `http_probe` acceptance predicates across 3 groups**
(`pets`, `identity-access`, `ungrouped`) —

```
get_healthz   [ungrouped]        GET  /healthz                   -> 200
get_pets      [pets]             GET  /pets                      -> 200
post_pets     [pets]             POST /pets                      -> 201
get_pets-petid[pets]             GET  /pets/{petId}              -> 200
get_users     [identity-access]  GET  /users                     -> 200
post_users... [identity-access]  POST /users/{userId}/sessions   -> 200
```

`import_goal/2` round-trips the same input straight through `Kazi.Goal.Loader`
into a `%Kazi.Goal{mode: :create}` with 6 predicates + 3 declared groups. The
deterministic spec->intent backbone of ADR-0021 §1 works as specified: a machine
spec becomes a grouped intended set with no bespoke deserialiser.

### 3. Honest limitation: the original "dogfood an external service" target is GO, not Elixir

Plan T13.6 said "dogfood an external service via the general path". Reality
check: that service's API is a **Go** codebase (`<repo>/api`, `internal/openapi`,
zero `.ex` files), and `Kazi.Reconcile.SurfaceScanner` is **Elixir-only** (it
parses `.ex`/`.exs` with `Code.string_to_quoted/2`). It therefore CANNOT scan
that service's Go surface — so the scanner+coverage half of T13.6 was dogfooded on kazi
itself (part 1) instead, which is a legitimate Elixir target and a real result.

Concrete follow-ups to actually reconcile such a service:

- **(a) A Go surface scanner** — a sibling provider that inventories Go exported
  identifiers / HTTP route registrations, emitting the same `SurfaceElement`s the
  coverage meta-predicate already consumes. This is the unblock for `A \ I` on a
  Go service.
- **(b) Consume the service's published OpenAPI spec.** When a service publishes
  one (`<repo>/docs/openapi.yaml`, e.g. ~3.2k lines, OpenAPI 3.0.3), the importer
  accepts it in principle — BUT if it is **YAML**, and `OpenApiImporter` is
  **JSON-only** (YAML deferred behind its own dep ADR, per the module's own docs).
  So the path is: `yq -o=json docs/openapi.yaml | ...` out-of-band, then
  `import_map/2`. This yields the service's intended `I` (HTTP probes grouped by
  tag) even without a Go scanner.
- **(c) Prose importer over the service's ADRs** (`Kazi.Reconcile.ProseImporter`,
  T13.3) — a service with a large `docs/adr/` tree lets the harness-drafted,
  human-reviewed path capture intent that lives only in prose.

The **live-predicate escalation** (probing a RUNNING service to assert the imported
`http_probe`s actually pass) remains **deferred** — it needs a running instance +
test credentials, out of scope here.

### Bottom line

The E13 pipeline runs end to end and produces a real, valuable result on an
Elixir target (kazi: `A \ I = 288` against a representative goal, with the
matcher's approximation honestly visible in 2 spurious "owned" hits). The
importer's deterministic spec->intent path works (6 grouped predicates from the
petstore fixture). The "dogfood an external service" goal as literally written is
blocked on language: that service is Go, the scanner is Elixir — so it needs a Go
scanner, a YAML->JSON front-end to ingest the service's existing OpenAPI spec, or
the prose path, none of which were built here. Reported as not-yet-done for the Go
service specifically; done and verified for the Elixir half.

## 2026-06-24 — token benchmark (T15.9): kazi adds ~0% overhead vs vanilla Claude

First real A/B/C token measurement (the benchmark ADR-0010 promised; the
audit below flagged it missing). Question: does claude→kazi→claude cost more
tokens than vanilla Claude?

**Method.** Broken Go fixture (`deploy-target`, `healthBody="not-ok"` → one unit
test fails). Each arm a separate real git repo under `~/kazi-bench` (NOT `/tmp` —
opencode auto-rejects scratch dirs, T8.11), with workspace permissions granted
(`.claude/settings.local.json` accept-edits + `Bash`; `opencode.json` edit/bash
allow). Tokens captured by a shim wrapping the harness binary, teeing the
`--output-format json` envelope (kazi captures tokens internally but persists/
prints none — see bugs). Code-only goal (one `test_runner` predicate), so the
LLM cost is the agent dispatch; integrate/deploy are git/HTTP, not tokens.

**Results.**

| Arm | Harness | Outcome | Total tokens | Cost | Agent turns |
|-----|---------|---------|--------------|------|-------------|
| A — vanilla | `claude -p` (one freeform session) | converged | 326,507 | $0.4790 | 9 |
| B — kazi→Claude | `mix kazi.run` → `claude` (1 dispatch) | converged | 328,141 | $0.4791 | 9 |
| C — kazi→local Qwen | `--harness opencode --model local-ollama/qwen3.6:35b-a3b-q8_0` | did NOT converge in ~6min | — (dispatch in-flight) | $0 (local) | — |

Token split was near-identical (A: in 12,972 / out 1,116 / cache-read 288,183;
B: in 12,843 / out 1,187 / cache-read 290,090).

**Findings.**
1. **kazi imposes ~zero token overhead at the same model: +1,634 tokens (+0.5%),
   +$0.0001.** Both arms invoke the SAME `claude` agent, whose static system
   prompt + tools + workspace context dominate (~290k cache-read, identical in
   both). kazi's structured dispatch prompt (digest + failing evidence) is no
   bigger than a human's freeform ask. **The "claude→kazi→claude is inherently
   more expensive" fear is false for single-dispatch convergence.**
2. **The real token risk is MULTI-dispatch, not the wrapper.** kazi is stateless
   per iteration (ADR-0008), so an N-dispatch convergence re-pays that ~290k
   baseline N times where a vanilla session amortizes it. Mitigants: (a) the huge
   `cache_read` shows the agent's static prefix is already server-cached, and the
   5-min TTL means rapid successive dispatches still hit it; (b) the unwired
   orientation-prefix + Anthropic `cache_control` (T4.3, see audit below) would
   cut iters 2..N further. So "N× baseline" is the worst case, not the typical.
3. **Cost-tiering (arm C) is real in $ structure but gated by local-model speed.**
   kazi correctly observed the failure and dispatched opencode→the local Qwen; the 35B
   q8_0 simply didn't return within 6 min (reconfirms T8.11). When it does
   converge, the per-dispatch $ is ~0 (local compute) — that is the cheaper story,
   bottlenecked by inner-harness throughput, not kazi.

**Bottom line.** kazi is NOT more expensive than vanilla for equivalent work
(proven, N=1). Its cost win needs model-tiering (gated by local-model speed); its
correctness win (objective termination = "right the first time") is free. Earned
claim today: *"kazi adds no token tax over your existing agent."* The *"cheaper"*
headline still needs a multi-iteration benchmark on a faster local model.

**Bugs surfaced during the run (not yet filed/fixed):**
- **Stale example:** `priv/examples/deploy_target.toml` uses `cmd = "go test ./..."`
  (whole command as the executable) → `{:cmd_unrunnable, :enoent}`. `test_runner`
  wants `cmd = "go"`, `args = ["test","./..."]` (README quickstart 2 is correct).
- **Read-model crash on errored predicates:** an `:error` PredicateResult whose
  evidence holds a tuple (`reason: {:cmd_unrunnable, ...}`) fails the
  `Iteration.predicate_vector` `:map` cast — `record_iteration/1` raises, so an
  errored predicate is never persisted.
- **CLI CaseClauseError:** `Kazi.CLI.run_goal/4` (cli.ex:526) has no clause for the
  `{:ok, %{outcome: :over_budget, reason: :max_iterations, ...}}` shape and crashes
  instead of printing a clean over-budget verdict.
- **Unique-constraint warning:** `iterations_goal_ref_iteration_index_index`
  "has already been taken" on iteration 0 (double persist on a path).

## 2026-06-23 — token-efficiency audit: is claude→kazi→claude cheaper than vanilla?

Audited whether the orchestrator→kazi→implementer stack (ADR-0023) actually
beats vanilla Claude on cost, and where kazi leaks tokens today. Verified against
the live dispatch path (`lib/kazi/loop.ex:1208 dispatch_prompt/2`), not the ADR
prose.

**The honest framing.** "Cheaper" ≠ "fewer tokens". The naive setup — claude →
kazi → claude with the SAME big model on every layer, stateless per iteration
(ADR-0008) — is *more* tokens than vanilla: vanilla amortizes orientation across
one growing context, while kazi re-pays per-iteration orientation N times AND
adds the orchestrator on top. kazi wins on **cost**, not token count, via two
levers that are intrinsic, not yet proven:
1. **Model tiering (ADR-0023).** Expensive model authors predicates ONCE; a cheap
   LOCAL model (e.g. Qwen on a local GPU host via opencode/claw) does the N grind iterations; objective
   predicates keep the cheap model honest. The expensive tokens are paid once; the
   N iterations run on near-free compute.
2. **"Right the first time."** Objective termination removes the hidden cost of a
   human re-prompting an agent that *thought* it was done. That cost is real but
   uncounted in a naive token diff.

**What's already shipped well (verified):** real token/cost capture from
`claude --output-format json` (`harness/profiles/claude.ex`); code-review-graph
MCP registered + refreshed in the target `.mcp.json` before every dispatch
(`workspace.ex` — gives the inner agent ~10× cheaper structural queries per
ADR-0010 research); bounded working-set digest carried across iterations as map
memory (`loop/digest.ex`); graphify retrieval adapter present (off by default,
SHA-cached); SHA-keyed orientation-pack cache keyed on `(workspace, git_sha,
failing_set)` (`context.ex:165`).

**Where kazi leaks tokens TODAY (gaps found):**
1. **Orientation pack is delivered as a file, not a cached prompt prefix.** The
   live loop's `dispatch_prompt/2` builds digest + `inspect(evidence)` + optional
   retrieval, and writes the pack to `.kazi/context.md`. The inner agent must READ
   that file (tool calls + input tokens, no cache discount) instead of receiving
   it as a stable, prompt-cacheable prefix. The prefix-injection path
   (`Harness.Prompt.build_prompt/3`, T4.3 — marked done, tested) EXISTS but is NOT
   called by the loop. Wiring it + Anthropic `cache_control` on the stable prefix
   is the single highest-leverage fix and the code is already written — realizes
   the 50–90% input savings ADR-0010 cites. **Landmine: T4.3 is "done" but unwired
   on the live path.**
2. **No Anthropic prompt caching (`cache_control`) anywhere.** Even the workspace
   file approach forfeits the cache discount on the stable goal/orientation prefix.
3. **Evidence rendered via raw `inspect/1`** in `dispatch_prompt/2`, bypassing
   `Prompt.truncate_evidence/2` (T4.8) — large evidence maps go in untruncated on
   the live path.
4. **caller-drafts mode absent (T15.2 open).** If `propose` spawns its own model to
   draft predicates while the orchestrator already reasoned about the idea, that is
   the redundant expensive call ADR-0023 §4 warns about. T15.2 caller-drafts
   removes it; until then the agent-drivable path double-pays authoring.
5. **No benchmark exists.** The "cheaper" claim is UNMEASURED — there are zero
   token A/B numbers in this repo. ADR-0010 promised "the first self-hosted run
   becomes the benchmark"; T15.9 (live claude→kazi→claw/Qwen dogfood) is the slot
   and is still open. Until run, "cheaper" must NOT appear on the README/site.

**Prioritized levers (brainstorm, not yet decided):**
- **P0 — Run the benchmark (T15.9).** Same broken fixture converged three ways:
  (a) vanilla Claude, (b) claude→kazi→Opus, (c) Opus-authors→kazi→local-Qwen.
  Record input/output/cache tokens, $, iterations, and correctness. This turns
  "we think it's cheaper" into the headline marketing line — or exposes the leaks.
- **P0 — Wire the orientation prefix + prompt caching** (realize T4.3 on the live
  loop; add `cache_control`). Highest token-per-hour win; code largely exists.
- **P1 — Ship caller-drafts (T15.2)** to kill the redundant authoring call.
- **P1 — Feed more blast-radius from the graph INTO the prompt** (impact radius /
  detect-changes symbols) so the cheap agent never greps to orient.
- **P2 — Auto-enable graphify retrieval above a repo-size threshold** (cache built);
  differential evidence (send only the delta vs last iteration); predicate-level
  memoization so expensive live/browser predicates don't re-run when their blast
  radius is unchanged.

**Bottom line:** the architecture is DESIGNED to be cheaper and the hard parts
(graph integration, token capture, caching infra) are built — but the two levers
that prove it (prompt-cache prefix, caller-drafts) are unwired and the benchmark
is unrun. "Cheaper" is the right north star; it is not yet earned in numbers.

## 2026-06-23 — harness CLI contracts researched (motivates E14 / ADR-0022)

Researched the CLI contracts of three coding harnesses to onboard as profiles
(ADR-0016 makes a harness data, not a module). The load-bearing criterion for kazi:
it drives a harness as a NON-INTERACTIVE SUBPROCESS (no TTY) and parses stdout.

- **Codex** — `codex exec "<prompt>" --json [--model <m>]` (or `codex e`) emits a
  newline-delimited JSON (JSONL) event stream (`thread.started`, `turn.completed`,
  `item.*`, `error`); `--output-schema` for a structured final; auth `OPENAI_API_KEY`
  / `codex login`. FULLY conformant — the parser mirrors the opencode NDJSON path.
  Priority addition. (developers.openai.com/codex/exec; openai/codex docs/exec.md)
- **Antigravity** (`agy` / `antigravity`) — non-interactive via `--prompt` / `-p` /
  `--prompt-file`; structured via `--output json`; `--yes` auto-approves; auth
  `GEMINI_API_KEY` / `ANTIGRAVITY_API_KEY`. LANDMINE: `agy -p` SILENTLY DROPS stdout
  under a non-TTY (pipe/subprocess/redirect) — issue google-antigravity/
  antigravity-cli#76 — exactly kazi's mode. Workaround: `--prompt-file` +
  `--output json` written to a file we read back; may need version pinning.
- **claw-code** — `claw prompt "<text>"`, env API keys (ANTHROPIC_API_KEY/
  OPENAI_API_KEY), NO documented JSON output, no model flag; the repo calls itself
  "an agent-managed museum exhibit rather than a production tool." Fails the
  structured-output bar → best-effort/demo-grade profile only (raw-stdout parse, no
  cost extraction). (github.com/ultraworkers/claw-code)

Decision recorded in ADR-0022 (conformance contract + onboarding recipe + tiered
support); built as E14. The Antigravity non-TTY landmine should also go to
docs/lore.md when T14.3 lands.

## 2026-06-23 — external-service dogfood: capability-manifest adjudication (motivates E12)

Dogfooded kazi's reconciliation thesis against an external service's
`docs/capabilities.json` (a `<service>-capability-manifest/v1`): 317 capabilities
across 9 pillars, each carrying machine-checkable evidence (`file:line`). One-off
code-level adjudication (no running service) -- does each capability's CLAIMED
evidence still exist?

- **Claimed (manifest):** WIRED 205, BACKEND_ONLY 55, FLAG_GATED 48, REMOVED 6,
  PLANNED 1.
- **kazi-verified (evidence exists now):** 307 built, 6 partial, 3 drift, 1
  no-evidence. The manifest is largely HONEST at the file-existence level.
- **Real production-readiness gaps are not "is the code there" (it mostly is)** but
  48 FLAG_GATED (not GA), 55 BACKEND_ONLY (no UI), and the manifest's own 178
  `with_drift` -- contract/behavior drift a file-existence check CANNOT see.
- Specific finds: one capability's evidence pointed at a transient
  `.claude/worktrees/...` path (never merged to main, or manifest built against a
  worktree); one capability's referenced source file was gone; several duplicate
  capability rows.

Lessons baked into ADR-0020 / E12: (1) the natural hierarchy is pillar -> domain ->
capability and the manifest already declares pillars as a closed list -> grouping
must reference a DECLARED taxonomy by id, not free text; (2) per-pillar budgets fall
out of per-group budgets + existing partitioning (no sub-goals needed); (3) the
honest next step to answer "production ready" is LIVE predicates against a running
service (needs an instance + test creds) -- code-existence != "it works". Output: an
Obsidian vault at `<repo>/tmp/state-vault/` (gitignored scratch).

## 2026-06-23 — E11 interactive `propose`: clarify phase verified live (T11.9)

Built the interactive clarify phase for `kazi propose` (E11, UC-029, ADR-0019):
a deterministic gap-detection FLOOR (`Kazi.Authoring.Clarify.gaps/2`) merged with
harness-drafted candidate questions on the existing stub seam, asked before the
draft, with answers folded into the draft prompt; an inline rationale on the goal
metadata (`--adr` also writes an ADR-lite doc); a refine loop via the existing
upsert. Suite 855 -> 899 (+44 tests).

LIVE VERIFICATION (real app, real SQLite read-model):

- **Strict, non-interactive, harness-free** — `propose "add a widgets feature"
  --strict` piped (no TTY): exit 1, `error: idea is underspecified (missing:
  live-target, scope); answer the clarify questions interactively or add detail`.
  The gap floor + `--strict` short-circuit fire BEFORE the harness.
- **Interactive clarify (forced via the `tty:` inject seam, answers over stdin)**
  — the real `terminal_ask` rendered the live-target question (3 numbered options,
  recommended starred `*`), read `2` (Production logs) from stdin, then the scope
  question (Enter = default), then the refine prompt (Enter = accept). The drafted
  predicate came back `live (prod_log)` — i.e. the chosen answer FOLDED into the
  draft (render -> IO.gets -> resolve_answer -> fold_answers -> draft), and the
  rationale printed. Proposal persisted (`prop-add-a-widgets-feature-...`).

CAVEAT (honest): the `:io.rows()` TTY AUTODETECT (`tty?/0`, the one line that
decides whether to enter the interactive path) could not be exercised in this dev
env — `mix run` runs the BEAM in noshell mode so `:io.rows()` returns
`{:error,:enotsup}`, the escript cannot bundle the SQLite NIF (so authoring has no
read-model there), and the Burrito binary cannot build on this macOS-26 host
(R-E6-1). In a real terminal launching the binary, `:io.rows()` returns `{:ok,_}`
and the verified flow runs. The rendering + choice-resolution it gates are pure
and fully unit-tested (`Clarify.render_question/1`, `Clarify.resolve_answer/2`);
the real claude harness, driven live, produced non-strict-JSON on the DRAFT call
(`proposal is not valid JSON`) — a PRE-EXISTING one-shot-parser limitation, not
E11; the clarify wiring around it ran correctly.

## 2026-06-22 — brew distribution lifecycle proven end to end (v0.1.0 -> v0.1.1)

The full release-to-upgrade chain was exercised against the live tap (E6,
ADR-0014/0017): bump `mix.exs` + the release-please manifest -> push `vX.Y.Z` ->
`release.yml` builds the three native-arch Burrito binaries (macOS arm64, Linux
x86_64, Linux arm64), SMOKE-TESTS each (`kazi_<target> --help` on its own arch)
before publishing, uploads them + `.sha256` -> regenerate `Formula/kazi.rb` ->
`brew upgrade kazi-org/tap/kazi`. Verified live: `brew upgrade` moved 0.1.0 ->
0.1.1 and the upgraded binary reports `kazi 0.1.1` (the new `kazi --version`
flag added this session). Shipping platforms: 3; only Intel macOS deferred
(GitHub macos-13 runner scarcity). The auto-release pipeline (release-please ->
build -> tap auto-bump) is wired but gated on the operator enabling
Actions-create-PRs + a `HOMEBREW_TAP_TOKEN` secret; until then releases are this
manual bump+tag. See lore L-0005 for the `mix release --overwrite` cache gotcha.

## 2026-06-22 — T8.11 heterogeneous dogfood: wiring proven, local 35B too slow to converge

**Setup.** The capstone E8 exercise: Claude (the planner) authored a tiny broken Go
fixture goal (`Add` used subtraction; `go test ./...` fails), and kazi drove
`opencode --model local-ollama/qwen3.6:35b-a3b-q8_0` (the implementer) to converge it.
The T8.9 finding was addressed first: a project-local `opencode.json` in the
workspace granting `permission.edit/bash` = `allow`, in a REAL git repo (not a
`/tmp` scratch), so opencode would no longer auto-reject edits.

**What was PROVEN (the heterogeneous loop works end to end).** kazi observed the
objective failure (`go test` exit 1, recorded the FAIL output), persisted iteration
0 to the SQLite read-model, and dispatched opencode->the local GPU host. Objective termination
held throughout: kazi could not and did not declare success while the predicate
failed. The plan/implement split (strong model authors the predicate set, cheap
local model drives the loop, predicates keep it honest) is demonstrated.

**What did NOT happen (the honest result).** opencode ran for ~40 minutes on
iteration 1 against the 35B-a3b-q8_0 and never produced an edit to `add.go`, so the
goal did not converge in a usable window. The bottleneck is the LOCAL MODEL's
agentic throughput, not kazi: opencode's loop makes several model calls per turn
(survey the repo, reason, propose the edit), each very slow on the q8_0 35B, and the
permission fix meant the blocker this time was purely speed (no auto-reject). The run
was capped manually.

**Takeaway / landmine.** "Claude plans, local model implements" is mechanically
sound and kazi's correctness guarantee holds regardless of implementer quality. Its
PRACTICALITY is gated by local-model speed: a local ~35B-q8_0 via opencode is too slow
for an interactive convergence loop. To make this dogfood converge, use a faster
local model (smaller/lower-quant, or a faster server), or accept long wall-clock for
batch-style runs. The throwaway workspace is `~/kazi-dogfood` (a single-predicate
`go test` goal); rerun `kazi run ~/kazi-dogfood/dogfood.goal.toml --harness opencode
--model <faster-model> --workspace ~/kazi-dogfood` to retry.

## 2026-06-22 — E8 generic multi-harness support shipped; opencode->local-model live smoke skips

**What shipped (ADR-0016).** The single `Kazi.Harness.ClaudeAdapter` was generalized
into config-driven harness **profiles**: `Kazi.Harness.Profile` (a `command` + a pure
argv renderer + a pure stdout parser + supported opts), a `Kazi.Harness.Registry`
(`:claude`, `:opencode`), one generic `Kazi.Harness.CliAdapter`, and a
`Kazi.Harness.resolve/1` seam (CLI `--harness`/`--model` > goal-file `[harness]`
table > `config :kazi, :harness` > default `:claude`). `Kazi.Runtime`, `Kazi.CLI`,
`Kazi.Authoring`, and `Kazi.Adopt.enrich` all route through it; the Claude path is
pinned byte-for-byte by a golden test (CliAdapter+claude == the old adapter). Adding a
harness is now profile DATA, not a new module. Suite 755 → 853.

**opencode specifics.** opencode's non-interactive surface is
`opencode run "<msg>" --model <provider/model> --format json`, where `--format json`
emits an **NDJSON event stream** (not Claude's single envelope) — which is exactly
why a profile carries a parser strategy, not just an argv template.

**Live opencode->local-model smoke: ATTEMPTED, did not converge, SKIPS honestly.** With
opencode v1.17.9 wired to a locally-hosted Qwen3.6 35B-A3B, a `kazi run --harness
opencode` against a fixture goal returned `{:error, :await_timeout}` after ~480s. The
endpoint and model were reachable (~100s/turn via a direct probe); the non-convergence
is environmental, not a kazi defect, with two causes:
1. the local 35B model is slow (~100s/turn), so a multi-iteration converge blows
   the loop's await window;
2. **opencode auto-rejects tool calls when run in an external/scratch workspace** —
   `external_directory; auto-rejecting` — so the agent never edits and the predicate
   never flips. The target workspace must be one opencode's permission policy treats
   as in-scope (not a bare `/tmp` dir).
The live test is tagged `:opencode_live` and EXCLUDED by default (it never gates CI);
run it manually with `mix test --only opencode_live` against a responsive endpoint and
a permitted workspace. No convergence was claimed.

## 2026-06-22 — WITHDRAWN: the E7 registry adapter (the entry below is now history)

The capability-registry adapter described in the next entry was **removed** before
the open-source release. `capabilities.json` was a bespoke artifact of one internal
product; it did not generalize, and shipping a `--registry` flag whose input format
nothing public produces is a liability for a v1 OSS tool. Deleted
`Kazi.Adopt.Registry`, the `kazi init --registry` CLI mode + tests, the
`capabilities.json` fixture, and the goal-set writer path. Kept the general pieces:
stack-detection `kazi init <repo-dir>` (ADR-0013) and the goal-file writer
`Kazi.Adopt.to_toml/1`. ADR-0015 rewritten to record the withdrawal and to point at
the generalizable replacement — a future importer for a STANDARD spec (OpenAPI
paths → `http_probe`; gherkin scenarios → acceptance predicates) under its own ADR
when there is demand (UC-025, deferred). Suite 785 → 755. The entry below remains as
a record of what was built and why the cardinality decision was made.

## 2026-06-22 — E7: registry adapter + goal-set (`kazi init --registry`), ADR-0015

**What shipped.** `kazi init` grew a second deterministic source: a capability
registry (`capabilities.json`) -> a goal SET, one goal-file per capability
(ADR-0015). Delivered in PR #75 alongside the two prerequisites that did not yet
exist on main — the goal-file writer `Kazi.Adopt.to_toml/1` (T5.3) and the `kazi
init` CLI verb (T5.5). New modules: `Kazi.Adopt.Writer` (deterministic hand-rolled
TOML renderer + commented `http_probe` live-predicate scaffold; no TOML-encoder
dep) and `Kazi.Adopt.Registry` (`parse/2`, `to_goal_set/2`). JSON decode via the
existing `jason` dep. Suite 741 -> 785.

**The cardinality decision (ADR-0015).** One goal-file PER capability, not one
goal carrying a predicate matrix. A goal is the unit of convergence/budget/status;
a capability is the unit of "what the product does" and the status we want
computed. A predicate matrix would couple N capabilities into one convergence unit
(one failure => whole goal stuck; shared budget; per-capability status lost). The
goal set is what makes status loop-computed per capability — the point of the
feature.

**Boundaries enforced mechanically.** Prose `.md` is rejected before reading
("generated views, not registry inputs" — bakes JSON-is-truth into the tool).
Source-inferred bindings stay behind `--enrich` (off by default), filling only
gaps, never overriding a declared binding. Live predicates are commented TODO
scaffolds, never guessed.

**Independent verification (not the subagent's word).** Ran the fixture
`capabilities.json` (3 capabilities) through `Registry.parse` -> `to_goal_set` ->
`Kazi.Goal.Loader.from_map` myself: all 3 goals load; a multi-binding capability
yields multiple `test_runner` predicates; prose `.md` rejected with a clear
message. The convergence test (`adopt_registry_convergence_test.exs`) drives a
registry-derived goal through the REAL `Kazi.Runtime` with the same stub seams
`Kazi.RuntimeTest` uses and reaches `:converged` — proving a registry-derived goal
is runnable, not merely loadable.

**Plan note.** E7 listed T5.3/T5.5 as prereqs and also (accidentally) duplicated
their WBS lines; reconciled to single entries under E5, marked done. T6.2 (Burrito
wrap, PR #74) merged its config/wiring but is left UNCHECKED: the host binary
could not be linked locally (Zig 0.15.2 vs macOS-26 SDK); it completes on the T6.3
CI matrix (macOS-15/Ubuntu runners), not this machine.

## 2026-06-21 — Slice-2 creation dogfood (T2.5): kazi BUILDS a small real feature from failing acceptance criteria to green-and-live

**What was exercised.** The Slice-2 creation acceptance dogfood (UC-010, D2) —
the creation analog of the Slice-0 full-loop dogfood (T0.11/T0.12) and the
Slice-1 regression dogfood (T1.8). Where Slice 1 proves kazi catches a BAD fix,
this proves kazi makes a GOOD one: it does not just REPAIR regressed behavior, it
CREATES behavior that did not exist before. Driven end-to-end through the REAL
`Kazi.Runtime`/`Kazi.Loop` with the REAL providers (`Kazi.Providers.TestRunner`
over a real temp workspace; `Kazi.Providers.HttpProbe` over a REAL local server),
the REAL `Kazi.Harness.ClaudeAdapter` (pointed at a real local "build" binary via
its `:command` seam), the REAL `Kazi.Actions.Integrate` (a real local
rebase-merge into a bare `origin`, no GitHub) and `Kazi.Actions.Deploy` (a stub
emulating `gcloud run deploy`, no gcloud), and real SQLite read-model
persistence. Test: `test/kazi/slice2_dogfood_test.exs`. Hermetic: own Sandbox
connection, a real harness binary, a real temp git repo, a real local HTTP
server — no Go, no external network, no GitHub, no GCP, no real browser.

**The feature spec (as failing acceptance predicates).** A tiny real feature —
*GET /greeting returns 200 with a body containing `hello, kazi`* — authored as a
create-mode goal (`mode: :create`) whose three acceptance criteria are all
designed to FAIL at t0:

- `feature_built` (`tests`, acceptance): the feature source exists
  (`grep -q '^built$' greeting.feature`). RED at t0 (marker `absent`). This CODE
  criterion is what carries the loop past dispatch into integrate/deploy.
- `greeting_endpoint` (`http_probe`, acceptance): `GET /greeting` returns 200. A
  REAL request against a running stdlib `:inets`/`:httpd` server. RED at t0 — the
  route does not exist yet, so the server genuinely **404s** (the
  `create_feature.toml` "no such route yet" shape).
- `greeting_body` (`http_probe`, acceptance): `GET /greeting` body contains
  `hello, kazi`. The precise behavior kazi must CREATE. RED at t0 (no endpoint).

The "live" check is a REAL http_probe request against an actually-running local
server whose response the deploy step rewrites — "live" here means a genuinely
running service the probe hits over `127.0.0.1`, NOT Cloud Run. A pre-flight
assertion confirms all three criteria genuinely fail against the real world at t0
(so the vacuous-goal guard, T2.3, does not trip — there is real work to do).

**How the build happens (over the real seams, zero-stub in lib/).** The harness
binary is the coding agent: it performs the genuine build by writing the feature
source marker (`built`) into the workspace, flipping `feature_built` red → green.
The integrate action's `:integrator` seam really rebase-merges the built feature
onto origin's `main`. The deploy action's `:deploy_cmd` seam "ships" the feature
by creating the server's backing resource serving the greeting, so the route
comes into being live — the live http_probe criteria pass only against the
deployed feature.

**What kazi did (observed, not expected).** The recorded trajectory:

```
outcome=converged  iterations=4
actions=[:dispatch_agent, :integrate, :deploy]
  iter 0: feature_built=fail greeting_endpoint=fail greeting_body=fail  converged=false  # honest start: feature absent, route 404s
  iter 1: feature_built=pass greeting_endpoint=fail greeting_body=fail  converged=false  # agent BUILT the source; route still absent
  iter 2: feature_built=pass greeting_endpoint=fail greeting_body=fail  converged=false  # landed; still not deployed -> live still 404
  iter 3: feature_built=pass greeting_endpoint=pass greeting_body=pass  converged=true   # deployed -> route live -> whole acceptance vector holds
```

1. **Failed at t0, non-vacuously.** Every acceptance criterion was RED before
   kazi did anything (feature absent, endpoint 404). The goal was real work, not
   a vacuous "already done" — the t0 guard let it through and the first persisted
   observation is all-fail.
2. **Built the feature.** The agent dispatch made `feature_built` go green
   (`greeting.feature` = `built` in the real workspace); integrate landed it on
   origin's `main` (`git ls-tree main` shows `greeting.feature`); deploy created
   the live route serving the greeting. The full creation arc:
   dispatch (BUILD) → integrate (LAND) → deploy (SHIP).
3. **Did NOT converge before the feature existed.** The objective-termination
   guard (T0.8) held for CREATION exactly as for repair: there are observed
   states (iters 1–2) where the built CODE acceptance passed but the LIVE
   greeting had not yet flipped — and the loop did NOT converge in any of them.
   Convergence was gated on the live feature, not on code-green.
4. **Converged green-and-live, persisted in order.** Only the LAST iteration is
   marked converged; the terminal vector is objectively satisfied; a final REAL
   `:httpc` request confirms the running endpoint serves `hello, kazi`.

**Evidence.** `result.outcome == :converged`,
`result.actions == [:dispatch_agent, :integrate, :deploy]`; the workspace file
`greeting.feature` = `built`; `greeting.feature` present on origin's `main`; a
direct `:httpc` GET against the live server returning the greeting; the persisted
read-model history (4 iterations) showing the all-fail t0 start, the
code-green-but-live-red gate, and exactly one converged iteration at the end.

**Conclusion: D2 acceptance holds (hermetically).** kazi builds one small real
feature from failing acceptance predicates to green-and-live: the criteria fail
at t0, kazi dispatches a build, lands it, ships it, and converges only once the
live endpoint genuinely serves the new behavior — never declaring the feature
done before it is live.

**Honesty note — the Cloud-Run caveat.** This dogfood proves the creation arc
*hermetically*: the "live" surface is a real local `:inets` server, and the
deploy step is a stub emulating `gcloud run deploy`. Production-Cloud-Run-live
(an http_probe passing against a real Cloud Run URL after a real `gcloud`
deploy) remains **T0.12**, which is human/GCP-gated and out of scope here by
design (the task forbids Go/GCP/external network so CI stays self-contained).
So D2's "to live" is met in the local-running-service sense, not yet against
production Cloud Run; that final step is tracked by T0.12. Everything behaved as
designed on the first real run; no `lib/` change was needed.

## 2026-06-21 — Slice-1 dogfood (T1.8): naive fix regresses a coupled predicate; kazi detects + escalates

**What was exercised.** The Slice-1 acceptance dogfood (UC-007), the
trustworthiness analog of the Slice-0 full-loop dogfood (T0.11/T0.12). Driven
end-to-end through the REAL `Kazi.Loop` with the REAL `Kazi.Providers.TestRunner`
(shelling out to `grep` over a real temp workspace), the REAL
`Kazi.Harness.ClaudeAdapter` (pointed at a real local "naive fix" binary via its
`:command` seam), real SQLite read-model persistence, and Noop integrate/deploy
doubles. Hermetic: own Sandbox connection, a real harness binary, a real temp
workspace — no Go, no network, no GitHub, no cloud. Test:
`test/kazi/slice1_dogfood_test.exs`.

**The scenario (a genuine coupling, not a contrived flag).** Two CODE predicates
over the temp workspace:

- `pred_a` passes iff `a.txt` contains `ok`; starts RED (`a.txt` = `broken`).
- `pred_b` passes iff `b.txt` contains `ok`; starts GREEN (`b.txt` = `ok`).

The "naive fix" harness is a real executable run with `cd: workspace`. It fixes
`pred_a` (writes `ok` into `a.txt`) but, because the predicates are coupled,
BREAKS `pred_b` as a side effect (writes `broken` into `b.txt`). This is the
canonical "a fix for predicate A breaks predicate B" (concept §5, the case
ADR-0002 rejects a single exit code for) — observed through the real provider
over a real mutated workspace, not faked with a status script. The harness is
idempotent (same edit each dispatch), so once B is red it stays red.

**What kazi did (observed, not expected).** The recorded trajectory:

```
outcome=stopped  reason=:stuck  iterations=4
actions=[:dispatch_agent, :dispatch_agent, :dispatch_agent]
  iter 0: pred_a=fail pred_b=pass      # honest start: A is real work, B green
  iter 1: pred_a=pass pred_b=fail      # naive fix flipped A green AND B red
  iter 2: pred_a=pass pred_b=fail      # failing set settles on {pred_b}
  iter 3: pred_a=pass pred_b=fail      # 3rd identical observation -> stuck
REGRESSION pred_b green@0 -> red@1 status=fail attributed=[:pred_a]
stuck_failing=[:pred_b]
```

1. **Detected the regression.** The regression detector flagged `pred_b`
   green→red between observation 0 and 1, and ATTRIBUTED it to the
   `:dispatch_agent` whose failing work-list was `[:pred_a]` — i.e. the very fix
   sent to repair A is named as the cause of B breaking. Visible in `snapshot/1`
   and read back from the persisted read-model (`ReadModel.regressions/1`,
   string-keyed on-disk form).
2. **Did NOT falsely converge.** The objective-termination guard (T0.8) held:
   the whole vector was never all-pass, because the instant the naive fix made A
   pass it made B fail. `:converged` was never reached; no persisted iteration is
   marked converged. The workspace confirms the coupling really happened
   (`a.txt` = `ok`, `b.txt` = `broken`).
3. **Escalated rather than spinning forever.** The same non-empty failing set
   `{pred_b}` persisted across the stuck window (3), the human-escalation hook
   fired exactly once with `failing == {:pred_b}`, and the loop stopped
   `:stopped` / reason `:stuck`. The iteration-budget backstop (50) was never
   reached — escalation, not budget exhaustion, ended the run. Terminal outcome,
   reason, the regression flag, and `stuck_failing` are all visible in both
   `snapshot/1` and the persisted read-model.

**Evidence.** `snapshot/1` carried the regression flag, `stuck_failing =
[:pred_b]`, and terminal state `:stopped`. The read-model carried the same
regression (queryable via `ReadModel.regressions/1`), an in-order iteration
history with NO converged iteration, and an iteration showing `pred_a :pass`
while `pred_b :fail` — the coupled regression made durable.

**Conclusion: D1 acceptance holds.** kazi catches the naive fix that trades one
green predicate for another rather than declaring false success: it detects the
regression, attributes it to the causing dispatch, refuses to converge while the
regressed predicate is red, and escalates to a human via the stuck detector. The
Slice-1 trustworthy-loop acceptance is met.

**Honesty note.** Everything behaved as designed on the first real run; nothing
needed a lib/ fix. One thing worth recording: the regression is flagged once (at
the green→red edge, iter 1) and is NOT re-flagged on subsequent identical
observations — `pred_b` stays red (red→red is not a new green→red edge), so the
single persistent flag is correct, not a missed re-detection. The loop continues
to surface that flag every iteration via `snapshot/1`/the read-model until it
escalates.

## 2026-06-22 — E4 context-injection epic shipped; pool drained

**Session:** `/loop /apply --pool`. Executed E4 (ADR-0010) end-to-end across two
waves, 8 PRs, all rebase-merged with green CI and verified on integrated main.

- **Wave 13:** T4.1 (adapter `--output-format json`: real token/cost/touched →
  budget, PR #41), T4.2 (`Kazi.Context` orientation-pack builder, deterministic +
  hermetic, PR #43), T4.5 (`Kazi.Workspace` code-review-graph MCP wiring + graph
  freshness before dispatch, PR #42).
- **Wave 14:** T4.3 (stable cacheable orientation prefix in `build_prompt`, PR #44),
  T4.4 (target `.kazi/context.md` orientation file, PR #46), T4.6 (SHA-keyed
  orientation-pack cache in the read-model + migration `20260622060000`, PR #47),
  T4.8 (per-dispatch token/cost ceiling + `truncate_evidence/2` + least-privilege
  tool/permission set, PR #45), then T4.7 (`Kazi.Loop.Digest`: bounded working-set
  digest across iterations — map memory only, never the transcript, preserving
  ADR-0008 anti-anchoring, PR #48).
- **Tests:** 372 → 495 passing (+123) across the epic; format + warnings-as-errors
  clean at every merge. T4.9 (semantic-retrieval RAG) remains deferred per ADR-0005.

**Pool drained of ready work.** Remaining incomplete tasks are not pool-eligible:
- **T0.6h** (`kind: human`) — GCP project/billing/Cloud Run provisioning. Blocks
  **T0.12**, the headline Slice-0 dogfood (idea→live production probe), which is the
  project's success bar. This human task is the critical-path blocker.
- **T3.1 / T3.5 / T3.7** — unblocked by deps (T2.6 done) but coarse Slice-3
  placeholders (NATS leases, predicate-authoring front-end, Telegram) with
  `Est: TBD` and no acceptance criteria; need `/plan` granularization into hermetic
  subtasks before agents can execute against a checkable bar. T3.2/T3.6 sit behind
  T3.1.

**Next:** either (a) complete T0.6h (human GCP setup) to unblock the T0.12 dogfood,
or (b) `/plan` the Slice-3 epic (T3.1/T3.5/T3.7) into granular tasks for a new pool wave.

## 2026-06-22 — Slice-3 epic (E3) shipped via pool; all plannable agent work done

**Session:** continuation of `/loop /apply --pool`. After granularizing the coarse
Slice-3 backlog into 16 hermetic subtasks (see the plan Change Summary + ADR-0011),
executed them end-to-end across Waves 15-18, 16 PRs (#49-#64), all rebase-merged
with green CI and verified on integrated main.

- **Wave 15:** T3.1a (lease behaviour + in-memory backend + shared conformance suite),
  T3.5a (`Kazi.Authoring.propose`), T3.6a (Phoenix LiveView skeleton + Playwright).
- **Wave 16:** T3.1b (real NATS JetStream KV lease backend; integration test gated on
  `NATS_URL`, excluded by default so `mix test` stays hermetic — added `gnat`),
  T3.1c (presence/intent snapshot), T3.2a (`Kazi.Partition` blast-radius partitioning
  reusing the T4.2 graph seam), T3.5b (approve/reject/edit workflow), T3.6b (goal board
  LiveView), T3.7a (Telegram ingress via client seam).
- **Wave 17:** T3.1d (acquire lease before dispatch), T3.2b (partition->lease-key map),
  T3.5c (CLI propose/approve), T3.6c (presence + lease-map LiveView), T3.6d (history
  timeline LiveView), T3.7b (egress pings on terminal loop events). T3.6c/T3.6d shared
  `router.ex` — merged T3.6c first; T3.6d rebased with a manual one-line router conflict
  resolution (kept both routes), re-verified green before merge.
- **Wave 18:** T3.7c (end-to-end ingress->authoring->approval->run->egress test).
- **Tests:** 372 (session start) -> 650 passing (+278 across E4 + E3), 17 `:nats`
  integration tests excluded by default; format + warnings-as-errors clean at every merge.
- **ADR-0011** added: Slice-3 operator surfaces (LiveView dashboard + Telegram bridge)
  are READ projections over the read-model + NATS and never couple into the core loop;
  both sit behind injectable seams for hermetic tests.

**Pool drained — all plannable agent work in the plan is now complete (E0-E4 + E3).**
Remaining incomplete tasks are NOT pool-eligible:
- **T0.6h** (`kind: human`) — GCP project/billing/Cloud Run provisioning. Still the
  single critical-path blocker for **T0.12**, the headline Slice-0 dogfood (idea -> live
  production probe) that is the project's success bar.
- **T4.9** — deferred semantic-retrieval/RAG adapter (ADR-0005); off by default,
  un-deferring is a deliberate user decision (adds an embeddings dependency surface).

**Next:** complete T0.6h (human GCP setup) to unblock the T0.12 live dogfood; OR opt in
to building the deferred T4.9. No other autonomous pool work remains.

## 2026-06-22 — T4.9 retrieval adapter shipped; plan fully built (only human GCP remains)

**Session:** continuation of `/loop /apply --pool`. Per user direction, un-deferred
T4.9 (the ADR-0005 pluggable memory adapter), granularized it (ADR-0012), and built
it across Waves 19-20, PRs #65-#67, all rebase-merged green.

- **T4.9a** (PR #65): `Kazi.Retrieval` behaviour + no-op default + optional
  build_prompt section, OFF by default (default output byte-identical, tested).
- **T4.9b** (PR #66): graphify-embeddings backend behind the seam; integration test
  tagged `:graphify` and excluded by default so `mix test` stays hermetic.
- **T4.9c** (PR #67): per-goal opt-in wiring + SHA-keyed snippet cache (migration
  20260622080000) reusing the T4.6 pattern; off-by-default leaves the loop unchanged.
- **Tests:** 666 -> 698 passing (+32), 18 excluded (`:nats` + `:graphify` integration
  tests); format + warnings-as-errors clean at every merge. ADR-0012 records the design.

**Plan fully built. Every buildable agent task is complete: E0 (scaffold + Slice-0
loop), E1 (trustworthy loops), E2 (creation mode), E3 (Slice-3: NATS leases,
partitioning, authoring, LiveView dashboard, Telegram), E4 (context injection),
and T4.9 (retrieval).** Cumulative this session: 372 -> 698 tests (+326).

**The ONLY remaining work is human-gated:**
- **T0.6h** (`kind: human`) — provision the GCP project + Cloud Run service + deploy
  credentials. Irreducibly human (billing/credentials). This is the sole blocker for...
- **T0.12** — the headline Slice-0 dogfood (idea -> live, verified production
  deployment), which is the project's success metric (CLAUDE.md). It cannot run until
  T0.6h lands. T0.13 already built the deployable fixture + Cloud Run deploy workflow,
  so once GCP credentials exist the dogfood is unblocked.

**Next (human):** complete T0.6h, then run T0.12 to close the idea->production loop and
hit the project's success bar. No autonomous pool work remains.

## 2026-06-22 — T0.12 Slice-0 dogfood CONVERGED (idea → live production)

kazi drove the `fixtures/deploy-target` Go service from a deliberately failing test
to a live, verified Cloud Run deployment — autonomously, end-to-end. This is the
project's success bar (CLAUDE.md): idea → production, with objective convergence.

**Run (`Kazi.Runtime.run`, goal = test_runner + http_probe, budget 8 iters):**
- iter 1: both predicates FAIL (go test `not-ok`; live `/livez` body `not-ok`) → `:dispatch_agent` — a real `claude -p` edited `healthBody "not-ok"→"ok"`.
- iter 2: code green, live still FAIL (not deployed) → `:integrate` (branch → PR #69 → rebase-merge to main).
- iter 3: landed, not deployed → `:deploy` (`gcloud run deploy --source`).
- iter 4: both PASS — live `/livez` returns `ok` → **`:converged`** (release_ref `release-kazi-deploy-target-1782167118`).
- Independently verified live: `curl https://kazi-deploy-target-2r7ah2mlpa-wl.a.run.app/livez` → `200 "ok"`; `origin/main` fixture `healthBody = "ok"` (kazi's PR #69 merged).
- Crucially, kazi REFUSED success while either predicate failed (iters 1-3 stayed non-converged) — done is objective, not the agent's opinion.

**Real defects the dogfood surfaced (all now fixed or recorded):**
- L-0001/L-0002: first Cloud-Run `--source` deploy needs `artifactregistry.admin` on the deploy SA and `cloudbuild.builds.builder` on the default compute SA.
- L-0003: Cloud Run intercepts the exact path `/healthz`; the fixture's liveness route moved to `/livez`.
- L-0004: a TOML goal-file can only express `body_match` as the string `"exact"`; the http_probe matched only the `:exact` atom, so it silently fell back to substring-contains and `"ok"` falsely passed on `"not-ok"`. Fixed in `Kazi.Providers.HttpProbe` (PR #68) + regression test; example goal corrected.
- Open follow-up (non-fatal): running via `mix run` (not `mix kazi.run`) skips the read-model migration, so this run logged `no such table: iterations` and did NOT persist evidence to SQLite. Convergence is proven by the run log + the live service; persistence works under `mix kazi.run` (which migrates on startup). Worth a guard so any entrypoint ensures the read-model schema.

**Infra note:** the `kazi-deploy` project's Domain-Restricted-Sharing org policy was
relaxed (project-scoped allValues=ALLOW) to permit `allUsers` public invoker so the
live probe can reach `/livez`. Restore it (delete the project-level override) if the
fixture no longer needs to be public.

## 2026-06-26 — T32.11 expanded-catalog dogfood CONVERGED (the E32 framework drives a real fixture)

The expanded predicate catalog (E32) converged a self-contained fixture on the
**released binary** (`kazi 1.64.1`, downloaded from the v1.64.1 release, sha256
verified): four new-kind predicates started RED and a real `claude` agent drove
them to objective-true under active anti-gaming enforcement. Honest result — every
predicate gated as intended, enforcement held, no gaming. The fifth new-kind
predicate (sustained-health) was demonstrated separately (no service in a
self-contained agent loop). Fixture committed at
`priv/examples/expanded_catalog_dogfood/`.

**The fixture.** A creation-mode goal (`mode = "create"`, enforcement default-on)
over a tiny `stats` module. The grader scripts under `checks/` are deterministic
stand-ins for the real tools (Dialyzer/coverage/mutation-tester/trivy) so the run
is reproducible offline, but they observe REAL workspace state, so the agent
converges them with real edits — the framework (provider gating, the envelope-v2
score gradient, the ratchets, enforcement) is what T32.11 tests, and the providers
are generic command-runners by design (ADR-0040).

**Run (`kazi apply … --harness claude --json --stream`, workspace = a git checkout
of the fixture):**
- iter 0 (observe): all four new-kind predicates FAIL with their t0 scores —
  `coverage` f/`20.0`, `mutation-score` f/`0.2`, `no-unsafe-eval` (`:static` SARIF)
  f/`1.0` finding, `no-vulnerable-deps` (`:cve`) f/`1.0` vuln; the `test-count`
  enforcement guard passes. → `:dispatch_agent`.
- iter 1 (observe): all five PASS → **`:converged`**. The terminal `predicates`
  vector carries `prior_score` (`20.0 / 0.2 / 1.0 / 1.0`) so the RED→GREEN gradient
  is auditable in one object.
- `iterations: 2`, `iterations_to_convergence: 2`, `cost_usd ≈ 0.363`,
  `tokens 146819`, `wall_clock_s ≈ 62`, `next_action: done`.

**Per-predicate gating — all correct (observed, not expected):**
- `:static` (SARIF): t0 1 finding → `:fail`; agent removed `eval(` from
  `src/stats.py` → 0 findings → `:pass`. (Gated on parsed SARIF findings, not the
  exit code — the grader exits 0 either way.)
- `:coverage` ratchet: t0 20% (1/5 functions tested) < target 80 → `:fail`; agent
  added a `test_<fn>` for every function → 100% → `:pass`. Project no-regression
  dimension (`project_baseline = "stored"`) held.
- `:mutation`: t0 score 0.2 (1 assertion) < threshold 0.8 → `:fail`; agent added
  assertions → score 1.0 → `:pass`. Threshold is **0.8, not 100%** (the loader
  rejects a 1.0 threshold by design).
- `:cve` (manifest tier, `count_path`/`baseline 0`): t0 1 vuln (`requests==2.19.0`)
  → `:fail`; agent bumped to `requests==2.32.3` → 0 vulns → `:pass`.

**Enforcement — active and held (`enforcement` in `--json`):**
`active: true`, `guarantees: [clean_tree, fail_on_skip, ratchet_guards,
read_only_lease, separate_process]` (all five), `gaming_events: []`. The agent
edited only `src/`, `tests/`, and `requirements.txt`; `checks/` was UNCHANGED, so
the read-only lease held and nothing was flagged — the agent did the real work
rather than editing a grader. (No gaming was attempted, so the flag path was not
exercised in the positive; the lease + clean-tree guarantees were merely reported
active.)

**Sustained-health (`http_probe`, T32.10) — demonstrated separately, both gates:**
Against a local server (`/stable` always 200, `/flapping` alternates 200/503), an
`http_probe` with `samples = 3, interval_ms = 200`:
- `/stable` → the predicate PASSES at t0, so kazi rejected the goal as
  `vacuous_goal` ("every predicate already passes at t0") — direct proof the
  sustained-health probe was satisfied by 3 consecutive 200s.
- `/flapping` → `:fail` at t0 with evidence `healthy_count: 1` and an
  `assertion_failures` entry `{expected: 200, actual: 503}` — a lone transient 200
  among failures never reaches N consecutive, exactly the K8s `failureThreshold`
  model. A single 200 does not pass.

**Two real findings surfaced building the fixture (worth recording):**
- A relative grader `cmd` (e.g. `cmd = "checks/lint.sh"`) is resolved against the
  LAUNCHER's cwd, not `--workspace`, and fails `:enoent` (Erlang `spawn_executable`
  semantics). A PATH-resolvable `cmd` with the script in `args`
  (`cmd = "bash", args = ["checks/lint.sh"]`) runs in the workspace correctly. The
  example goal-files use a relative `cmd` (`scripts/coverage`) — that pattern only
  works if the script is on the launcher's path or absolute. Fixture uses the
  `bash <script>` form.
- The `:static` `format = "dialyzer"` parser only recognizes findings on
  `.ex/.exs/.erl/.hrl` files (`@dialyzer_re` in `lib/kazi/providers/static.ex`); a
  `.py` finding line silently parses to ZERO findings → a false `:pass`. For a
  polyglot fixture, `format = "sarif"` is the language-neutral path and gates
  correctly. (Expected for a Dialyzer-led provider, but a quiet false-pass for a
  non-BEAM file is a sharp edge — SARIF or a BEAM-extension source avoids it.)

**Verdict: T32.11 DONE (positive).** The expanded catalog converged a real fixture
on the released binary; all four agent-driven new-kind predicates gated correctly
RED→GREEN with a visible score gradient; the sustained-health probe gated correctly
in both directions; enforcement was active with no gaming. Reusable fixture at
`priv/examples/expanded_catalog_dogfood/`.

## 2026-06-26 — T23.9 predicate-graph waves dogfood: kazi computes + executes a pipelined needs-DAG (live), plus a released-binary `--parallel` bug

The E23/ADR-0028 proof: encode a real multi-group goal with `needs` edges and
observe kazi (1) COMPUTE the topological wave schedule and (2) EXECUTE it
pipelined — disjoint groups in parallel, dependent groups sequenced behind their
deps' objective convergence, a stuck dep escalated (not hung). Fixture:
`priv/examples/predicate_graph_waves.toml` (`result-contract` and `health` in
frontier 0, `streaming` needs `result-contract` in frontier 1). Inner harness:
`claude`, with a one-line permission wrapper (`exec claude
--dangerously-skip-permissions "$@"`) set as the goal-file `[harness] command`, the
same workaround the T30.4 dogfood found — vanilla `kazi apply --harness claude` has
no `--permission-mode` flag, so the inner agent otherwise makes zero edits. A
`hello.txt` smoke confirmed the wrapper grants edits (converged in 2 iters) before
the real run.

**Computed schedule (`kazi apply <fixture> --workspace <scratch> --explain --json`,
verified on the RELEASED binary v1.64.1):**
```
frontier 0:  result-contract  ||  health   (two blast-radius partitions, concurrent)
frontier 1:  streaming                      (gated behind result-contract)
```
`--explain` dispatches nothing and exits 0 — it is pure planning and works on the
released binary. The schedule is exactly the authored `needs`-DAG: `streaming` in
its own frontier after `result-contract`; `health` parallel with `result-contract`.

**RELEASED-BINARY BUG (the headline operational finding).** `kazi apply
<goal> --workspace <ws> --parallel` on the released v1.64.1 binary crashes
immediately, deterministically (reproduced twice), with:
```
{"error":"{:noproc, {GenServer, :call, [Kazi.Scheduler.PartitionSupervisor,
  {:start_child, {{Task, :start_link, [...DepScheduler.start_group/2]}, ...}}}}",
 "status":"error","next_action":"investigate"}
```
Root cause: `Kazi.Application.start/2` hands straight to `Kazi.Release.burrito_main()`
under a Burrito standalone binary, so the supervision tree — including
`{Kazi.Scheduler.PartitionSupervisor, ...}` (application.ex) — is NEVER stood up.
The CLI's `migrate_read_model/0` manually `start_link`s only `Kazi.Repo` in the
standalone path (the same retrofit the homebrew read-model crash needed); it never
starts `PartitionSupervisor`. So `run_goal_parallel/4` → `Kazi.Scheduler.run_goals/2`
→ `DepScheduler` → `PartitionSupervisor.start_child(PartitionSupervisor, …)` calls a
named process that doesn't exist → `:noproc`. **Every released binary's `--parallel`
is broken** (the entire E23/E21 parallel-execution surface). `--explain` is
unaffected (pure planning, no supervisor). This is a release-packaging bug, not a
goal-file error; see lore (predicate-graph-waves entry). Fix: start
`PartitionSupervisor` in the CLI parallel path, mirroring `ensure_read_model`.

**How the LIVE EXECUTION evidence below was captured.** Because the released binary
cannot execute `--parallel`, the live run was driven from an in-tree source build
(`mix kazi.apply`, full supervision tree → `PartitionSupervisor` running) at commit
`d88a771`. The COMPUTED schedule is from the released binary; the EXECUTION is
in-tree. Stated plainly so the two artifacts are not conflated.

**Run A — convergence (`--parallel`, in-tree), observed timeline (from the loop
log):**
- `01:55:59.487` `result-contract` iter=1 starts; `01:55:59.489` `health` iter=1
  starts — **2 ms apart → DISJOINT GROUPS PARALLELIZED** (frontier 0, blast-radius
  partitions running concurrently).
- `01:57:57` `health` converges; `01:58:09.963` `result-contract` converges.
- `01:58:10.454` `streaming` iter=1 starts — **0.5 s after `result-contract`
  converged**, ~2 m 11 s after t0. `streaming` did NOT start at t0 alongside
  `health`, and `health` converging at `01:57:57` did NOT trigger it: it waited
  specifically for its `needs = ["result-contract"]` dep → **DEPENDENT GROUP
  SEQUENCED, pipelined per-group readiness (no global wave barrier), objectively
  gated** (the gate is `result-contract`'s evidence-backed convergence, not "an
  agent said done").
- `01:58:40` `streaming` converges. Collective `converged`, `blocked: []`, exit 0.
  The agent wrote all five Go files (`widget.go`/`widget_test.go`,
  `health.go`/`health_test.go`, `stream.go`) and `go test` gated each group.

**Run B — blocked-dependency escalation (`--parallel`, in-tree).** Same shape, but
`result-contract`'s sole predicate is impossible (`[ "$(date +%Y)" = "1999" ]`, the
agent cannot fix the clock) with `max_iterations = 2`:
- `01:59:53.152` `result-contract` iter=1 and `health` iter=1 start in the **same
  millisecond** (parallel again).
- `02:00:20` `health` converges — **a sibling OUTSIDE the blocked sub-DAG still
  finishes**.
- `02:00:31` `result-contract` iter=2 still failing → **`over_budget`** (budget=2).
- `streaming` is **never dispatched** (no loop line) — it is **escalated as blocked**
  rather than hung. Final JSON:
  `blocked: [{"reason":"over_budget","group":"streaming","blocked_by":"result-contract"}]`,
  `collective: "over_budget"`, `next_action: "raise_budget"`, exit 1. The schedule
  reports `result-contract: over_budget`, `health: converged`, `streaming: blocked`.
  **The blocking dep is NAMED, the dependent never ran against an unconverged dep,
  and the scheduler did not hang** — exactly the T23.5 escalation contract,
  observed live.

**Honesty notes.** (1) The COMPUTED schedule is from the released binary; the
EXECUTION evidence is from an in-tree `mix` build because the released `--parallel`
is broken (bug above). (2) The permission wrapper is required for the inner claude
agent to edit at all (T30.4 finding), so this is not a vanilla out-of-the-box run.
(3) Run A and Run B both used `custom_script` (`go test` / `grep` / `date`)
predicates — objective, evidence-backed gates.

**Verdict: T23.9 acc MET (predicate-graph-waves behavior observed live —
parallelism of disjoint groups, sequencing of dependent groups, pipelined objective
gating, and blocked-dep escalation with the dep named) — with one material caveat:
the released binary cannot execute `--parallel` (PartitionSupervisor `:noproc`); the
live evidence is in-tree. The feature is proven; the release path needs the
supervisor-startup fix before a released binary can run it.** Fixture reused:
`priv/examples/predicate_graph_waves.toml`.

## 2026-06-26 — native-parallel runtime bugfixes: group-collapse + `/leases` 500 (from the T21.12/T23.9 dogfood)

Three related native-parallel bugs surfaced by the parallel-run dogfooding. #1 (the
released-binary `--parallel` `:noproc`) was already fixed and released in v1.64.2
(commit `1708f3b`, `ensure_started/1` on the CLI path; see lore L-0047) — left as-is,
verified present in the tag. This entry covers the two remaining fixes.

**Bug #2 — disjoint GROUPS collapse into one serial partition (no parallelism
without `needs`).** The CLI `--parallel` path always hands `Kazi.Scheduler.run_goals/2`
a SINGLE goal, and the flat partition unit is the whole goal, so a single bare goal
always yields exactly one partition (reproduced: a 2-group, no-`needs` goal →
`Partitioner.partition([goal])` = 1 partition). The group axis only engaged when a
group declared a `needs` edge (`DepScheduler.dag?/1`), so a goal with 2+ INDEPENDENT
groups ran as ONE serial loop — even though `--explain` showed N parallel partitions
within the single frontier (explain and execution disagreed). Fix: `run_goals/2` now
routes a single goal through the group scheduler when `dag?` OR `group_parallel?/1`
(2+ groups AND every acceptance predicate carries a declared group). With no `needs`,
`DepScheduler` dispatches every group in one frontier — fully parallel, matching
explain. Guard: a goal with any UNGROUPED acceptance predicate stays flat so the
per-group sub-goal split never drops a predicate (guards, which may be ungrouped, are
replicated into every sub-goal). Verified via
`test/kazi/scheduler/run_goals_group_parallel_test.exs` (two gated group reconcilers
both dispatch before either is released → concurrent; ungrouped-predicate goal stays
flat with all predicates intact). See lore L-0020.

**Bug #3 — `/leases` 500s on a NATS-free (native) run.** The dashboard defaulted to
`KaziWeb.CoordinationSource.Transport`, whose `snapshot/0` → `Transport.Memory.fetch`
→ `bus_pid` RAISES `ArgumentError "requires a :bus handle"` when no `:coordination_opts`
is configured (the native default). And native parallel uses per-run in-memory lease
stores with no readable singleton, so there was nothing for the dashboard to project.
Fix: added `Kazi.Coordination.LeaseTable` (a globally-readable, best-effort `Agent`
registry of held native leases — every write a no-op when absent, so it never couples
the scheduler to the web tree), started in the web subtree; `LeasedReconciler` records
on acquire / forgets on terminal. Added `KaziWeb.CoordinationSource.Native` (projects
the table, no NATS) and made it the DEFAULT source; Transport is now opt-in via
`:lease_map_source` for when NATS is wired. `/leases` renders the live native lease map
(empty state when nothing is held) instead of 500-ing. Verified via
`test/kazi_web/live/lease_map_live_native_test.exs` (the view renders empty + populated
through the default native path), `test/kazi_web/coordination_source/native_test.exs`,
`test/kazi/coordination/lease_table_test.exs`. Honesty note: the CLI `--parallel` path
does not yet inject `:lease`, so a CLI run shows the EMPTY lease map until CLI-level
leasing is wired — but it RENDERS (no 500), which was the blocker. See lore L-0021.

**Quality gates:** `mix format` clean, `mix compile --warnings-as-errors` clean, full
suite green (2290 passed, 24 excluded). All three fixes verified VIA TEST (ExUnit);
released-binary `--parallel` for #1 was independently verified live on v1.64.2 (lore
L-0047). #2/#3 not yet exercised on a released binary (post-release coordinator step).

## 2026-06-30 — fix: scrub the burrito release/ERTS env from custom_script children (L-0022)

**Symptom (L-0022):** a `custom_script` predicate of `cmd = "mix", args = ["test", …]`
died with an opaque **exit 2 / empty output** when kazi ran from the released
(burrito-packaged) binary, so a goal whose grader is `mix test` could never SEE the
green and looped to `max_iterations`. `mix format` survived, which made it look
model-specific. Same "kazi can't see the green" class as the opencode `--workspace`
landmine.

**Root cause (diagnosed by dumping the child env via a passing probe predicate):**
the burrito binary exports its own release/ERTS locators — `BINDIR`, `ROOTDIR`,
`RELEASE_ROOT`, `RELEASE_SYS_CONFIG`, `__BURRITO`, `__BURRITO_BIN_PATH` — into its OS
environment, and every spawned child inherits them. A nested `erl` (invoked by the
child `mix`/`elixir`) **honours `BINDIR`/`ROOTDIR` and execs the burrito `erlexec`**,
booting the kazi release instead of the child's own BEAM — which is why the child
printed kazi's CLI usage (`unknown command "/opt/homebrew/bin/mix"`). Isolation
proved `BINDIR`/`ROOTDIR` are the killers: unsetting just them (even with the
polluted PATH intact) makes the nested `mix test` pass, so no PATH surgery is needed.

**Fix:** `Kazi.Providers.CommandRunner.run/4` — the single `System.cmd/3` choke
point all command-runner providers (custom_script, test_runner, prod_log) fold onto
— now clears that footprint via the `:env` option (`{var, nil}`) before every spawn,
on both the no-timeout and timeout paths. It COMPOSES with the caller's own `:env`
(caller entries last, so they still win) and leaves the rest of the inherited
environment intact; from a dev shell none of those vars are set, so the scrub is a
no-op. Authored test-first (the read-only bar in
`test/kazi/providers/command_runner_test.exs`) and converged by **kazi driving
`claude-sonnet-5`** (3 iterations, $2.49, zero gaming events).

**Verified:** the bar (5/5) and full suite (2310 passed, 24 excluded) green; `mix
format` clean. End-to-end proof under a *real* simulated-burrito env (the actual
`BINDIR`/`ROOTDIR`/`RELEASE_*` values + burrito-first PATH): the fixed `CommandRunner`
spawned a nested `elixir` that returned `{:ran, "CHILD_BEAM_OK\n", 0}` — the BEAM
booted correctly instead of re-entering the host release. Released-binary
confirmation follows the next release build. Resolves lore **L-0022**.

## 2026-07-04 — E46 starmap slice: first kazi-driven feature lands; live verification catches a seam-level-only proof

The first E46 slice (run registry T46.1, `kazi dashboard` verb T46.4, starmap
LiveView skeleton T46.5) was driven end to end BY kazi (`kazi apply --harness
claude --model claude-sonnet-5`, goal-set from the approved proposal): 7/7
predicates converged, PR #789 rebase-merged, v1.73.0 released, local binary
upgraded. Findings, in the order the DoD walk surfaced them:

- **Budget accounting is cache-inclusive and BIG.** One sonnet-5 dispatch on
  this slice measured ~15.1M counted tokens (ADR-0046 accounting). A 600k
  `max_tokens` cap — generous-sounding — is ~4% of one dispatch. Calibrate caps
  in dispatch-units, not API-token intuition.
- **`over_budget` reports a STALE vector** (kazi#790): the budget gate fired
  after a dispatch that had actually finished ALL the work, and the terminal
  result showed the pre-dispatch 2/7 — re-running with a raised budget
  converged at iteration 0 with zero dispatches. Until fixed, treat an
  over_budget vector as "unknown", not "no progress": re-evaluate before
  escalating (an escalation ladder would have pointlessly re-dispatched a
  frontier model onto green work).
- **`kazi plan` accepts what `approve` cannot load** (kazi#788): caller-drafts
  custom_script predicates without `cmd` persist fine, then approve fails with
  "the stored goal no longer loads". Workaround: re-plan with config.cmd; the
  upsert on the same proposal_ref replaces the stored goal.
- **File-scoped `mix test` predicates are gameable-by-honesty.** The
  `starmap_view` predicate ran "this test file passes"; the agent (openly —
  the moduledoc says so) built a walking skeleton and wrote tests for what it
  built. The description demanded wave bands + 6 node states; the cmd could
  not see the difference. Predicates must pin the SPEC (assert the behavior),
  not delegate to a test file the implementer authors.
- **Live verification caught a seam-level-only proof.** T46.1's registry
  passed 9 ExUnit tests and its migration applies — but a REAL converged
  `kazi apply` on the released v1.73.0 binary left the `runs` table EMPTY:
  the live apply path never calls RunRegistry. Same shape as the
  context-store non-engagement (2026-07-01): module-green, production-inert.
  T46.1 reopened with an integration-predicate requirement. The starmap
  LiveView also renders unstyled (semantic HTML, no design language) — the
  design reference exists for the restyle pass.
- The main-CI red after the merge was the known ProviderDeprecationTest
  stderr-capture flake; re-run greened it.

Net: kazi drove a real 946-line feature to converged/merged/released in two
iterations, and the definition-of-done's live-verify step earned its place
twice in one slice.

## 2026-07-05 — T46.1 reopen closed: the run registry is wired into the real apply path

The seam-level-only gap from 2026-07-04 above (`runs` table empty on a real
converged `kazi apply`) is fixed at its actual root: `Kazi.Runtime.run/2` —
not the CLI, not the loop — is the ONE place every real entry point (the
escript, `mix kazi.apply`, and the scheduler's parallel path, all of which
converge on `Runtime.run/2`) reaches, so registering there makes the registry
see every run regardless of entry point:

- `run/2` upserts a `runs` row (via `RunRegistry.start/1`) once `Loop.start_link/1`
  actually succeeds — not before, so a failed start never orphans a `"running"`
  row nothing finishes.
- The heartbeat is composed onto the SAME `on_iteration` seam the read-model
  iteration projection already uses, so every observed tick advances it — no
  new polling loop, no new process.
- The terminal status (`"converged"` / `"stuck"` / `"over_budget"` / `"stopped"`
  / `"error"`) is recorded once `Loop.await/2` returns, mapped from the loop's
  existing `t:Kazi.Loop.result/0` outcome/reason.
- All three are gated by the SAME `:persist?` flag the iteration projection
  already honors, so "persistence off" (as several Tier-2 tests set) still
  means zero read-model writes, registry included — this is what let the
  existing `Runtime`/CLI test suite pass unmodified.

The regression proof is `test/kazi/integration/run_registry_wiring_test.exs`:
unlike `Kazi.ReadModel.RunRegistryTest` (which pins the registry MODULE in
isolation and would pass even if nothing ever called it — exactly how this gap
shipped undetected through PR #789), the new test drives a fixture goal through
`Kazi.CLI.run/2` — the same shared entry the escript and mix task use — and
asserts a `runs` row lands in the real read-model with a `"converged"` terminal
status. T46.1 (`docs/plans/E46.md`) is closed on this basis.

## 2026-07-05 — kazi#795: an `:unknown` verdict (quarantine included) must never converge

The bug (observed on v1.73.1, kazi apply'ing its own `suite_green` predicate):
iterations evaluated `fail`, `fail`, then a genuinely-flaky predicate got
quarantined by T1.3's flake detector (recorded `:unknown`) — and the run
reported `converged`/exit `0` while that predicate's true state was unknown.
Root cause: `Kazi.Loop.decide/2`'s convergence clause called
`all_satisfied?(vector, data.quarantine)`, which DROPPED every quarantined id
from the vector before checking satisfaction — a flake correctly carries no
convergence claim, but the fix over-applied that principle to the wrong gate.
Quarantine's actual job is narrower: excluding a flaky predicate from the
WORK-LIST (`PredicateVector.failing/1`, real `:fail`s only) so it is never
re-dispatched as an agent task. It was never supposed to also exit the
convergence bar.

The fix: `all_satisfied?/1` now takes only the vector and delegates straight to
`PredicateVector.satisfied?/1` (already `:pass`-only) — quarantine is no longer
special-cased there at all. A quarantined predicate's `:unknown` status blocks
`:converged` exactly like any other unresolved predicate; with nothing to
dispatch and no convergence reachable, the loop just keeps re-observing. The
terminal `result()` also gained a `:quarantine` field (`kazi apply --json`'s
additive `quarantine` array) naming which predicate ids are quarantined, so a
non-converged stop is diagnosable without re-deriving state from the vector —
closing the second half of the report (a quarantine mechanism silently
widening the bar with no trace of which predicate did it).
Regression: `test/kazi/loop/verdict_bar_test.exs`.

**The `suite_green` hermeticity this exposed** (the same predicate's second,
latent failure): `mix test` run standalone was reliably green, but the SAME
suite evaluated as a kazi `custom_script` predicate flaked on two independent,
unrelated tests:

- `Kazi.Goal.ProviderDeprecationTest` captures the NAMED `:stderr` device via
  `ExUnit.CaptureIO`. Capturing a named device is process-INDEPENDENT — it
  swaps the globally registered `:standard_error` for the capture's duration,
  so any other `async: true` test process writing to stderr concurrently
  (a warning, another suite's own capture) leaks into this module's buffer.
  Fix: `async: false` on this one module; every other module stays async.
- `Kazi.Goal.LoaderAtomSafetyTest` asserts the BEAM atom table grows by fewer
  than 50 atoms across 200 rejected-config-key load attempts. `Kazi.Goal.Loader`
  force-loads a predicate's provider module (`Code.ensure_loaded/1`, the M3
  atom-safety guarantee) the first time any goal declares that kind — a real,
  one-time cost that interns every atom literal in the module's own source.
  Left lazy, whichever async test process happens to be first in the WHOLE
  suite to touch a given provider absorbs that one-time burst; when that
  process was this test's own measurement window, it flaked on a timing
  accident, not a loader defect. Fix: `test/test_helper.exs` now force-loads
  every real provider module before `ExUnit.start/1`, so the burst happens
  once, deterministically, before any test's atom-count snapshot.

Neither was a flaky ASSERTION — both were real nondeterminism from a shared,
process-global resource (`:standard_error`, the atom table) that only a kazi
in-loop evaluation's concurrency pattern reliably exposed; a human running
`mix test` by hand rarely hit either race.

### 2026-07-05: T46.3 transcript sink wired end-to-end

`Kazi.Sink.Transcript.tee/3` (event extraction, redaction, ordering, size cap
+ single truncation marker) already existed as a pinned-in-isolation module;
the reopen risk from T46.1 (a registry that worked in unit tests but was never
called on the live `kazi apply` path) applied here too, so the actual task was
wiring: `Kazi.Harness.CliAdapter`'s dispatch tees the raw captured output to
`opts[:transcript_sink_path]` as a passive, best-effort side effect right after
computing the base result map (never altering what dispatch returns), and
`Kazi.Runtime.run/2` computes a per-run path
(`<sinks_dir>/<run_id>/transcript.jsonl`, gated on the same `:persist?` flag the
run registry and iteration projection already honor) and threads it through
`adapter_opts` — plus records it on the `runs` registry row so a reader (the
future transcript-peek LiveView, T46.8) can find a given run's sink without
re-deriving the path convention.

One latent bug caught along the way: `RunRegistry.start/1`'s upsert
`on_conflict: {:replace, [...]}` column list had been written before
`transcript_sink_path` existed on the schema and was never updated, so a
restarted process reclaiming its own `run_id` would have silently dropped the
sink path back to whatever the first insert wrote (or `nil`). Fixed by adding
the column to the replace list.

Proof follows the same shape as T46.1's reopen fix:
`test/kazi/integration/transcript_sink_test.exs` drives a fixture goal through
`Kazi.CLI.run/2` (not `Kazi.Runtime.run/2` directly) with a stub harness that
emits a plain-text line and a line carrying a seeded `DATABASE_URL` secret,
then reads the transcript path off the run's registry row and asserts the
plain line landed and the secret was redacted on disk.

### 2026-07-16: T54.10 burrito maintenance notice -- measured streams vs the field report

Field feedback (a 24/7 fleet): every kazi invocation prints `[l] Skipped
cleanup of older version (vN): still in use by a running process` while ANY
long-lived process holds an older payload, alleged to land on STDOUT and so
break the ADR-0023 `--json` single-JSON-object contract. Reproduced against
the released 1.150.0 binary by staging a fake older install (`_metadata.json`
with a lower semver + a `.burrito_live/1` pidfile -- PID 1 counts alive via
EPERM, the fork's own zig-test trick) inside the real burrito install prefix.
Measured with streams captured separately:

- The notice is on **stderr**, not stdout -- and has been for every fork-built
  release (the only pin kazi ever had, `084e1e3`, already routed it through
  the fork logger's stderr path). `--json` stdout parsed as exactly one JSON
  object with the in-use payload staged; the purity contract was NOT broken.
  The stdout half of the report did not reproduce; combined-stream capture
  (`2>&1`, or reading a terminal) is the likely observation channel.
- The **repetition** half is real: the wrapper's maintenance pass runs on
  every launch, so the notice reprinted on every invocation, forever, until
  the old process exited.

Fix landed in the fork (kazi-org/burrito PR #1, `maintenance-skip-notice-once`
onto `payload-liveness-guard`): each announced version is recorded in a
`.burrito_announced_skips` marker next to `.burrito_live` in the CURRENT
install dir, so the notice prints once per installed version (a new version
extracts to a fresh dir and announces once again); recording is best-effort
and never blocks a launch. Proven end-to-end on the fork's `cli_example`
binary: notice exactly once on stderr, runs 2-3 silent on both streams,
cleanup still resumes (`Uninstalled older version`) once the pidfile is gone.

Kazi-side limitation, stated plainly: the pollution happens in the zig wrapper
BEFORE the BEAM boots and `/usr/local/bin/kazi` IS the wrapper binary (no
shell launcher), so NO in-app or launcher-side mitigation is possible -- the
ADR-0023 `--json` logger guard cannot reach it, and there is no env kazi could
set for its own current invocation. The kazi half is therefore a regression
pin, not a fix: `test/kazi/cli/release_binary_stdout_purity_test.exs`
(`:release_binary_live`, excluded by default) stages the same fixture against
the real release binary and asserts (1) `--json` stdout stays one JSON object
(green today) and (2) the notice appears at most once across two invocations
(green once the fork PR merges, mix.exs bumps the `084e1e3` pin, and a release
built from the new pin is installed). The pin bump is sequenced by the
coordinator AFTER the fork PR merges. `BURRITO_NO_CLEAN_OLD=1` remains the
operator-side kill switch (skips the cleanup pass, and with it the notice).

## 2026-07-17 — T44.14 dogfood: a goal lands itself end to end (E44 capstone) — landing works, but the serial loop does not auto-drive Integrate

Live `kazi apply --harness claude` against a self-contained throwaway fixture
(a tiny Python `calc` repo whose `add`/`mul` raise `NotImplementedError`, with
two `custom_script` predicates that pass once implemented, `[integration] mode =
"pr"`, `[harness] permission_mode = "bypassPermissions"`, `[budget]
max_iterations = 12`). Goal-file shipped as `priv/examples/landing.goal.toml`.
Run from a worktree at latest main via `mix run` (the released 1.160.0 binary
predates the whole T44.x arc). Two live runs plus a direct Integrate call.

**Run 1 (agent unconstrained). Converged in 3 iterations, 312,362 tokens.**
The streamed predicate vector is the clean evidence for two acceptance criteria:

- iter 0 — `adds=fail muls=fail landed=fail` (stubs unimplemented).
- iter 1 — `adds=pass muls=pass` **`landed=fail`** — code green, convergence
  BLOCKED by `landed` (T44.2 doing its job: the change was committed but not yet
  landed to the `pr` degree).
- iter 2 — `adds=pass muls=pass landed=pass` → **converged**.

The inner agent made **3 small scoped conventional commits**, not one monolith
(the T44.4 process contract visibly shaping it): `feat: implement add and mul`
plus two `chore:` commits adding `.gitignore` entries. Honest nuance: the two
`calc` functions landed together in the one `feat` commit; the extra commits are
gitignore hygiene (pycache, kazi's own `.kazi/`/`.mcp.json` context), so the
scoping was by concern, not one-commit-per-function.

But the PR the run produced was opened **by the agent**, not by kazi's Integrate:
its body was agent-authored prose (`## Changes` / `## Verification`), NOT kazi's
auto-generated verification report. Under `bypassPermissions` — which the agent
*needs* to commit its own work (`acceptEdits` grants edits but not Bash/git) —
the agent also has `gh`, so it pushed and opened the PR itself, front-running the
controller's Integrate step.

**Run 2 (same goal + a `[conventions] extra_rules` line telling the agent to
commit but NOT push/open a PR — leave landing to kazi). STUCK.**
The agent implemented `add`/`mul` and committed 3 scoped conventional commits on
`task/landing-dogfood`; the tree was clean and both code predicates passed — but
the branch was **never pushed and no PR was opened**, so `landed` stayed failing
for iters 1–3 and the loop escalated `STUCK — same failing set persisted:
[:landed]` at 4 iterations. The loop's documented "code green but not landed →
`:integrate`" decide clause did **not** drive the controller Integrate action to
push+PR the branch; with the agent no longer self-landing, nothing landed.

**Direct Integrate on run 2's committed branch → the vector-body PR.**
Invoking `Kazi.Actions.Integrate.execute/2` (the T44.3 verifies-then-ships path)
directly on that clean, committed, code-green branch pushed it and opened a PR
titled `integrate(landing-dogfood): … [adds, muls]` whose body is exactly the
auto-generated report:

```
## kazi verification report

Goal `landing-dogfood` (…) converged; landing verified — clean tree, committed on `task/landing-dogfood`.

Branch `task/landing-dogfood` → `main` — **rebase-merge** (never squash, never a merge commit).

### Predicate vector

- [x] `adds` — pass
- [x] `muls` — pass
```

So T44.3's PR-body generation (the predicate vector in the body) **works**; it
is simply not what opened the PR in the loop-driven run.

**What each piece did, honestly:**
- **T44.2 `landed` predicate — works.** It gated convergence in both runs: code
  green did not converge until landing was real (run 1), and correctly held the
  goal open → stuck when nothing landed (run 2).
- **T44.4 process contract — works.** Small scoped conventional commits on the
  goal branch in both runs.
- **T44.3 Integrate verifies-then-ships — the feature works** (produces the
  vector-body PR on a clean committed branch), but **the serial `kazi apply`
  loop did not auto-invoke it** for a `landed`-failing state. Landing in the
  converged run (run 1) was performed by the agent itself, not the controller.

**Finding (for follow-up, not fixed here — architectural, out of a dogfood's
scope):** in the serial single-workspace apply path, a failing `landed` predicate
is routed to agent re-dispatch, not to the controller Integrate action, so
landing depends on the agent self-landing under `bypassPermissions`. Two coupled
gaps: (1) the loop's `code-green-but-not-landed → :integrate` edge does not fire
here; (2) `bypassPermissions` (required for the agent to commit at all) also lets
the agent push/PR, so its self-authored PR body pre-empts kazi's verification
report even when Integrate would otherwise run. Worth a plan task to decide the
intended division of labor (agent-lands vs controller-lands) and wire the serial
loop accordingly.

**Acceptance vs. observed:** ≥2 scoped commits — met (3, both runs). `landed`
blocked-then-achieved — met (run 1 iter 1→2). A real PR with the predicate vector
in its body — produced by kazi's Integrate (the report above), though in the
loop-driven converged run the PR was agent-authored; reported honestly rather
than overclaimed. `mode = "merge"` was not exercised. Fixture repo and its PRs
were deleted after capture.

## 2026-07-17 — T55.10 LIVE dogfood: the E55 "team that nobody reminds", observed — and the no-reminder bar FAILS under load

The epic-closing observational dogfood for the whole E55 session-bus arc, run
against real live sessions on the shared NATS bus. Honest verdict up front: the
individual E55 surfaces mostly work, but the headline promise — a starting
session reaches the board WITHOUT a human prompt — is **FALSE in the real
environment today**, because the board is too slow for the hook that injects it.

### Environment (the staleness landmine, live)

- Installed CLI was **1.160.0** (stale; predates the entire E55 arc — it cannot
  even run `bus board`). Latest release is **v1.193.0** (cut today, includes
  E55). Per the CLAUDE.md landmine, I installed the v1.193.0 release binary
  directly (sha256-verified) over the stale one; `kazi version` → 1.193.0.
- The running SHARED daemon still reports **vsn 1.160.0** (uptime ~3.5 h,
  predates today's releases). I did **not** restart it: it serves live
  cross-machine sessions and a restart is high-blast-radius. So daemon-side E55
  code (T55.7 digest assembly, liveness verdicts) runs on stale code in the
  actual environment. This is itself the landmine live: the epic shipped to a
  release that the running daemon does not have.
- **Cross-machine: confirmed.** `kazi bus who --all` shows sessions on two
  machines (a laptop and a mini) sharing one bus.

### What works (observed live)

- **Idle vs dead (T55.11/T55.14).** `who --all` renders 13 sessions as `idle` or
  `active` with real recent heartbeats and **zero `dead-reaping`**, across both
  machines. The exact field pain that was diagnosed earlier today (a live session
  rendering `dead-reaping`) is gone in the live roster.
- **Claim visibility (T55.8).** `bus board`'s claims section shows 8 live pool
  claims with owner + age, including sibling agents' active claims. A starting
  session that reads the board CAN see what is already claimed. Caveat, observed
  live (docs/lore L-0037): every claim's owner renders as the SAME git identity
  (`t@example.com@<host>`), so the board shows WHAT is claimed but not WHICH
  session — it cannot attribute or fully de-dupe among sibling pool sessions.
- **Run-lifecycle mirroring (T51.5).** Live `run:*` progress facts on the board
  (e.g. `run:330915d9: iter 1: 0/2 passing`) — a supervisor sees a run's state
  without watching its JSONL.
- **Directed-message fate, half of it (T55.12).** A real `bus tell` returned a
  message id; `bus status <id>` reported **`pending`** with recipient + sent
  time. The `pending → consumed` transition was NOT cleanly reproduced in a
  self-directed test (a follow-up `bus read` did not consume it — likely a
  session-identity-resolution nuance across repeated CLI invocations, or the
  deep-inbox batching of L-0040). Pending-fate verified; consumed-transition not.

### Digest token cost (measured, #1)

One live sample of my session's inbox: `bus read --json` (bounded digest) =
**73 bytes**; `bus read --json --full` (every pending message, the pre-E55
raw-transcript equivalent) = **33,452 bytes** — a ~458× / ~99.8% reduction (~18
vs ~8,360 tokens at 4 B/token). Caveat: the two sequential reads share ack state,
so this is the mechanism's ceiling, not a perfectly-controlled A/B; the bound is
structural (ADR-0072, ≤40 lines regardless of backlog), and the 33 KB full read
is the raw volume the digest replaces.

### The no-reminder bar: FALSE (the capstone finding)

The `SessionStart` hook IS installed (`~/.claude/settings.json`:
`kazi bus hook session-start`) and DOES register presence on real starts (live
sessions show presence, so it runs). But invoking it — bare and with a real
`SessionStart` JSON on stdin — emits **nothing** (exit 0, empty stdout), so a
starting session gets **no board**.

Root cause, measured: `Kazi.Bus.Hook.run/2` hard-bounds the hook to **2 s**
(`@timeout_ms 2_000`, `lib/kazi/bus/hook.ex:37`), and `session_start/1` calls
`Bus.board`, but `kazi bus board` takes **9.70 s** under the real 127+-topic
machine-scope backlog (`/usr/bin/time -p kazi bus board` → `real 9.70`). 9.7 s ≫
2 s ⇒ the board call is always `Task.shutdown`'d ⇒ `:silent` ⇒ no injection. The
ADR-0072 40-line bound caps the board's OUTPUT, not its client-side DRAIN time,
and the machine scope had accumulated 127+ `run:*` mirror-fact topics (T51.5) to
drain. So under exactly the busy-team load the feature targets, the "team that
nobody reminds" silently reminds no one. Filed as **#1295** with the measurement
and suggested fixes (paged/deadlined board drain or server-assembled board;
raise the session-start hook budget; bound the `run:*` topic space).

**Verdict:** "the operator did not have to tell a session to check the bus" —
**FALSE as it stands in this environment.** The mechanism is wired and fires,
but the board it depends on is ~5× too slow for the hook's own timeout, so the
injection silently no-ops. The individual pieces (board, claims, presence,
idle/dead, run-mirror, tell/status-pending) are real and observable; the
end-to-end no-reminder promise is not yet met under real load. Reported as
observed, not as hoped.

## 2026-07-17 — T20.11 dogfood: kazi as the L1 merge gate — it works when driven with `--check`, but the documented recipe is wrong

Dogfood of the `/apply --verify-with-kazi` L1 gate (ADR-0026 L1, `apply/PHASES.md`
Step S2b): before merging a pooled task's PR, run the task's kazi goal and block
the merge unless the predicates objectively hold. Observed on the released
kazi **v1.193.0**. Both halves proven — and a real bug in the gate's documented
invocation surfaced.

### The gate mechanism works (observed both ways)

On a controlled fixture goal (one fast `custom_script` predicate: a marker file
must exist), driven with the observe-only mode:

- **PASS** (marker present): `kazi apply gate.goal.toml --check --json` →
  `status = "pass"`, `predicates=[{marker-present, pass}]`. The gate would ALLOW
  the merge.
- **BLOCK** (marker absent): same command → `status = "fail"`,
  `predicates=[{marker-present, fail, evidence:{exit:1}}]`. The gate would BLOCK
  the merge and surface the failing predicate's evidence.

### It blocks real broken code, on a real shipped goal

Corroborated against a real self-referential goal shipped by this pool wave —
`.kazi/goals/0072-json-locale-ascii-safe.goal.toml` (the T54.7 `--json` locale
fix). Reverting the one-line T54.7 fix (`escape: :unicode_safe` → plain
`Jason.encode!`) in a throwaway checkout and running the gate:

```
kazi apply .kazi/goals/0072-json-locale-ascii-safe.goal.toml --check --json
→ status = fail
   json-ascii-safe  -> fail (exit 1)   # the real T54.7 acceptance test
   full-suite-green -> fail (exit 1)
   format-clean     -> fail (exit 1)
   landed           -> fail (exit 1)
```

The gate correctly reported `fail` with the real acceptance predicate
(`json-ascii-safe`) catching the reverted fix — it would have BLOCKED a merge of
that broken state. The fix was restored immediately after; nothing broken was
committed or pushed anywhere.

Honest scoping: I proved the clean converged PASS on the fixture, not on 0072,
because 0072 carries a synthesized `landed` predicate (clean tree + pushed
upstream + HEAD==upstream) that always reports `fail` in a local, unpushed
checkout — so a real shipped goal cannot show an all-green converged verdict
locally regardless of code quality. That is a property of the goal's predicate
set, not the gate. The per-predicate teeth (`json-ascii-safe` flipping to `fail`
on broken code) is the real-code evidence.

### Finding: the S2b gate recipe is wrong (filed #1306)

Step S2b documents the gate as `kazi apply <goal-file> --json` (a FULL apply, no
`--check`) and says to proceed on `status == "converged"`. Both parts are wrong:

- A full `kazi apply` on already-passing predicates returns
  `status = "error", reason = "vacuous_goal"` (the t0 guard), **not**
  `converged` — so the documented gate would FALSE-BLOCK every correctly
  converged task. (And on failing code a full apply would DISPATCH a harness to
  fix it — not gate behavior at all.)
- The correct observe-only mode is `--check` (issue #805), whose status
  vocabulary is `pass`/`fail`, never `converged` — so gating on `"converged"`
  never matches the real output.

The gate is sound when driven as `kazi apply <goal> --check --json` and gated on
`status == "pass"`; the doc just names the wrong flag and the wrong status
token. Filed as **#1306** with the fix.

### L3 scope note

ADR-0026's ladder puts blast-radius **leasing across sessions** at **L3** (NATS
required); this task is the **L1** verification-gate dogfood (git-refs only). The
acc note's "after L3, extend to a leasing dogfood" is therefore out of scope
here — L3 is a later maturity level, not yet the subject of this task.

### Verdict

Did the kazi gate block a non-converged task, and cleanly pass a converged one?
**Both — yes, when invoked correctly (`--check`, gate on `pass`).** The gate's
value holds up under real observation. The one caveat is that the shipped
operator recipe (S2b) does not invoke it correctly and would misfire; #1306
tracks the doc fix.

## 2026-07-17 — T43.6 LIVE dogfood: the browser UI-assertion pack against kazi's own deployed site

Closed E43 (the browser UI-assertion pack) with a LIVE, read-only dogfood on the
deployed https://kazi.sire.run and a consolidated `assertions[].type` reference.

### The live check actually ran (not stub-only)

The blessed `agent-browser` path was **unusable here** — its global symlink
(`/usr/local/bin/agent-browser`) is a broken link to a `-darwin-x64` binary that no
longer exists in the package. But outbound HTTPS to the site works
(`node -e "fetch('https://kazi.sire.run')"` → HTTP 200), and the npm registry is
reachable, so I installed the runner's real deps into a scratch dir
(`npm i playwright axe-core && npx playwright install chromium`) and drove the
**actual shipped runner** — `priv/browser/playwright_runner.js`, the same code
`Kazi.Providers.Browser` invokes — against the live site with the exact JSON
payloads `priv/examples/live_site_ui.toml`'s predicates produce. Real Chromium,
real navigation, real axe-core. Observed verdicts:

- **`console_clean` (network = true)** → `{"status":"pass", assertions:[{type:"console_clean","ok":true,"expected":0,"found":[]}]}`.
  Zero `console.error`, zero failed 4xx/5xx on the landing page.
- **`a11y` (severity = "critical", max_violations = 0)** → `{"status":"pass", assertions:[{type:"a11y","ok":true,"count":0,"found":[]}]}`.
  Zero critical accessibility violations.

### The verdict is genuinely computed, not a rubber-stamp

Re-running `a11y` at the stricter `severity = "serious"` bar returned
`{"status":"fail", ...,"count":2}` — two real serious violations on the live page
(`color-contrast`, `scrollable-region-focusable`), with the count surfaced as the
envelope-v2 score (`lower_better`). Same page, same runner, different bar → a real
`:fail`. That is the proof the pack returns objective verdicts about the actual DOM
rather than always-green. The shipped goal-file gates at `critical` (a defensible
production bar the site currently clears); raise it to `serious` once those two are
fixed.

### What was NOT exercised through the full kazi loader→provider path

I drove the runner directly with the goal-file's payloads rather than through
`kazi apply priv/examples/live_site_ui.toml`, because the browser provider's
JSON-mapping seam (`Kazi.Providers.Browser.interpret/5`) is already covered by the
hermetic stub suite and the `*_live_test.exs` real-runner tests; the live value
this task adds is *the runner's verdict on the real site*, which is exactly what
ran. The goal-file loads clean through `Kazi.Goal.Loader` (verified in the
validation ladder), so the end-to-end path is `apply`-ready wherever Playwright +
axe-core are installed.

### Docs

Consolidated the full `assertions[].type` vocabulary (13 types: `visible`,
`hidden`, `text`, `url`, `console_clean`, `download`, `attr`, `count`, `enabled`,
`field_value`, `form_validation`, `a11y`, `visual`) into
`docs/browser-assertions.md`, with keys, examples, and pass/fail/error semantics
per type, matching `kazi schema browser` and the loader's
`browser_assertion_types/0` allow-list exactly. Linked from `docs/live-providers.md`
and the `docs/README.md` index.

## 2026-07-17 — T59.2: #1019 migration-lock fix holds under a live mixed-version window

Live-verified that #1019's two fixes — `1e4cccb` (bound the migration-lock wait
instead of hanging) and `4352f24` (refuse to migrate a schema NEWER than the
running binary knows) — hold when multiple released kazi binaries on DIFFERENT
versions concurrently touch one shared read-model db, the scenario the issue was
filed for. Both fixes are on `origin/main` (first released in v1.142.0).

### Method (real released binaries, isolated state)

Downloaded two prebuilt release binaries spanning a real schema gap (no repo
compile): **v1.195.0** (has the fixes; migration set ends at `20260709210000`)
and **v1.212.0** (latest; adds `20260717120000` roadmap_ref + `20260717170000`
discovery). Checksums verified against each release's `.sha256`.

**Isolation correction (operationally important):** `KAZI_STATE_DIR` does NOT
isolate the read-model db. `config/runtime.exs:21` resolves the db path as
`Path.join([System.user_home() || File.cwd!(), ".kazi", "kazi.db"])` — keyed off
HOME, not `KAZI_STATE_DIR` (which only covers `crash_dump.ex`, the `runs/` dir,
and the daemon). A first attempt with `KAZI_STATE_DIR` set still logged
"Migrations already up" against the REAL `~/.kazi/kazi.db`. Caught it before any
older-binary write; those touches were read-only/observe-only (`status`,
`apply --check`) and no migration ran, so the shared db was unharmed
(`PRAGMA integrity_check` = ok, 27 migrations intact afterward). Re-ran fully
isolated via `HOME=<scratch>` (plus a per-version `KAZI_INSTALL_DIR`), which
correctly created a throwaway db under the scratch HOME.

### Results — both fixes hold, no recurrence

- **`4352f24` refuse-newer-schema (sequential):** with the scratch db migrated to
  `20260717170000` by v1.212.0, running v1.195.0 against it degraded CLEANLY:
  `read-model schema v20260717170000 is newer than this binary (v20260709210000);
  running without persistence -- upgrade kazi` / `{:newer_schema, …}`, exit 0 in
  4s, valid JSON output. No migration-lock contention, no hang.
- **`4352f24` under CONCURRENT contention:** 3× v1.212.0 + 3× v1.195.0 hammering
  the one shared scratch db simultaneously all exited in **2s** — every v1.212.0
  persisted OK, every v1.195.0 refused-newer-schema cleanly and continued without
  persistence. The original bug was a 20+min 0%-CPU hang; it did not recur.
- **`1e4cccb` bounded migrate wait:** under box load ~30–40 even a single fresh
  isolated db occasionally hit `read-model migrate unavailable ({:timeout, 5000});
  continuing without persistence` — i.e. the bounded 5s wait degrading cleanly to
  no-persistence (L-0035 Guard) rather than the unbounded 0%-CPU hang. Retried and
  migrations completed once the momentary lock cleared.

Conclusion: neither the migration-lock deadlock nor the 0%-CPU startup hang
recurs across a real mixed-version window with the fixes present. #1019's remedy
is confirmed live; closing #1019 with this evidence.

### Secondary findings (routed, not silently dropped)

1. **Burrito wrapper prints housekeeping to STDOUT.** Every invocation of the
   downloaded binaries printed `[i] New install path is: …` (and, on a real
   upgrade, `[l] Skipped cleanup of older version …`) to STDOUT, before the BEAM
   starts — the `kazi-org/burrito` zig wrapper (`maintenance.zig`
   `do_clean_old_versions` / `erlang_launcher.zig`). This is the same
   stdout-pollution class as T58.3 gap 3 but a DIFFERENT code path (pre-BEAM
   wrapper, not the Elixir logger), so `bus read`'s logger→stderr fix does not
   cover it. It pollutes stdout for any machine-parsed command (`kazi version
   --json`, etc). → scoped as a new E58 task (see the T58.3 stdout-hygiene theme).
2. **Concurrent same-version cold-start install race.** Three concurrent FIRST
   invocations of one version sharing one `KAZI_INSTALL_DIR` failed with
   `error: FileNotFound` from the burrito wrapper (partial extraction visible to a
   racing sibling). Pre-warming each version's install dir once removed it. This
   is the burrito payload-liveness family (#1006/#1018), tangential to #1019's
   db-migration mechanism — noting it here; not a new task unless it recurs
   without the shared-install-dir artifact.

## 2026-07-17 — T59.1: #937 full gap inventory (serial-apply isolation / multi-process safety)

Read #937 in full — the issue body plus all 6 comments (2026-07-08 → 2026-07-10
triage ledger) — to scope the REMAINING concurrency-safety gaps, not just Gap A.
#937 was filed after three prior incidents (#786, #924, #936) plus a fourth,
previously-unfiled gap that caused a real data-loss incident (a serial `apply`
pointed at a live checkout whose internal "clean landing" then deleted every
untracked file outside the goal's `[scope]`). The comment thread adds facets the
body did not name, so scoping from the body alone would have missed the two
live incidents documented later in the thread.

### Distinct gaps named across the body + all 6 comments, with current status

**Gap A — serial `apply` has none of E21's `--parallel` isolation.** The umbrella
gap; decomposes into four sub-facets tracked separately below (A1–A4) because they
shipped/remain independently.

- **A1 — worktree indirection for serial `apply` (kazi owns the working dir).** The
  proposal's core ask: treat a serial goal as the 1-partition degenerate case so
  `--workspace` means "the branch/base to integrate onto" and kazi materializes and
  cleans the actual working directory. **Status: OPEN.** Only the primary-worktree
  *refusal* shipped (see A2). Evidence: `lib/kazi/runtime.ex:150` refuses a primary
  worktree but does not create a linked worktree for a serial run; there is no serial
  worktree materialization path analogous to the parallel `Kazi.Scheduler.Worktree.wrap/2`.
  The destructive-clean itself IS structurally gone — `lib/kazi/scheduler/serial_landing.ex:17`
  documents that landing never runs `git reset`/`git clean` against the base checkout —
  so the data-loss vector is closed, but the "kazi owns an isolated working dir for
  serial" ask is not. → **appended as T59.6.**
- **A2 — refuse a primary (non-linked) worktree as `--workspace`.** **Status: FIXED.**
  #940/#942 MERGED, v1.115.0 — `apply` refuses a repo's primary worktree root by
  default; `--allow-primary-workspace` overrides (`runtime.ex:150`).
- **A3 — never implement "clean landing" as a tree-wide `git reset`/`git clean`.**
  **Status: FIXED.** `serial_landing.ex` never resets/cleans the base checkout;
  landing is rebase-merge of the run-owned branch, recognized by branch IDENTITY
  (T54.1, #1079/#1080), not by tree-clean.
- **A4 — dispatch/landing commit step must stage only authored paths, never a blind
  `git add -A`** (the comment-5 incident where one group's commit swept a sibling
  group's uncommitted WIP — silent commit-boundary corruption). **Status:
  PARTIALLY FIXED.** `lib/kazi/actions/integrate.ex` `stage_all/2` (issue #819): a
  goal that declares `[scope] paths` gets scoped staging (`git add -u` for tracked
  mods + `git add -- <paths>`, never sweeping untracked files elsewhere). BUT a goal
  with NO declared `[scope] paths` still falls back to whole-workspace `git add -A`
  (`integrate.ex:512`, "backward compatible default"), so an unscoped goal sharing a
  tree can still absorb a sibling's WIP. → remaining piece **appended as T59.8.**

**Gap B — no supervised checkpoint between `needs`-DAG waves under `--parallel`
(#936).** **Status: FIXED.** #936 CLOSED — `--pause-between-waves`/`--resume` with a
persisted checkpoint (ADR-0065).

**Gap C — predicates converge on vacuous/superficial (grep) matches (#924).**
**Status: PARTIALLY FIXED / OUT OF SCOPE for E59.** The raise-the-floor mechanism —
ADR-0064 scenario predicates (epic E49) — has shipped; #924 itself is still OPEN.
Explicitly OUT OF SCOPE for this epic (with reason): it is a predicate-quality lane,
not a multi-process-safety one, already tracked in #924 + E49 and independently
valuable regardless of A/B/D. Named here so it is not silently dropped; no E59 task
appended for it by design.

**Gap D — native fleet mode for several goal-files as one coordinated DAG (#1005).**
**Status: FIXED.** #1005 CLOSED — `kazi apply --fleet <dir|manifest>` with cross-goal
`depends_on` DAG, per-member task worktrees, serial landing (T50.4/T50.5). The
first-dogfood teardown defect (#1053) is also CLOSED.

**Gap E — landing/acceptance predicates scoped to "the whole working tree is clean"
are unsafe under ANY multi-goal-same-workspace scheduling** (comment 2, 2026-07-09:
a `*-landed` predicate = `git status --porcelain` empty gave false negatives while a
sibling goal committed in the same tree; NON-destructive, but still corrupts the
predicate verdict). **Status: PARTIALLY FIXED.** T54.1 (#1079/#1080) made serial
landing recognize run-owned work by branch IDENTITY rather than a tree-clean check,
which removes the false-negative for the *landed* gate specifically. The general
hazard — a goal AUTHOR writing a `git status --porcelain`-empty *acceptance*
predicate that is structurally unsafe in a shared tree — remains unguarded; the
authoring clarify floor does not warn on it. → **appended as T59.10** (an authoring
guard/doc, low surface), and further mitigated by the isolation tasks T59.6/T59.7.

**Gap F — `--parallel` did not materialize one linked worktree per partition**
(comment 3, 2026-07-09, v1.127.0: `git worktree list` showed ONE worktree — the
`--workspace` path — with 9–10 `claude -p` agents all sharing that cwd; recommended:
verify `--parallel` always creates a per-group worktree AND surface isolation in
`--explain`/`--check`). **Status: LIKELY FIXED, surfacing UNVERIFIED.** The
worktree-per-partition machinery is present now — `Kazi.Scheduler.Worktree.wrap/2` +
`leased_reconciler.ex` + the `worktree_table.ex` survival registry (T21.4) + T54.1
real-branch checkout — so partitions get their own worktrees. What is NOT confirmed
is (a) that a `[[group]]`-only goal of the exact 1.127 incident shape actually
materializes N worktrees end-to-end, and (b) the thread's specific ask that
`--explain`/`--check` SURFACE the per-partition isolation so a caller can confirm it
before a long grind. → **appended as T59.9** (verification + surfacing).

**Gap A-dup (a facet noted in comment 1) — a second concurrent `apply` of a goal a
LIVE run already holds.** **Status: FIXED.** #942 MERGED / #944 CLOSED —
`guard_no_live_duplicate/2` (`runtime.ex:302`) refuses a second apply while a
fresh-heartbeat registry row for the SAME goal_ref is live; `--allow-duplicate-run`
overrides; zombie rows age out via staleness.

**Gap G — refuse a run whose `--workspace` is already in use by a DIFFERENT live
run** (comments 2 & 4: N goals dispatched against the SAME non-primary worktree by
hand; each goal's landed gate became "has every OTHER goal also finished," and worse,
cross-goal commit bleed). Distinct from Gap A-dup, which only covers the SAME goal on
the same workspace. **Status: OPEN.** The only cross-process guard is
`guard_no_live_duplicate/2`, keyed by goal_ref, not by workspace path; there is no
guard that refuses when the passed `--workspace` is already leased by a *different*
live goal. → **appended as T59.7.**

### Secondary observation (not a concurrency gap; routed, not dropped)

Comment 5 also noted a `Logger - error: {removed_failing_filter,logger_translator}`
/ repeated `DEFAULT FORMATTER CRASHED` burst around a mid-run Homebrew auto-upgrade
(1.127→1.129), flagged as "possibly a second, separate bug." This is the same
upgrade-path / burrito-old-version-cleanup family as #1255, which E59 already tracks
as **T59.3**. Noting it here so it is not lost, but NOT creating a new task —
T59.3's reproduction attempt should watch for this formatter-crash burst as a
correlated symptom.

### Scoping outcome

Shipped/closed: A2, A3, B, D, A-dup. Partially fixed with a named remaining piece:
A4 (→T59.8), E (→T59.10), F (→T59.9). Fully open: A1 (→T59.6), G (→T59.7). Out of
scope with a stated reason: C. Five new checkable tasks appended to Workstream A
(T59.6–T59.10). No gap silently omitted.

## 2026-07-17 — T58.4 scoped: burrito wrapper housekeeping pollutes STDOUT

Split out of T59.2's secondary finding into its own E58 task. T58.3 fixed
`bus read`'s stdout hygiene at the Elixir-logger layer, but a separate, EARLIER
path still writes to stdout: the `kazi-org/burrito` zig wrapper prints `[i] New
install path is: <dir>` (first-invocation extraction) and `[l] Skipped cleanup of
older version (vX.Y.Z): still in use by a running process` (old-version cleanup)
to STDOUT before the BEAM starts. Live-observed on the v1.195.0/v1.212.0 release
binaries during the T59.2 mixed-version repro — every invocation emitted the `[i]`
line to stdout (captured via separate stdout/stderr redirection with a scratch
`KAZI_INSTALL_DIR`). No Elixir logger change can reach pre-BEAM zig output, so the
fix is in the burrito fork (emit to stderr / gate behind verbosity) + a `mix.lock`
pin bump. Tracked as T58.4 (docs/plans/E58.md, Workstream B). Not the same bug as
T58.3 (different layer) or #1255 (that hang is fixed; this is output-stream only).

## 2026-07-17 — T59.3: #1255 `kazi version` hang — documented non-repro + startup watchdog

Per T59.3's acc ("EITHER a reproduced hang is root-caused and fixed, OR a
documented real reproduction attempt + a startup-hang watchdog/diagnostic ships"),
the outcome is the second branch: an honest non-reproduction of the original
`kazi version`-after-upgrade hang, plus a diagnostic watchdog so the NEXT specimen
is diagnosable in seconds instead of hours.

### Reproduction attempt (real, documented — matches the author's non-repro)

Downloaded the exact versions named in #1255's specimens (v1.154.0, v1.167.0,
v1.172.0, prebuilt release binaries, checksums verified), isolated via a scratch
`HOME` (NOT `KAZI_STATE_DIR` — that does not isolate the read-model db; see the
T59.2 entry) plus a per-version `KAZI_INSTALL_DIR`, never the shared brew install.
Three variants, none hung:

1. **Steady-state `kazi version`** (already-extracted binary): 1.7–6.4s over 5
   runs, exit 0. Consistent with the issue author's code read — the `version` path
   is Burrito-standalone and touches nothing that can block.
2. **First-invocation extraction**: 4–22s depending on box load — CPU-ACTIVE unzip
   (phoenix/live_view/erts payload), NOT the issue's idle-scheduler signature. A
   user on a heavily loaded box could *perceive* the 20s extraction as a hang; it
   is not the bug.
3. **The `.burrito_live` cleanup-skip path — the issue's own screenshot signature**:
   held v1.167.0 live via a real pid marker in its
   `.burrito/kazi_erts-<erts>_1.167.0/.burrito_live/<pid>` dir, then ran a fresh
   v1.172.0 upgrade invocation. It printed the exact issue line —
   `[l] Skipped cleanup of older version (v1.167.0): still in use by a running
   process` — and completed in **1.1s, exit 0**. No hang. (`.burrito_live/` is a
   directory of empty pid-named files; a STALE pid lets cleanup delete the old
   version, a LIVE pid makes it skip — reproduced cleanly.)

The original idle-scheduler `version` hang remains unexplained/unreproducible, as
the author found. The confirmed bus-path mechanism (`Gnat.Jetstream.Pager` no-`after`
`receive`) was already fixed in #1266/v1.186.1.

### Shipped: `Kazi.StartupWatchdog` (the diagnostic fallback)

`lib/kazi/startup_watchdog.ex` wraps the CLI dispatch at all three entry points
(`Kazi.CLI.main/1`, `Kazi.Release.cli/1`, `Kazi.Release.burrito_main/0`) in a
SEPARATE monitoring process with a deadline. It works precisely because the
observed hangs left schedulers IDLE — a distinct process is still scheduled and its
`after` timer fires. On timeout it dumps to STDERR where the main process is stuck:
its `:current_stacktrace` (turns "hung for 7 hours" into "blocked in
`Gnat.Jetstream.Pager.receive_messages/2`"), status/mailbox depth, run-queue
lengths (all-zero = the idle-scheduler signature), and open ports/fds (the `lsof`
the investigator ran by hand). Burrito's pre-BEAM extraction runs BEFORE this code,
so its time is not counted against the deadline.

Behaviour follows the codebase's degrade-visibly posture (`Kazi.SwapDiagnosis`, the
L-0035 read-model Guard): **dump-and-CONTINUE by default** so a legitimately slow
startup is never turned into a failure; opt into a hard `System.halt(124)` with
`KAZI_STARTUP_WATCHDOG_HALT=1`. Deadline via `KAZI_STARTUP_WATCHDOG_MS` (default
30000; `0` disables). Tested at the function level
(`test/kazi/startup_watchdog_test.exs`) — a blocking fun trips the dump and names
the block; a fast fun returns its value with no dump; `deadline_ms: 0` is a
pass-through — no full release build needed for the test.

### Secondary (routed to T58.4)

Confirmed the stream split for the burrito-stdout gap: the `[l] Skipped cleanup`
lines go to STDERR (already correct); only the `[i] New install path is:` line
goes to STDOUT. So T58.4's precise fix target is the `[i]` install-path line.

## 2026-07-18 — T62.5: live origin-branch landing for `--parallel` per-group results (#1241 part 1)

T44.10 (PR #1240) shipped the per-group landed-refs contract but tested it only
through the injectable integrator seam. The live gap it deferred turned out to be
TWO concrete defects, not just a missing verification — both found and fixed here:

**Finding 1 — converged commits never reached origin.** A `--parallel` partition's
worktree is torn down the instant its reconcile returns (issue #1053). The only
push was the CREATE-time upstream push (issue #1075), which pushes the isolation
branch while it is still at the base tip — the converged commit that lands AFTER it
was never pushed, so origin's group branch carried nothing to land. Fix: on
`:converged` (parallel path only, and only when a landing is configured), the
worktree wrapper now pushes the worktree HEAD to the STABLE group landing branch
before teardown.

**Finding 2 — the landing branch and the pushed branch disagreed.** The worktree
branch carries a per-process nonce suffix (issue #1074) for cross-run isolation,
but the scheduler derives the collective's landed branch as the NONCE-LESS
`<branch_prefix>/<slug>` (`partition_landing_branch/2`). A live worktree-less
landing keyed on the derived name would never find the pushed nonce branch. Fix:
the pre-teardown push targets the stable name explicitly (`HEAD:<prefix>/<slug>`),
so the pushed branch and the landing target agree.

**Shipped — `Kazi.Scheduler.Integration.OriginIntegrator`.** The worktree-less
landing the default `ActionIntegrator` could not do (`{:error, :no_worktree}` when
the worktree is gone): given a group branch already on `origin` and the shared
base, it rebase-merges the branch onto the base entirely through a kazi-owned
scratch worktree of a checkout that shares `origin`, then pushes the advanced base
back. A rebase/push conflict maps to the same re-dispatchable `{:conflict, _}` the
other integrators use; a missing `origin/<branch>` is an honest hard error, never a
silent success.

**Live proof.** `test/kazi/scheduler/origin_landing_live_test.exs` (tagged
`:integration`) runs a real 2-group `run_goals` against a throwaway bare origin —
real worktrees, real disjoint commits, the real OriginIntegrator (no mock) — then
verifies every surfaced `landed` ref INDEPENDENTLY against a fresh clone of that
origin: each branch exists, each `merge_commit` is a real commit reachable from
`origin/main`, and both groups' disjoint files are present on the landed base. A
`mode:none` run (no integrator) leaves the base byte-identical — regression pin.
Deferred to T62.6: persisting these refs into the read-model `kazi status` verb,
and auto-selecting OriginIntegrator from a goal's `[integration]` mode in the real
CLI (still its own review, per PR #1240's scoping).

## 2026-07-18 — T49.13 DOGFOOD: kazi's own capabilities as scenario predicates (UC-066/UC-067)

kazi's shipped surfaces gated as `scenario` predicates (ADR-0064) against the
RELEASED binary. Artifacts: `docs/specs/kazi_cli.feature` (an `@interface:cli`
Scenario "A user inits plans approves and applies a hello goal" + an
`@interface:web` dashboard Scenario), `priv/examples/kazi_capabilities.goal.toml`,
and the cli pin
`docs/specs/pins/kazi-cli__a-user-inits-plans-approves-and-applies-a-hello-goal.pin.json`.

**Binary flavor (honest).** Released binary `kazi 1.228.0` — the macOS x86_64
GoReleaser/burrito asset of tag `v1.228.0`, sha256 verified, installed to
`/usr/local/bin/kazi`. This was the newest release WITH published assets: the
newest tag at run time, `v1.229.0`, had 0 assets (released minutes earlier, still
building), so per the task's "newest release with assets" fallback I used 1.228.0
and recorded the flavor here rather than block.

**The cli pin (the grader).** A `:cli`-surface pin whose `trace.script` is the four
real sub-invocations of the journey — `kazi init .` → `kazi plan --json
--predicates <hello> --replace` → `kazi approve <content-hashed-ref>` → `kazi apply
<trivially-green fixture> --check` — each with its own exit-code + stdout
assertions. The proposal ref is deterministic (`prop-caller-supplied-predicates-<hash>`,
a content hash, not random), so `--replace` makes the plan→approve handoff
replayable without a `{{placeholder}}`. `scenario_sha` matched on first try (the
pin classified `:pinned`, i.e. reached replay, never `{:stale, :spec_changed}`).

**GREEN replay (observed — the truth invariant).**
`kazi apply priv/examples/kazi_capabilities.goal.toml --workspace . --check --json`
with the cli predicate's `cmd` resolving to the CLI binary → predicate
`cli-hello-goal-journey` verdict **pass**, all four journey steps green, replayed
by the `:cli` surface provider against the released binary. No agent claim in the
loop — the pass is what the surface provider observed on replay.

**RED chain (observed — capability regression, not selector rot).** With the pin
UNCHANGED and the workspace `HEAD` still equal to the pin's `minted.commit` (so a
red replay is classified a regression, not `{:stale, :code_drift}`), pointing
`cmd` at a throwaway shim that delegates every verb to the real binary EXCEPT
`apply` (which it fails, exit 1, no `pass` on stdout): predicate verdict **fail**,
`pin_state: pinned`, `passing_steps: 3 / 4`, `failed_step` = the `apply` step, with
`assertion_failures` `exit_code expected 0 found 1` and `stdout contains "pass"
found ""`. The pin did not move; the surface (binary) broke — exactly the
regression signature the truth invariant is meant to catch. The shim was never
committed. **Re-demonstration fails by construction:** the demonstrator's
born-reproducible acceptance gate (T49.7) mints a pin then IMMEDIATELY
validate-and-replays it, keeping it only on green; that replay is the very red
observed above against the broken surface, so no freshly-minted pin can be
accepted — a broken capability cannot be re-pinned green.

**Finding — nested-`kazi` PATH shadowing.** `cmd = "kazi"` (a `$PATH` lookup)
reds when the OUTER driver is itself the release binary: the release process
prepends its release `bin/` — which holds a `kazi` START LAUNCHER
(start/daemon/eval/rpc), not the CLI — to the child `$PATH`, so a nested bare
`kazi` hits the launcher and every step reds with the launcher usage on stderr.
Driving the identical pin against the CLI binary directly (an outer that does not
shadow `kazi`, or `cmd` set to the binary's absolute path) replays green. The
shipped `cli_release_smoke.goal.toml` reproduced the same red here (its nested
`kazi version`/`status`/`apply` all exited 1), so this is a latent hazard of the
`:cli` surface under a release-binary outer, not specific to this pin.

**Honest gaps.**
- The pin was HAND-AUTHORED (docs/scenario-predicate.md sanctions this as an
  identical artifact to a demonstrator-minted one); a LIVE harness-driven
  demonstrator dispatch was NOT run — no coding-agent harness is available in this
  sandbox. The demonstrate→reject mechanics are covered by T49.7/T49.8 ExUnit; the
  load-bearing observation here is the REPLAY verdict (green→red), which is the
  predicate's truth regardless of who authored the pin.
- The `@interface:web` dashboard Scenario is NOT live-verified. `kazi dashboard`
  DOES boot on the released binary (observed: it logged `Running KaziWeb.Endpoint
  ... at 127.0.0.1` and served), but the `:browser` replay could not run from this
  sandbox — HTTP egress even to loopback is blocked here (no live browser). Its pin
  is left `:unpinned` (demonstrator/live-browser work), and the goal-file documents
  it as CHECK-not-converge, mirroring `cli_release_smoke`'s live-infra surfaces.
- Binary flavor is 1.228.0, one release behind the newest tag (1.229.0, assets not
  yet published at run time).
