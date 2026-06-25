# kazi -- project instructions

kazi is a reconciliation controller for software goals: declare a goal as
machine-checkable predicates; kazi drives a coding agent in a loop until the
predicates are objectively true, stuck, or over budget. It drives harnesses
(Claude Code, Codex); it is not a harness.

## Read before changing anything

- `docs/concept.md` -- canonical concept and architecture (source of truth).
- `docs/adr/0001`..`0007` -- frozen decisions. Do NOT relitigate them in passing.
  To change a decision, write a superseding ADR.
- `docs/plan.md` -- the live build plan and the unit of execution.

## Plan layout (split, T31.1)

`docs/plan.md` is a **master index**: each epic heading is a pointer
(`### ENN -- Title -> plans/ENN.md`) and the epic body (its `- [ ] TNN ...` task
lines) lives in `docs/plans/ENN.md`. To read the FULL WBS, expand the includes:

```
python3 ~/.claude/skills/plan/scripts/parse_plan.py   # -> .claude/scratch/parsed-plan.json
```

or read the epic files directly. **Do not** raw-grep `docs/plan.md` alone for task
lines — it holds only pointers. Tooling that walks tasks must cover
`docs/plan.md` AND `docs/plans/*.md` (the doc-freshness checks and `/apply --pool`
task-discovery do). The split is transparent to `parse_plan.py` (same epic/task
counts as the pre-split monolith) and is the precondition for per-epic archival
(T31.2).

## Execution model

- Work the plan with `/apply --pool` (the operator runs several sessions via
  `/loop /apply --pool`). The plan's Waves section prescribes parallelism; the
  WBS (master `plan.md` + `docs/plans/*.md`) is the single checkable source of
  truth.
- Pool coordination uses `/claim` (atomic git-ref locks at `refs/claims/*`). The
  repo has no local `.claude/scripts/claim.sh`; the global fallback
  `~/.claude/skills/claim/scripts/claim.sh` is used automatically.
- Build order is a walking skeleton, idea -> production from Slice 0. Deepen
  phases later; do not add a phase because the SDLC diagram lists it (ADR-0007).
- Success bar: kazi converges a goal a prose pipeline left subtly broken
  (dogfood fixtures T0.12, T1.8), including a live production probe.

## Stack conventions

- Elixir / OTP. Tests in ExUnit; format with `mix format` (CI checks
  `--check-formatted`). Prefer stdlib + the Phoenix/Ecto ecosystem; do not pull
  heavy deps without an ADR.
- SQLite (WAL) via Ecto SQLite3 for the local read-model.
- Podman for container builds; Cloud Run for the deploy target; GitHub Actions
  for CI/CD.
- NATS JetStream and Phoenix LiveView are NOT dependencies until Slice 3. Deploy
  IS in Slice 0 (thin, behind a stub until the cloud target T0.6h is provisioned).

## Definition of done

Per the global definition of done: tests green, `mix format` clean, PR
rebase-merged with CI green, and -- for any production surface -- deployed and
verified live (a live predicate passes), reported honestly. Many small commits;
do not commit files from different directories in one commit.

## Docs land with the code (ADR-0034)

A user-facing or behavioral change is not done until its docs are done in the SAME
change. If you add or change a command, flag, CLI/API surface, predicate provider,
config, or public capability, update the matching docs (README / `docs/` / `kazi
help` text / the relevant ADR) before the task is complete. Code without its doc
counterpart is unfinished. Exception: a trivial internal refactor with no surface
change. Enforced as an `/apply` wave gate and a CI check (E29).

## Open source repo -- never leak internal info (ADR-0034)

This repo is public. Do NOT put internal-only details into code, comments, docs,
commit messages, issues, or PRs: private IPs/hostnames (`192.168.*` etc.), internal
infrastructure or tool names, internal company/project codenames, personal usernames
or absolute home paths, or "how we run it internally" process detail. Genericize
(say "a local model" / "a deploy target", not the specific internal host) or omit.
Honest engineering findings + benchmarks are fine once scrubbed of internal
specifics. A CI guard scans the diff for these markers (E29).
