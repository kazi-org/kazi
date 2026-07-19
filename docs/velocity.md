# Velocity data — the delivery-event projection (T67.2, ADR-0079)

The velocity surface (E67) answers "how fast are my agents delivering?" from data
kazi already has, with **no GitHub call at render time**. Its first building
block is the **delivery-event projection**: a pure read projection (ADR-0011 §2)
that scans a workspace's git history and records one row per delivery fact into
the `delivery_events` read-model table, written only through the daemon
single-writer (ADR-0068).

## What it derives

`Kazi.ReadModel.DeliveryProjection.project(workspace, opts)` scans every commit
that touches `docs/plan.md` / `docs/plans/*.md` (in the requested range) and
records:

- **`:task_tick`** — one row per added `- [x] TNN ... Done: <date> (PR #N)` plan
  line, carrying the task id, its epic (from the plan file path), the `Done:`
  date, and the PR the line names.
- **`:pr_merge`** — one row per distinct PR number a commit lands, carrying the
  PR number, the landing commit sha, and the merge time.

Each row also carries `repo_slug` (`org/repo`, from the workspace's git `origin`
remote), for fleet grouping. See `Kazi.ReadModel.DeliveryEvent` for the full
column set (all the join keys ADR-0079 §3 names).

## Session attribution — honest by construction (ADR-0079 §1)

The authoritative delivery→session spine is the **run registry**, not the commit
trailer. A git-derived tick carries no `goal_ref`, so on a trailer-stripped repo
(like kazi's own) `session_uuid` is `nil` — an honest **fleet-level** row
(ADR-0046), never guessed from timing. The run-registry join
(`goal_ref` → `run.harness_session_id`) is applied wherever a `goal_ref` is known
for a delivery; it is the query-time join the KPI layer (T67.4) leans on.

### The `Claude-Session:` commit-trailer grammar (optional enrichment)

A commit MAY carry a trailer line of the form:

```
Claude-Session: https://claude.ai/code/session_<id>
```

where `session_<id>` is an opaque token (`session_` followed by URL-safe
characters: letters, digits, `._~-`). The projection captures that `session_<id>`
token verbatim into the **nullable, optional** `trailer_session_id` column.

**This repo strips the trailer before push** (the standing commit-hygiene rule),
so it is absent on kazi's own history and the enrichment yields nothing here — by
design, not a bug. `trailer_session_id` exists for repos that *keep* the trailer;
it is never a required join key (ADR-0079 §1 rejects the trailer as the primary
join precisely because kazi strips it).

## Idempotency & incrementality

- **Idempotent.** Each row upserts on a composed `dedup_key`
  (`kind|task_id|pr_number|merge_commit_sha`, with `""` sentinels for the nullable
  parts) via `on_conflict: :nothing`. Re-scanning the same history produces each
  row exactly once — same history in, same rows out.
- **Incremental.** `project/2` accepts `:since` (a commit-ish) to bound the git
  log to `<since>..HEAD`. `last_seen_commit/0` returns the newest already-projected
  landing commit, so a caller can scan only what is new.

## Boundaries

- No network: every fact is derived from local commit history alone.
- No loop coupling: reads only, writes only through the daemon (ADR-0068); the
  socket seam is pinned by `test/kazi/read_model/delivery_projection_socket_test.exs`.
- No completion estimate: the schema has no ETA/estimate column (ADR-0079 §3), so
  a fabricated date is unrepresentable at the storage layer.
