# Handover -- 2026-07-21T22:30Z (approx), session 26dd9fa2

## TL;DR
This session ran a large multi-agent push: closed E67 (velocity dashboard),
ran the T45.10 self-hosting exit-proof twice (both FAIL, but each failure
found and fixed a real bug), root-caused and fixed the exit-78 launchd
crashloop (#1484), and bounded the Mission Control mount query (T66.5). Plan
is 392/396. **Single next action:** deploy v1.275.0 to the affected mac-mini,
update its LaunchAgent, and observe a clean `launchctl kickstart -k` to close
out T66.2 (see Blocked).

## Done & VERIFIED (observed evidence per line)

- **E67 (velocity/dashboard KPIs) fully closed.** T67.6 ticked; PR #1660
  merged. Verified by watching a live number move, not by reading a green
  check: the velocity collector was found DISABLED with stale rows already in
  the read-model (the exact #1483 "plausible dashboard over silently-empty
  data" shape this task existed to catch); after opting the collector in and
  restarting the daemon, a real pass wrote fresh rows and the Mission Control
  panel's DELIVERED figure moved 200 -> 202 in front of me.
- **Guard contract fix.** PR #1661 merged, issue #1652 closed. Guard.run/3
  now uses an unlinked `spawn_monitor` worker instead of `Task.async` (which
  links, so an untrappable async exit used to kill a non-trapping caller like
  MissionControlLive). Tripwire test **inverted** (not deleted) -- it now
  asserts the fixed behavior. 116/116 read_model tests pass. Honestly scoped:
  no production trigger for the original defect was ever identified; this was
  a contract-correctness fix (`read_model.ex` promised "never fails the
  caller" and that was false for non-trapping callers).
- **T66.5 -- Mission Control's mount query no longer scales with total run
  count.** PR #1675 merged. Added `RunRegistry.list_recent/1` (SQL
  `LIMIT`-bounded, default 150), wired into the LiveView's mount + 2s poll
  tick. I independently reproduced the improvement myself (reverted the
  wiring in the worktree, re-ran the mount test with explicit timing):
  **1826ms unbounded vs 808ms bounded**, ~2.3x, on a clean checkout. Trade-off
  documented at the call site: CLOSED-tab counts now reflect the 150-row
  window, not literal all-time totals; full history stays available via
  `RunRegistry.list/0` (CLI/API).
- **#1484 root-caused and fixed (code).** PR #1676 merged, issue #1484
  CLOSED, in v1.275.0 (verified by `git merge-base --is-ancestor`). Root
  cause: exit 78 is launchd's own `EX_CONFIG`, **not kazi's** -- kazi never
  returns 78 anywhere in `lib/`. The installed binary is adhoc/linker-signed;
  an in-place upgrade (Homebrew, self-update) leaves a registered LaunchAgent
  pinned against the PREVIOUS binary's code requirement, and launchd refuses
  to spawn the job at all. Confirmed by experiment on the affected mac-mini:
  `launchctl bootout` + `bootstrap` of the same plist, with no change to the
  binary, flipped the job's last exit code from **78 -> 1** and its `runs`
  counter from **33,035 -> 2**. Fix adds `kazi daemon reregister` (macOS-only,
  no-op elsewhere) plus conditional `KeepAlive` so the crashloop can't recur.
  **This fix is in the code and released (v1.275.0) but NOT YET DEPLOYED to
  the affected mac-mini** -- see Blocked/T66.2.
- **T45.10 authoring gaps fixed.** PR #1672 merged, issues #1668 and #1669
  closed. `kazi plan` now detects when it's authoring against kazi's own
  source tree and (a) warns + steers away from `cli`/`custom_script`
  predicates that would measure the installed binary instead of the edited
  source, (b) defaults a minimal grader read-only lease. I caught and sent
  back one real overreach before merge: the first cut would have silently
  turned enforcement ON for a repair-mode goal via struct defaults; fixed to
  overlay only `read_only_paths` onto the mode-respecting profile.
  **Unblocks a real third T45.10 attempt** (see In flight below).
- **kazi help / registry parity fixed.** PR #1663 merged, issue #1659 closed.
  `dashboard` and `spec` were registered but missing from the human-readable
  `kazi help` text; added, plus a registry-enumerating parity test so this
  can't silently drift again.
- **Task.async link-site audit.** PR #1667 merged. Every remaining
  `Task.async` call site in `lib/kazi/` was walked against the L-0053 defect
  class (async exit kills a non-trapping caller); **none were reachable** --
  documented as L-0054 in `docs/lore.md` specifically so a future reader
  doesn't "fix" one of these on shape alone (the #1637 mistake this session
  kept re-encountering in other forms).
- **Attribution guard now enforced in CI.** PR #1673 merged. A dispatched
  agent added `Co-Authored-By:` trailers to 5 commits mid-session; caught by
  hand, not by any gate. `.github/scripts/no_attribution_guard.sh` now blocks
  on it (scans commit messages, not just the diff -- the existing leak guard
  only scans the diff and could never have caught this). Verified it passes
  against its own introducing PR.
- **T45.10 attempt-2 evidence recorded + a corrected re-run bar.** PR #1664
  merged. The plan's own advice ("provision the workspace first") was
  unachievable as written -- kazi grades predicates in a task worktree, not
  the directory an operator provisions -- and the corrected text says so, so
  the next runner doesn't repeat the dead end.
- **Branch triage:** ~20 stale git branches reviewed against plan/issue
  state; 19 confirmed superseded and deleted, 1 salvaged (4 files landed via
  PR #1671; a 5th file, `docs/handover.md`'s predecessor draft, was
  deliberately dropped for containing a personal gist URL + absolute home
  path). **The 19 deleted branches' restore SHAs are recorded below** (their
  original list lived only in this session's ephemeral scratchpad and would
  otherwise be lost).
