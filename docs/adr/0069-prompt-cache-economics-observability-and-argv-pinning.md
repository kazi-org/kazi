# ADR 0069: Prompt-cache economics -- cache-ratio observability in `kazi economy`, and explicit dispatch-argv pinning (`--bare`, dynamic-sections exclusion) behind the benchmark gate

## Status

Proposed

## Date

2026-07-10

## Context

A research pass (`docs/research/token-efficiency-and-cheaper-agentic-coding.md`,
2026-07-10) grounded Claude Code's documented prompt-caching mechanics against
kazi's actual dispatch implementation. Four findings motivate this ADR:

1. **The cache-token split is recorded but never reported as a ratio.** The
   `:claude` profile already parses the Anthropic usage object per-field
   (T34.2, ADR-0046): `cache_read_input_tokens -> :cached_input_tokens`,
   `cache_creation_input_tokens -> :cache_write_tokens`, honest-unknown
   fidelity-tagged. T48.7 persists cached-input tokens per run
   (`budget_cached_input_tokens` on `Kazi.ReadModel.Run`), and
   `Kazi.Economy.KPIs` computes "fresh input tokens avoided". But
   `Kazi.Economy.History.aggregate/1` -- the group aggregate behind
   `kazi economy` -- exposes only `tokens`/`cost_usd`/`dispatch_count`/
   `wall_clock_s` percentiles. An operator cannot see whether a goal-shape
   bucket's dispatches are actually reusing the harness's prompt cache (a
   high read ratio) or re-paying full input price every iteration (a low
   one). The loop's `record_counters/3` byte-diff heuristic measures what
   kazi *constructed*, not what the harness's cache actually *served* -- the
   authoritative numbers are already in the read-model, unaggregated.

2. **Worktree-per-attempt isolation (ADR-0065) has an unpriced cache cost.**
   Claude Code's system prompt embeds the working directory, git-repo flag,
   platform, shell, OS, and auto-memory paths; its cache is an exact prefix
   match. Two dispatches of the SAME goal with byte-identical predicates,
   model, and config that run in different worktrees therefore never share a
   cache entry. Claude Code documents a flag for exactly this fleet shape --
   `--exclude-dynamic-system-prompt-sections` moves the per-session dynamic
   context into the first user message so identical configs cache-share
   across directories -- and kazi's `:claude` profile ALREADY carries the
   passthrough (T36.1/ADR-0047 economy-flag map, version-gated). Nothing
   sets it: not `DispatchSurface.minimal_default`, not the loop's dispatch
   path, and there is no CLI/goal-file surface to reach it. It is a dormant
   lever.

3. **Dispatches are not bare, and upstream is about to change that under
   us.** The `:claude` argv is `-p <prompt> --output-format json` plus
   opt-gated flags -- no `--bare`. So every dispatch auto-discovers whatever
   CLAUDE.md, hooks, plugins, auto-memory, and MCP config exist on the
   dispatching machine: context kazi does not construct, does not account
   for, and cannot reproduce across a pool whose sessions run under
   different `~/.claude` states. The ADR-0047 minimalism opts
   (`--tools`/`--disallowedTools`/`--strict-mcp-config`/`--max-turns`) cap
   the tool surface but not discovery. Claude Code's docs recommend `--bare`
   as the default for scripted callers and state it "will become the default
   for `-p` in a future release" -- when that flip lands, kazi's dispatch
   context changes silently unless kazi has pinned its own choice first.
   Note the counter-consideration: a workspace-committed CLAUDE.md is repo
   context, not machine state -- some goals may genuinely converge better
   with it present.

4. **Statelessness is settled; effort tiering has plumbing but no policy.**
   The cold-subprocess-per-iteration model is a named ADR-0008/0009 decision
   with the orientation pack (ADR-0009/0010) as its chosen mitigation -- the
   profile even ships a `:no_session_persistence` opt pointing the OTHER
   way. And `kazi apply --effort` (T36.6) already forwards `claude --effort`,
   but no tiering recipe (ADR-0035 ladder, `docs/pool-model-tiering.md`)
   uses effort as a rung.

ADR-0058 decision 3 already governs how any dispatch-prompt/context change
ships: behavior proposes, the benchmark gate (`mix kazi.bench --variant`,
T48.12) disposes. Flipping `--bare` or `--exclude-dynamic-system-prompt-sections`
on by default IS a dispatch-context change and falls squarely under that
gate. What is missing is (a) the instrument to see cache economics at all,
and (b) operator-reachable plumbing so the variants can even be run.

