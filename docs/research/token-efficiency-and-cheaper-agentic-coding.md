# Research: token efficiency in Claude Code / the Claude API, and how kazi could exploit it

Status: RAW RESEARCH — not a decision doc, not an ADR, not yet vetted by the
T48.12 benchmark gate (`docs/economy.md`). Collected 2026-07-10 for later
review. Every "candidate" below needs the same treatment ADR-0058 already
requires for any dispatch-prompt/context change: measure `Δ Tokens` / `Δ
Iters` on a fixture goal via `mix kazi.bench --variant`, ship only on a
measured reduction with no convergence-rate regression. Nothing here should
be implemented from this doc alone.

## Part A — how Claude Code / the Claude API become cheaper, factually

Sourced from `code.claude.com/docs` (fetched 2026-07-10) and the bundled
`claude-api` skill (platform.claude.com docs, cached 2026-06-24). This is the
factual substrate; kazi-specific ideas are in Part C.

### A.1 Prompt caching — the mechanism everything else rests on

- **Prefix match, not per-file.** The API caches on exact-byte-match of the
  request prefix (`tools` → `system` → `messages`). One byte anywhere in the
  prefix invalidates everything after it. No partial/per-segment caching.
- **Cache economics.** Reads cost ~0.1× input price; writes cost 1.25× (5 min
  TTL) or 2× (1 h TTL). Break-even is ~2 requests (5 min TTL) or ~3 (1 h TTL).
- **Minimum cacheable prefix is model-dependent**: 4096 tok (Opus 4.8/4.7/4.6,
  Haiku 4.5), 2048 tok (Fable 5, Sonnet 4.6, Haiku 3.5/3), 1024 tok (Sonnet
  4.5 and older). A prompt below the floor silently never caches — no error,
  `cache_creation_input_tokens: 0`.
- **20-block lookback window** — a single turn with >20 content blocks (long
  agentic loops with many tool_use/tool_result pairs) can silently miss the
  cache on the next turn's breakpoint. Fix: an intermediate breakpoint every
  ~15 blocks.
- **Verify, don't assume.** `usage.cache_read_input_tokens == 0` across
  repeated identical-prefix requests means a silent invalidator is at work —
  diff the rendered prompt bytes to find it.

**Claude Code's specific caching behavior** (from `code.claude.com/docs/en/prompt-caching`):

- Claude Code auto-manages caching; you don't set `cache_control` yourself.
  Layering: system prompt (tools, instructions, output style) → project
  context (CLAUDE.md, auto memory, rules) → conversation (turns).
- **Cache-invalidating actions**: switching model, switching effort level,
  toggling fast mode, connecting/disconnecting an MCP server whose tools are
  loaded into the prefix (not deferred), enabling/disabling a plugin that
  provides an MCP server, denying an entire tool (bare-name deny rule),
  `/compact`, upgrading the Claude Code binary.
- **Cache-preserving actions**: editing repo files, editing CLAUDE.md
  mid-session (doesn't apply until next `/clear`/`/compact`/restart — so it's
  cache-safe but also *behavior*-inert until then), changing output style
  mid-session (same caveat), changing permission mode, invoking
  skills/commands, `/recap`, `/rewind` (truncates back to an already-cached
  prefix — cheaper than compaction, which builds a new one), spawning a
  **named** subagent (separate cache, doesn't touch parent's), spawning a
  **fork** (inherits parent's exact prefix, so its first request is a cache
  *hit* on the parent's cache — this is the cheap way to spin off work that
  needs full context).
- **Cache scope is machine+directory-bound.** The system prompt embeds
  working directory, git-repo flag, platform, shell, OS version, auto-memory
  paths. Two sessions in different directories (including different
  worktrees of the *same* repo) never share a cache entry. Sequential
  sessions in the same directory only share cache if the git-status snapshot
  at startup matches (branch + recent commits are baked into the prompt).
- **`excludeDynamicSections` / `--exclude-dynamic-system-prompt-sections`**
  (Agent SDK / CLI, v0.2.98+ TS / v0.1.58+ Python): moves the per-session
  dynamic context (cwd, git flag, platform, shell, OS, memory paths) out of
  the system prompt and into the first user message instead, so **identical
  agent configs sitting in different directories/machines can share one
  cache entry**. Explicitly documented for "a fleet of agents running from
  different directories." Tradeoff: that context now carries slightly less
  instruction-following weight (user message vs. system prompt).
- **TTL**: subscription auth gets 1 h TTL automatically and free (usage is
  plan-included, not metered); API-key/Bedrock/Vertex/Foundry auth defaults
  to 5 min unless `ENABLE_PROMPT_CACHING_1H=1` is set (pays the 2× write
  premium for it). `FORCE_PROMPT_CACHING_5M=1` overrides back down.