- **Two dead ADR links fixed** (PR #1670) found during T25.10's mechanical
  launch-gate prep; that prep is otherwise fully green (model IDs verified
  live against the API reference, version currency, README<->site coherence,
  no "coming soon" tags, no measured-cost claim) -- only the go/no-go and the
  announcement itself remain, and those are founder-only.
- **Local `kazi` binary upgraded to v1.275.0** on this machine (checksum
  verified against the published `.sha256`), matching the latest release --
  required so this machine's own dogfooding reflects today's fixes rather
  than silently running around them.
- **Separate repo, `dndungu/skills`:** the personal `/sitrep` skill was
  rewritten to forbid bare task/issue IDs (every ID must now carry a
  plain-English gloss); a `parse_plan.py` regex bug that undercounted
  completed tasks (`DATE_RE` anchored to end-of-line missed any date
  followed by trailing PR/release provenance) was fixed; a `color-design`
  skill that was sitting untracked got committed. Merged as
  `dndungu/skills#115`.

### Branch restore manifest (19 branches deleted as superseded; all verified
fully-merged via `git cherry` before deletion -- restorable if any call was
wrong)

```
d29be764303f21bb15e3cbea9127f9226cfcb129 refs/heads/MVP
621da6989422f9b0ed6009d87a31a9c174dfe92d refs/heads/v0
551d4fc6578436287119fff76ef3e4be9982104b refs/heads/v1
65fbf192feb9431dbd4c857037be68fc487bb4e6 refs/heads/v2
923cab7aa523f2e79f4bebbe3a77703f35c655f9 refs/heads/v3
cdb7bdd323468cba80bc35184065e36c5d1d0197 refs/heads/v4
a2775276d8f62b9c4de550fb016a270e894563c3 refs/heads/v5
56adf55f90fb21b1cf1cd1c3550b3ffe11914920 refs/heads/v6
039fcbcf2ac3b5c5bdc90056c3fd37d37ad82596 refs/heads/feat/t32.2-envelope-v2-evidence
a92ea54c48d58c7e866b96a295fd7b33acbb0346 refs/heads/fix/issue-769-claude-permission-surface
24f95b0ced20bd10bc9d1e2b9de1951382ce51e0 refs/heads/kazi/integrate-1783473824
027b7a149e8e368e91e22fa4f70b2eeeeeedad65 refs/heads/feat-plan-apply-provenance
76e91662a774f3fce94f93fbafc50a04e51a7f0a refs/heads/task/fleet-discovery-dag
d0b69d77ddab2ffb7362ff3129ddfa31aa253e2b refs/heads/task/e50-safe-concurrent-work
6e45f2c2656cb6973e55595e8cdd18a95055b920 refs/heads/kazi-partition/p-daemon-cross-mac-9
fd339f7d2446ba47154180aa7a199ca772801fb8 refs/heads/task/scoped-commit-guard
904b1dafba3c75bcc3caf985c58d45f2b6ffa12c refs/heads/task/warnings-clean
2c16a0daadb23dcf9fa342714aec91abce1be40f refs/heads/pool-task-T45.1
4753eb05d228d3563d475c726a1d45d67263745b refs/heads/task/t60-5-economy-table
```
Restore any of these with: `git push origin <sha>:refs/heads/<name>`.

