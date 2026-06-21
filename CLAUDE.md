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

## Execution model

- Work the plan with `/apply --pool` (the operator runs several sessions via
  `/loop /apply --pool`). The plan's Waves section prescribes parallelism; the
  WBS is the single checkable source of truth.
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
