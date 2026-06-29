# ADR 0047: Inner-harness minimalism — context-budget tiers + per-run tool-surface restriction

## Status
Accepted

## Date
2026-06-24

## Refines
ADR-0008 (kazi owns context; stateless per-iteration inner calls) and ADR-0009 (thin,
deterministic evidence projection) and ADR-0010 (orientation injection). Those decide
*what* context kazi assembles; this ADR decides *how much* of it to send per task and
*which tools* the inner harness may see while it runs. Depends on the ADR-0046
accounting envelope to measure whether each lever is a net win.

## Context

Two related sources of inner-loop waste are not yet governed:

1. **One context shape for every task.** Today the loop assembles orientation +
   evidence (+ optional retrieval) the same way for a one-line test failure and a
   cross-file refactor. A trivial failure does not need the orientation pack; an
   ambiguous one may need graph + retrieval. Sending the maximal shape always is
   tokens spent with no convergence benefit; sending the minimal shape always leaves
   ambiguous failures under-supported.

2. **The inner harness sees more tool surface than the task needs.** Claude Code
   supports `--tools`, `--disallowedTools`, `--strict-mcp-config`, `--mcp-config`,
   `--max-turns`, `--exclude-dynamic-system-prompt-sections`, and
   `--no-session-persistence`. The kazi `claude` profile exposes only budget, allowed
   tools, permission mode, and model. `--allowed-tools` governs *approval* but does
   not necessarily *remove the tool schemas from the model's context* — every
   irrelevant MCP server's tool definitions are input tokens the inner harness pays
   for on every dispatch, and extra tools widen the action space a cheap model can
   wander into.