- **Subagents get their own 5 min TTL even under a subscription** — the 1 h
  auto-upgrade only applies to the main conversation.

### A.2 Context-window composition and compaction

- Startup layers, in cache order: system prompt (~4.2K tok) → auto memory
  MEMORY.md (first 200 lines / 25 KB) → environment info → MCP tool names
  (deferred schemas) → CLAUDE.md/rules → conversation.
- **CLAUDE.md**: loaded in full regardless of length, but Anthropic's own
  guidance is "target under 200 lines... longer files consume more context
  *and reduce instruction adherence*." Path-scoped `.claude/rules/*.md` with
  `paths:` frontmatter load only when Claude touches a matching file — this
  is the mechanism to keep base context small without losing coverage.
  `@import` syntax does NOT reduce context (imports still load in full at
  launch) — it's an organizational tool only.
- **Auto memory** (`MEMORY.md` + topic files) truncates to 200 lines/25 KB at
  load; topic files load on demand via normal Read, not at startup. This is
  structurally identical to kazi's context-store "index heavy, return
  budget-fitted snippet" pattern (see Part B) — Anthropic converged on the
  same shape independently.
- **Compaction**: replaces message history with a summary. The summarization
  call itself reuses the existing cache (same system prompt + tools + full
  history + a final "summarize" instruction), so *compaction's cost is the
  summarization generation, not a cache miss*. The turn *after* compaction
  only needs to cache the (much shorter) summary. Project-root CLAUDE.md is
  re-read from disk and re-injected after compaction; nested CLAUDE.md is
  not (reloads only when a matching file is next read).
- **`/rewind` is cheaper than `/compact`** for "abandon this path" — it
  truncates to an earlier, already-cached prefix rather than building a new
  summary-based one.
- Custom compaction instructions: `/compact <focus>`, or a
  `# Compact instructions` section in CLAUDE.md that's applied on every
  auto-compaction, not just manual ones.

### A.3 Subagents / forks as the primary context-isolation primitive

- A **named subagent** starts a genuinely fresh context (own system prompt,
  own cache, no parent history) and returns only its final result to the
  parent — this is the mechanism Anthropic recommends for "verbose
  operation, throwaway detail": test runs, log triage, doc fetches, wide
  exploration. Only the summary re-enters the expensive parent context.
- A **fork** (`/fork`, or `CLAUDE_CODE_FORK_SUBAGENT=1` for model-initiated
  forks) inherits the *entire* parent conversation and hits the parent's
  cache on its first request — cheaper than a named subagent when the task
  genuinely needs full context, because a named subagent pays a cold cache
  on its first call.
- Built-in `Explore`/`Plan` subagents skip CLAUDE.md and git-status entirely
  (kept fast/cheap by design) and, as of Claude Code v2.1.198, inherit the
  parent's model (capped at Opus) rather than defaulting to Haiku — meaning
  cost control for exploration now has to happen by explicitly overriding
  `model: haiku` in a custom `Explore` definition if you want it.
  `general-purpose` and custom subagents default to `model: inherit`.
- **`isolation: worktree`** on a subagent gives it a throwaway git worktree,
  auto-cleaned if it makes no changes — directly load-bearing for kazi
  (ADR-0065 "safe concurrent work — serial worktree fleet" already does this
  pattern at the kazi-orchestration level; Claude Code now offers the same
  primitive one level down, inside a single session).
- Nested subagents (subagent spawning subagent) are supported to depth 5.

### A.4 Headless/programmatic driving (the surface kazi actually uses)

From `code.claude.com/docs/en/headless` — this is the part most directly
load-bearing for how kazi *invokes* Claude Code as a harness:

- `claude -p "<prompt>" --output-format json` returns `total_cost_usd` and a
  per-model cost breakdown in the response payload — a controller doesn't
  need to separately estimate cost from token counts if it trusts this field
  (Anthropic's own docs flag it as a **client-side estimate, not
  authoritative billing** — same caveat kazi's own `Kazi.Economy` docs
  already encode via ADR-0046 honest-unknown).
- **`--bare`**: skips auto-discovery of hooks, skills, plugins, MCP servers,
  auto memory, and CLAUDE.md. Documented as *"the recommended mode for
  scripted and SDK calls, and will become the default for `-p` in a future
  release."* Only flags passed explicitly take effect. This trades away
  CLAUDE.md/skill context for reproducibility and a smaller/cheaper startup
  prompt — a real lever for any kazi dispatch that doesn't need the
  project's interactive-session conveniences.
- **`--continue` / `--resume <session_id>`**: continues the most recent (or
  a specific) conversation — this is what actually preserves the prompt
  cache *across separate CLI invocations*. Session ID lookup is scoped to
  the current working directory (and its worktrees).
- **`--fork-session`**: on resume, mints a new session ID instead of
  mutating the original — branch off a run without losing the ability to go
  back to it.
