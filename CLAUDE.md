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
- `docs/specs/` -- per-task **behavior specs** (Gherkin `.feature`, ADR-0050):
  the reviewable "what behavior is being built" tier, upstream of `goal.toml`
  predicates. Optional per task; a plan task references its spec via `spec:`.
  Not the same as a "goal spec" (`goal.toml`, ADR-0036) or an Elixir `@spec`.

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
counts as the pre-split monolith).

**Archival (T31.2/ADR-0036 L1).** `.github/scripts/trim_plan.py` is the
deterministic, lossless trim: it archives an epic ONLY when it is fully closed
(no open/blocked task) AND release-covered (every `[x]` task's `Done:` date is on
or before the newest release tag). It moves the epic file verbatim to
`docs/plans/archive/`, drops its WBS pointer, and records a one-line entry in the
master's `## Archived epics` section. `trim_plan.py` dry-runs by default; `--apply`
performs it; `test_trim_plan.py` pins the lossless round-trip. Archived epics leave
the live WBS (parse_plan.py no longer expands them), and the `docs/plans/*.md` glob
the doc-freshness checks use is non-recursive, so `archive/` is out of the
live-plan checks. (The live trim of this repo's done epics is T31.7.)

**Knowledge extraction (T31.3/ADR-0036 L2).** `.github/scripts/extract_knowledge.py`
is the gated propose-then-confirm pass that runs AFTER an epic is archived: it lifts
the durable nuggets out of an archived block and routes each to its tier per the
ADR-0036 map — invariant/landmine -> `docs/lore.md`, finding/benchmark ->
`docs/devlog.md`, decision -> a new proposed `docs/adr/` file, architecture ->
`docs/concept.md` (NOT design.md). It NEVER writes to or removes from the archive,
so the archive is the lossless backstop and a mis-route loses no knowledge. It
dry-runs by default (printing the routing for human review); `--apply` is the
human-confirm gate that writes the edits. Source: `--epic docs/plans/archive/ENN.md`
or `--latest` (the most-recently-archived epic). Nuggets are found by explicit
`Nugget(<class>): ...` annotations, class hashtags (`#invariant` etc.), or a keyword
heuristic; each written edit carries a `kx:<sig>` provenance marker so re-running is
idempotent. `test_extract_knowledge.py` pins the tier map, the never-touch-archive
invariant, the no-knowledge-lost backstop, and idempotency.

**Standing goal (T31.6/ADR-0036).** The whole lifecycle is encoded as a committed
kazi STANDING goal-file, `priv/examples/doc_lifecycle.goal.toml`, so kazi DRIVES it
(`kazi apply priv/examples/doc_lifecycle.goal.toml --workspace .`): the six
doc-freshness checks are `custom_script` predicates (ADR-0040) wrapping the T31.4
scripts via `bash <script>`, plus a doc-coverage `ratchet` (% commands documented,
higher_better) and a stale-task-count `ratchet` (to 0, lower_better) per
envelope-v2 (ADR-0041). An `[enforcement]` block marks the checkers + lifecycle
tools `read_only_paths` (ADR-0042) so an agent cannot edit a grader. NO doc logic
lives in kazi core. See `docs/doc-freshness.md` ("The standing goal") and
`test/kazi/goal/doc_lifecycle_goal_test.exs`. The live dogfood run is T31.7.

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

<!-- code-review-graph MCP tools -->
## MCP Tools: code-review-graph

**IMPORTANT: This project has a knowledge graph. ALWAYS use the
code-review-graph MCP tools BEFORE using Grep/Glob/Read to explore
the codebase.** The graph is faster, cheaper (fewer tokens), and gives
you structural context (callers, dependents, test coverage) that file
scanning cannot.

### When to use graph tools FIRST

- **Exploring code**: `semantic_search_nodes` or `query_graph` instead of Grep
- **Understanding impact**: `get_impact_radius` instead of manually tracing imports
- **Code review**: `detect_changes` + `get_review_context` instead of reading entire files
- **Finding relationships**: `query_graph` with callers_of/callees_of/imports_of/tests_for
- **Architecture questions**: `get_architecture_overview` + `list_communities`

Fall back to Grep/Glob/Read **only** when the graph doesn't cover what you need.

### Key Tools

| Tool | Use when |
|------|----------|
| `detect_changes` | Reviewing code changes — gives risk-scored analysis |
| `get_review_context` | Need source snippets for review — token-efficient |
| `get_impact_radius` | Understanding blast radius of a change |
| `get_affected_flows` | Finding which execution paths are impacted |
| `query_graph` | Tracing callers, callees, imports, tests, dependencies |
| `semantic_search_nodes` | Finding functions/classes by name or keyword |
| `get_architecture_overview` | Understanding high-level codebase structure |
| `refactor_tool` | Planning renames, finding dead code |

### Workflow

1. The graph auto-updates on file changes (via hooks).
2. Use `detect_changes` for code review.
3. Use `get_affected_flows` to understand impact.
4. Use `query_graph` pattern="tests_for" to check coverage.
