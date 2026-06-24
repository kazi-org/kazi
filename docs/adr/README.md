# Architecture Decision Records

Each ADR captures one decision: the context, the decision, the consequences, and
the alternatives rejected. ADRs are immutable once accepted — to change a
decision, write a new ADR that supersedes the old one (and update
[`../concept.md`](../concept.md)).

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-positioning-outer-loop-reconciler.md) | Positioning: an outer-loop reconciler, not a harness | Accepted |
| [0002](0002-goals-as-predicates.md) | Goals are machine-checkable predicate sets | Accepted |
| [0003](0003-language-elixir-otp.md) | Runtime: Elixir / OTP + Phoenix LiveView | Accepted |
| [0004](0004-coordination-substrate-nats-jetstream.md) | Coordination substrate: NATS JetStream | Accepted |
| [0005](0005-data-layer-split.md) | Data-layer split (Git / JetStream / ETS / SQLite) | Accepted |
| [0006](0006-coordination-leases-and-graph-partitioning.md) | Coordination by resource leases + graph partitioning | Accepted |
| [0007](0007-build-strategy-walking-skeleton.md) | Build strategy: walking skeleton (idea → production) | Accepted |
| [0008](0008-harness-invocation-and-context.md) | Harness invocation: headless, stateless per iteration; kazi owns context | Accepted |
| [0009](0009-prompt-construction-thin-evidence-projection.md) | Prompt construction: a thin, deterministic evidence projection | Accepted |
| [0010](0010-context-injection-reexploration-mitigation.md) | Context injection to mitigate per-iteration re-exploration | Accepted |
| [0011](0011-slice3-operator-surfaces.md) | Slice-3 operator surfaces (LiveView dashboard + Telegram bridge) decoupled from the core loop | Accepted |
| [0012](0012-pluggable-retrieval-memory-adapter.md) | Pluggable semantic-retrieval memory adapter (off by default) | Accepted |
| [0013](0013-adopt-reverse-engineer-goals.md) | Adopting kazi on an existing project (`kazi init` reverse-engineers a goal-file) | Accepted |
| [0014](0014-binary-distribution-burrito-homebrew.md) | Binary distribution via Burrito + Homebrew (supersedes escript-as-distribution) | Accepted |
| [0015](0015-init-source-output-model-registry-goal-set.md) | Withdraw the capability-registry adapter; a future spec importer (OpenAPI/gherkin) instead | Accepted |
| [0016](0016-generic-harness-profiles.md) | Generic harness profiles: config-driven multi-harness support (opencode, Codex, ...) | Accepted |
| [0017](0017-automated-brew-release-pipeline.md) | Automated brew release pipeline (release-please -> CI build -> tap auto-bump) | Accepted |
| [0018](0018-website-stack-hosting-domain.md) | kazi website: Astro + Tailwind on GitHub Pages at kazi.sire.run | Accepted |
| [0019](0019-interactive-clarify-phase-for-propose.md) | Interactive clarify phase for `kazi propose` (hybrid question-gen, CLI-first, inline + `--adr` rationale) | Accepted |
| [0020](0020-hierarchical-predicate-grouping.md) | Hierarchical predicate grouping via a declared group taxonomy (referenced by id, validated at load; derived per-group budgets; Obsidian/Mermaid export) | Accepted |
| [0021](0021-intended-vs-actual-reconciliation.md) | Intended-vs-actual reconciliation: import intent from standard specs (OpenAPI/gherkin) + prose via the harness; detect dead code via a surface-coverage meta-predicate | Accepted |
| [0022](0022-harness-onboarding-conformance.md) | Onboarding any CLI coding harness: the profile conformance contract (non-TTY subprocess-safe, structured output) + the add-a-harness recipe; Codex/Antigravity/claw-code tiers | Accepted |
| [0023](0023-harness-friendly-agent-drivable-cli.md) | kazi as a harness-friendly, agent-drivable CLI: `--json` + non-interactive guarantees + a versioned result contract (kazi self-conforms to ADR-0022); orchestrator owns the two-tier model policy; `kazi propose` is the single agent authoring path | Accepted |
| [0024](0024-kazi-self-teaching-to-harnesses.md) | kazi is self-teaching to harnesses: an opt-in Claude Code skill (`kazi install-skill`) + `kazi help --json`/`schema` + `AGENTS.md` + a `kazi mcp` server, so an agent knows how to drive kazi | Accepted |
| [0025](0025-docs-lead-with-agent-driven-onramp.md) | Documentation and website lead with the agent-driven on-ramp (claude->kazi->cheap-harness); vanilla `kazi run` demoted to a reference tier; honest cost framing; sequenced after the install-skill/mcp on-ramp ships | Accepted |
| [0026](0026-kazi-under-apply-pool.md) | kazi UNDER `/apply --pool` (shape a): `/claim` stays outer task-selection, kazi blast-radius leases are inner coordination; caller-drafts bridges `acc:`->predicates; layered L1 gate -> L2 loop -> L3 leases (NATS) -> L4 observability; does not replace the pool | Accepted (parallelization stance superseded by 0027; retained as interop) |
| [0027](0027-kazi-owns-parallelization-native-scheduler.md) | kazi owns parallelization: a native scheduler partitions a goal-set by blast radius, leases each partition, and spawns N supervised concurrent reconcilers (in-memory lease single-node = NATS-free) to collective convergence; codifies `/apply --pool`+`/claim` into kazi; single-goal stays the serial on-ramp | Accepted |
| [0028](0028-dependency-aware-partitioning-predicate-graph-waves.md) | Dependency-aware partitioning ("predicate-graph waves"): declare `needs` edges between predicate groups; the scheduler executes the DAG topologically with blast-radius parallelism inside each frontier, objective-convergence gating, and pipelining (no barrier); codifies `/plan`'s `deps:` + `/apply`'s Waves | Accepted |
| [0029](0029-drop-telegram-bridge.md) | Drop the Telegram bridge -- the orchestrating agent (Claude) is the human's mobile interface, so a kazi-native chat surface is redundant; remove the bridge (no dep change), drop T20.9, keep the LiveView dashboard; headless-autonomous pings deferred to a future generic webhook (supersedes the Telegram part of 0011) | Accepted |
| [0030](0030-content-marketing-agent-native-positioning.md) | Content-marketing + agent-native positioning (research-grounded): lead every surface with the agent-drives-kazi paradigm + a human-noun/borrowed-frame tagline; hero = a transcript of the loop reaching objective-true; without/with before-after; agent-voiced proof + a memorable invocation; ONE recurring growth engine (a dogfood "done" leaderboard); HN-first launch kit (refines ADR-0025) | Accepted |