- `--output-format stream-json` + `--verbose` +
  `--include-partial-messages` for token-level streaming; `system/init`
  event reports model/tools/MCP/plugins loaded, useful for asserting a
  dispatch's actual configuration in CI.
- `--allowedTools`, `--permission-mode` (`dontAsk`, `acceptEdits`,
  `bypassPermissions`, etc.) control approval friction, not cost directly,
  but `bypassPermissions` avoids the "harness stalls waiting for an
  interactive approval that never comes" failure kazi's own lore already
  documents (L-0023: pooled dispatch needs `--permission-mode
  bypassPermissions` for headless dispatch — this session's memory).
- Piped stdin capped at 10 MB (v2.1.128+) — large artifacts need to go
  through a file reference instead, which is exactly what kazi's
  context-store "index heavy, pass a reference" pattern already does
  independently (see Part B).
- Background Bash tasks are killed ~5 s after the CLI's final result unless
  they're a background subagent/workflow (waited on, capped at 10 min by
  default via `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`).

### A.5 MCP tool-loading cost

- **Tool search / deferred loading is the default** on supported models:
  only tool *names* enter context; full schemas load on demand when Claude
  actually reaches for a tool. This is why kazi's existing
  "expose Gist MCP server search-only, not index" wiring
  (`docs/context-store.md` §"Inner-harness contract") is cheap by default —
  the schema cost is deferred either way, and the allow-list only bounds
  *capability*, not context, in the deferred case.
- CLI tools (`gh`, `aws`, `gcloud`, `sentry-cli`) are flagged as *more*
  context-efficient than MCP even with deferral, because they add zero
  per-tool listing at all — Claude just runs them via Bash. Relevant if a
  future kazi-side tool integration is choosing between "give the harness an
  MCP server" and "give it a documented CLI it can shell out to."
- A deny rule on a bare tool name (`Bash`, or an MCP-tool-name glob that
  matches only deferred tools) is cache-cheap; a deny rule that removes a
  tool that was loaded into the prefix (non-deferred, e.g. on Haiku, or
  `alwaysLoad`, or threshold-loaded) is cache-expensive.

### A.6 Effort / thinking as a cost dial (API-level, applies to any harness call)

- `output_config.effort`: `low`/`medium`/`high`/`xhigh`/`max`. Lower effort
  → fewer, more consolidated tool calls, less preamble, terser confirmations
  — a direct, cheap lever completely orthogonal to model choice. `xhigh` is
  recommended for coding/agentic work on current-gen models; `low`/`medium`
  suit subagents and mechanical/simple tasks.
- Adaptive thinking (`thinking: {type: "adaptive"}`) lets the model decide
  depth per-request instead of a fixed `budget_tokens` — removes the
  guessing game of hand-tuning a thinking budget per task shape.
- Claude Code's own guidance (`/costs`): route simple subagent tasks to
  `model: haiku`; use `/effort` or a fixed `MAX_THINKING_TOKENS` budget on
  fixed-budget models for routine work; reserve Opus/high-effort for
  architectural decisions.

### A.7 Hooks as a token-efficiency mechanism, not just a safety mechanism

`PreToolUse`/`PostToolUse` hooks can rewrite a command or its output *before
it enters context* — Anthropic's own worked example: a `PreToolUse` hook on
`Bash` that rewrites `npm test`/`pytest`/`go test` into
`<cmd> 2>&1 | grep -A5 -E '(FAIL|ERROR)' | head -100`, turning a 10K-line
log into a few hundred tokens. This is the *exact same shape* as kazi's
context-store evidence-compression path (index-if-oversized, inline
otherwise) but implemented one layer lower, inside the harness's own tool
loop rather than in the dispatch-prompt assembly. The two are complementary,
not redundant: kazi's context store bounds what the *outer controller*
re-sends across iterations; a hook like this bounds what the *inner harness*
lets into its own turn in the first place.

## Part B — kazi's existing token-economy machinery (grounding, not brainstorm)

Read directly from `docs/economy.md`, `docs/context-store.md`,
`docs/pool-model-tiering.md`, `docs/tiering-signals.md`, plus a source survey
of `lib/kazi/harness*.ex`, `lib/kazi/context*.ex`, `lib/kazi/economy/*.ex`
(survey pending at time of writing this section — see addendum below once
the Explore pass returns). What's already true and load-bearing:

- **`kazi economy`**: persists per-run tokens/cached-tokens/cost/dispatch
  count/wall-clock, grouped by `{goal_shape_bucket, model, harness}`,
  honest-unknown throughout (ADR-0046 — never fabricates a `0`).