The proposals frame both as token-economy levers. But there is an asymmetry worth
encoding in the decision: **restricting the tool surface is low-risk and independently
sound** (fewer schemas in context, narrower action space — strictly cheaper, and it
cannot reduce capability the task does not use), whereas **context-tier escalation is
a policy whose net effect must be measured** (too-low a default raises stuck rate;
the right ladder is an empirical question that E19's benchmark exists to answer).
This ADR commits the first now and gates the second on measurement, so we do not bake
a guessed tier ladder into the loop.

## Decision

1. **Per-run inner tool-surface restriction (commit now).** Extend the `claude`
   profile's `supported_opts` to pass through the economy flags — `:tools`,
   `:disallowed_tools`, `:strict_mcp_config`, `:mcp_config`, `:max_turns`,
   `:exclude_dynamic_system_prompt_sections`, `:no_session_persistence`, and the
   reasoning-effort lever `:effort` (`--effort <level>`, T36.6). The economy levers
   are **Claude-only by design** (parity-by-design, ADR-0016 item 3): only the
   `:claude` profile advertises them in `supported_opts`, so they are never
   forwarded to opencode/codex/antigravity/claw/gemini_cli, and `--effort` requires
   a Claude CLI new enough to accept it. kazi
   defaults a reconcile dispatch to the **minimal** surface the task needs:
   `--strict-mcp-config` with only the MCP servers kazi actually injected (the
   orientation/graph server, and the context store from ADR-0045 in search-only
   mode), and the file/edit/shell tools the harness needs to fix predicates — not the
   ambient set. Absent these opts, argv is byte-identical to today (back-compat).

2. **Context-budget tiers (define now, escalate empirically).** Name a tier ladder:

   | Tier | Context | Use when |
   |---|---|---|
   | 0 | failing evidence only | tiny obvious test failures |
   | 1 | evidence + cached orientation pack | **default** |
   | 2 | tier 1 + code-review-graph MCP | cross-file impact, refactors |
   | 3 | tier 2 + semantic retrieval snippets | ambiguous failures, missing local signal |
   | 4 | tier 3 + compact repo snapshot | architecture/design tasks, not repair loops |

   **Default is tier 1.** Escalation is on **non-progress against the same failing
   set** (the ADR-0041 score gradient says "not progressing"), never immediately.
   The *ladder shape and the escalation trigger thresholds are tunable config, set
   from the E19 benchmark (T19.5/T19.7), not hardcoded* — kazi must not ship a guessed
   ladder as if it were proven.

3. **Tiers and tool-surface are reported, not silent.** Each iteration's
   `context` envelope (ADR-0046) records the active tier and whether the tool surface
   was restricted, so the benchmark can attribute convergence/stuck outcomes to the
   tier — the experiment arms in E19 (evidence-only / +orientation / +cache / +graph /
   +retrieval / +tool-restriction) map one-to-one onto these knobs.

4. **Stop rule.** Any tier or restriction change that lowers tokens but raises stuck
   rate or wall-clock enough to *increase cost per converged predicate* (ADR-0046) is
   reverted. The KPI is cost-per-converged-predicate, not minimal tokens.

## Consequences

- The inner harness pays for fewer irrelevant tool schemas per dispatch and has a
  narrower action space — a strict, low-risk win the moment the flags land, before
  any tier policy is tuned.
- Context spend becomes a dial the loop turns on evidence (non-progress), not a fixed
  cost — trivial failures get cheaper, ambiguous ones get the graph/retrieval they
  need, and the choice is logged and attributable.
- The E19 benchmark gets concrete arms to measure (tier 0–4, surface on/off) instead
  of an abstract "try less context."
- Risk: a too-aggressive minimal surface removes a tool the task actually needed →
  stuck. Mitigation: the default surface is "what kazi injected + standard edit/shell"
  (not an empty set), escalation restores graph/retrieval on non-progress, and the
  stop rule reverts net-negative restrictions.
- Risk: `--strict-mcp-config` / `--exclude-dynamic-system-prompt-sections` behavior
  varies by Claude Code version. Mitigation: pass-through is opt-in per profile with a
  version-gated capability check; on an unsupported version the flag is dropped, not
  errored.
- Risk: encoding a tier ladder tempts hardcoding the thresholds before they are
  measured. Mitigation: thresholds are config with benchmark-derived defaults, and
  this ADR explicitly forbids shipping a guessed ladder as proven.

## Alternatives rejected

- **Restrict tools but skip tiers.** Captures the safe win, but leaves the
  one-shape-fits-all context waste in place; the tier scaffolding is cheap to define
  and is what makes the benchmark arms meaningful.
- **Ship a fixed tier ladder now.** Bakes a guess into the loop; the repo's own
  discipline (T19.5 is a verdict-to-measure, not an assumption) says measure first.
  Define the ladder, default to tier 1, tune from data.
- **Always send maximal context to minimize stuck rate.** Optimizes the wrong KPI —
  it minimizes iterations at the cost of per-iteration spend, and the operator pays
  for graph+retrieval+snapshot on every trivial failure. Cost-per-converged-predicate,
  not stuck rate alone, is the target.
- **Rely on `--allowed-tools` alone for surface control.** It governs approval, not
  context inclusion; the irrelevant tool schemas can still be in the prompt. Use the
  strict-config / exclude flags to actually remove them.

## Implementation

Decision 1 (per-run tool-surface restriction) ships in two steps:

- **T36.1** extends the `:claude` profile's `supported_opts`/`build_args` with the
  economy opts → flags (`:tools`/`:disallowed_tools`/`:strict_mcp_config`/
  `:mcp_config`/`:max_turns`/`:exclude_dynamic_system_prompt_sections`/
  `:no_session_persistence`), each appended only when supplied, version-gated where
  the flag's behavior is version-sensitive. Absent the opts, argv is byte-identical.
- **T36.6** adds the reasoning-effort lever to that same surface: a `:value`
  economy flag `:effort -> --effort <level>` on the `:claude` profile, threaded by
  a `kazi apply ... --effort <level>` CLI flag and a goal-file `[harness] effort`
  table key. Precedence is **CLI `--effort` > goal-file `[harness] effort`**;
  absent both, argv is byte-for-byte unchanged. `Kazi.Runtime.build_adapter_opts/3`
  folds the resolved effort into `adapter_opts` for the claude profile, and because
  only the `:claude` profile lists `:effort` in `supported_opts`, a non-Claude
  harness drops it at `Kazi.Harness`'s `Keyword.take` (Claude-only,
  parity-by-design). It forwards to `claude --effort` and so requires a Claude CLI
  recent enough to support that flag.
- **T36.2** consumes those opts: `Kazi.Harness.DispatchSurface` computes the
  **minimal default surface** — `--strict-mcp-config` plus a `--mcp-config` scoped to
  the MCP servers kazi injected (the orientation/graph server in the workspace
  `.mcp.json`) and a `--tools` allow-list of the standard edit/shell tools (the
  never-empty floor) plus an `mcp__<server>` ref per injected server. `Kazi.Loop`
  merges this surface UNDER the dispatch's adapter opts (an explicit operator/goal opt
  still wins), gated on the resolved profile advertising the economy opts and on a
  workspace being present — so non-Claude harnesses and workspaceless loops are
  unchanged.

  The injected-server set is the single seam `DispatchSurface.injected_servers/1`
  exposes: the **E35** `Kazi.ContextStore` (search-only, ADR-0045) plugs in by
  appending its `{name, config}` entry there once T35.1 lands — no change to the
  rendering logic. Until then the minimal surface is computed from the servers kazi
  currently injects (orientation/graph only).

Decision 2 (context-budget tiers) lands its **scaffolding** in T36.3 and stays gated
on the E19/E34 benchmark for ESCALATION — no tier ladder is shipped as proven:

