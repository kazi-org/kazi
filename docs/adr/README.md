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
| [0019](0019-website-dedicated-repo.md) | Move the website to a dedicated kazi-org/website repo (supersedes 0018 location) | Accepted |