- **`kazi economy --rediscovery <goal>`**: reads per-iteration tool-use
  counters and ranks which tool category (file reads / search / graph
  queries) keeps *recurring* across dispatches instead of falling off after
  iteration 1 — a direct signal for "this goal is re-deriving the same
  context every loop turn," i.e. exactly the failure mode prompt caching and
  context stores exist to prevent.
- **The T48.12 benchmark gate** (`mix kazi.bench --variant`): the ONLY path
  by which a rediscovery candidate or debrief hypothesis becomes an actual
  dispatch-prompt change — run the same fixture goal `baseline` vs.
  `candidate`, ship only on `Δ Tokens < 0 OR Δ Iters < 0` with no
  convergence-rate regression. This is already exactly the discipline this
  research doc's own preamble asks any reader to apply to what follows.
- **Learned budget suggestions** (`kazi plan`/`kazi init`, T48.9): p95×1.5
  headroom over matching history, commented-out in the generated goal-file,
  never auto-applied.
- **Context store (Gist provider, ADR-0045)**: off by default; when wired,
  compresses oversized (>5 KB default) failing evidence into a SHA-scoped
  indexed label + one-line summary in the dispatch prompt, with a separate
  budget-fitted "indexed evidence" section per iteration. Redacts before
  indexing (shared redactor with the harness-prompt egress path). Inner
  harness gets **search-only** MCP access by default (`gist_search`, not
  `gist_index`) — "outer indexes, inner searches" (ADR-0045 §7).
- **Stuck-bundle replay** (ADR-0045 §5): on a `:stuck` stop, produces a
  bounded (~12 KB) projection — failing predicates + last-changed files +
  budget-fitted store snippets — for a higher model rung to consume instead
  of the lower rung's full transcript. "This is where the dollars are."
- **Model tiering** (`docs/pool-model-tiering.md`, ADR-0026): strong model
  authors predicates ONCE (caller-drafts, `kazi plan`); cheap/local harness
  (`opencode`+local Qwen, `codex`, `claw`) grinds the inner loop under the
  SAME objective predicate bar — kazi holds the bar, so a cheap
  implementer's cost savings can never buy a false "done." Measured caveat:
  a slow local model can make the tiering worthless end-to-end even though
  per-dispatch $ is near-zero (T8.11, 2026-06-22: 35B q8_0 local model via
  opencode took ~40 min/iteration and never converged in a usable window).
- **Skill-side escalation ladder** (ADR-0035, `docs/tiering-signals.md`):
  kazi's `--json` terminal result (`status`/`next_action`/`predicates[]`)
  is *sufficient* signal for a skill to run a bounded Haiku→Sonnet→Opus
  ladder per-slice; the cross-invocation "stuck N times" counter is
  explicitly kept OUT of kazi core (policy stays in the skill, state stays
  in kazi) — verdict already recorded as "no kazi-core change needed."

### Addendum: harness-invocation mechanics (Explore-agent survey, confirmed)

An `Explore` pass over `lib/kazi/harness.ex`, `harness_adapter.ex`,
`context.ex`, `context_store.ex`, `context/tier.ex`, `context/stuck_bundle.ex`,
`retrieval.ex`, `economy/*.ex`, `loop.ex` (3699 lines — the `:gen_statem`
reconcile engine), and `docs/add-a-harness.md` answers the questions this
addendum originally posed:

1. **Fresh subprocess per iteration — confirmed, and deliberate.** kazi
   drives every harness turn as a non-interactive, no-TTY CLI subprocess
   (`claude -p ...`); `Kazi.Loop` builds a full prompt from scratch on every
   `:dispatch_agent` action (`dispatch_prompt_parts/2`,
   `assemble_prompt/1`) and calls `Kazi.HarnessAdapter.run/3` fresh
   (`loop.ex:1950`). The harness's own `session_id` is captured
   (`loop.ex:2379-2388`, `565-570`) but **only for a human-facing dashboard
   "resume" link** — grep of `lib/kazi/harness/` confirms it is never wired
   into a subsequent dispatch's argv (no `--resume`/`--continue`/`-c`
   anywhere). Every iteration is a cold call. This is an explicit
   architectural tradeoff already named in ADR-0008/ADR-0009: *"the
   deliberate cost of statelessness is per-iteration re-exploration"*
   (`context.ex:13`) — kazi chose stateless-per-call and built
   `Kazi.Context`'s orientation pack specifically to blunt that cost via a
   stable, cache-friendly prefix rather than via session continuity.
2. **No `--bare` (or equivalent) found; not clearly needed either way.**
   `docs/add-a-harness.md`'s contract only requires "non-interactive,
   no-TTY, parses stdout" — it doesn't specify bare-mode-style suppression
   of hook/skill/plugin/CLAUDE.md auto-discovery. Given kazi already builds
   its own structured context (orientation pack, evidence, tier ladder) and
   caps the *tool/MCP surface* per dispatch via `DispatchSurface.minimal_default`
   (`dispatch_adapter_opts/1`, `loop.ex:2025`, an ADR-0047 cost lever), the
   open question is whether ambient CLAUDE.md/hook/plugin auto-discovery on
   the dispatch machine is (a) load-bearing for some harness profiles, or
   (b) pure unbounded-and-unaccounted extra context riding along for free.
   Not resolved by this pass — needs a direct read of `Kazi.Harness.CliAdapter`'s
   actual argv construction.
