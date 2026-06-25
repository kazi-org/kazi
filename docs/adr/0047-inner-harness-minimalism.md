# ADR 0047: Inner-harness minimalism — context-budget tiers + per-run tool-surface restriction

## Status
Proposed

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
   `:exclude_dynamic_system_prompt_sections`, `:no_session_persistence`. kazi
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
</content>