## Decision

1. **Cache-ratio observability in `kazi economy` (report-only).**
   `Kazi.Economy.History.aggregate/1` groups gain the cached-input dimension:
   a `cached_input_tokens` percentile pair and a derived
   `cache_read_ratio` (cached input / (cached input + fresh input), per run,
   percentiled like the other metrics). ADR-0046 honest-unknown discipline
   holds: runs that never reported the split are excluded from the
   percentile input, never coerced to zero; a group with no reporting runs
   renders `null`, and `n_with_usage` already conveys sample density. The
   `--json` schema change is additive (bump `schema_version` per the
   existing contract). This is a read-only reporting surface -- outside the
   T48.12 gate by ADR-0058's own boundary.

2. **Dormant argv levers become operator-reachable, OFF by default.**
   - `:bare` joins the `:claude` profile's economy-flag map
     (`--bare`, `kind: :boolean`, version-gated with a conservative
     `min_version` floor like `--exclude-dynamic-system-prompt-sections`,
     so an older CLI never receives a flag it would error on).
   - `kazi apply`/`kazi run` gain passthrough flags (and the goal-file
     `[harness]` table gains keys) for `:bare` and
     `:exclude_dynamic_system_prompt_sections`, following the T36.6
     `--effort` precedent (Claude-profile-only via `supported_opts`;
     parity-by-design).
   - With none of the new opts supplied, the rendered argv is byte-for-byte
     unchanged -- pinned by tests, same discipline as every prior
     economy-flag addition.

3. **Default flips ship ONLY via the benchmark gate.** This ADR authorizes
   plumbing and measurement -- it does NOT flip any default. Turning
   `--exclude-dynamic-system-prompt-sections` on for kazi-managed worktree
   dispatches, or `--bare` on generally, each requires a T48.12 variant run
   showing `Δ Tokens < 0` or `Δ Iters < 0` with no convergence-rate
   regression, per `docs/economy.md`. The bare-mode fixture set MUST include
   a goal whose convergence depends on a workspace CLAUDE.md, so the
   known risk (finding 3's counter-consideration) is measured, not assumed
   away. The upstream `-p`-defaults-to-bare flip is a tracked hazard: once
   kazi has an explicit `:bare` opt, the eventual default decision is kazi's
   own recorded choice rather than an inherited surprise.

4. **Not relitigated here.** The stateless cold-dispatch-per-iteration model
   (ADR-0008/0009) stands; session reuse (`--resume` across iterations)
   would be a superseding ADR with its own benchmark evidence, and the
   stuck-bundle escalation (ADR-0045 §5) remains deliberately
   bounded-context, not fork-shaped. Effort-as-a-ladder-rung is skill-side
   policy per ADR-0035/ADR-0056 (`[escalation]` data), not kazi-core, and is
   recorded in the research doc as a candidate for that surface.

## Consequences

Positive:

- `kazi economy` can finally answer "is the stable-prefix discipline
  (stable->volatile prompt ordering, orientation-pack caching) actually
  earning cache reads for this goal shape?" from data already recorded --
  the instrument every subsequent cache-related variant run reads.
- The two highest-leverage documented levers for kazi's exact fleet shape
  become one flag away instead of unreachable, without changing any default
  behavior until measured.
- kazi's dispatch context becomes an explicit, versioned choice ahead of the
  upstream bare-mode default flip, instead of ambient inheritance.

Negative / accepted costs:

- One more additive `--json` schema bump for `kazi economy` consumers.
- The economy-flag map and its version-gating grow again; each new flag is
  another argv-stability test to maintain.
- Benchmark-gated means slower: neither default flips until someone runs the
  fixtures -- intended, per ADR-0058.
- `cache_read_ratio` is only as trustworthy as harness usage reporting;
  profiles with `usage_fidelity: :none` (e.g. `claw`) contribute nothing,
  which the honest-unknown rendering makes visible rather than hides.

Extends ADR-0047 (inner-harness minimalism surface: two new economy flags)
and ADR-0058 (economy aggregate gains a dimension; the gate governs the
flips). Depends on ADR-0046 (honest-unknown usage envelopes) and T34.2/T48.7
(the recorded split being aggregated). Interacts with ADR-0065 (the worktree
fleet is the shape the dynamic-sections exclusion exists for). Refines
nothing in ADR-0008/0009 (statelessness untouched).