3. **Prompt IS already ordered stable→volatile, and the reason is stated
   in the source.** `loop.ex:2071-2075`: orientation pack → work-item line
   → working-set digest → evidence → retrieval → attempt-ledger/memory-recall
   → debrief question, explicitly "to maximise the inner `claude -p`'s OWN
   prompt cache." But the same comment records the honest limit: *"kazi sets
   no `cache_control` itself"* — it relies entirely on the harness CLI's own
   opaque caching, with zero direct visibility or control at the Anthropic
   API layer. `record_counters/3` (`loop.ex:2332`) does a **post-hoc, heuristic
   byte-comparison** of this dispatch's orientation/retrieval prefix against
   the *prior* dispatch's to classify a cache "hit"/"miss" for KPI
   purposes — this is measurement, not optimization, and it cannot observe
   the harness's *actual* `cache_read_input_tokens` (that number lives
   inside the harness process, not in what kazi constructed).
4. **Worktree-per-attempt (ADR-0065) is a real cost, not incidental** —
   confirmed via A.1's "different directory ⇒ different cache" rule and the
   fact that nothing in the surveyed harness code special-cases or
   compensates for it. Not flagged anywhere in the surveyed source as a
   known tradeoff.
5. **`max_tokens` accounting is best-effort/estimated, not authoritative,
   and can go silently inert.** `loop.ex:1962-1964`: kazi "accumulate[s]
   this run's token estimate (if the harness reported one)" — some harness
   profiles (`:claw`, per ADR-0022) report no usage at all, and
   `maybe_flag_unreported_usage` (`loop.ex:3323`) exists precisely to flag
   that the token budget silently cannot bind for those profiles. This
   mirrors, and is consistent with, Claude Code's own `total_cost_usd`
   caveat in A.4 ("client-side estimate, not authoritative") — kazi
   inherits that uncertainty one layer up rather than resolving it.

**Additional confirmed levers not anticipated by the original addendum
questions** (folded into Part C below): a cumulative 0–4 **context-tier
ladder** (`Kazi.Context.Tier`) that gates how much gets assembled per
dispatch, with an auto-escalation policy (`Kazi.Context.Escalation`, T36.4)
that bumps the tier after 2 consecutive non-progress observations and
explicitly **reverts the bump if it was net-cost-negative** — already
cost-aware, already provisional pending its own T36.5 benchmark. And a
**rediscovery report** (`Kazi.Economy.Rediscovery`) that already computes
exactly the "which tool category keeps getting wastefully re-paid every
iteration" signal, but is pinned by a dedicated test
(`rediscovery_prompt_boundary_test.exs`) to **never** feed back into a
dispatch prompt automatically — a deliberate, documented human-in-the-loop
gap, not an oversight.

## Part C — brainstormed candidates (UNVALIDATED — benchmark before shipping)

Ranked by estimated leverage × confidence, not effort. "Confidence" reflects
how directly Part A's factual material and the confirmed Part B addendum
support the claim; every candidate still needs the T48.12 gate before it
ships. Each is tagged with which kazi layer it touches.

### C.1 High confidence, high leverage

1. **Reconsider session-per-run instead of session-per-iteration —
   but this now reads as revisiting a NAMED architectural decision, not
   filling a gap.** Confirmed: kazi captures `harness_session_id` purely for
   a dashboard link and never wires it into the next dispatch
   (`loop.ex:2379-2388`, no `--resume` anywhere in `lib/kazi/harness/`).
   Every iteration is a cold `claude -p` call, and A.1/A.4 establish that a
   cold call re-pays full input price for the whole orientation-pack +
   goal-shape prefix every time. BUT this is not an oversight — ADR-0008/
   ADR-0009 name it explicitly: *"the deliberate cost of statelessness is
   per-iteration re-exploration"* (`context.ex:13`), and kazi already built
   `Kazi.Context`'s cached, cache-friendly orientation pack as the chosen
   mitigation instead of session continuity. Session reuse would trade that
   deliberate independence (each iteration free to `/rewind`-equivalent
   away from a bad path, immune to a poisoned/over-long conversation) for
   cache reads on everything *except* what already gets served by the
   orientation-pack's own cache-friendliness. The marginal win may be
   smaller than it first looks — kazi already caches the expensive,
   re-derivable part (structural context); a resumed session would mainly
   save re-sending the (cheap, already-bounded) evidence/goal-shape text.
   **Verdict: worth a T48.12 variant run to measure the actual `Δ Tokens`
   this buys over the status quo before treating it as a live candidate at
   all** — it may turn out the orientation-pack cache already captures most
   of the available win, in which case this is not worth the architectural
   risk. If a variant is tried, scope it narrowly: reuse the session only
   within a single non-stuck, non-escalated run, and keep the `:stuck`
   detector's "same failing set N times" check independent of whatever the
   session's own state drifts toward.