## Done but UNVERIFIED

- **Main CI at the current HEAD (`a6aaca4c`, release 1.275.0 auto-cut) was
  still IN PROGRESS when this session ended.** Not confirmed green. Check
  `gh run list --branch main --workflow CI --limit 1` before trusting main is
  clean.
- **T66.5's own live acceptance criterion** (a released binary, hours after
  restart, real accumulated history, `GET /` under 20s) was explicitly NOT
  verified -- that needs a release + live check, which is why the plan line
  stays unticked despite the fix being merged. Don't tick it without that
  observation.
- **The remote GPU host used for the T45.10 dogfood attempts is still up and
  reachable** (confirmed at handover time: idle, load ~0.2 across 20 cores),
  with a warm Elixir/OTP toolchain and an authenticated Claude Code + `gh`
  session from earlier. Whether those auth sessions are still valid was not
  re-checked. Not torn down -- useful for a T45.10 attempt 3, disposable
  otherwise.

## In flight

None. Everything that was mid-work at session end either finished (see Done)
or is cleanly parked (see Blocked) -- no half-finished edits, no open
worktrees beyond the main checkout.

## Blocked

- **T66.2 (tracks #1484)** -- needs David or a session with mac-mini access.
  The FIX is merged and released (v1.275.0), but T66.2's own acceptance bar
  requires a LIVE observation on the AFFECTED machine: deploy v1.275.0 +
  the new LaunchAgent template there, run `launchctl kickstart -k` from a
  clean slate, and observe either a clean start (stable pid, socket served,
  versioned log line) or a loud non-zero exit with a diagnostic -- "78 with
  zero output" must be impossible. **Do not tick T66.2 from the GitHub
  issue's closed state alone** -- #1484 auto-closed when PR #1676 merged, but
  that is not the same as the plan task's acceptance bar being met.
  Confirmed at handover time: the affected mac-mini is still running the
  OLD binary (`kazi 1.273.7`) and has not received the fix.
- **T25.10 (launch gate)** -- mechanical prep is fully green (see Done). The
  go/no-go decision and the announcement itself are founder-only; nothing
  else to do here without David.
- **T45.10 (self-hosting exit-proof)** -- stays open after 2 FAIL attempts.
  Both failures were legitimate findings, not wasted runs: attempt 1's
  confounds (loaded machine, unprovisioned workspace) were removed and
  attempt 2 still failed because `kazi plan` had no self-hosting awareness
  (now fixed, see Done). **A third attempt is now meaningful** and the
  environment is still warm (see Unverified above) -- but it is a multi-hour,
  real-money dogfood run, not something to launch casually; get explicit
  buy-in before spending it.

## Running processes left alive

- **The local daemon on this machine** (`run.kazi.busdaemon` via launchd) is
  healthy: 263+ velocity passes, 0 crashed, collector enabled. Left running
  on its existing binary (older than the just-upgraded CLI on PATH -- this is
  normal; the daemon doesn't need to match the interactive CLI's version, and
  restarting a healthy long-running daemon for a handover was judged not
  worth the disruption to other sessions sharing the bus).
- No kazi converges (`kazi apply` runs) were left running by this session.
- The remote GPU host (see Unverified above) has no kazi process running on
  it currently, just a warm toolchain.

## Landmines & context (non-obvious things that will bite)

- **macOS has no `timeout` binary.** Use `ssh -o ConnectTimeout=N` or
  backgrounded commands with your own polling instead, or things silently
  hang the session.
- **A stale git branch's raw diff can look like it reverts recent work when
  it's actually just base drift.** Several PRs this session showed large
  deletions in `git diff origin/main..branch` because the branch predated
  later merges landing on main; always check `git show --stat` /
  `git log --name-only` on the ACTUAL commits in question before treating a
  diff stat as ground truth.
- **`git checkout <branch>` does not fast-forward from `origin/<branch>`.**
  After merging a PR, `git checkout main` alone can leave you on a stale
  local `main` that's missing the just-merged commit. Fetch + `git merge
  --ff-only origin/main` (or `reset --hard` after confirming via `git cherry`
  that nothing local is unique) after every merge.
- **The doc-command-accuracy CI guard (T28.4) treats any dash-token on a
  line containing the word "kazi" as a kazi flag** -- even a `grep -c` or
  `grep --count` belonging to a DIFFERENT command on the same line. Keep
  foreign commands' flags off any line that also names `kazi`.
- **The #1255 startup watchdog prints a "hang" banner during completely
  normal long waits** (harness dispatch, `Loop.await`) -- it produced a wrong
  verdict on T45.10 attempt 1 ("wedged at iter 0") when the run was actually
  fine. Filed as #1662, not yet fixed. Don't trust the banner's own framing;
  check whether the process actually completed.
- **`kazi apply` runs predicates in a task worktree with no `deps/`/`_build/`**
  (both gitignored) -- any mix-backed predicate is red at t0 by construction
  (#1642), and provisioning the WORKSPACE you pass to `--workspace` does not
  fix this, because that isn't the directory kazi grades in. `--in-place`
  is refused on a repo's primary worktree (#937) for good reason (an agent's
  shell could reset/clean the whole checkout). The only working path found
  this session: `git worktree add` a DEDICATED directory, warm IT
  specifically (`mix deps.get && mix compile` inside it), then
  `kazi apply --in-place --workspace <that dedicated worktree>`.
- **`~/.claude` (the parent dotfiles dir) has its own git repo with no
  `.gitignore`** and ~811MB of untracked runtime state (session transcripts,
  history, caches) that should almost certainly never be committed.
  `~/.claude/skills` is a SEPARATE, intentional repo (`dndungu/skills`) --
  the only one of the two that should be touched for skill/config changes.
- The claim `refs/claims/T66.7` is still held on the bus/git-refs claim
  system even though T66.7 is long since ticked `[x]` on main -- looks like a
  stale claim from a session that finished without releasing it. Not
  released by this session (not held by this session, and touching another
  session's claim ref is out of scope) -- worth a `/claim --prune` sweep by
  whoever owns that.

## How to resume

1. `git fetch origin && git checkout main && git pull --ff-only`.
2. Read this file, then `docs/roadmap.md`'s "Last updated" line, then
   `docs/plan.md` + `docs/plans/E66.md` (T66.2) / `E45.md` (T45.10) /
   `E25.md` (T25.10) for the three open tasks' exact acceptance text --
   don't rely on this summary alone for the acceptance bar wording.
3. Confirm main's CI is actually green at HEAD (see Unverified above) before
   building on top of it.
4. Pick a lane: T66.2 needs mac-mini access; T25.10 needs David; T45.10
   attempt 3 needs explicit buy-in given its cost, plus a fresh check that
   the remote GPU host and its Claude Code/`gh` auth are still live.
5. No checkpoint file was needed for this handover (no mid-task state to
   resume; everything reached a clean commit/merge boundary) -- this file IS
   the resume point.
