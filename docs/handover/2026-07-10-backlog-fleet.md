# Handover: run the backlog fleet (briefs 0027–0032)

**From:** triage + planning session, 2026-07-10. **For:** the next coordinator session, starting in this directory (`~/Code/kazi-org/kazi`, main @ `5fea4f6`).

## State

- The 2026-07-10 issue triage is done: #936 and #1005 closed as shipped, #1061 filed (main CI hard-red), cluster comments on #1019/#1060/#937. Open actionable issues map 1:1 onto grind briefs `.kazi/goals/0027–0032` (merged via PR #1062, `kazi lint` clean).
- **Main CI is RED** (deterministic, not flaky): all 8 daemon tests fail on Linux because `nats-server` is not installed on the runner (`Kazi.Daemon.start/1` fails fast per T51.2; `ci.yml` has no install step). Brief 0027 fixes it and every other brief `depends_on` it — do not fan out before 0027 lands and main's CI run is green.
- Fleet DAG verified read-only: `kazi apply --fleet <dir> --explain --json` → waves `[ci-daemon-nats-green] → [fleet-teardown-hardening, upgrade-lifecycle-hardening, bus-cli-contract, scoped-commit-guard, full-suite-deflake]`.

## The run

```sh
# fresh base worktree (never point --workspace at this checkout; #940 will refuse anyway)
git worktree add ../wt-backlog origin/main --detach

# batch dir with ONLY the six new briefs (a full .kazi/goals fleet would re-drive old converged briefs)
mkdir -p /tmp/fleet-0027-0032 && cp .kazi/goals/002[7-9]*.goal.toml .kazi/goals/003[0-2]*.goal.toml /tmp/fleet-0027-0032/

kazi apply --fleet /tmp/fleet-0027-0032 --workspace ../wt-backlog \
  --harness claude --model claude-haiku-4-5 --json --stream
```

- Two-tier recipe: predicates are already authored (frontier tier); Haiku grinds. On a `stuck`/`over_budget` member, escalate that member only, up the ladder `claude-haiku-4-5 → claude-sonnet-5 → claude-opus-4-8` (per-goal_id counter; see the kazi skill).
- Each brief lands its own `task/<goal-id>` branch (the `landed` predicate requires push). Rebase-merge PRs; no squash, no merge commits, no attribution lines in commits.
- After 0027 merges, confirm a green CI run on main **before** trusting wave 1's full-suite guard predicates — they are only meaningful on a green base.

## Watchpoints

- #1013 (RunRegistryWiringTest): hardening already landed; it now polls the projection and WARNs on drop points. If it reds a run, capture the WARN lines — do not rework it (brief 0032 says the same).
- Fleet teardown is itself the subject of brief 0028 — the fleet *running* this batch may hit #1053's teardown crash. If a member reports `crashed` with its branch already pushed, treat the work as landed (verify the branch) and continue; that is exactly the bug being fixed.
- The linux_aarch64 release job 422s when re-uploading an existing asset (raw curl, no upsert) — known, unfiled, unrelated to this batch.

## Out of scope (deliberate)

#924 (owned by E49 scenario predicates), live/maintainer plan-tasks #335/#382/#696, and the E20/E25/E37 epics.
