# ADR 0010: Context injection to mitigate per-iteration re-exploration

- Status: Accepted
- Date: 2026-06-22

## Context

kazi invokes the harness as a fresh, stateless `claude -p` per iteration and owns
durable context itself (ADR-0008); the prompt is a thin projection of the
work-item + failing-predicate evidence (ADR-0009). The deliberate cost of
statelessness is **per-iteration re-exploration**: each fresh agent re-discovers
where things live in the target workspace (grep, read, orient) because it carries
no memory from the last iteration. For a multi-iteration convergence this re-pays
cold-start orientation every cycle.

The reframe that resolves the tension: statelessness discards two different
things, and only one is waste.

- **Map memory** — *where things are* (structure, which files matter). Re-deriving
  this every iteration is pure loss.
- **Conversation memory** — *what we already tried* (the transcript, failed
  approaches). Discarding this is a feature: it is exactly what the regression and
  stuck guards (Slice 1) need gone to avoid anchoring on a dead end (ADR-0008).

So the goal is to make each stateless call *start oriented* (keep map memory)
while still dropping the conversation (keep determinism + anti-anchoring).

Research grounding (see docs/devlog.md for the full survey):
- **Inject-structure** (aider repo map; the Codebase-Memory MCP code-graph paper):
  serving ranked structure from a tree-sitter graph instead of grep+read gives
  ~10x fewer tokens, ~2x fewer tool calls, >100x faster at ~90% quality parity
  for structural queries; **Elixir shows only a ~1% quality gap**. Weakness:
  source-level / macro-heavy detail. Verdict: *hybrid* (graph for structure, files
  for source).
- **Compact-and-persist** (claw-code, a clean-room Claude Code rewrite): no repo
  map; instead transcript compaction, hard token budgets, tool-result truncation,
  tool-pool capping (<=15 tools), workspace indexing, auto-loaded `CLAUDE.md`, and
  filesystem session memory.
- **Prompt caching**: cached input ~10% of normal, 50-90% input savings for
  repeated static context, 5-min TTL -- realized only with a stable prefix.

kazi already runs `code-review-graph` and `graphify`, and already knows the
failing predicates each iteration (hence the blast radius). It is well placed to
*inject* orientation rather than let the agent rediscover it.

## Decision

Mitigate re-exploration by **injecting deterministic, blast-radius-scoped
orientation into each stateless call, and externalizing durable map-memory to the
workspace** -- without reintroducing conversation memory. Concretely:

1. **Orientation pack in the prompt (refines ADR-0009).** A new `Kazi.Context`
   builder turns the failing predicates + workspace into a bounded, ranked
   orientation pack (impacted files/symbols, the failing test's source, its
   callers/callees). Built from `code-review-graph` when the target has a graph,
   else an aider-style tree-sitter repo map. It is added as a **stable, cacheable
   prefix** section of `build_prompt/2`; the failing-evidence section (ADR-0009)
   remains.
2. **Workspace orientation file (externalized map-memory).** kazi generates and
   refreshes a `CLAUDE.md` / `.kazi/context.md` in the target (from the code graph
   / `graphify`) so every fresh `claude -p` reads durable orientation for free.
   This is the harness-agnostic, deterministic substitute for `--resume`.
3. **Graph MCP in the workspace (cheap exploration when it happens).** Wire
   `code-review-graph` into the target's `.mcp.json` and keep it fresh before
   dispatch, so the agent's own exploration uses 10x-cheaper structural queries,
   with file-read fallback for source-level detail (the hybrid).
4. **Cache + measure.** Adopt `claude -p --output-format json` to capture
   structured result + real token/cost (feeds the T1.4 budget) and the touched
   working set. Cache the orientation pack in the SQLite read-model keyed on
   `(workspace, git-SHA, failing-predicate-set)`, invalidated incrementally on the
   changed blast radius, so the prefix stays identical (prompt-cache hits).
5. **Bounded working-set digest, never `--resume` by default.** Carry a distilled
   "files touched / what changed" note across iterations (map memory), not the
   transcript (conversation memory). `--resume` is allowed only inside a single
   convergence attempt and is reset when the stuck detector fires.
6. **claw-code hygiene.** Per-dispatch token ceiling, truncated evidence/tool
   results, and a minimal per-goal tool/permission set.

Semantic retrieval over the target (via `graphify` embeddings) is the natural
home for this as the **pluggable memory adapter deferred in ADR-0005** -- an
optional enricher feeding `build_prompt`, never a core dependency.

This composes with, and does not overturn, ADR-0008 (still stateless per
iteration; kazi still owns context) or ADR-0009 (the prompt gains a deterministic
orientation section but still carries no conversation).

## Consequences

- Each iteration starts oriented; the agent spends tokens on the change, not on
  rediscovering structure. Cache hits on the stable prefix cut input cost further.
- The stateless model, determinism, and anti-anchoring guarantees are preserved --
  only map memory is added back, never conversation.
- New moving parts kazi must maintain: the `Kazi.Context` builder, graph
  freshness, the workspace orientation file, and the SHA-keyed pack cache. These
  are deterministic, hermetically testable (stub graph/repo-map; fixture repos).
- Graph abstraction omits source lines and mis-handles macro-heavy code, so
  source-level fixes still read the file -- the hybrid is intentional; do not go
  graph-only.
- Until `--output-format json` lands these are unmeasured; it is sequenced first
  so the rest can be tuned against real numbers, and the first self-hosted run
  becomes the benchmark.

## Alternatives rejected

- **Full conversational continuity (`--resume` everywhere).** Reintroduces
  anchoring and breaks determinism/harness-neutrality (ADR-0008); it would also
  re-grow context unboundedly. We keep map memory instead, not conversation.
- **Graph-only context (no file reads).** Loses source-level and macro detail
  (the Codebase-Memory paper shows this directly); kazi keeps the file-read
  fallback.
- **A bespoke always-on vector store in the core.** Premature and against
  ADR-0005; semantic retrieval is an optional, pluggable adapter, not the
  foundation.
- **Do nothing (accept re-exploration).** Viable for short goals, but wasteful for
  exactly the long, verify-heavy convergence where kazi is supposed to win.