- **T36.3** defines the ladder as `Kazi.Context.Tier`: tiers `0`–`4` with a
  cumulative feature set (`orientation`/`graph`/`retrieval`/`snapshot`), the default
  (`default/0` = tier 1), and resolution of the `:context_tier` adapter opt
  (`resolve/1`, normalizing a malformed value to the default — a bad opt never
  crashes a dispatch). The active tier drives assembly:

  - the orientation prefix is gated on `Tier.orientation?/1` in `Kazi.Loop`, so tier
    0 DROPS the cached orientation and tier ≥ 1 keeps it (still subject to the T19.4
    `:orientation_prefix` toggle); the default tier 1 is byte-identical to the
    pre-T36.3 prompt;
  - the live code-review-graph MCP server is gated on `Tier.graph?/1` in
    `Kazi.Harness.DispatchSurface`, so it is the tier-2 "+ graph" feature — the
    default tier 1 surface now EXCLUDES it (the agent has the cached orientation TEXT
    but no live graph MCP), and tier ≥ 2 exposes it. (This refines T36.2's minimal
    surface, which previously always injected the graph server: under the tier ladder
    the graph MCP belongs to tier 2, matching the table above.)
  - tiers 3 (retrieval snippets) and 4 (compact snapshot) are named, selectable, and
    recorded; their richer content sources are wired in later — the scaffolding is
    real, not a stub that errors.

  The active tier is RECORDED per iteration in the ADR-0046 `context` envelope
  (`context.tier`), satisfying decision 3.

- **T36.4** adds the escalation trigger (non-progress against the same failing set)
  and the stop rule, with thresholds loaded from config (E19/E34-derived), NOT
  hardcoded — that is where a tier ladder could be claimed "proven", and only from
  data.

  The policy is the pure `Kazi.Context.Escalation` state machine (`init/2` +
  `step/3`), so the ladder is tunable, not baked into the loop. `Kazi.Loop` owns the
  signal and applies the resulting tier: each observation it computes a
  **non-progress** verdict — the SAME `Kazi.Loop.StuckDetector` rule (identical
  non-empty failing set, no graded-score improvement, ADR-0041) over a 2-window —
  and a per-iteration **cost** delta from the ADR-0046 usage envelope (dollars when
  reported, else the token total), folds them through `Escalation.step/3`, and reads
  the resulting `escalation_state.tier` as the active tier for the next dispatch
  (gating the orientation prefix, the tier-2 graph MCP surface, and the recorded
  `context.tier`). With no non-progress the active tier never leaves the base, so
  the dispatch path is byte-identical to T36.3.

  **Escalation trigger.** On `threshold` consecutive non-progress observations at a
  tier, the active tier steps up one rung (1 → 2 → 3 → 4), bounded by `max_tier`.
  Progress (a shrinking/changing failing set, an improving score, or convergence)
  resets the streak and holds the tier — escalation only ever climbs, it never
  de-escalates a paying tier.

  **Stop rule (decision 4).** Each escalation captures the rung-below's
  per-iteration cost as a baseline; if the escalated rung's first iteration still
  does not progress AND cost MORE than the baseline, the bump was net-negative — the
  loop reverts to the lower tier and stops climbing for the run (cost-per-converged-
  predicate is the KPI, not minimal tokens nor maximal context). A cost-neutral
  escalation is kept and the climb may continue.

  **Config (thresholds from config, not magic numbers).** The knobs resolve from the
  `:context_escalation` `Kazi.Loop` opt, then `config :kazi, :context_escalation`,
  then the provisional defaults (`Kazi.Context.Escalation.Config`):

  | Knob | Default | Meaning |
  |---|---|---|
  | `:enabled` | `true` | Master switch; `false` pins the active tier at the base. |
  | `:threshold` | `2` | Consecutive non-progress observations at a tier before stepping up. |
  | `:min_tier` / `:max_tier` | `0` / `4` | The tier window the ladder clamps to. |
  | `:stop_rule` | `true` | Revert a net-negative (cost-up, no-progress) bump. |

  The default `:threshold` is **provisional**: `2` is one below the stuck window
  (`StuckDetector.default_iterations/0` is `3`) so a stall gets a richer-context
  attempt BEFORE the run is abandoned as stuck. It is explicitly NOT shipped as
  proven — the E19 benchmark (T19.5/T19.7) and the T36.5 arms set it from data; this
  ADR forbids shipping a guessed ladder. The active tier and the ordered tier-change
  log (escalations + reverts) are surfaced in `Kazi.Loop.snapshot/1`
  (`:context_tier` / `:context_tier_escalations`) so a run's ladder is observable.

  Distinct from ADR-0035's model-tiering (`docs/tiering-signals.md`): that is a
  CROSS-invocation `--model` ladder owned by the skill; this is a WITHIN-run CONTEXT
  ladder owned by kazi core. Different axis, different owner.
</content>
