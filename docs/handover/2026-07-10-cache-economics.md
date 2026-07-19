# Handover: cache-economics research → ADR-0069 → brief 0033

**From:** token-efficiency research session, 2026-07-10 evening. **For:** the next session in this directory (`~/Code/kazi-org/kazi`, main @ `ab58637`).

## What landed (PR #1063, rebase-merged)

Three commits, one traceable chain — research → decision → executable brief:

1. `docs/research/token-efficiency-and-cheaper-agentic-coding.md` — Claude Code / Claude API token-efficiency mechanics (prompt-cache prefix rules, compaction, subagents/forks, headless flags, MCP deferral, effort) grounded against kazi's dispatch implementation via a source survey with file:line citations. Read Part B's addendum before touching anything cache-related: it corrects several "gaps" that turned out to already be implemented.
2. `docs/adr/0069` (**Proposed**) — cache-ratio observability in `kazi economy`; `--bare` + `--exclude-dynamic-system-prompt-sections` become operator-reachable (OFF by default); default flips reserved for the T48.12 benchmark gate; statelessness (ADR-0008/0009) explicitly not relitigated.
3. `.kazi/goals/0033-cache-economics-observability.goal.toml` — grind brief for ADR-0069 decisions 1–2 (`kazi lint` clean, 0 warnings).

A `plan`-kind bus message (topic `cache-economics`, project scope) announced this; other sessions get it on their next `kazi bus read`.

## Key confirmed facts (don't re-derive)

- Every reconcile iteration is a **cold `claude -p` subprocess**; `session_id` is captured but never fed to `--resume` — deliberate (ADR-0008/0009), not a gap.
- Dispatch prompt is already ordered stable→volatile for the harness's own cache (`loop.ex:2071-2075`), but kazi cannot see whether it's working — the byte-diff heuristic in `record_counters/3` is not `cache_read_input_tokens`.
- The cache split IS parsed (T34.2, `claude.ex:328-348`) and persisted (T48.7) — only the `kazi economy` ratio aggregation is missing (brief 0033 predicate 1).
- `--exclude-dynamic-system-prompt-sections` passthrough exists in the profile (`claude.ex:96-120`) but NOTHING sets it; no `--bare` opt at all — dispatches inherit ambient host CLAUDE.md/hooks/plugins, and upstream plans to flip `-p` to bare-by-default (behavior-change hazard once it lands).
- ADR-0065's worktree-per-attempt fleet = different cwd per attempt = zero Claude Code cache sharing across attempts today; the exclusion flag is the documented fix for exactly this shape.

## Next steps, in order

1. **Grind 0027 first** (`ci-daemon-nats-green`) — main CI is still hard-red on Linux (nats-server missing, #1061); brief 0033 `depends_on` it and its full-suite guard is meaningless on a red base. The 0027–0032 fleet handover (`docs/handover/2026-07-10-backlog-fleet.md`) has the full run recipe.
2. **Grind 0033** (can join the fleet batch dir once 0027 is landed): `kazi apply .kazi/goals/0033-cache-economics-observability.goal.toml --workspace <fresh-worktree> --harness claude --model claude-haiku-4-5 --json --stream`. Escalate per the ladder on stuck.
3. **Operator work, not grindable:** the T48.12 benchmark runs that would flip the new flags' defaults (`mix kazi.bench --variant` — procedure in `docs/economy.md`). The bare-mode fixture set MUST include a goal whose convergence depends on a workspace CLAUDE.md (ADR-0069 decision 3 requires this).
4. When 0033 lands, flip ADR-0069's status Proposed → Accepted in the same change (or note partial acceptance if only decision 1 ships).

## Watchpoints

- Brief 0033 predicate 1 tells the implementer to check whether the history row carries fresh `input_tokens` split from the total; if only summed total + cached exist, derive fresh = total − cached only when both non-nil. Verify against the actual `Kazi.ReadModel.Run` schema before trusting the brief's assumption.
- Brief 0033 predicate 2 says to verify the real Claude Code version that introduced `--bare` for the version-gate floor — do not guess.
- `kazi bus who` returned `stream not found` on the fresh daemon (presence KV unprovisioned); posts work fine. If presence matters, check whether a session-registration step is missing rather than assuming the bus is broken.
- Pre-existing local state left untouched: a modified `.kazi/goals/0027-ci-daemon-nats-green.goal.toml` in the working tree (not mine — check with the operator before discarding) and an untracked `tmp_C04...` directory.

## Out of scope (deliberate)

Session-reuse across iterations (`--resume`) — would need its own superseding ADR + benchmark; effort-as-escalation-rung — skill-side per ADR-0035/0056, recorded as research candidate 11; anything that flips a dispatch default without a T48.12 table.