2. **CORRECTED after direct source read: the cache-token split is ALREADY
   parsed and persisted.** `Kazi.Harness.Profiles.Claude.parse/1` maps the
   Anthropic usage object per-field (T34.2, ADR-0046): `cache_read_input_tokens
   → :cached_input_tokens`, `cache_creation_input_tokens → :cache_write_tokens`,
   with honest-unknown fidelity tagging (`claude.ex:328-348`); T48.7
   persists cached-input tokens onto `Kazi.ReadModel.Run` (`history.ex:4`);
   and `Kazi.Economy.KPIs` already computes "fresh input tokens avoided"
   from cached reads (`kpis.ex:17,374-375,430-451`). What remains of the
   original candidate is only the REPORTING slice: `kazi economy`'s group
   output surfaces `tokens`/`cost_usd` percentiles but (per
   `docs/economy.md`'s `--json` schema) not a read:creation cache ratio per
   goal-shape bucket — see candidate 12. The prompt ordering itself
   (`loop.ex:2071-2075`, stable→volatile) can therefore be validated with
   data kazi ALREADY records — no new plumbing needed, just a query.

3. **CONFIRMED after direct source read: kazi dispatches are NOT bare —
   ambient host config rides along on every dispatch.** The `:claude`
   profile's argv is `-p <prompt> --output-format json` plus opt-gated
   flags (`claude.ex:60-63`); no `--bare` (and no `:bare` opt in the
   economy-flag map). So every dispatch auto-discovers whatever
   CLAUDE.md/hooks/plugins/auto-memory/MCP config happens to exist on the
   dispatching machine — uncosted (it inflates the harness's context
   before kazi's prompt even starts), and non-reproducible across a pool
   whose sessions run on different machines or under different `~/.claude`
   states. kazi already partially compensates via `--strict-mcp-config` /
   `--tools` / `--disallowedTools` opts (the ADR-0047 minimalism surface),
   but those cap tools, not CLAUDE.md/hook/skill/memory discovery. Claude
   Code's own docs recommend `--bare` as *the* default for scripted
   callers and say it will become the `-p` default upstream — meaning
   kazi's dispatch behavior will silently CHANGE when that upstream flip
   lands unless kazi pins its choice explicitly first. Concrete candidate:
   add `:bare` to the economy-flag map (version-gated like
   `--exclude-dynamic-system-prompt-sections`), benchmark it ON via
   T48.12. Watch item either way: the upstream default flip is a
   behavior-change hazard worth a lore entry once a decision is made.
   Caveat: some operators may *rely* on a workspace CLAUDE.md reaching the
   inner harness (it is repo-committed context, not just machine state) —
   the benchmark fixture should include a goal whose convergence benefits
   from CLAUDE.md to catch that regression.

4. **CORRECTED after direct source read: the
   `--exclude-dynamic-system-prompt-sections` passthrough ALREADY EXISTS —
   the candidate is now "turn it on by default for the worktree fleet,"
   a policy change, not plumbing.** The `:claude` profile's economy-flag
   map (`claude.ex:96-120`, T36.1/ADR-0047) already renders
   `:exclude_dynamic_system_prompt_sections` → the bare CLI switch,
   version-gated so an older CLI never sees a flag it would choke on. But
   nothing SETS it: grep shows neither `DispatchSurface.minimal_default`
   nor `Kazi.Loop`'s dispatch path supplies the opt, so today it's a
   dormant lever an operator would have to know to reach for. Part B's
   addendum still stands: ADR-0065's worktree-per-attempt fleet means every
   attempt runs from a different cwd and (per A.1) never shares a Claude
   Code cache entry — and this flag is documented by name as the fix
   ("a fleet of agents running from different directories can reuse the
   same cached system prompt"). Concrete candidate: default it ON in
   `DispatchSurface.minimal_default` for the `:claude` profile (or at
   least whenever the workspace is a kazi-managed worktree), benchmark via
   T48.12. Tradeoff per A.1: cwd/env context moves to the first user
   message and carries marginally less instruction weight — likely fine
   since kazi's working-set digest already tells the model what changed,
   but that's exactly what the benchmark run should confirm.

5. **1-hour cache TTL (`ENABLE_PROMPT_CACHING_1H=1`) as a passthrough env
   var for pool-fleet dispatches specifically.** Not previously considered
   in the draft candidate list — added after confirming kazi's pool
   coordination (atomic claim locks, `/claim`) can introduce real gaps
   between a task's successive dispatches (waiting on a claim, a wave
   boundary, another session's turn). A.1: on API-key auth (which a pooled
   fleet is more likely to use than a single interactive subscription
   session), the cache TTL defaults to 5 minutes unless this var is set,
   at a 2× (vs 1.25×) write-cost premium. If candidate 1 or 2 above ever
   produces a session/cache worth preserving across a multi-minute pool
   gap, this is the cheap, zero-architecture-risk env-var flip that makes
   it actually survive the gap — but it's a pure write-cost-vs-hit-rate
   tradeoff, not free, and only pays off if the gap is real and the hit
   would otherwise be lost.

6. **Route kazi-orchestration-level exploration-shaped subagent calls
   through an explicit cheap model, not `inherit`.** A.3: as of Claude Code
   v2.1.198, `Explore`/`general-purpose` subagents default to inheriting
   the parent's model (capped at Opus on the API), not Haiku. Any part of
   kazi's OWN operational tooling that spawns exploration-shaped subagents
   (not the inner-implementer harness this repo drives — the orchestrator
   layer described in `pool-model-tiering.md`'s three-layer stack) should
   double-check it isn't silently paying Opus-tier rates for lookups that
   would do fine on Haiku. This is a prompt/config check outside kazi core,
   not a kazi-core change — flagged here because it's the kind of thing
   this exact research pass (an Explore-agent-heavy session) would
   otherwise miss auditing on itself.

### C.2 Medium confidence — real, but needs product judgment before a benchmark run

7. **Extend `Kazi.Economy.BudgetSuggestion` to learn context-tier defaults
   and the evidence-compression threshold per goal shape, not just budget
   ceilings.** Confirmed hardcoded today: orientation-pack token budget
   (4,000 tokens, `context.ex:71`) and context-store compression threshold
   (5,120 bytes, `loop.ex:107`) are fixed constants, while `BudgetSuggestion`
   already learns `max_tokens`/`max_dispatches`/`max_wall_clock_ms` from
   `Economy.History` per `{goal_shape_bucket, model, harness}` (T48.9). A
   goal shape that reliably converges at context-tier 1 (evidence +
   orientation only) never needs the tier-2/3/4 machinery, but there's no
   learned signal steering a NEW goal of that shape toward starting there
   instead of at the (also fixed) default. This is squarely inside the
   ADR-0058 decision-3 boundary (behavior proposes, benchmark gates,
   nothing auto-ships) — the natural shape is a new advisory field
   alongside the existing commented-out `[budget]` block, never an
   auto-applied tier change.

8. **A `PreToolUse`-hook-shaped compression layer inside the inner
   harness, complementing (not replacing) kazi's own evidence-compression.**
   Still contingent on candidate 3 (bare vs. not) — A.7's worked example
   (filter `npm test`/`pytest` output to failures only, before it enters the
   INNER harness's own context) operates one layer below anything
   `Kazi.Loop` can see: it bounds what the harness burns *within* one
   dispatch doing its own exploration, which `kazi economy --rediscovery`
   cannot observe today (it only sees kazi's own loop-level tool counters
   via `Kazi.Economy.Rediscovery`, not the inner harness's turn-by-turn tool
   use). Only shippable via an explicit `--settings`/hook-template
   passthrough if dispatches turn out to already be effectively bare-mode
   (candidate 3); irrelevant if they already load a full interactive
   session's hooks, since a project-level hook would then already apply.

9. **Leave the stuck-bundle escalation path exactly as-is — this is a
   confirmation, not a candidate.** ADR-0045's stuck-bundle mechanism
   (bounded ~12 KB: failing predicates + changed files + context-store
   snippets) is deliberately NOT a fork-shaped "hand the higher rung the
   full prior transcript" escalation — A.3 establishes a fork inherits the
   *entire* parent conversation, which is precisely the "re-pay for every
   token of failed work" cost `stuck_bundle.ex:9` already names as the
   thing being avoided. kazi's existing design already made the correct
   call per A.3's own tradeoff table. Worth a one-line citation added to
   `docs/context-store.md` linking this reasoning to the underlying Claude
   Code fork-vs-subagent cache tradeoff, so the "why not just fork" question
   has a documented answer next time someone asks it — otherwise no code
   change.

10. **Close the rediscovery→prompt firewall selectively, gated by the
    T48.12 benchmark, not by removing the test that currently pins it
    closed.** `Kazi.Economy.Rediscovery` already computes exactly the "which
    tool category keeps getting wastefully re-paid every iteration" signal
    (file reads / search calls / graph queries recurring past dispatch 1)
    — and `rediscovery_prompt_boundary_test.exs` deliberately pins it OUT
    of any dispatch-prompt path. That firewall is correct as a *default*
    (ADR-0058 decision 3's whole point is no auto-shipped prompt change),
    but the natural NEXT step the doc already describes
    (`docs/economy.md` §"The T48.12 benchmark gate") is exactly "take a
    ranked rediscovery candidate, turn it into a concrete pack change,
    benchmark it, ship only on a measured win." Recorded here only to note
    that Part A's material (deferred MCP tool loading, retrieval-cache
    patterns, hook-based compression) gives several concrete SHAPES a
    rediscovery-driven candidate pack could take — this doc doesn't invent
    a new mechanism, it supplies raw material for whoever next runs that
    already-documented procedure.

### C.3 Lower confidence / needs product judgment, not just measurement

11. **CORRECTED after direct source read: the `--effort` passthrough
    ALREADY EXISTS (T36.6, ADR-0047) — the candidate is now "make effort a
    tiering-policy axis," not "add a flag."** `kazi apply --effort
    low|medium|high` forwards `claude --effort <level>` (`cli.ex:126,198-199`,
    `claude.ex:114-119`), Claude-profile-only by design (only `:claude`'s
    `supported_opts` advertises `:effort`, so a non-Claude harness never
    sees it). What does NOT exist yet is any *policy* that uses it:
    `pool-model-tiering.md` tiers by `--harness`/`--model` only, the
    skill-side escalation ladder (ADR-0035, `docs/tiering-signals.md`)
    steps `--model` rungs only. A.6 suggests effort is a cheaper,
    finer-grained first rung than a model swap — e.g. a mechanical
    "1-3"-predicate goal shape might converge as reliably at
    `--effort medium` on the same model, with none of the
    cheap-harness-too-slow risk ADR-0026's honest caveat records (T8.11).
    Natural shape: the skill-side ladder gains an effort rung BELOW the
    first model-swap rung (e.g. sonnet/medium → sonnet/high → opus/high),
    still entirely outside kazi core per ADR-0035's policy/state split.
    Also worth noting: the same economy-flag map carries
    `:no_session_persistence` — the OPPOSITE of candidate 1's session
    reuse — meaning kazi's authors already reached for "less session
    state," not "more," when they last touched this surface (worth
    understanding why before pursuing candidate 1).

12. **A `kazi economy --cache-efficiency` report — upgraded from
    speculative to near-term, since the data already exists.** Candidate
    2's correction confirms the cached-vs-fresh split is already parsed
    (T34.2) and persisted (T48.7, `budget_cached_input_tokens` on
    `Kazi.ReadModel.Run`), and KPIs already compute "fresh input tokens
    avoided" — the only missing piece is a per-goal-shape-bucket
    read:creation ratio in `kazi economy`'s group output. A low ratio for
    a bucket = "this goal shape keeps re-paying for the same prefix"
    (fixable via candidates 3/4/1); a high ratio = the stable-prefix
    discipline is already working and further cache work is low-yield
    there. Read-only reporting surface, so outside the T48.12 gate's
    scope — but it is the instrument every OTHER candidate's benchmark
    run would want to read, so it's arguably the right FIRST implementation
    step of this whole list.

## Sources

- `code.claude.com/docs/en/costs` — "Manage costs effectively"
- `code.claude.com/docs/en/prompt-caching` — "How Claude Code uses prompt caching"
- `code.claude.com/docs/en/sub-agents` — "Create custom subagents"
- `code.claude.com/docs/en/memory` — "How Claude remembers your project"
- `code.claude.com/docs/en/hooks` — hooks reference (fetched via summarizing prompt)
- `code.claude.com/docs/en/headless` — "Run Claude Code programmatically"
- `code.claude.com/docs/en/context-window` — "Explore the context window"
- `code.claude.com/docs/en/agent-sdk/modifying-system-prompts` — incl. `excludeDynamicSections`
- `code.claude.com/docs/en/agent-sdk/cost-tracking` — "Track cost and usage"
- `code.claude.com/docs/en/mcp` — "Connect Claude Code to tools via MCP" (tool search / deferred loading)
- bundled `claude-api` skill docs (`shared/prompt-caching.md`, `shared/agent-design.md`, `shared/model-migration.md`) — cached 2026-06-24
- kazi repo: `docs/economy.md`, `docs/context-store.md`, `docs/pool-model-tiering.md`, `docs/tiering-signals.md`
- kazi repo source survey (Explore agent pass, this session): `lib/kazi/harness.ex`, `harness_adapter.ex`, `context.ex`, `context_store.ex`, `context/tier.ex`, `context/stuck_bundle.ex`, `retrieval.ex`, `economy/price_map.ex`, `economy/history.ex`, `economy/kpis.ex`, `economy/budget_suggestion.ex`, `economy/rediscovery.ex`, `loop.ex`, `docs/add-a-harness.md`
