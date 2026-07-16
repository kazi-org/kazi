# kazi -- Build Plan (remaining work)

## Context

kazi is a reconciliation controller for software goals: declare a goal as
machine-checkable predicates; kazi drives a coding agent in a loop until the
predicates are objectively true, stuck, or over budget. It drives harnesses
(Claude Code, Codex, opencode, claw, Antigravity, ...); it is not a harness.

**Shipped and merged on `main` (DONE -- do NOT replan; knowledge lives in
`docs/concept.md`, the ADRs, and `docs/devlog.md`):**

- **E0-E5** -- the walking skeleton idea->production: the convergence loop to a
  live Cloud Run deploy; regression/flake/budget/stuck/prod-log; creation mode +
  self-hosting; NATS leases + graph partitioning + standing reconcilers;
  idea->predicate authoring; LiveView + Telegram; context injection + pluggable
  retrieval-memory; `kazi init` adopt (ADR-0013).
- **E6** -- the automated brew release pipeline (ADR-0014 + ADR-0017):
  `brew install kazi-org/tap/kazi` is LIVE for 3 platforms (macOS arm64, Linux
  x86_64/arm64); release-please -> CI Burrito build -> tap auto-bump runs hands-off
  and was validated end to end through **v0.3.0** (`brew upgrade` -> `kazi 0.3.0`).
  Intel macOS is the only deferred target (runner scarcity).
- **E8** -- generic config-driven harness **profiles** (ADR-0016): `Kazi.Harness.
  Profile` + `CliAdapter` + `Registry` + `resolve/1`; `kazi run --harness opencode
  --model <m>` works; a new CLI harness drops in as profile DATA (the basis for E14).
- **E9 core** -- the public website is LIVE at **https://kazi.sire.run** (Astro +
  Tailwind on GitHub Pages, HTTPS, README<->site coherence drift-check, ADR-0018).
  Only T9.5 (Playwright smoke) + T9.6 (perf/a11y) polish remain.
- **E11** -- interactive `kazi propose` clarify phase (ADR-0019), shipped in v0.3.0.
- **E7** (registry adapter) was built then WITHDRAWN before release (ADR-0015):
  its `capabilities.json` input was bespoke and did not generalize.

**State of `main`: 899 tests pass** (68 doctests, 831 tests), 19 excluded
(`:nats`/`:graphify`/`:opencode_live` tags); `mix format --check-formatted` +
`mix compile --warnings-as-errors` clean. Latest release: **v0.3.0** (brew).

**Open work (the entire content of this plan):**

- **E9 leftovers** -- T9.5 (Playwright smoke), T9.6 (perf/a11y/OG image).
- **E12** -- hierarchical predicate grouping + Obsidian/Mermaid export (ADR-0020).
- **E13** -- intended-vs-actual reconciliation: import the intended set
  (OpenAPI/gherkin/prose) + detect dead code via a surface-coverage meta-predicate
  (ADR-0021).
- **E14** -- onboard more harnesses (Codex / Antigravity / claw-code) as profiles +
  an "add your own harness" recipe (ADR-0022).
- **E15** -- harness-friendly, agent-drivable kazi: a `--json` CLI + a versioned
  result contract (ADR-0023).
- **E16** -- kazi self-teaching to harnesses: an opt-in Claude Code skill +
  `help --json`/`schema` + `AGENTS.md` + a `kazi mcp` server (ADR-0024).
- **E17** -- adoption: README/website/docs lead with the agent-driven workflow.

**Strategic spine for adoption: E15 -> E16 -> E17** (the JSON contract -> the skill
that teaches agents to drive kazi -> the docs/website that sell the agent-driven
workflow). **E12 -> E13** (the grouping + intended-vs-actual thesis) and **E14**
(more harnesses) are independent parallel tracks. See Waves for the full order.

**Frozen design (do NOT relitigate):** `docs/concept.md` (canonical architecture +
source of truth) and ADRs `0001`..`0024`. To change a decision, write a superseding
ADR.

## Use Case Summary

All use cases are tracked in `.claude/scratch/usecases-manifest.json`. **UC-001..
UC-029 are DELIVERED and verified on `main`** (incl. UC-024 brew install, UC-026/
UC-027 multi-harness, UC-028 website [live], UC-029 interactive propose [v0.3.0]).
Open work:

- **UC-028** (public website) -- LIVE; only T9.5/T9.6 polish remain (E9).
- **UC-030** (hierarchical predicate grouping via a declared taxonomy +
  Obsidian/Mermaid export of intended/built/pending/dead, ADR-0020) -- E12.
- **UC-025** (import the intended set from a STANDARD spec -- OpenAPI/gherkin --
  plus prose docs via the harness, ADR-0021) -- E13.
- **UC-031** (detect dead code / undocumented surface via a surface-coverage
  meta-predicate -- the `A \ I` half of "no dead code", ADR-0021) -- E13.
- **UC-032** (onboard more CLI coding harnesses -- Codex, Antigravity, claw-code,
  and any major harness -- as profiles per a conformance contract, ADR-0022) -- E14.
- **UC-033** (kazi as a harness-friendly / agent-drivable CLI: `--json` + a
  versioned result contract, ADR-0023) -- E15.
- **UC-034** (kazi is self-teaching to harnesses: `kazi install-skill` +
  `help --json`/`schema` + `AGENTS.md` + a `kazi mcp` server, ADR-0024) -- E16.
- **UC-035** (adoption: README/docs/website lead with the agent-driven workflow +
  two-tier economics, to grow stars/adoption, ADR-0023/0024) -- E17.
- **Reliability** (no new UC) -- E18: bug fixes from the T15.9 benchmark hardening
  the run loop's read-model persistence + the shipped example (UC-024/UC-033
  robustness).
- **Token efficiency** (no new UC) -- E19: realize the unwired orientation-prefix +
  stable-prefix caching (ADR-0010) and a multi-iteration benchmark to earn (or
  refute) the "cheaper" claim (UC-033 + infrastructure).
- **UC-036** (harden a multi-session `/apply --pool` workflow with kazi: objective
  done as a merge gate, blast-radius coordination beneath task-claims, live swarm
  observability, phone-driven direction, ADR-0026) -- E20 (INTEROP).
- **UC-037** (kazi natively parallelizes a goal-set across disjoint blast-radius
  partitions to collective convergence -- no external orchestrator, single machine
  NATS-free; codifies `/apply --pool`+`/claim` into kazi, ADR-0027) -- E21 (PRIMARY
  parallelization story).
- **Pre-publish docs** (no new UC -- documents UC-033..UC-037) -- E22: the launch
  documentation pass; README + `docs/` + website refreshed to the FINAL shipped
  product, gated on E15-E21, with a no-vaporware accuracy audit (ADR-0025/0018).
- **UC-038** (kazi computes + executes a dependency-aware, pipelined, objectively-
  gated wave schedule from declared predicate-group `needs` edges + blast-radius
  partitioning -- codifies `/plan`'s `deps:` + `/apply`'s Waves, ADR-0028) -- E23.
- **UC-039** (a newcomer landing on the README / `kazi.sire.run` understands and
  adopts the AGENT-DRIVES-KAZI paradigm in one screen -- chat with Claude Code, it
  drives kazi -- via research-grounded content: paradigm-led copy, a loop-transcript
  hero, without/with proof, an agent-voiced testimonial, a memorable invocation, and
  a dogfood "done" leaderboard, ADR-0030) -- E25.
- **UC-040** (the operator's `loop -> plan -> apply -> tidy -> qualify` workflow
  collapses onto a kazi skill router: `kazi plan` authors a goal-set and `kazi apply`
  converges it -- subsuming loop+apply+qualify for code goals -- with `/plan`
  re-seated as the intent layer and `/tidy` kept as hygiene, ADR-0031) -- E26.
- **UC-041** (one verb per concept across the agent prompt, the skill, and the CLI:
  the CLI commands are `kazi plan` (was `propose`) and `kazi apply` (was `run`), with
  `run`/`propose` as deprecated aliases, ADR-0032) -- E27.
- **UC-042** (the design/architecture docs reflect what kazi IS now: `docs/concept.md`
  + README describe the native scheduler, predicate-graph waves, the agent-driven
  router model, and the renamed verbs -- current through ADR-0032, no command
  referenced that does not exist) -- E28.
- **UC-043** (a Claude Code user gets better token economy with NO local model: chat
  with Claude Code -> it drives kazi -> easy iterations on a cheap Claude model, hard
  reasoning on a frontier model, predicates keep the cheap model honest; the
  in-family-tiering cost story + benchmark, ADR-0033) -- E19 (T19.6/T19.7) + E25
  (T25.11).
- **UC-044** (the public repo enforces OSS contribution gates: docs land with code,
  and no internal-info leaks -- CI guards + a one-time scrub keep the docs honest and
  the repo free of internal IPs/hosts/codenames/personal paths, ADR-0034) -- E29.
- **UC-045** (a Claude Code user gets ADAPTIVE token economy: the kazi skill starts
  the grind on the cheapest capable Claude model and ESCALATES (Haiku -> Sonnet ->
  Opus, capped) only when kazi reports the loop stuck -- so easy slices stay cheap
  and hard slices still converge, predicates keeping every tier honest; the policy
  lives in the skill, not kazi, ADR-0035) -- E30 (+ benchmark T19.7, content T25.11).
- **UC-046** (kazi keeps its OWN plan + docs healthy: a standing goal trims
  completed work out of the live plan (lossless archive), lifts the durable
  knowledge into the tier docs, and holds documentation FRESH via machine-checkable
  predicates in CI -- so the plan stays small/cheap and the docs never go stale; the
  flagship self-dogfood, ADR-0036) -- E31.
- **UC-047** (anyone declares a NEW kind of objective check without a kazi release: a
  generic `custom_script` predicate runs any CLI tool -- mutation/fuzz/security/contract
  -- with an explicitly-declared verdict + structured-evidence parse, defusing the
  exit-code gotchas; it is the SINGLE command-runner -- `test_runner`/`prod_log` fold in
  as deprecated presets, removed in v2.0.0, ADR-0040) -- E32.
- **UC-048** (every predicate reports a GRADED score + structured, localized evidence
  -- `{pass, score, prior_score, direction, evidence[]}`, SARIF/JUnit/LSP-shaped -- so
  the stuck-detector gets a real gradient and fixer agents get one-iteration fix
  context; coverage/perf/size collapse onto one first-class `ratchet` mode, ADR-0041)
  -- E32.
- **UC-049** (kazi's "truth lives in the controller" becomes ENFORCED, not declarative:
  read-only predicate/test leasing, skipped-as-failed, test-count + coverage ratchets,
  a diff-inspection guard, and an optional held-out acceptance subset make objective
  done resistant to a capable grind model, ADR-0042) -- E32.
- **UC-050** (the catalog expands to a real verification workhorse: first-class
  `:static` (Dialyzer-led + polyglot SARIF), `:coverage`, `:property` (PropCheck),
  `:mutation`, `:cve` (govulncheck reachability) providers + documented
  contract/perf/security-tail recipes, plus live upgrades -- sustained-health,
  `:metrics` (PromQL/RED), SLO burn-rate, synthetic journey, ADR-0043) -- E32.
- **UC-051** (a developer evaluating kazi reads a twelve-part credibility-building blog
  series on https://kazi.sire.run/blog that walks them from a vanilla coding-agent
  workflow up the same ladder the author climbed -- persistent context, knowledge tiers,
  real-world verification, structural code understanding, reusable skills, a written
  plan, an honest definition of done, safe parallelism -- to a reconciliation workflow,
  and adopts kazi as the natural conclusion; each post is independently useful and the
  series describes only shipped behavior, ADR-0048) -- E38.
- **UC-052** (a kazi contributor authors a per-feature behavior spec -- a Gherkin
  `.feature` file under `docs/specs/` -- and mechanically derives its `goal.toml`
  acceptance predicates from it via the already-shipped `GherkinImporter`, closing
  the traceability gap between ADRs/plan tasks and hand-typed predicates, ADR-0050)
  -- E40.
- **UC-053** (a product's use cases are cataloged as tagged Gherkin Scenarios
  (`@role:`/`@priority:`/`@interface:`, real Cucumber tags) at the product/capability
  scope, imported into standing predicates via the SAME `GherkinImporter`/`kazi spec
  import` path UC-052 already uses -- no bespoke schema, no external skill; for an
  existing undocumented codebase, `kazi init --discover` writes a goal that
  CONVERGES toward full coverage (every surface-scanner-found element has a Scenario)
  via ordinary `kazi apply` instead of a one-shot audit prompt; an opt-in prod-log
  correlation flags a passing predicate whose route is erroring live, ADR-0054/
  ADR-0051) -- E41.
- **UC-054** (`AGENTS.md` and the `kazi install-skill`-generated `SKILL.md` describe
  kazi's upstream-planning/downstream-hygiene contract generically instead of naming
  the operator's personal skills (`/plan`/`/tidy`/`/loop`/`/qualify`) as if universal,
  a coherence guard catches any recurrence, and the non-functional
  `Kazi.Retrieval.Graphify` backend -- which shelled out to a `graphify` CLI that
  does not exist -- is retired, ADR-0052) -- E42.
- **UC-055** (a goal can assert that the SHIPPED CLI binary actually runs: a first-class
  `:cli` predicate drives the built binary as a user invokes it -- argv -> exit code +
  stdout/stderr matchers (`equals`/`contains`/`regex`/`json_path`), an ordered
  sub-invocation script, and a `--help` golden-snapshot -- so the artifact-serves gap
  that `:tests` is blind to (the `:noproc` CLI crash, the OTP stderr warning, the
  L-0022 `RELEASE_*` env leak, the brew `Kazi.Repo`-not-started crash, all GREEN in
  `mix test`) becomes a pre-merge predicate; dogfooded on kazi's own release binary,
  ADR-0053) -- E43.
- **UC-056** (a goal can assert real UI behavior objectively: the `:browser` runner's
  assertion vocabulary gains a higher-level pack -- `console_clean`, `a11y` (axe-core),
  `visual` (baseline diff), `form_validation`, richer DOM assertions
  (`attr`/`count`/`enabled`/`field_value`), and a `viewport` matrix -- so "no console
  errors / accessible / renders on mobile / the form validates / this component still
  looks right" are declarative predicates on what a real browser observes, not a
  hand-authored click/type sequence; runner + schema only, zero kazi-core change,
  ADR-0053) -- E43.
- **UC-057** (converged work always LANDS: an `[integration]` goal-file block
  (commit/branch/pr/merge/none) is enforced as an implicit `landed` predicate, so a
  code-green-but-dirty workspace is an UNSATISFIED vector -- the inner agent commits in
  small scoped conventional commits, Integrate verifies-then-ships (push -> PR with the
  predicate vector as body -> rebase-merge; no more `git add -A` monolith), and
  `--parallel` groups land as per-group branches/PRs merged in `needs` order with
  `git cherry` silent-revert verification, ADR-0055) -- E44.
- **UC-058** (the working discipline an external orchestrator gave for free is
  controller-owned: a versioned, cacheable process-contract section in every dispatch
  prompt (small one-directory commits, zero-stub, lore-grep, migration-number safety;
  `[conventions]` to extend/disable), deterministic gate providers
  (`no_stubs`/`oss_hygiene`/`docs_updated`) replacing prose wave gates, an apply
  preflight, and a clarify floor that flags a code goal with no landing mode,
  ADR-0055) -- E44.
- **UC-059** (a PROJECT is plannable and drivable as one kazi artifact: `kazi plan
  --project` authors a roadmap as a goal DAG (`needs` edges between goals), rolling-wave
  is native (an outline phase is a goal whose `plan_expanded` predicate converges when
  the phase's goal-set exists, floor-passed, approved -- a standing roadmap apply
  triggers the next planning pass when the frontier lands), `kazi apply <roadmap>` runs
  goals in topological frontiers to a collective verdict, `kazi plan render` emits the
  human-readable plan as a GENERATED view of the read-model, and `kazi plan --discover`
  unifies the authoring on-ramp, ADR-0056) -- E45.
- **UC-060** (kazi is the ONE system for engineering work -- no external plan/apply
  orchestration skills required: the escalation ladder is `[escalation]` goal-file data
  (core still holds no selection policy), the self-teaching artifacts carry the full
  surface from the binary alone, kazi's own WBS migrates to a roadmap goal-DAG with
  `docs/plan.md` generated, and retirement of the external skills is gated on a
  zero-skill idea->landed-PR->live-verify dogfood, ADR-0056) -- E45.
- **UC-061** (the FLEET is observable in one pane: every `kazi apply` on the machine
  registers itself (run registry + heartbeats in the shared read-model, stale =
  crashed, never silently absent) and `kazi dashboard` renders the starmap home view
  -- the goal DAG in topological wave bands with node states landed/converging/
  claimed/pending/stuck, per-node run tags, fleet counts, and a ranked attention
  queue fed by the existing stuck/flake/regression/budget signals; read-only
  projection, no control plane, ADR-0057) -- E46.
- **UC-062** (no run is a black box: every run leaves a replayable trail -- an
  `events.jsonl` sink (loop events + per-iteration predicate vectors) and a
  REDACTED `transcript.jsonl` tee of the inner-harness stream -- so the operator can
  peek into any goal live or post-mortem: the convergence heatmap (predicates x
  iterations) with an iteration scrubber, and transcript peek with tool-call
  folding; peeking equals tailing a file, ADR-0057) -- E46.
- **UC-063** (budgets are estimated from data, not guessed: run-end economics --
  budget_spent tokens/USD/dispatches, outcome + cause, harness/model/tier, goal
  shape -- persist to the local read-model (honest-unknown NULLs, no telemetry)
  and `kazi plan`/`adopt` propose provenance-annotated `[budget]` values from
  history percentiles, ADR-0058) -- E48.
- **UC-064** (budget stops are honest: live-predicate config errors fail at
  goal-load; persistent permanent errors terminate early as a named `:stuck`
  (never 40 wasted iterations to a mislabeled `over_budget`); terminal results
  carry a cause class; a token ceiling that cannot bind warns loudly;
  `max_dispatches` counts dispatches, not observe ticks, ADR-0058) -- E48.
- **UC-065** (dispatch prompting improves from measured behavior: tools-counter
  rediscovery candidates + opt-in debrief hypotheses (never direct prompt
  mutation) gated by the E19/T34.7 benchmark rig -- a variant ships only on a
  measured tokens-to-converge reduction, ADR-0058) -- E48.
- **UC-066** (a goal asserts a CAPABILITY -- "a user can create and download a
  PAT" -- as a first-class `scenario` predicate: one tagged Gherkin Scenario
  bound to a committed PIN (a replayable trace in the existing `:browser`/`:cli`
  config vocabulary), passing ONLY when the pin validates (every When -> >=1
  step, every Then -> >=1 assertion, Scenario-hash current) and replays green
  through the delegated surface provider -- hand-authored pins work day one; an
  agent claim never grades, ADR-0064) -- E49.
- **UC-067** (pins author and repair THEMSELVES without entering the fixer's
  reach: a DEMONSTRATOR dispatch role, write-disjoint from the fixer via
  role-scoped `read_only_paths` (demonstrator writes ONLY pins; fixer never
  does), authors a pin accepted only on validate-plus-green-replay;
  repin-with-diff distinguishes selector rot from capability regression;
  repeated demonstration failure terminates as `:stuck` cause
  `capability_unreachable`; standing goals replay pins as live capability
  monitors -- the DoD "verified live" step as a predicate, ADR-0064) -- E49.
- **UC-068** (concurrent sessions across machines work as a TEAM without a human
  relaying between them: delivery is installed harness mechanics -- an opt-in
  turn-boundary hook that costs nothing when the bus is quiet -- rather than a
  documented recipe no session ever runs; a digest bounded at RENDER keeps
  awareness affordable on the `--json`/MCP paths agents actually use, with
  documents addressable via `bus get` instead of flooding a routine check; and a
  cursor-free board projects roster + claim ownership + current facts, so a
  starting session sees who is here and what is already claimed BEFORE it picks
  up work -- retiring the machine-local markdown blackboards two teams rebuilt
  by hand, ADR-0071/0072/0073) -- E55.

## Checkable Work Breakdown

The WBS below is the single checkable source of truth; toggle `[ ]` to `[x]`.
Status `kind: agent` is implicit unless noted. Completed epics (E0-E8, E11, and the
E9 core T9.1-T9.4/T9.7-T9.9) are removed from this WBS -- they are done on `main`;
their narrative lives in the ADRs and `docs/devlog.md`.

### E9 (leftovers) -- Website polish (P2, ADR-0018) -> plans/E9.md
### E15 -- Harness-friendly, agent-drivable kazi: JSON CLI + result contract (P3, ADR-0023) -> plans/E15.md
### E19 -- Realize the unwired token-efficiency levers + measure (P2, ADR-0010) -> plans/E19.md
### E20 -- kazi UNDER /apply --pool: objective-done + coordination + observability beneath pooled sessions (P1, ADR-0026) -> plans/E20.md
### E21 -- kazi owns parallelization: a native scheduler over a partitioned goal-set (P1, ADR-0027) -> plans/E21.md
### E22 -- Pre-publish documentation refresh -- RETIRED / CONSOLIDATED into E25 (2026-06-25) -> plans/E22.md
### E23 -- Dependency-aware partitioning: predicate-graph waves (P2, ADR-0028) -> plans/E23.md
### E25 -- Content-marketing refocus: lead with the agent-drives-kazi paradigm (P1, ADR-0030) -> plans/E25.md
### E26 -- The kazi skill becomes a router: plan/apply/status/adopt (P1, ADR-0031) -> plans/E26.md
### E27 -- Rename the CLI verbs: run -> apply, propose -> plan (P1, ADR-0032) -> plans/E27.md
### E28 -- Doc-sync: bring concept.md + the architecture docs to current reality (P1, no ADR) -> plans/E28.md
### E29 -- OSS contribution gates: docs-with-code + no-internal-leak (P1, ADR-0034) -> plans/E29.md
### E30 -- Adaptive in-family model tiering, skill-driven (P1, ADR-0035) -> plans/E30.md
### E31 -- Self-maintaining docs: plan trim + freshness as a kazi standing goal (P1, ADR-0036) -> plans/E31.md
### E32 -- Predicate catalog & evidence v2: the verification workhorse (P1, ADR-0040/0041/0042/0043) -> plans/E32.md
### E33 -- `kazi mcp` as a first-class installed subcommand (P1, ADR-0044) -> plans/E33.md
### E34 -- Economy accounting envelope: cached-vs-fresh tokens + cost-per-converged-predicate (P1, ADR-0046) -> plans/E34.md
### E35 -- Context-store layer + Gist provider: evidence compression + stuck-bundle replay (P2, ADR-0045) -> plans/E35.md
### E36 -- Inner-harness minimalism: tool-surface restriction now, context tiers measured (P2, ADR-0047) -> plans/E36.md
### E37 -- Wire the Gemini CLI harness profile (P2, ADR-0016/0022) -> plans/E37.md
### E38 -- Adoption blog series: "From Vibe Coding to Reconciliation" (12 parts) (P1, ADR-0048) -> plans/E38.md
### E39 -- Orchestrator-driving ergonomics: close the plan -> approve -> apply loop over `--json` (P1, ADR-0049) -> plans/E39.md
### E40 -- Behavior specs: wire the dormant Gherkin importer into a first-class `docs/specs/` tier (P2, ADR-0050) -> plans/E40.md
### E41 -- Crystallize discovered truth: Gherkin + tags for product-level use cases, iterative discovery via `kazi init --discover`, and prod-log predicate correlation (P2, ADR-0054/ADR-0051) -> plans/E41.md
### E42 -- Fix kazi's self-teaching artifacts: no personal-skill assumptions, retire dead Graphify retrieval (P1, ADR-0052) -> plans/E42.md
### E43 -- Higher-level interactive-surface predicates: a `:browser` assertion pack + a first-class `:cli` provider (P1, ADR-0053) -> plans/E43.md
### E44 -- Landing is part of convergence: `[integration]` + implicit `landed` predicate + controller-owned process contract (P1, ADR-0055) -> plans/E44.md
### E45 -- One system: roadmap-scope planning, plan-as-generated-view, escalation-as-data, skill retirement (P1, ADR-0056) -> plans/E45.md
### E46 -- Fleet observability: run registry, per-run sinks, `kazi dashboard` starmap (P1, ADR-0057) -> plans/E46.md

### E47 -- Fleet observability follow-up: event river + roadmap-ref starmap (P2, ADR-0057/ADR-0056) -> plans/E47.md

### E48 -- Economy feedback loop: persisted run economics, learned budgets, behavior-first prompting, honest budget stops (P1, ADR-0058) -> plans/E48.md

### E49 -- Scenario predicates: capability-level verification by demonstrate-then-pin (P1, ADR-0064) -> plans/E49.md
### E50 -- Safe concurrent work: serial worktree indirection, wave checkpoints, fleets over goal-files (P1, ADR-0065) -> plans/E50.md

### E51 -- Session coordination bus: `kazi daemon` + bus primitives on the JetStream substrate (P1, ADR-0067) -> plans/E51.md

### E52 -- The daemon becomes the single writer for the read-model (P2, ADR-0068) -> plans/E52.md

### E53 -- Reliability hardening: the four open runtime bugs from the E50 execution sweep (P0/P1) -> plans/E53.md

### E54 -- Reliability hardening II: the nine 2026-07-11/12 execution-sweep bugs -- partition branch lifecycle, dispatch budget-burn safety, --json locale, provider/bus DX (P0/P1) -> plans/E54.md

### E55 -- Teamwork is first-class: installed delivery, a bounded digest, and a board (P1, ADR-0071/0072/0073) -> plans/E55.md

## Risk Register

| ID | Risk | Impact | Likelihood | Mitigation |
|----|------|--------|------------|------------|
| R-E12-1 | Free-text grouping fragments the hierarchy on inconsistent spelling. | Med | Med | The taxonomy is DECLARED and referenced by id, validated at load (T12.1/T12.2); slug normalization + a `kazi lint` near-duplicate-name warning (T12.7) are the second net. ADR-0020. |
| R-E13-1 | The prose->predicate path (T13.3) is non-deterministic (an LLM extracts intent). | Med | High (inherent) | Route through the existing HUMAN-REVIEWED authoring/clarify flow (nothing accepted without approval); the deterministic spec path (OpenAPI/gherkin) is the trustworthy backbone. ADR-0021. |
| R-E13-2 | The surface scanner (T13.4) is language-specific and blind to reflection/string-dispatch, risking false dead-code flags. | Med | High (inherent) | Approximate-by-design + an explicit allow-list + WARN-don't-auto-delete (T13.5); documented in `docs/lore.md`. ADR-0021. |
| R-E14-1 | Antigravity `agy -p` SILENTLY drops stdout under a non-TTY subprocess (issue #76) -- exactly kazi's mode. | High | High (observed in research) | T14.3 uses the `--prompt-file` + `--output json` (read a file) workaround, NOT bare `-p`; pin a version; record the landmine in `docs/lore.md`. ADR-0022. |
| R-E14-2 | claw-code emits no structured output ("museum exhibit"), so cost/parse fidelity is degraded. | Low | High (inherent) | T14.4 is BEST-EFFORT only (raw-stdout parse, no invented cost), explicitly labelled demo-grade. ADR-0022. |
| R-E15-1 | The `--json` result schema is a compatibility surface an orchestrator pins against; a breaking change silently breaks callers. | Med | Med | Version it (`schema_version`, T15.3); the orchestrator recipe documents pinning; a self-conformance test (T15.7) guards regressions. ADR-0023. |
| R-E39-1 | `apply <proposal-ref>` adds a second argument mode (ref vs goal-file); a wrong disambiguation could run the wrong goal or break the existing path. | Med | Low | The `prop-` prefix is the discriminator; a non-approved/unknown ref errors clearly; a path argument stays byte-for-byte the old behavior; ExUnit pins all three (T39.2). ADR-0049. |
| R-E15/16-1 | End-to-end value needs a capable, FAST-ENOUGH inner harness; claw->local Qwen is best-effort/slow (T8.11). | Med | High (known) | The JSON contract makes kazi drivable regardless; convergence speed is the inner harness's problem. T15.9/T16.6 report honestly (wiring proof vs fast convergence). |
| R-E16-1 | The shipped skill/`AGENTS.md` drift from the real CLI. | Med | Med | `help --json` is GENERATED from the command table (T16.1); a coherence test (T16.4) fails CI when the skill names a command `help --json` does not report. ADR-0024. |
| R-E17-1 | Website/README copy drifts from what kazi actually does. | Med | Med | Copy DERIVES from README/concept; the README<->site canonical-string drift-check (T9.9) fails CI on divergence; T17.1/T17.2 update both in lockstep. |
| R-E18-1 | A read-model serialization change (T18.2) alters the stored shape and breaks the deserialize round-trip / dashboard reads. | Med | Low | T18.2 keeps `:pass`/`:fail` serialization byte-compatible; only non-JSON evidence (the crash case) changes; an ExUnit round-trip pins it. |
| R-E19-1 | Injecting the orientation prefix (T19.1) ADDS per-dispatch input tokens and may be net-NEGATIVE if it does not save enough exploration / cache. | Med | Med | Treat as a hypothesis: T19.4/T19.5 measure B-vs-C and the verdict may be REVERT (keep file-based orientation). Prefix kept behind a flag so reverting is config, not code. |
| R-E19-2 | Cross-dispatch prompt-cache hits depend on the inner harness's own cache (kazi sets no `cache_control`) and a <5min TTL between dispatches; slow predicate evaluation can blow the TTL. | Low | Med | T19.2 maximizes the stable head so hits are likely when dispatches are rapid; T19.5 reports the realized cache_read delta honestly rather than assuming the win. |
| R-E20-1 | Running `/claim` (git refs) AND kazi leases (NATS) can deadlock two sessions each holding a claim + a lease. | High | Low | T20.7 fixes the acquire order (claim then lease), bounds a crashed holder with a lease TTL, and orders release (lease before claim); a constructed cross-acquire test proves no deadlock. |
| R-E20-2 | L3/L4 add a NATS dependency the pool does not have today (CLAUDE.md: NATS not required until Slice 3). | Med | Med | L1-L2 are git-refs-only and ship first; NATS is opt-in, required only at L3 (blast-radius leasing) / L4 (presence). Adopters get value before NATS. |
| R-E20-3 | The cheaper-via-tiering win (T20.5) is gated by local-model speed (T8.11). | Med | High (known) | T20.5 is optional; objective done holds regardless of implementer quality; report wiring-vs-fast-convergence honestly, never a false convergence. |
| R-E20-4 | The opt-in gate in the GLOBAL `/apply` skill drifts from kazi's CLI (cross-repo). | Med | Med | The skill references only commands `kazi help --json` reports; enhance globally (not project-local, per the skills policy); the recipe pins the JSON contract (`schema_version`). |
| R-E20-5 | kazi overhead is not worth it for trivial pooled tasks. | Low | Med | The gate is OPT-IN per task (`--verify-with-kazi`); reserve kazi for tasks with real verification surface (live endpoints, regressions, multi-iteration); trivial tasks use the bare pool. |
| R-E21-1 | Partition QUALITY depends on graph freshness; a false-disjoint partition lets two reconcilers edit coupled code. | High | Med | Leases catch residual overlap and serialize (T21.3/T21.6); the graph is refreshed before dispatch (ADR-0010); merge convergence (T21.5) re-dispatches on a detected conflict -- never a silent merge. |
| R-E21-2 | Git-worktree-per-partition risks disk pressure and the `rm -r` cwd-worktree landmine. | Med | Med | T21.4 creates/cleans a worktree per terminal path and honors the worktree-guard (never `rm -r` a cwd worktree); cleanup is tested on every exit (converged/stuck/over_budget/crash). |
| R-E21-3 | A crashed partition reconciler corrupts shared lease/worktree state or takes down the coordinator. | High | Low | T21.10: the coordinator survives child crashes (DynamicSupervisor); a crashed child's lease frees via TTL and its worktree is reconciled; siblings unaffected. |
| R-E21-4 | Building a scheduler before it is needed (premature) / scope creep vs the shipped serial loop. | Med | Med | E21 REUSES the existing serial per-goal loop (one per partition) -- it adds a supervisor + coordinator, not a new loop; single-goal stays the default; parallelism is opt-in. The substrate (Partition/leases) is already built. |
| R-E22-1 | Publishing docs while a feature epic (E15-E21) is incomplete -> the docs advertise vaporware. | High | Med | E22 is GATED on all feature epics (T22.1 deps list them); T22.7 is a no-vaporware audit (every command verified against `kazi help --json`); T22.8 launch checklist blocks publish until green. |
| R-E22-2 | Docs drift from the CLI between writing and publishing (the surface is large). | Med | Med | Coherence guards: README<->site (T9.9), skill/`AGENTS.md`<->CLI (T16.4), and T22.7's full audit generated from `kazi help --json` (the source of truth), not hand-maintained lists. |
| R-E22-3 | E22 duplicates/conflicts with the README/site rewrite (E25, which superseded E17 content). | Low | Med | E22 BUILDS ON E25 (T22.2 deps T25.3, T22.5 builds on T25.4/T25.9) -- it adds full feature coverage + the audit + the launch gate ON TOP of E25's lead, it does not re-theme or re-message. |
| R-E23-1 | `needs` edges are AUTHORED (kazi cannot derive semantic order); the burden + the chance of wrong/missing edges fall on the operator. | Med | Med | `needs` is OPTIONAL (absent = full parallel); the edges are the irreducible semantic input (ADR-0028); `--explain` (T23.6) surfaces the resulting order so wrong/over-constrained deps are visible before a run. |
| R-E23-2 | Over-declaring `needs` re-serializes and loses kazi's parallelism advantage. | Med | Med | Declare only true precedence; T23.6 `--explain` + T23.7 dashboard show realized parallelism; spatial partitioning still parallelizes within each frontier. |
| R-E23-3 | A cycle or a stuck dep makes a sub-DAG unsatisfiable / hangs dependents. | Med | Low | Cycles rejected at load (T23.1, like ADR-0020's parent-cycle guard); a stuck/over-budget dep escalates and is NAMED (T23.5), never a silent hang. |
| R-E23-4 | E23 depends on E21 (the scheduler), which is not built yet. | High | Low | Sequencing is explicit: T23.3+ deps T21.1/T21.2; E23-1 (the pure model T23.1/T23.2) can proceed against E12 alone, ahead of the scheduler. |
| R-E25-1 | "Done" is harder to make falsifiable than "fast" (research risk #1) -- the agent-paradigm pitch misfires without a reproducible number. | High | Med | T25.7 builds the dogfood "done" leaderboard with a REPRODUCIBLE methodology (the number must hold up, the Ruff lesson); the hero transcript (T25.2) makes "objective done" visible; lead with the outcome, not the abstraction. |
| R-E25-2 | "Reconciliation controller" is a new category (education tax); the agent-driven framing may read as me-too in a crowded harness field. | Med | Med | ADR-0030: borrowed frame ("CI for coding agents") in line 1 with the precise category as the second beat; position as a different LAYER (verification), not another harness. |
| R-E25-3 | E25 duplicates/contradicts the open E17 + E22 README/site tasks (multiple generations of the same doc). | Med | Med | RESOLVED 2026-06-25: E25 is now the SINGLE canonical docs+content epic -- E22 is RETIRED (T22.1-9 folded into E25 T25.3/T25.4/T25.9/T25.10) and the doc parts of E17/T20.10/T21.11/T30.5/T31.8 fold in too. Each surface is written ONCE here (execute per ADR-0025/0030); the epic intro + wave notes + this row record it so no pool session runs two generations. |
| R-E25-4 | The hero transcript (T25.2) needs a real recordable end-to-end run; if unavailable, a mockup could mislead. | Low | Med | A static fallback is allowed ONLY if HONESTLY labelled as a mockup (ADR-0030); never presented as a recorded run; replace with a real asciinema cast once a clean run exists (the E18 re-verify shows clean runs are now achievable). |
| R-E25-5 | Distribution rides the Claude Code / MCP host; a host change breaks the install/invocation story. | Med | Low | Keep multi-harness (Codex/opencode) in the on-ramp (the Cline lesson); the invocation phrase (T25.6) is documented + coherence-checked (T16.4); instrument downloads/retention, not stars. |
| R-E30-1 | Escalation triggers too eagerly (collapses to always-frontier -> no saving) or too lazily (wastes cheap-tier iterations / never converges). | Med | Med | The ladder is bounded + capped (ADR-0035); the 3-arm benchmark (T19.7) reports $/tokens AND convergence/correctness per arm so a collapse-to-frontier or cheaper-but-fails outcome is VISIBLE; the stuck threshold is a tunable skill knob; predicates make a wrong tier fail to converge, never a false done. |
| R-E30-2 | Pressure to "just put tiering in kazi core" (auto-select by phase/difficulty) -- the derail ADR-0033/0035 reject. | Low | Med | Policy stays in the skill (orchestrator); kazi only exposes `--model` + reports state; T30.3 permits at most a read-only signal enrichment, never model-selection logic; reviewers cite ADR-0035's rejected-alternative. |
| R-E31-1 | The deterministic trim (T31.2) mis-judges "released" and archives in-flight work. | Med | Low | Trim requires BOTH all-`[x]` AND a release tag covering the epic; the archive is append-only + git-tracked so any wrong move is reversible; refuses any epic with an open/blocked task. |
| R-E31-2 | Doc-freshness predicates (T31.4/T31.5) are too strict -> CI thrashes and gets disabled. | Med | Med | Warn-first then ratchet to blocking (the E29 pattern); predicates scoped to SHIPPED surfaces (commands in `help --json`, real symbols); each failure names the exact location so fixes are cheap. |
| R-E31-3 | An autonomous standing goal (T31.6) churns docs or loops. | Med | Low | Objective convergence (the predicates gate it); Layer-2 extraction keeps a human-confirm gate; kazi's budget/stuck termination bounds it; Layer 1/3 are mechanical/idempotent. |
| R-E31-4 | Pressure to build a doc engine INTO kazi core -- the derail ADR-0036 rejects. | Low | Med | Trim/extraction/freshness logic lives in the skill + CI layer; the standing goal's actions shell out to those tools; kazi stays a pure controller (ADR-0023 line); reviewers cite ADR-0036's rejected-alternative. |
| R-E26-1 | The router claims `kazi apply` replaces `/apply --pool` before the native scheduler is proven at scale (E21/E23 dogfoods open). | High | Med | ADR-0031 decision 6 + T26.6: the subsumption claim is GATED on T21.12/T23.9 passing; until then the on-ramp marks it "coming" and keeps `/apply --pool` as the documented interop fallback (ADR-0026). |
| R-E26-2 | Skill-verb vs CLI-verb mismatch (apply->run, plan->propose) confuses users or drifts from the CLI. | Med | Med | The verb map is documented in the router SKILL.md (T26.1); the skill<->CLI coherence guard (T16.4/T26.5) asserts every sub-skill routes to a real `kazi help --json` command; `kazi run` is not renamed. |
| R-E26-3 | Retiring loop/qualify from the code on-ramp loses capability for non-code or edge cases. | Low | Med | They are retired only from the CODE on-ramp; both remain general skills for non-code work; `/plan` (intent) + `/tidy` (hygiene) are explicitly kept (ADR-0031). |
| R-E27-1 | The verb rename breaks the shipped agent-drivable JSON contract / skill / MCP for existing callers. | High | Low | `run`/`propose` (+ `mix kazi.run`) stay as DEPRECATED ALIASES dispatching identically (T27.1/T27.2); the `schema_version` bump (T27.3) makes the contract change explicit; a deprecation-window note (T27.7); alias tests pin back-compat. |
| R-E27-2 | A broad rename misses a reference, leaving an inconsistent surface. | Med | Med | Coherence guards cover it: skill<->CLI (T16.4), README<->site (T9.9), self-conformance (T15.7); `kazi help --json` is generated from the real command table; T27.8 live-verifies both verbs. |
| R-E27-3 | The `schema_version` bump breaks orchestrators pinning the old version. | Med | Low | Documented as a breaking contract change (ADR-0032/T27.3), not silent; the old command names remain valid aliases so only the pinned version (not the call) must update. |
| R-E32-1 | The `custom_script` generic provider becomes a footgun: a mis-declared verdict (e.g. `exit_zero` on a tool that exits 0 WITH findings) silently passes a real failure. | High | Med | Verdict is EXPLICITLY declared, not assumed (T32.1); safe defaults + the `:error`-vs-`:fail` distinction; the exit-code gotchas (govulncheck/trivy/semgrep/grype) are encoded as recipe config (T32.9), and shipped examples model the json-verdict pattern. ADR-0040. |
| R-E32-2 | A graded `score` (ADR-0041) re-introduces reward hacking through the gradient -- the agent inflates a proxy (assertion-free tests lifting line coverage) without improving the true goal. | Med | Med | The THRESHOLD (the gate), not the gradient, is authoritative and measures the true goal; prefer gaming-resistant scores (mutation over raw line coverage); the score only feeds progress/stuck classification, never the `:converged` gate. ADR-0041 + ADR-0042. |
| R-E32-3 | Anti-gaming enforcement (T32.4) over-restricts and breaks legitimate work -- the agent SHOULD author new tests in creation mode, but read-only test leasing blocks it. | Med | Med | The read-only class is scoped to the goal's PREDICATE/acceptance files, not all tests; the diff-inspection guard (T32.5) is advisory (surface, not hard-block) at first; held-out (T32.6) is opt-in for the acceptance subset only; the working predicates stay visible so the gradient + fix context survive. ADR-0042. |
| R-E32-4 | "Run the checker outside the agent's reach" (T32.4) collides with how dispatch + worktrees are actually wired, so the clean-tree guarantee is wrong/partial. | High | Med | T32.4 carries an explicit PRECONDITION: verify the seam against `lib/kazi/loop.ex` + the worktree wiring BEFORE implementing, and document the reference; the guarantee is reported in `--json` (T32.4) so a partial guarantee is visible, never silently assumed. ADR-0042. |
| R-E32-5 | Live metric/burn-rate predicates (T32.10) assume an observability stack (Prometheus) kazi cannot provision, so they mislead when absent. | Med | Med | They degrade to "not applicable" (never a false pass) when no metrics endpoint is configured; sustained-health needs only an HTTP endpoint and is the universal baseline; the bake-window discipline is documented. ADR-0043. |
| R-E32-6 | Provider sprawl: too many first-class kinds to maintain. | Low | Med | The earns-first-class test (ADR-0043 §context): only five code-side providers (`:static`/`:coverage`/`:property`/`:mutation`/`:cve`) + the live upgrades are first-class; the long tail (contract/perf/a11y/visual/secret/IaC) stays `custom_script` config (T32.9), growing the catalog without growing the release surface. |
| R-E32-7 | Unifying + deprecating `test_runner`/`prod_log` (T32.1b) breaks existing goal files, or the eventual removal force-bumps a premature v2.0.0. | Med | Low | T32.1b ships NON-BREAKING -- both names keep resolving as presets with a stderr deprecation hint and a near-mechanical migration documented in `docs/deprecations.md`; the actual REMOVAL is a SEPARATE future v2.0.0 task (not in E31), mirroring the run/propose -> v1.0.0 window; an existing-goal-file load test pins back-compat. ADR-0040 decision 7. |
| R-E38-1 | The series reads as condescending toward "vibe coders" or as influencer hype, repelling the working engineers it must win. | High | Med | ADR-0048 freezes a fellow-traveler stance; the committed style sheet (T38.5) encodes voice + a no-hype checklist; a human voice/continuity review is a REQUIRED gate step (T38.18d) because a coherence check cannot catch tone. |
| R-E38-2 | A post advertises a kazi capability that is not shipped (vaporware), breaking the credibility the series is built to create. | High | Med | No-vaporware is an ADR-0048 non-negotiable: every command verified vs `kazi help --json`/`concept.md`; the E29 removed-verb guard is extended over `site/src/content/blog/**` (T38.4) and the E31 freshness checks + the T38.18 gate block publish until green; "coming" only where honestly labelled. |
| R-E38-3 | Twelve quality posts are a large sustained writing effort; the series stalls half-published and reads as abandoned. | Med | Med | Posts are independently useful (ADR-0048) so a partial series still delivers value; the plan publishes incrementally (Wave E38-2) and each post ships live on its own; the gate (T38.18) runs over whatever is published, not all-or-nothing for value (only for the launch announcement T38.19). |
| R-E38-4 | The series duplicates or contradicts the E25 README/site launch messaging (two generations of the same pitch). | Low | Med | E38 is the LONG-FORM companion to ADR-0030/E25, not a rewrite: it REUSES E25's hero transcript (T25.2), without/with frame, and dogfood gallery (T25.7) and links the same launch; T38.19 explicitly coordinates with (does not duplicate) the E25 T25.10 launch gate. |
| R-E38-5 | Naming the product late depresses near-term conversion / lead-gen from the early posts. | Low | Med | Deliberate trade per ADR-0048 (credibility over a conversion spike); every post still links forward and the final third (posts 10-12) converts; distribution widens because marketing-allergic communities will share product-light, useful posts. |
| R-E38-6 | The journey runs on the author's PRIVATE/internal stack (personal memory/browser/graph tooling); readers cannot reproduce it and a public post could leak internal infra. | High | Med | ADR-0048 dec. 5 (added in the skills-coverage second pass): every post LEADS with the commodity, reproducible technique and names a personal/internal tool only as "what I used" with a commodity alternative; no post requires a private tool; the T38.18 gate runs the E29 no-leak scan over `site/src/content/blog/**` and asserts no required-private-tool. |
| R-E38-7 | Scope creep -- a well-meaning execution pass bolts marketing machinery (a 30-agent-org post, email drip funnels, a team charter) onto the series, diluting the anti-hype stance. | Med | Med | ADR-0048 "Considered and deliberately excluded" names each and why; the two sanctioned supporting tasks are bounded (T38.20 "diagrams not ad creative", T38.21 "one signal not a funnel"); reviewers cite the exclusion list. |
| R-E43-1 | The UI-pack assertions (T43.2/T43.3/T43.10) drag runner-side deps (axe-core, a screenshot-diff lib, Maestro) into the browser runner, inflating its footprint or breaking `mix test`. | Med | Med | Deps stay runner-side and OPTIONAL: an assertion whose dep is absent returns `:error` "unavailable", never `:fail` (exactly how Playwright is handled today); `mix test` drives the STUB runner and never installs a browser dep; ADR-0053 §1/§4. |
| R-E43-2 | `:cli` overlaps `:tests`/`:custom_script`, confusing authors about which to reach for. | Low | Med | ADR-0053 delineates them: `:tests`=the suite (compile+unit truth), `:custom_script`=an arbitrary tool with a declared parse, `:cli`=turnkey golden-invocation of a SHIPPED binary (exit/stdout/stderr matrix + `--help` golden). `kazi schema cli` + the docs how-to state the boundary (T43.7). |
| R-E43-3 | `:cli`/UI live dogfoods (T43.6/T43.9) need a real browser or a real built binary that a headless pool session may lack, so the wave stalls or reports a false "verified". | Med | Med | Both tasks are `kind: any` and REPORT HONESTLY which path ran (stub vs live; mix/escript/burrito) per the global Definition-of-Done; the stub-path ExUnit in T43.1-T43.5/T43.7-T43.8 is the machine-checkable backbone, the live run is the confirmation, never the gate. |
| R-E49-1 | A demonstrator authors a WEAK-but-structurally-mapped pin (a `Then` realized by a trivial assertion), so replay passes without proving the capability -- the residual gaming gap ADR-0064 names. | Med | Med | The T49.1 step-map floor kills VACUOUS pins deterministically; pins land via PR (repin diffs are review artifacts); `repin = "manual"` for high-stakes goals; the demonstrator prompt is controller-owned + versioned (T49.7) so hardening is central; semantic-faithfulness checking stays future work and is NEVER an LLM judgment inside the envelope. |
| R-E49-2 | The demonstrator needs a REACHABLE app (base_url/built binary) and browser/CLI automation the harness may lack in a headless pool session, so Wave B stalls or a false "demonstrated" is reported. | Med | Med | Wave A ships hand-authored-pin value with zero demonstrator involvement; T49.7's acceptance gate (validate + green replay) makes a false "demonstrated" structurally impossible -- a claim without a replaying pin changes nothing; T49.13 is `kind: any` with the R-E43-3 honest-report discipline. |
| R-E49-3 | Cross-epic deps (T43.1/T43.7-8, T40.2, T41.1 -- all OPEN) stall the epic if encoded as epic-wide gates. | Med | High (known) | Deps are isolated per-task: Waves A/B depend ONLY on code shipped on main today (verified against main 2026-07-08, seams pinned in the epic's Implementation contract); only T49.10/T49.11/T49.13 gate on E43/E40/E41 tasks and the pool schedules them whenever those land. |
| R-E49-4 | The two-role loop thrashes: repin churn masks a real regression, or demonstrate-fail loops burn budget. | Med | Med | At most ONE re-demonstration per iteration; a red replay at the minted commit routes to the FIXER (never re-demonstrated); two failed demonstrations on an unchanged workspace terminate `:stuck` cause `capability_unreachable` (T49.8) ranked needs-a-human (T48.14); demonstrator dispatches are budget-counted + economy-attributed (T49.9). |

## Operating Procedure

Definition of done (all must hold): for code changes, ExUnit tests written and
green; `mix format --check-formatted` clean; `mix compile --warnings-as-errors`
clean; PR merged to `main` via **rebase** (not squash, not a merge commit) with CI
green. For any user-facing surface (the website, the brew packages), verified live
and reported honestly. Many small focused commits; **never commit files from
different directories in one commit**.

Execution model: work the plan with `/apply --pool` (atomic git-ref claims at
`refs/claims/*` via the global `~/.claude/skills/claim/scripts/claim.sh`). The WBS
above is the single checkable source of truth; toggle `[ ]` to `[x]` as tasks land.

Releases are AUTOMATIC: merging Conventional Commits to `main` lets release-please
open a release PR; merging that PR cuts a `vX.Y.Z` tag -> the Burrito build + tap
auto-bump run hands-off (validated through v0.3.0). Type every commit correctly --
Conventional Commits are load-bearing for versioning.

**Concurrent sessions share this working tree.** Before a full-file rewrite (e.g.
`docs/plan.md`), `/claim R-plan-md`, re-read, write, release. When committing,
stage only YOUR files (`git add <paths>`) so a sibling session's uncommitted WIP is
never swept into your commit.

## Progress Log

### 2026-07-16 -- Change Summary (bus observation pass: E55 planned off ADR-0071/0072/0073; E51 Wave B superseded)
- **Observation pass on the live bus.** The E51 bus is working: a `kazi daemon`
  up 16h carrying a dozen sessions across two machines and three projects, with
  cross-machine presence/facts/directed messages round-tripping on the released
  binary. Adoption failed anyway; three structural causes found, none of them
  agent discipline.
- **Delivery was never built.** ADR-0067 point 6 shipped the turn-boundary hook
  as a documented recipe; its observed install rate is zero (no hook on either
  machine). The operator is the delivery mechanism -- every session that reads
  the bus does so because a human told it to, again. Two enhancement passes on
  the skill's bus section changed no behaviour.
- **The digest protects the wrong reader.** `Kazi.Bus.Digest` is reached only
  from the TTY branch of `emit/3` (`cli.ex:3951/3974/4010`), so `--json` and the
  MCP tools -- every agent path, including the documented hook recipe -- return
  the full transcript. Measured: one `bus peek --json` returns the whole backlog
  verbatim including two ~10-20 KB filler messages. **R-E51-4 materialized with
  all three mitigations failed** (1 KB cap raised 64x for a real need, T51.4
  unstarted, T51.6 blocked behind it); recorded in E51's register.
- **Teams need state, not a stream.** Two project teams independently abandoned
  the bus for machine-local markdown blackboards and never returned -- rebuilding
  ADR-0067's explicitly rejected alternative, and losing cross-machine to do it.
  `fact`'s last-value retention was already a board with no verb to render it.
  Duplicate work traced to lock VISIBILITY: `refs/claims/*` are invisible to the
  bus, so a lead hand-maintains ownership in prose.
- ADR-0071 (delivery is installed, not documented -- supersedes 0067 point 6),
  ADR-0072 (the digest bounds context at render, keeping the document-carrying
  limits -- supersedes 0067 point 5's producer cap), ADR-0073 (the board:
  current-state projection + claim visibility + stable identity -- extends 0067,
  readmits its rejected blackboard's interaction model) written; **Accepted** (operator approved 2026-07-16).
- **E55 added** (10 tasks, plans/E55.md; UC-068): Wave A delivery + the bound,
  Wave B board + identity, Wave C server-side + claims + payload, Wave D the
  cross-machine dogfood. Use Case Summary: UC-068 added.
- E51 Wave B superseded into E55: T51.4 (its brief predates the `--json`
  bypass finding) and T51.6 (T55.10 is a superset) move to `[~]`. T51.5 stays
  open, now cross-referencing T55.3 so dashboard presence is not built twice.
- Same-day field feedback folded in (a supervisor session, 24h of real
  five-session two-machine fleet ops; 3 bugs + 5 ranked asks): **E55 grows to
  13 tasks** -- T55.11 presence liveness (idle-alive vs dead via a local-daemon
  pid+start-time sweep, ghost-row reaping, `who` filters, TTL exposed), T55.12
  `tell` delivery visibility (message ids, `bus status <id>` pending|consumed,
  inbox depth in `who --all`, error on dead recipients -- the supervisor's
  top-ranked pain), T55.13 the documented wake contract (worker parks a
  background `bus watch`; the harness re-invokes on completion; gated on
  T54.9). **T54.10 added to E54** (the ADR-0066 burrito maintenance line
  pollutes stdout on every call and breaks ADR-0023 `--json` purity).
  **T51.5 extended** with per-iteration progress facts (a 9-hour
  single-invocation apply was observed with no intermediate observable state).
  Bus HA deferred explicitly (E55 not-in-scope note): history survives daemon
  restarts (file storage, verified), and convergence never depends on the bus.
- Operator question answered and recorded: harness-native agent teams vs the
  bus are complementary (teams = intra-session orchestration; bus =
  inter-session coordination plane); T55.13's doc gains a "when to use teams
  instead" paragraph, and E55's not-in-scope note carries the watch item (ride
  the native mechanism if teams ever spans sessions/machines).

### 2026-07-10 -- Change Summary (E50 execution swept done; E51/E52/E53 planned off ADR-0067/0068 + the bug triage)
- E50 executed: T50.1-T50.6 + T50.8 marked done (goals 0013-0019 driven via
  `kazi apply`; PRs #1016/#1026/#999/#1010/#1031/#1033/#1029, all rebase-merged,
  released through v1.136.0). T50.7 (live fleet dogfood on the released binary)
  is the epic's only open task and is scheduled to run AS the E51 Wave-A fleet.
- ADR-0067 (session coordination bus) + ADR-0068 (daemon single-writer
  read-model) written and Accepted (PR #1035). New epics: E51 (executable --
  daemon lifecycle, bus MVP over supervised nats-server, surfaces; Wave A =
  T51.1->T51.2->T51.3), E52 (outline -- single planning task gated on the E51
  daemon shapes, rolling-wave rule), E53 (executable -- the four triaged
  runtime bugs #1027/#1022/#1020/#1013 as tasks T53.1-T53.4, Wave E53-1
  ordered to unblock landings then CI trust).
- Goal-files 0020-0023 (E53) and 0024-0026 (E51 Wave A, with `[metadata]
  depends_on` + `[scope]` so the batch doubles as the T50.7 fleet DAG)
  authored in this change; new-goal `landed` predicates pin the NAMED task
  branch (the #1027 fix-direction-2 shape) so runs cannot loop or
  false-converge on a substituted integrate branch.
- Bug triage recorded on GitHub: #1018 closed (fixed v1.131.2), #1006
  reclassified enhancement, #1005 annotated shipped-pending-dogfood,
  bug labels added to #1027/#1020/#1019.

### 2026-07-09 -- Change Summary (E50 second pass: ADR-0065 decision 5 -- mutating-verb coverage + fresh-base guard; goal batch PR #994)
- Operator observation while authoring the E50 goal batch: the planning session
  itself had to hand-build a fresh worktree off origin/main because the shared
  checkout was parked on a stale feature branch -- the exact ritual ADR-0065
  exists to absorb, and a freshness gap decision 1 did not cover (worktrees cut
  from the workspace HEAD are isolated but can be stale).
- ADR-0065 amended (decision 5): the worktree indirection covers EVERY
  workspace-mutating verb (executing apply serial/parallel/fleet, goal-file
  materialization per ADR-0059, `kazi plan render` per ADR-0056), and the base
  ref is explicit + validated -- default = workspace HEAD, `--base <ref>`
  overrides, behind-upstream emits a loud warning, never an implicit network
  fetch. Grounded in ADR-0056 (operator-skill conventions migrate into kazi).
- T50.8 added to plans/E50.md (Wave E50-2, deps T50.1; risk R-E50-4); the epic
  acceptance now requires stale-base visibility.
- kazi layer authored separately: PR #994 adds `.kazi/goals/0013-0018`, one
  grind-ready goal-file per code task T50.1-T50.6 (ADR-0059 batch shape,
  seams verified at v1.125.0); T50.7 stays operator-run post-release.

### 2026-07-08 -- Change Summary (E49: scenario predicates -- demonstrate-then-pin; ADR-0064)
- Operator directive: higher-level / UX-level predicate checkers ("form
  validates input", "a user can create and download a PAT") -- there is no
  standard way of verifying software BEHAVIOR. Analysis: "form validates
  input" was already decided (ADR-0053/E43 assertion pack); the CAPABILITY
  level was the unowned gap -- ADR-0054 d3 lowers `@interface:web` Scenarios
  to `:browser` predicates but nothing owns prose -> executable steps.
- ADR-0064 written and ACCEPTED (operator sign-off 2026-07-08, PR #981):
  a first-class `scenario` provider binds a tagged Gherkin Scenario to a
  committed PIN (replayable trace in the existing `:browser`/`:cli` config
  vocabulary); `:pass` comes ONLY from a validated pin replaying green --
  judgment never grades (ADR-0002/0009). Pins are authored/repaired by a
  DEMONSTRATOR dispatch role write-disjoint from the fixer (role-scoped
  ADR-0042 `read_only_paths`); repin-with-diff distinguishes selector rot
  from capability regression; standing goals replay pins as capability
  monitors (the DoD "verified live" step as a predicate).
- E49 added (13 tasks, plans/E49.md; UC-066/UC-067): Wave A pin
  schema/extraction/provider/generators/docs (T49.1-T49.5, hand-authored pins
  work day one, depends only on shipped code -- seams pinned in the epic's
  Implementation contract, verified against main); Wave B demonstrator role +
  role-scoped enforcement + repin lifecycle + `capability_unreachable` stuck
  cause + economy attribution (T49.6-T49.9); Wave C `download` assertion
  (gates T43.1), importer lowering (gates T40.2/T41.1), standing monitors,
  and the released-binary dogfood (T49.10-T49.13).
- Use Case Summary: UC-066 (capability predicates via pinned replay), UC-067
  (self-authoring/repairing pins + capability monitors) added. Risk rows
  R-E49-1..4.

### 2026-07-07 -- Change Summary (E48: economy feedback loop + honest budget stops; ADR-0058)
- Grounding: an audit of every `over_budget` run in the live read-model (54
  finished runs, 5 over_budget) found all 3 diagnosable real cases were
  mislabeled ERROR-WEDGES -- a live predicate stuck in `:error` (e.g.
  `missing_url`) spinning no-op ticks to `max_iterations` in under a minute --
  because `error_stuck?` only sees `code_history` (live ids dropped), there is
  no error permanence taxonomy, and the terminal label prescribes the wrong fix.
  Budgets are hand-authored round numbers with no data feedback (run-end
  economics never persisted); a `max_tokens` ceiling is silently unbounded when
  the harness reports no usage (claw reports none).
- ADR-0058 written (Accepted, extends ADR-0046/ADR-0041, refines ADR-0002):
  persist run-end economics locally (honest-unknown NULLs, no telemetry);
  learned `[budget]` proposals from history percentiles with provenance;
  behavior-first prompt improvement (tools-counter rediscovery candidates;
  opt-in debrief stored as hypotheses only -- never direct prompt mutation, a
  T32.5-class gaming surface; E19/T34.7 benchmark rig as the only shipping
  gate); budget honesty (load-time live-config validation, permanent/transient
  error taxonomy, live-predicate persistent-error detection, terminal cause
  classes, no-usage warning, `max_dispatches`).
- E48 added (13 tasks, plans/E48.md; UC-063/UC-064/UC-065): Wave A honesty
  spine + persistence (T48.1/2/5/6/7/11), Wave B detection + queries
  (T48.3/8/10), Wave C proposals + labels + benchmark gate (T48.4/9/12),
  Wave D live proof on the released binary (T48.13).
- Use Case Summary: UC-063 (data-grounded budgets), UC-064 (honest budget
  stops), UC-065 (measured prompt improvement) added.

### 2026-07-03 -- Change Summary (E46: fleet observability -- run registry, per-run sinks, `kazi dashboard`; ADR-0057)
- Operator problem: several concurrent sessions each drive a `kazi apply` and the
  fleet is a black box -- the LiveView surface is per-BEAM-node, one-shot CLI runs
  have no surface, the inner-harness transcript is discarded, and a dead run is
  indistinguishable from a converged one. Grounding: the shared read-model already
  holds per-iteration predicate vectors + ADR-0046 counters machine-wide; the
  stuck/flake/regression detectors already compute the attention signals; the
  LiveView assets exist. The missing pieces are a run REGISTRY, persisted
  TRANSCRIPTS, and a fleet-mode surface -- not new instrumentation.
- ADR-0057 written (Accepted): read-only fleet projection (ADR-0011 reaffirmed);
  a `runs` registry with heartbeats in the shared read-model (liveness =
  staleness, no IPC); per-run append-only JSONL sinks -- `events.jsonl` +
  `transcript.jsonl` teed through redaction, retention-capped (the sink kills the
  black box; the dashboard is one consumer); a `kazi dashboard` verb in standalone
  fleet mode, localhost-bound; home view is the operator-chosen STARMAP (goal DAG
  in `--explain` wave bands, ADR-0055 landed as a node state, attention queue),
  drill-in is the convergence heatmap (predicates x iterations) + iteration
  scrubber + transcript peek with tool-call folding. NATS fan-in stays Slice 3
  (this dashboard is its first real consumer); external OTel/Grafana rejected as
  the primary surface (domain-specific viz; sinks stay open JSONL).
- E46 added (10 tasks, plans/E46.md; UC-061/UC-062): Wave A data spine
  (T46.1 registry -> T46.2 event sink / T46.3 transcript sink), Wave B surface
  (T46.4 verb -> T46.5 starmap / T46.7 heatmap / T46.8 peek; T46.6 attention
  queue), Wave C docs overview + a >=3-concurrent-runs live browser dogfood
  (T46.10). T20.8 marked SUPERSEDED in plans/E20.md (its shared-instance
  assumption is obsolete; the live proof folds into T46.10).

### 2026-07-03 -- Change Summary (E45: one system -- kazi subsumes the plan/apply orchestration skills; ADR-0056)
- Operator directive: before kazi there was one plan/apply orchestration-skill pair;
  now there are TWO parallel systems maintaining copies of the same facts (`acc:`
  lines vs predicates, hand-authored Waves vs the `needs`-DAG schedule, checkpoint
  files vs the read-model, the pool vs the native scheduler). Requirement: ONE way of
  doing things, one set of tools to maintain.
- ADR-0056 written (Accepted): `kazi plan --project` authors a roadmap as a goal DAG
  (ADR-0028 lifted one level); rolling-wave is native -- an outline phase is a goal
  whose `plan_expanded` predicate converges when the phase's goal-set exists, floor-
  passed, approved, so planning itself converges and a standing roadmap apply
  schedules the next planning pass; `kazi plan render` makes the plan document a
  generated VIEW (output, never input); `kazi plan --discover` unifies the on-ramp;
  the ADR-0035 escalation ladder becomes `[escalation]` goal-file DATA (supersedes
  decision 1's ladder location; no-policy-in-core retained -- README row amended);
  non-engineering explicitly OUT; retirement gated on a zero-skill
  idea->landed->live dogfood (extends ADR-0031; ADR-0026 historical on proof).
- E45 added (10 tasks, plans/E45.md; UC-059/UC-060): Wave A roadmap core
  (T45.1-T45.5), Wave B discovery + escalation (T45.6-T45.7, independent), Wave C
  retirement (T45.8-T45.10) deliberately coarse per the rolling-wave discipline and
  gated on Wave A + the E44 landing dogfood (T44.14); T45.9 migrates kazi's OWN WBS
  to a roadmap (pre-migration plan archived verbatim as the escape hatch); T45.10 is
  the exit proof that flips ADR-0026/0031 status notes ONLY on a passing run.

### 2026-07-03 -- Change Summary (E44: landing is part of convergence; ADR-0055)
- Operator-reported regression vs the external plan->apply orchestration: parallel
  `kazi apply` runs finish and NOTHING commits -- N dirty worktrees to reconcile by
  hand. Root-caused structurally: `Kazi.Loop.decide/2` reaches `:converged` (clause 1)
  before `:integrate` (clause 3) whenever the goal is all code predicates, so the
  existing branch->commit->push->PR->rebase-merge action only fires when a LIVE
  predicate keeps the vector unsatisfied. Compounding: Integrate bulk-commits
  (`git add -A` + one monolith) and the dispatch prompt carries zero process
  discipline.
- ADR-0055 written (Accepted): `[integration]` block enforced as an implicit `landed`
  predicate (T0.8 guard untouched -- landing joins the objective bar); Integrate
  verifies-then-ships; a versioned controller-owned process-contract prompt section
  (the explicit decision: goal-files stay declarative -- kazi plan does NOT embed the
  orchestrator's ~15 prose discipline blocks; each routes to predicate / prompt
  contract / controller behavior); per-group branch-PR landing in `needs` order under
  `--parallel` with `git cherry` verification; first-class `no_stubs`/`oss_hygiene`/
  `docs_updated` gate providers; an apply preflight. Also the missing half of
  ADR-0031's subsumption claim.
- E44 added (14 tasks, plans/E44.md; UC-057/UC-058): Wave A core chain T44.1->T44.3 +
  process contract T44.4 + permission alignment T44.5 (builds on #776/#769); Wave B
  gate providers + preflight (independent); Wave C parallel landing; Wave D authoring
  floor + self-teaching docs (incl. the Tier-0 explicit `landed` custom_script pattern
  for older binaries) + a live dogfood. Interim mitigation usable today: an explicit
  `landed` predicate in any goal-set drives the inner agent to commit via failing-
  predicate evidence.

### 2026-06-28 -- Change Summary (E39 added: resolve the T15.9 orchestrator-driving friction; ADR-0049)
- Operator directive (/plan "to resolve the friction"): the T15.9 nested-loop dogfood
  (orchestrator -> kazi -> a local model via opencode) drove the full `plan -> approve
  -> apply` spine over `--json` and the inner loop worked, but surfaced four points
  where kazi is awkward to drive as a tool. Captured them as a new epic instead of
  letting the findings die in the devlog.
- **New epic E39 (P1, ADR-0049):** close the spine over `--json` end to end.
  - T39.1 `plan --json --predicates` honors caller `goal_id`/`idea` (today it mints a
    generic id).
  - T39.2 `apply <proposal-ref>` runs an APPROVED proposal directly -- the key fix for
    the broken approve -> apply handoff (approve never wrote a goal-file, apply required
    one, forcing orchestrator-side reconstruction).
  - T39.3 `approve <ref> --write <path>` materializes the goal-file for file-based flows.
  - T39.4 `--json` stdout is the single JSON object on every entrypoint (dev `mix run`
    co-mingles logs into stdout; the released binary is already clean).
  - T39.5 authoring on the escript: degrade (ephemeral store) or guide clearly (it
    hard-fails today because an escript cannot bundle the SQLite NIF).
  - T39.6 LIVE regression dogfood: re-drive the loop over CLEAN `--json` with the fixes.
- **ADR created:** docs/adr/0049-approve-to-apply-handoff.md -- accept `apply
  <proposal-ref>` + `approve --write` to close the handoff; honor caller goal_id/idea;
  guarantee `--json` stdout purity; guide/degrade escript authoring.
- Friction source recorded in docs/devlog.md (2026-06-28, T15.9). New risk row R-E39-1.

### 2026-06-25 -- Change Summary (E38 second pass: skills-coverage review -> folded sub-beats + 2 tasks; ADR-0048 revised)
- Operator directive (/plan, second pass): review ALL of the operator's global skills to
  find gaps the E38 plan/ADR missed. Read 39 SKILL.md files via two parallel reviewers
  (engineering-workflow + creative/marketing/meta), built a skill->post coverage matrix,
  triaged with judgment (did NOT absorb every suggestion).
- **Folded the genuinely-missing RUNGS in as SUB-BEATS (count stays twelve):** knowledge
  maintenance (lint/tidy/audit-docs -> post 3, reinforces kazi's own E31 self-maintaining
  docs); safe refactoring + research-as-graph (refactor/ingest/graphify -> post 5);
  adversarial/security review (deep-review/red-team -> post 8); resilience/recovery
  (preflight/resume) + crew-vs-pool (-> post 9); reconciliation-applies-to-work-progress
  (-> post 10); code->prod + deploy triage (-> post 4); harden-your-harness (audit-setup
  -> post 12).
- **Added two bounded SUPPORTING tasks:** T38.20 visual assets (the reconcile-loop /
  ladder / before-after diagrams + per-post header art -- diagrams in the site palette,
  NOT ad creative; reuse existing assets first) and T38.21 instrumentation (ONE named
  adoption signal + privacy-respecting static-site analytics + a UTM scheme + the
  canonical-syndication rule, per ADR-0030's "measure adoption not stars"). Strengthened
  T38.18 (code examples must RUN; model-ids checked; the no-leak/no-required-private-tool
  assertion) and T38.5 (the private-stack + harness-agnostic framing rules) and T38.19
  (canonical syndication to avoid duplicate-content).
- **Two gaps the reviewers under-stated, now in ADR-0048:** (dec. 5) SEPARATE the
  technique from the author's PRIVATE stack -- lead with the commodity technique, name a
  personal/internal tool only as "what I used" with an alternative, never require it or
  leak internal infra (ADR-0034); (dec. 7/8) show the loop with diagrams + instrument one
  honest signal.
- **Deliberately EXCLUDED, recorded in ADR-0048** so a pool session cannot re-add them: a
  hierarchical agent-org post, email/lifecycle drip funnels, a separate team charter
  (each off-thesis or anti-hype or backend-requiring on a static site).
- Risks R-E38-6 (private-stack reproducibility/leak) + R-E38-7 (scope creep) added. E38
  is now 21 tasks (4 infra + 1 style sheet + 12 posts + gate + announcement + visuals +
  instrumentation). Authored in an isolated worktree off origin/main (lore L-0014).

### 2026-06-25 -- Change Summary (E38: adoption blog series "From Vibe Coding to Reconciliation"; ADR-0048)
- Operator directive (/plan): plan a TWELVE-part blog series for the kazi website that
  walks a reader from a vanilla coding-agent user ("vibe coder") to a super-user who
  reaches for kazi, to drive ADOPTION by building CREDIBILITY for kazi's ideas. Explicit
  caution: the plan + ADR are PUBLIC docs shipped with kazi -- wrong framing would turn
  off engineers.
- Discovery: reconstructed the author's actual ladder from the global skills directory
  (memory -> knowledge tiers -> browser verification -> code graph/context economy ->
  skills -> plan -> definition-of-done -> pool/claim parallelism -> reconciliation/kazi);
  mapped the Astro site (`site/`, GitHub Pages, kazi.sire.run, no blog section yet,
  canonical strings in `site/src/canonical.mjs`); grounded the framing against ADR-0030
  (agent-native positioning) + `docs/concept.md` (the two gaps).
- **Created ADR-0048** (adoption blog series -- editorial stance): fellow-traveler tone
  (never talk down to "vibe coders"); every post independently useful; credibility over
  hype; NO vaporware (coherence/freshness-gated); the product EMERGES (kazi named late);
  one story / reused E25 assets / two surfaces. Builds on ADR-0025/0030.
- **Added E38** (P1, ADR-0048, UC-051): T38.1-T38.4 blog infrastructure on the Astro
  site (content collection + schema, index/series/post routes, RSS/nav + a verb-drift
  guard extending E29 over `site/src/content/blog/**`); T38.5 committed editorial style
  sheet; T38.6-T38.17 the twelve posts (one per rung, each ending on the limitation that
  motivates the next); T38.18 the single no-vaporware accuracy+coherence+quality gate;
  T38.19 announcement/cross-post kit coordinated with the E25 launch. Waves E38-1..3;
  risks R-E38-1..5.
- Non-overlap recorded: E38 is the LONG-FORM companion to E25's one-screen surfaces
  (README/site) -- it reuses the hero transcript (T25.2) + without/with frame + dogfood
  gallery (T25.7), does not re-create them, and T38.19 coordinates with (not duplicates)
  the E25 T25.10 launch gate.
- Authored in an isolated git worktree off origin/main (`plan/e38-blog-series`) per the
  shared-tree reset hazard (lore L-0014); local main was 30 commits behind, so numbers
  (E38/ADR-0048/UC-051) were taken from origin/main, not the stale local checkout.

### 2026-06-25 -- Change Summary (LIVE dogfood frontier UNBLOCKED for the headless pool -- enablers proven)
- The remaining open frontier is the LIVE dogfood / launch chain. A headless pool
  session VERIFIED the enablers are now present and proven, so most of these are no
  longer operator-only -- other sessions should claim them.
- **Enablers (verified 2026-06-25):** the `claude` CLI harness is installed and
  drives the loop; the RELEASED binary `kazi v1.45.0` (sha-verified) runs every
  read-model + `apply` command; `agent-browser` is available for the LiveView
  dashboards and the LiveView feature itself is built (`lib/kazi_web/live/*`,
  deps T20.6/T21.1 done). The build frontier is drained, so the feature-complete
  dogfood-policy gate is SATISFIED.
- **PROOF (a real reconcile, not a mock):** a minimal create-mode goal (a
  `custom_script` predicate asserting `hello.txt` contents == `ok`, failing at t0)
  driven by `kazi apply --harness claude --json` on v1.45.0 converged in 2
  iterations / 15.3s -- iter1 FAIL -> claude created the file -> iter2 PASS ->
  `status: converged`, enforcement active, zero gaming events.
- **Now headless-poolable** (goal-file-driven reconcile + browser): T20.11, T21.12,
  T23.9, T30.4, T31.7, T32.11, T35.10 (drive kazi on a goal-file, record evidence in
  `docs/devlog.md`); T20.8, T21.9 (LiveView dashboards via agent-browser); the
  live-site leg of T25.10. T15.9 too, modulo the secondary cheap-harness it names.
- **STILL blocked (with reason):** **T26.8** -- `kazi plan "<idea>"` prose drafting
  STILL fails live on v1.45.0 (`--json` asks for clarification; `--yes` returns
  "proposal has no predicates"). PR #623's robust-to-multiple-shapes parse did NOT
  match what real claude emits; the real fix needs a captured raw claude draft (see
  the T26.8 LIVE FINDING note in plans/E26.md). This also blocks **T16.6** / **T26.6**
  (both drive the prose plan->approve->apply path). **T25.2** (asciinema hero cast)
  needs a terminal recorder not installed here.
- Net: the operator-only assumption on the dogfoods was too conservative. The
  goal-file dogfoods + dashboard tasks are claimable headlessly TODAY; the prose
  on-ramp (`kazi plan`) is the one genuinely-still-broken surface -- fix T26.8
  against a captured real-claude draft before claiming T16.6/T26.6.

### 2026-06-25 -- Change Summary (docs/website consolidation + human->Claude->kazi->Claude reframe)
- Operator directive: collapse the sprawling, multi-generation doc/website tasks into
  fewer canonical tasks (stop drafting successive generations of the same document), and
  reframe every doc/site surface around the **human -> Claude -> kazi -> Claude** story --
  you direct Claude Code; Claude drives kazi; kazi reconciles to objective-done; Claude
  reports back. The legacy "a human runs the kazi CLI" framing is demoted to a
  Reference/Advanced note; the raw CLI is positioned as what the AGENT invokes.
- Consolidation (full): RETIRED epic E22 (former T22.1-T22.9) and folded the docs/positioning
  parts of E17, E20 (T20.10), E21 (T21.11), E30 (T30.5), E31 (T31.8) into the single canonical
  docs+content epic E25. ~13 pending tasks removed; E25's 6 remaining pending slots repurposed:
  * T25.3 = ONE canonical README rewrite to the spine + full capability coverage (absorbs T22.1 coverage-map, T22.2 coverage-pass, T21.11 native-parallelism positioning).
  * T25.4 = ONE canonical website rewrite + OG card (absorbs T22.5, the former T25.9 OG/launch-kit).
  * T25.9 = ONE docs/guide + concept.md alignment pass (absorbs T22.3 concept, T22.4 guide-set, T22.6 presentation decision, T20.10 pool guide, T31.8 self-maintaining-docs positioning).
  * T25.10 = ONE accuracy/coherence/publish + announcement gate (absorbs T22.7 audit, T22.8 publish, T22.9 announcement, T30.5 tiering-id gate); leans on the automated E31 doc-freshness predicates + E29 CI guard.
  * T25.2 (hero transcript) and T25.7 (dogfood "done" gallery) unchanged (distinct assets, not duplicates).
- No dependency breakage: no task outside E22 depended on T22.x; T21.12's deps are [T21.5,T21.8] (not T21.11); nothing depended on T20.10/T30.5/T31.8. Waves E20-docs/E21-4/E22/E25-2/E25-3/E30/E31 notes updated; R-E25-3 marked RESOLVED. Per operator: rationale recorded here, no new ADR (consistent with ADR-0025/0030).

### 2026-06-25 -- Change Summary (capture pending work for next sessions: site command-accuracy gate + confirmed-live verb-drift bugs)
- Context: a `/loop /apply --pool` session shipped E25 content (T25.1/T25.5/T25.6 -> PR #454, T25.8 -> PR #459, both deployed + live-verified) and, while verifying live, found TWO stale-command bugs on https://kazi.sire.run that no CI gate catches. Recording them so the next session does not rediscover them.
- **Added T29.4** (E29, OSS gates): a CI guard that scans `site/` source incl. `.svg` for DEPRECATED/removed kazi verbs (`kazi run`/`kazi propose`/the old `propose`->`approve` flow). This is the MISSING guard -- T9.9 only diffs canonical strings, T16.4 only scans SKILL.md/AGENTS.md, so site verb-drift shipped live unguarded. Ships warn-first, ratchets to blocking after the site is cleaned. deps: [].
- **Annotated T27.6** (verb rename across site): flagged READY NOW (dep T27.4 is done) and as the DIRECT fix for the confirmed-live `kazi propose`->`approve` Install-section bug (`site/src/pages/index.astro` step 2); acc extended to require the T29.4 guard pass.
- **Annotated T25.2** (hero proof asset): flagged that the current `proof-loop.svg` shows the removed `kazi run my-goal.toml` live; replacing the asset remedies it; acc extended.
- No ADR (no new architectural decision -- T29.4 extends the existing E29/ADR-0034 gate family). Knowledge also routed to docs/devlog.md.

### 2026-06-24 -- Change Summary (E33-E36: context-economy + harness-productivity; ADR-0044/0045/0046/0047)
- Source: a brainstorm over three external proposals (`tmp/kazi-context-architecture-proposal.md`,
  `tmp/gist-kazi-enhancement-addendum.md`, `tmp/context-economy-harness-productivity-proposal.md`)
  plus what `sirerun/gist` can offer. Grounded against the live tree before planning.
- Most of the proposals' advice was ALREADY decided/shipped (map-vs-conversation memory =
  ADR-0008/0010; model tiering = ADR-0033/0035; docs drift = E28/E31) -- not relitigated.
- Four NET-NEW decisions written as ADRs (Proposed): **0044** `kazi mcp` installed verb
  (the server exists only as `mix kazi.mcp` today); **0045** a `context_store` layer with
  Gist as first provider (evidence compression + stuck-bundle replay, opt-in until measured);
  **0046** an economy accounting envelope (cached-vs-fresh tokens, cost/converged-predicate);
  **0047** inner-harness minimalism (tool-surface restriction now; context tiers gated on the
  E19 benchmark).
- Four epics added: **E33** (ADR-0044, small/independent/unblocked), **E34** (ADR-0046,
  foundational; subsumes/unblocks T19.5), **E35** (ADR-0045, phased, depends on E34 to report
  savings), **E36** (ADR-0047, tool-flags now + benchmark-gated tiers). Recommended order:
  E33 ∥ E34 -> E35 ; E36 tool-surface alongside, tiers after the benchmark.
- Deferred as an evaluation note (no ADR): Serena / ast-grep / Semgrep / Repomix.

### 2026-06-25 -- Change Summary (E31<->E32 alignment: build doc-freshness on the new predicate paradigm)
- A sibling process landed E32 (Predicate catalog & evidence v2, ADR-0040/0041/0042/
  0043: the `custom_script` generic provider, envelope-v2 score/evidence + ratchet,
  anti-gaming enforcement) -- PR #423 merged, verified on main; it renumbered cleanly
  off my E31/ADR-0036 (no collision; my work intact).
- Reassessment: E31's design is UNCHANGED in shape -- it is improved, not threatened.
  T31.4 (already done) ships the freshness checks as shell-script CLI checkers, which
  are exactly the `custom_script` substrate (paradigm-neutral, no rework). The single
  alignment point is T31.6.
- **Amended T31.6** (the only change): the standing goal now authors the freshness
  predicates as `custom_script` (ADR-0040/T32.1) WRAPPING the T31.4 scripts -- not a
  bespoke engine -- with a doc-coverage `ratchet` (ADR-0041/T32.2-3) and CI-side
  anti-gaming (ADR-0042/T32.4). deps += [T32.1, T32.2]; Wave E31 updated. This also
  lets ADR-0036 honor its own "no doc engine in core" principle (custom_script makes
  the freshness checks pure config).

### 2026-06-24 -- Change Summary (E31: self-maintaining docs as a kazi standing goal; ADR-0036)
- Operator directive (via /plan discussion): plan.md is kazi's goal.toml; it bloats
  (1,142 lines, monolithic) and docs go stale; the existing trim (/plan step-0,
  /tidy) is "not working very well." Chosen direction: FULL 3-layer design driven by
  a kazi STANDING goal, dogfooded via kazi.
- **Added ADR-0036**: doc lifecycle as a kazi-reconciled standing goal -- (L1)
  deterministic lossless trim of done+released epics to an append-only archive; (L2)
  gated knowledge extraction to the tier docs; (L3) doc-freshness predicates in CI.
  kazi DRIVES; logic stays in the skill+CI layer (no doc engine in core). Fixes the
  kazi tier map (architecture -> concept.md, NOT design.md).
- **Added E31** (P1, ADR-0036): T31.1 split-plan migration, T31.2 deterministic trim
  tool, T31.3 gated extraction, T31.4 freshness predicates, T31.5 freshness CI gate,
  T31.6 standing goal, T31.7 live dogfood on this repo, T31.8 docs/positioning.
  Wave E31; UC-046; risks R-E31-1..4. T31.1/T31.4 unblocked now.
### 2026-06-24 -- Change Summary (E32: predicate catalog & evidence v2 -- the verification workhorse; ADR-0040/0041/0042/0043)
- Operator directive: review the state of the predicate checkers (unit tests, browser
  check, endpoint returns) and brainstorm how to expand them so kazi becomes a real
  software-development workhorse; deep-research the subject.
- Mapped the current state (4 providers: `test_runner`/`http_probe`/`prod_log`/`browser`;
  `surface-coverage` meta-predicate; `:coverage`/`:custom_script` named-but-unbuilt) and
  ran 3 deep-research streams (verification beyond unit tests, live/prod verification,
  agentic anti-gaming). FINDING: the framework is excellent; the catalog is thin, the
  evidence is raw, and the anti-gaming story (kazi's whole thesis) is declarative, not
  enforced. The biggest wins are FRAMEWORK changes that improve every checker, not a
  longer list.
- **Added `docs/research/predicate-verification-landscape.md`** -- the cited synthesis
  (primary sources flagged; secondary/vendor claims marked) as ADR input.
- **Added ADR-0040** (generic `custom_script` protocol -- the extensibility keystone;
  explicit verdict defuses the exit-code gotchas), **ADR-0041** (predicate envelope v2:
  graded `{pass, score, prior_score, evidence[]}` + SARIF/JUnit/LSP evidence + a
  first-class `ratchet` mode; `:converged` gate unchanged), **ADR-0042** (anti-gaming
  ENFORCEMENT: clean-tree checker, read-only predicate/test leasing, skipped-as-failed,
  count/coverage ratchets, diff-inspection guard, optional held-out acceptance subset;
  grounded in METR's 43x "sees the scoring function" result), **ADR-0043** (catalog
  expansion: which checkers ship first-class -- `:static`/`:coverage`/`:property`/
  `:mutation` + live upgrades -- vs `custom_script` config). All four are **Proposed**
  (awaiting operator ratification), not Accepted.
- **Added E32** (P1): T32.1-T32.3 (framework: generic protocol, envelope v2, ratchet),
  T32.4-T32.6 (anti-gaming enforcement + diff guard + held-out), T32.7-T32.10 (concrete
  providers + recipes + live upgrades), T32.11 (live dogfood). Waves E32-1..4; UC-047..
  UC-050; risks R-E32-1..6. Build the framework first, then the providers that prove it.
- Written in a worktree (`plan/e31-predicate-catalog`) per the shared-tree reset hazard
  (lore L-0014). Precondition flagged in T32.4/R-E32-4: the "checker outside the agent's
  reach" seam must be verified against `loop.ex` before implementing, not assumed.
- **RATIFIED (operator, 2026-06-24): ADR-0040/0041/0042/0043 -> Accepted.** Four
  decisions folded in: (1) `custom_script` is the SINGLE command-runner -- `test_runner`/
  `prod_log` fold in as deprecated presets (non-breaking now, removed in v2.0.0; added
  T32.1b + R-E32-7); (2) anti-gaming enforcement is DEFAULT-ON for creation-mode goals,
  opt-in for repair; (3) the "checker outside the agent's reach" isolation level is
  CLEAN-TREE + SEPARATE-PROCESS (full container deferred); (4) the CVE/security provider
  is promoted to a FIRST-CLASS `:cve` (govulncheck reachability) -- five first-class
  code-side providers now. Defaulted (no objection): a `direction` field on the score
  (ADR-0041), the schema bump is additive/non-breaking, and `:static` ships the polyglot
  SARIF path alongside Dialyzer in one provider.

### 2026-06-24 -- Change Summary (T25.12: close all-stars.md growth-playbook gap #10)
- Audited the `tmp/all-stars.md` growth research (docs/site playbook vs fast-growing
  OSS AI tools) against current surfaces. FINDING: 6 of 10 gaps already SHIPPED
  (version badge, social-proof badges, who-it's-for, why-now, before/after, OG image),
  2 PARTIAL (screencast/site-hero -> E25 T25.2/T25.4), 1 PLANNED (README restructure ->
  T25.3). The research was NOT formally ingested (it is an untracked tmp scratch file)
  but was clearly USED -- its specific suggestions match shipped surfaces (the README
  "Why now?" text is near-verbatim). The companion deep research IS ingested
  (devlog 2026-06-24 -> ADR-0030/E25).
- **Added T25.12** (the only unaddressed gap, #10): Community + getting-help links --
  enable GitHub Discussions (Issues fallback), add a README footer Discussions/concept
  pointer + a site Docs/Community nav + footer help link; coherence (T9.9) green;
  Playwright smoke (T9.5) covers the new nav; deployed + verified live. Wave E25-5;
  verifies UC-039/UC-035; unblocked now.

### 2026-06-24 -- Change Summary (E30: adaptive in-family model tiering, skill-driven; ADR-0035)
- Operator directive: "use kazi to optimize token economy (Opus for plan, Haiku/Sonnet
  for keystrokes), in code or via the kazi skill; brainstorm + discuss; if it derails
  kazi, discard." FINDING: the idea is already kazi's accepted default cost story
  (ADR-0033, with the `claude --model` enabler T19.6 DONE), and the only derailing
  variant (auto-tiering inside kazi) was already rejected. Operator decided (via
  /plan discussion): SKILL-ONLY policy + escalation-on-stuck as the headline feature.
- **Added ADR-0035** (refines ADR-0023/0033): adaptive in-family tiering is a SKILL
  recipe (default frontier-author -> cheap-grind; escalate Haiku->Sonnet->Opus, capped,
  on a kazi-reported stuck signal); kazi exposes `--model` + reports state only;
  auto-tiering in core rejected.
- **Added E30** (P1, ADR-0035): T30.1 (skill+AGENTS.md default to in-family tiering),
  T30.2 (escalate-on-stuck recipe), T30.3 (verify `--json` signal sufficiency; at most
  a read-only enrichment, no core policy), T30.4 (live escalation dogfood), T30.5
  (accuracy+coherence gate). Wave E30; UC-045; risks R-E30-1/2.
- **Extended** T19.7 (benchmark now has 3 arms: vanilla-frontier / static-cheap /
  escalating; reports $/tokens AND convergence/correctness) and T25.11 (content
  references the escalation recipe). No new kazi-core scope; skill-layer feature.

### 2026-06-24 -- Change Summary (v0.5.0/alias-removal collision: reconciled; added the removal task)
- Investigated the flagged collision (deprecation note said run/propose removed in
  v0.5.0, but release-please PR #228 IS v0.5.0 with aliases present). FINDING: already
  reconciled by a sibling -- `docs/deprecations.md`, `cli.ex` (the hint), and the
  `mix kazi.run` task all say removal in **v0.6.0**; the rename ships in v0.5.0 with
  aliases. No contradiction remains, so **PR #228 (release 0.5.0) is safe to merge**.
- The only OPEN gap was that no task actually REMOVES the aliases. Added **T27.9**:
  remove the run/propose CLI verbs + `mix kazi.run` + hints + alias tests in the
  **v0.6.0 cycle ONLY** (a breaking change; must not land before v0.5.0 ships, so the
  deprecation window is real). deps T27.8.
- No new ADR/UC (ADR-0032 already says "a later minor"; v0.6.0 honors it). Worktree
  (lore L-0014).

### 2026-06-24 -- Change Summary (T9.10: stale site version badge -- deploy-trigger gap)
- Diagnosed the operator's "version badge stale" report. The README release badge is
  the DYNAMIC shields `github/v/release` endpoint -- correct (resolves to v0.4.0), not
  hardcoded. The LIVE SITE badge is the stale one (shows v0.3.0 vs manifest/latest
  v0.4.0). Root cause: the site bakes the version from `.release-please-manifest.json`
  at BUILD time, but `pages.yml` only triggers on `site/**` pushes, so a release-please
  manifest bump never redeploys the site.
- Added **T9.10** (E9, P2): add `.release-please-manifest.json` (and/or a
  `release: [published]` trigger) to `pages.yml` so a release redeploys the site.
  Small, unblocked infra fix; flagged for prompt pickup since the public site is
  currently wrong. README badge untouched (already dynamic). Worktree (lore L-0014).

### 2026-06-24 -- Change Summary (ADR-0034 + E29: OSS contribution gates; CLAUDE.md + apply-skill enforcement)
- **Created ADR-0034** (OSS contribution gates): (1) docs land with the code in the
  same change; (2) no internal-info leakage in the public repo. Motivated by the
  ~10-ADR doc lag (E28) and ~48 internal-leak hits found in `docs/`+README.
- **Enforced at three layers:** added both rules to the local `CLAUDE.md` (this repo)
  AND the operator's global `CLAUDE.md`; added a docs-land check + a no-leak diff scan
  to the `/apply` skill's verification gate (global skill).
- **Added E29** (P1, ADR-0034, UC-044): T29.1 docs-with-code CI guard, T29.2
  no-internal-leak CI guard (IPs/hosts/codenames/personal paths, with an allow-list),
  T29.3 one-time scrub of the existing leaks (keep the honest finding, drop the
  specifics). Wave E29 (autonomous; safe early). UC-044.
- **Also filed** ultraworkers/claw-code#3262 (request structured/JSON output so kazi's
  `claw` profile can parse cost/result) -- enables a future fully-conformant `claw`.
- No trim (concurrent /apply --pool edits). Authored in an isolated git worktree
  (lore L-0014). ADR: `docs/adr/0034-oss-contribution-gates-docs-with-code-no-leak.md`.

### 2026-06-24 -- Change Summary (ADR-0033: cheaper via in-family Claude tiering, no local model)
- **Created ADR-0033.** Operator insight: the "cheaper" story assumed a LOCAL model
  (Qwen on a local GPU host), which almost no engineer has (and the 35B was too slow, T8.11). The same
  two-tier economics work IN-FAMILY: a frontier Claude model (Opus) authors predicates
  once -> kazi drives the grind on a CHEAP Claude model (Haiku/Sonnet) -> predicates
  keep it honest. Token economy for any Claude Code user, no local GPU host. Refines ADR-0023/0030;
  local/BYOM demoted to the privacy add-on.
- **Enabler gap found:** the `claude` harness profile omits `:model` from its
  `supported_opts`, so `--harness claude --model <cheap>` can't select a cheaper Claude
  model today. Added **T19.6** to fix it.
- **Added tasks:** T19.6 (`claude --model` passthrough, unblocked now), T19.7 (the
  in-family Claude-tiering COST benchmark -- frontier-authors -> cheap-Claude-grinds vs
  vanilla-frontier; report $/tokens AND convergence/correctness), T25.11 ("token economy
  without local models" content; cost stays "being measured" until T19.7). Waves E19-3,
  E25-4. UC-043.
- **Harness inventory (answered):** 5 supported -- claude (default), opencode, codex,
  antigravity, claw -- all config-driven profiles (ADR-0016); `--harness`/`--model` per
  call.
- No trim (concurrent /apply --pool edits). Authored in an isolated git worktree
  (lore L-0014). ADR: `docs/adr/0033-cheaper-via-in-family-claude-tiering.md` (+ index).

### 2026-06-24 -- Change Summary (operator decisions bake out the human-gated content tasks)
- The operator made the four decisions that were blocking the content work; baked
  into the tasks so the apply pool can now execute them autonomously:
  - **T25.1 tagline DECIDED:** `Your coding agent says "done." kazi proves it.`
    (precise category = the second beat). Pool wires it into canonical.mjs + README.
  - **T25.6 invocation phrase DECIDED:** "have kazi drive this until done"
    (Context7 pattern); document + wire across README/site/skill/AGENTS.md.
  - **T25.2 hero asset DECIDED:** record a REAL asciinema cast (no static fallback);
    needs a live run (operator / live-capable session, not the headless pool).
  - **T27.7 alias removal DECIDED:** `run`/`propose`/`mix kazi.run` removed in
    **v0.6.0** (next minor); the deprecation hint names v0.6.0.
- No new tasks/UCs; four existing tasks converted from human-gated to executable.
  Authored in an isolated git worktree (lore L-0014).

### 2026-06-24 -- Change Summary (E28: doc-sync to current reality; diagnose blocked doc work)
- **Diagnosed why doc work is blocked:** E22 is gated on whole feature epics
  (T22.1 deps E15-E21); E25's open tasks need human/creative input (tagline, hero
  recording, agent-voiced testimonial); E27's doc tasks chain behind the CLI code;
  E17 is chained AND superseded by E25. No unblocked, AUTONOMOUS task kept the design
  docs honest -- `docs/concept.md` stops at ADR-0023, README how-it-works at 0022
  (~10 ADRs behind: missing the scheduler, waves, agent-driven/router, verb rename).
- **Added E28** (P1, no ADR -- executes existing decisions): autonomous doc-sync.
  T28.1 concept.md native scheduler (ADR-0027), T28.2 concept.md predicate-graph
  waves + agent-driven/router model (ADR-0028/0024/0031, Telegram absent per 0029),
  T28.3 README how-it-works + ADR-index current through 0032 + new verbs (deps T27.6),
  T28.4 accuracy + coherence gate. Wave E28; UC-042. T28.1/T28.2 are unblocked NOW --
  the pure-doc work the pool was missing.
- **NON-OVERLAP recorded:** E28 = ongoing engineering-accuracy sync (now); E22 =
  final launch polish (gated); E25 = marketing content; T27.6 = verb-string rename.
- **Cleaned up E17:** annotated its open content tasks (T17.1/2/4/5) as SUPERSEDED by
  E25 (ADR-0030) + E28 -- the apply pool should SKIP them (removes the chained/dup
  doc work that was clogging the queue).
- **UC-042** added. No new ADR. Authored in an isolated git worktree (lore L-0014);
  no trim (concurrent /apply --pool edits).

### 2026-06-24 -- Change Summary (E27: rename CLI verbs run->apply, propose->plan, P1 + ADR-0032)
- **Created ADR-0032** (rename the CLI verbs): `kazi run` -> `kazi apply`,
  `kazi propose` -> `kazi plan` (+ `mix kazi.run` -> `mix kazi.apply`), so the verb is
  the same at the agent prompt, the skill, and the CLI. SUPERSEDES ADR-0031's
  skill-verb!=CLI-verb map (now 1:1). `run`/`propose` kept as DEPRECATED ALIASES for
  back-compat with the shipped JSON contract + skill/MCP; result-contract
  `schema_version` bumped.
- **Added E27** (P1, ADR-0032, UC-041): T27.1 CLI verbs + aliases, T27.2 `mix
  kazi.apply` (+ alias), T27.3 schema + `schema_version` bump, T27.4 help/schema,
  T27.5 skill/AGENTS.md/MCP, T27.6 README/site/docs, T27.7 deprecation note, T27.8
  live verify. Waves E27-1..3; risks R-E27-1..3 (contract break, missed reference,
  schema pin). Broad, autonomous ENGINEERING work the apply pool can execute.
- **Operator directive (2026-06-24):** unify the human-friendly verbs end to end --
  the reason for the rename beyond ADR-0031's skill-only naming.
- **Work-availability check:** all recent ADRs (0025-0031) HAVE plan epics (E17-E26);
  on main 42 tasks open, 6 immediately claimable. The pool likely stalled because the
  unblocked-but-open tasks are content/docs/live-dogfood (need human input or a live
  env); E27 refills the queue with pure, autonomously-applyable code tasks.
- **UC-041** added; E26 noted to simplify (router verbs now equal CLI verbs 1:1).
  ADR created: `docs/adr/0032-rename-cli-verbs-run-apply-propose-plan.md` (+ index).
  Authored in an isolated git worktree (lore L-0014). No trim (concurrent pool edits).

### 2026-06-24 -- Change Summary (E26: kazi skill becomes a router, P1 + ADR-0031)
- **Created ADR-0031** (kazi skill as a router; `kazi apply` subsumes loop+apply+
  qualify for code goals). Brainstorm with the operator: their `loop -> plan ->
  apply -> tidy -> qualify` pipeline IS a reconcile loop, which kazi now performs
  natively (E21 scheduler + E23 waves + objective predicates + standing mode).
- **Added E26** (P1, ADR-0031, UC-040): restructure the GLOBAL `kazi` skill into a
  router with sub-skills `plan`/`apply`/`status`/`adopt` whose verbs match the
  operator's vocabulary and drive the real CLI commands (propose/run/status/init).
  T26.1 router SKILL.md + verb map, T26.2 `kazi plan` (caller-drafts; feeds from a
  `/plan` doc when present), T26.3 `kazi apply` (CLI `kazi run`; subsumes loop+apply+
  qualify), T26.4 `status`/`adopt`, T26.5 coherence + retire loop/qualify from the
  code on-ramp, T26.6 live router dogfood. Waves E26-1..2; risks R-E26-1..3.
- **Operator naming decision (2026-06-24):** the execute sub-skill is `apply` (not
  `run`) for continuity with their `/apply`; it drives the `kazi run` CLI underneath
  (skill verb != CLI verb, like plan->propose). `kazi run` CLI is NOT renamed.
- **Decisions:** retire `loop`/`qualify` from the CODE on-ramp (fold into `kazi
  apply`); re-seat `/plan` as the intent-authoring layer that EMITS a goal-set (not
  folded); keep `/tidy` as hygiene; scope = code goals only (non-code keeps the
  general skills). Subsumption messaging GATED on the E21/E23 dogfoods (T21.12/T23.9).
- **UC-040** added. ADR created: `docs/adr/0031-kazi-skill-router-subsumes-loop-apply-qualify.md`
  (+ README index). No trim (concurrent /apply --pool edits; plan trimmed 2026-06-23).
  Authored in an isolated git worktree (shared-tree reset hazard, lore L-0014).

### 2026-06-24 -- Change Summary (E25: content-marketing refocus on the agent-drives-kazi paradigm, P1 + ADR-0030)
- **Deep research** (two sourced passes, ~15 fast-growing OSS AI tools + the
  agent-native/MCP tier + HN launch data) into how they won stars; distilled to
  `docs/devlog.md` (2026-06-24 "Content-marketing research") and **ADR-0030**.
  Verdict: kazi's analogs are agent-FACING tools the user does not operate (Serena
  "give your agent X", Context7 "use context7" + before/after) + Astral's proof
  discipline (a falsifiable number + a living leaderboard).
- **Created ADR-0030** (content-marketing + agent-native positioning; refines
  ADR-0025): lead every surface with the agent-drives-kazi paradigm + a human-noun/
  borrowed-frame tagline; hero = a transcript of the loop reaching objective-true;
  without/with before-after; agent-voiced proof + a memorable invocation; ONE
  recurring growth engine (a dogfood "done" leaderboard); HN-first launch kit.
- **Review finding:** the README/site still LEAD with the legacy human -> kazi route
  even though the agent-driving surfaces (skill/`mcp`/`--json`, E16) are shipped;
  E25 fixes the lead to the agent paradigm.
- **Added E25** (P1, ADR-0030, UC-039): T25.1 tagline/noun, T25.2 hero transcript,
  T25.3 README, T25.4 website, T25.5 agent-voiced testimonial, T25.6 invocation
  phrase, T25.7 dogfood "done" leaderboard (the growth engine), T25.8 docs
  quickstart-first, T25.9 launch kit + OG card, T25.10 accuracy gate + live publish.
  Waves E25-1..3; risks R-E25-1..5 (falsifiable-"done", category tax, E17/E22
  overlap, mockup honesty, host dependence).
- **Supersession:** E25 is the canonical content epic; it SUPERSEDES the messaging
  of the still-open E17 content tasks (T17.1/2/4/5) and E22's README/site tasks
  (execute per ADR-0030). Recorded in the E25 wave note + R-E25-3 so concurrent pool
  sessions do not run both.
- **UC-039** added. ADR created: `docs/adr/0030-content-marketing-agent-native-positioning.md`
  (+ README index). No trim (heavy concurrent /apply --pool edits; plan trimmed 2026-06-23).
  Authored in an isolated git worktree after a concurrent session reset the shared
  `main` working tree and wiped an earlier uncommitted draft of this change.

### 2026-06-24 -- Change Summary (E23: dependency-aware partitioning / predicate-graph waves, P2 + ADR-0028)
- **Created ADR-0028** (dependency-aware partitioning, "predicate-graph waves"): the
  fourth axis that lets kazi COMPUTE the operator's `/plan` `deps:` + `/apply` Waves
  instead of hand-authoring them. kazi has objective done (ADR-0002) + spatial
  parallelism (ADR-0006) + the native scheduler (ADR-0027) but NO semantic ordering;
  ADR-0028 adds a dependency DAG over predicate groups (extend the ADR-0020
  `[[group]]` taxonomy with `needs` edges) executed topologically -- blast-radius
  parallelism inside each frontier, objective-convergence gating, pipelined (no
  barrier). Builds on E12 + E21; no new loop. Authored `needs` edges are the
  irreducible semantic input (kazi does not derive precedence).
- **Added E23** (P2, ADR-0028, UC-038): T23.1 `needs` edges + validation, T23.2 DAG
  + ready-set (pure), T23.3 topological+spatial pipelined scheduling, T23.4
  regression re-gating, T23.5 blocked-dep escalation, T23.6 CLI/`--json`/`--explain`,
  T23.7 DAG dashboard, T23.8 docs/positioning, T23.9 live dep-DAG dogfood. Waves
  E23-1..4; risks R-E23-1..4 (authored-deps burden, over-serialization, cycles/stuck,
  E21 dependency).
- **UC-038** added. Rationale: the comparison of kazi to the operator's `/plan` +
  `/apply` waves surfaced that kazi's scheduler is SPATIAL only (no semantic order);
  E23 closes that, turning "kazi hardens my waves" into "kazi IS my waves." E23-1 (the
  pure model) can start ahead of E21; E23-2+ needs the E21 scheduler.
- ADR created: `docs/adr/0028-dependency-aware-partitioning-predicate-graph-waves.md`.

### 2026-06-24 -- Change Summary (E22: pre-publish documentation refresh, P1, gated on E15-E21)
- Added **E22** (P1, content + engineering; ADR-0025/0018, no new ADR): the LAUNCH
  documentation pass. README + `docs/` + website refreshed to the FINAL shipped
  product, ASSUMING all feature/ADR work (E15-E21) lands first. T22.1 feature-coverage
  audit (the map) -> T22.2 README final pass (native parallelism + full CLI ref, flip
  every "coming" tag to "available") / T22.3 concept.md (native scheduler architecture)
  / T22.4 docs index + guide completeness -> T22.5 website comprehensive refresh ->
  T22.6 docs-presentation decision (optional `/docs` on the site, maybe an ADR) ->
  T22.7 no-vaporware accuracy/coherence/freshness audit -> T22.8 launch checklist +
  publish (the done gate) -> T22.9 launch announcement (optional).
- **Builds ON E17** (does not redo T17.x): T22.2 deps T17.1, T22.5 builds on
  T17.2/T17.5. E22 adds full feature coverage (esp. E21 native parallelization, which
  E17 predated), the accuracy audit, and the publish gate.
- No new use cases (E22 documents UC-033..UC-037; the pass serves UC-035). Wave E22
  (gated, LAST) + risk rows R-E22-1..3 added. No trim this pass (concurrent /apply
  --pool sessions are editing the plan; the plan was trimmed 2026-06-23). No new ADR
  (T22.6 may produce a docs-presentation ADR if a `/docs` site is chosen).

### 2026-06-24 -- Change Summary (E21: kazi owns parallelization, P1 + ADR-0027; E20 -> interop)
- **Created ADR-0027** (kazi owns parallelization: a native scheduler over a
  partitioned goal-set). Diagnosis (verified in code): kazi has the parallelization
  SUBSTRATE (`Kazi.Partition` + `PartitionLease`, ADR-0006) but NO scheduler --
  nothing calls them to spawn agents; the loop is serial by design; the spawner
  lived in the operator's `/apply --pool` + `/claim`. So parallelization -- the
  piece that birthed kazi -- was never codified. ADR-0027 builds the scheduler INTO
  kazi: partition by blast radius -> lease each -> spawn N supervised reconcilers
  (the existing serial loop, one per partition) under a DynamicSupervisor, each in
  its own worktree -> collective convergence -> merge. SINGLE-NODE IS NATS-FREE
  (in-memory lease); NATS only for multi-machine.
- **ADR-0026 superseded IN PART** (parallelization stance) and RETAINED as the
  INTEROP story (kazi under an existing external orchestrator / CI). ADR README +
  the ADR-0026 status updated; E20 annotated as interop, E21 is the primary story.
- **Added E21** (P1, ADR-0027, UC-037): T21.1 scheduler+DynamicSupervisor, T21.2
  wire Partition, T21.3 lease lifecycle, T21.4 worktree-per-partition, T21.5 merge
  convergence, T21.6 overlap policy, T21.7 per-partition budgets, T21.8 CLI+`--json`
  collective, T21.9 dashboard, T21.10 supervision/restart, T21.11 docs/positioning,
  T21.12 live NATS-free dogfood. Waves E21-1..4; risks R-E21-1..4 (partition quality,
  worktree hygiene, crash isolation, scope).
- **UC-037** added. Rationale: closes the founding codification gap -- new users get
  parallelism from `kazi run` alone (no personal skills, no NATS on one machine),
  which the fragility/codification concern surfaced. kazi-the-tool was never fragile
  (single-goal is self-contained); the gap was that the PARALLEL story was BYO-
  orchestrator. ADR-0001 intact (kazi orchestrates harness dispatches; it is not one).
- ADR created: `docs/adr/0027-kazi-owns-parallelization-native-scheduler.md`.

### 2026-06-24 -- Change Summary (E20: kazi under /apply --pool, P1 + ADR-0026)
- **Created ADR-0026** (kazi UNDER `/apply --pool`, shape a): `/claim` stays the
  outer task-selection coordination; kazi's blast-radius leases
  (`Kazi.Partition`/`PartitionLease`, ADR-0006) are the inner coordination; the
  authoring bridge is caller-drafts (`propose --json --predicates`) turning a task's
  `acc:` into predicates; `run --json` is the objective-done gate. Does NOT replace
  the pool (shape b deferred); ADR-0001 intact.
- **Added E20** (P1, ADR-0026): the exhaustive integration, LAYERED so value lands
  without an up-front NATS dependency:
  - L1 verification gate (no NATS): T20.1 `acc:`->predicates bridge, T20.2 pool
    gate recipe, T20.3 opt-in `/apply --verify-with-kazi` (global skill, cross-repo).
  - L2 objective-done loop: T20.4 orchestrator recipe, T20.5 per-task model tiering.
  - L3 blast-radius leases (NATS): T20.6 per-task lease, T20.7 `/claim`<->lease
    compose-boundary + deadlock safety.
  - L4 observability: T20.8 live dashboard/lease map. (T20.9 Telegram dropped -- ADR-0029, removed in E24.)
  - Cross-cutting: T20.10 adoption guide, T20.11 LIVE multi-session dogfood (the
    honest proof -- did the gate block a non-converged task?).
- **UC-036** added (harden multi-session `/apply --pool` with kazi). Waves
  (E20-L1..L4 + docs) and risk rows R-E20-1..5 added (deadlock, NATS cost,
  local-model speed, global-skill drift, trivial-task overhead).
- Rationale: the operator's `/apply --pool` workflow is a hand-rolled kazi; this
  hardens its documented failure modes (false-completion, ~5/10 wave stalls, silent
  logical conflicts) as an opt-in layer beneath the sessions they already run.
- ADR created: `docs/adr/0026-kazi-under-apply-pool.md` (+ README index).

### 2026-06-24 -- Change Summary (E17 sharpened: adoption-first docs rewrite, P1)
- **Reframed E17** from "lead with the agent workflow" (P2) to a decisive,
  adoption-first DOCUMENTATION REWRITE (P1): README, website, and docs entry all
  LEAD with the claude->kazi->cheap-harness on-ramp ("keep Claude Code, add provable
  done + cheap grind"); vanilla `kazi run`/`propose`/harness/build demoted to a
  Reference tier. Motivated by the operator: people adopt kazi from INSIDE Claude
  Code (often remotely -- phone -> a Mac in the office), so leading with vanilla kazi
  is a friction wall.
- **Created ADR-0025** (docs lead with the agent-driven on-ramp) -- sets the
  information architecture + messaging hierarchy; vanilla is the reference tier;
  cost framing honest per the 2026-06-24 benchmark.
- **Operator decision (2026-06-24): promising planned work is OK** -- the docs may
  lead with the one-command `kazi install-skill`/`mcp` on-ramp BEFORE it ships,
  clearly marked "coming," with the works-today recipe alongside. So E17 is
  UNBLOCKED (no longer gated on T16.2/T16.5). ADR-0025 sec 2 + alternatives updated.
- **Tasks:** T17.1 (README rewrite to the new IA), T17.2 (website rewrite to match),
  T17.4 (the works-today "drive kazi from Claude Code" recipe, on the shipped JSON
  CLI), T17.5 (OG/social card previewing the on-ramp); T17.3 stays done. Wave E17
  rewritten (can start now; T17.4 -> T17.1 -> T17.2 -> T17.5).
- Current shipped state confirmed via `git pull`: E15 (agent-drivable JSON CLI) is
  DONE through T15.7; T16.1 (`help --json`/`schema`) done; T16.2/T16.3/T16.5 (skill/
  AGENTS.md/mcp) still open -- hence the "promise + label" approach.
- ADR created: `docs/adr/0025-docs-lead-with-agent-driven-onramp.md` (+ README index).
  No new use cases (maps to UC-035).

### 2026-06-24 -- Change Summary (E18 benchmark bug fixes + E19 token-efficiency wiring)
- Added **E18** (P2, no ADR): four reliability fixes for defects surfaced while
  running the T15.9 token benchmark (`docs/devlog.md` 2026-06-24): T18.1 stale
  `priv/examples/deploy_target.toml` `cmd = "go test ./..."` -> `cmd="go"`,
  `args=[...]` + a shipped-example runnability guard; T18.2 deep-sanitize read-model
  evidence so errored predicates (tuple evidence) persist instead of crashing
  `record_iteration/1` (`:map` cast); T18.3 idempotent terminal/budget-stop
  iteration persistence (no `(goal_ref, iteration_index)` unique collision); T18.4
  reproduce/close the over-budget `CaseClauseError` (likely already fixed by T15.3
  at `cli.ex:544`) + a regression test; T18.5 re-verify + lint.
- Added **E19** (P2, ADR-0010): realize the unwired token-efficiency levers + a
  multi-iteration benchmark. T19.1 wire the cached orientation pack into the live
  `dispatch_prompt/2` as a stable prefix (T4.3 is built but unused on the live
  loop); T19.2 stable-prefix discipline so the inner harness's OWN prompt cache hits
  across dispatches (kazi drives a subprocess and sets no `cache_control`); T19.3
  route live evidence through `truncate_evidence/2`; T19.4 a >=3-dispatch benchmark
  harness; T19.5 run + record an honest A/B/C verdict (may recommend REVERT if the
  prefix is not a net win).
- Risk rows R-E18-1, R-E19-1, R-E19-2 added. No ADRs created (E18 = bug fixes;
  E19 is covered by existing ADR-0010). No new use cases (fixes/measurement map to
  UC-024 + UC-033 + infrastructure). No trim this pass (plan was trimmed 2026-06-23).

### 2026-06-23 -- Change Summary (close-out trim: plan ready for a fresh `/apply` session)
- **Trimmed the completed epics** out of the WBS: E0-E8, E11, and the E9 core
  (T9.1-T9.4, T9.7-T9.9) are DONE on `main` and removed -- their knowledge lives in
  ADRs `0001`..`0024`, `docs/concept.md`, and `docs/devlog.md`. Only the OPEN work
  remains: E9 leftovers (T9.5/T9.6), E12, E13, E14, E15, E16, E17.
- **Rewrote Context, the Use Case Summary, the Risk Register, the Waves, and the
  Hand-off Notes** to the true current state: `main` at **899 tests**, latest
  release **v0.3.0** (brew, live). The stale "E6 is the only epic left" / "853
  tests" / "T8.11 in progress" notes are gone.
- **Risk Register** now carries only OPEN risks (E12-E17); the done R-E6-*/R-E9-1/
  R-E11-* risks were dropped.
- No new ADR; no code change. Build the open epics with `/apply --pool` -- the
  adoption spine is **E15 -> E16 -> E17**.

### 2026-06-23 -- Change Summary (E16 self-teaching + E17 adoption; propose two drive modes)
- **Refined ADR-0023 + T15.2**: `kazi propose` has TWO drive modes -- kazi-drafts
  (kazi spawns a model) and caller-drafts (the orchestrator supplies predicates;
  kazi applies the floor + persists + gates, NO inner model). Resolves the
  "claude -> kazi -> claude" redundancy: kazi's value is the floor + gate, not the
  drafting LLM, so a capable orchestrator pays for reasoning ONCE.
- **ADR-0024** + **E16** (kazi self-teaching: `install-skill`, `help --json`/
  `schema`, `AGENTS.md`, `kazi mcp`) and **E17** (adoption docs/website). UC-034/035.

### 2026-06-23 -- Change Summary (E15 agent-drivable; E13/E14 added; E12 grouping)
- **ADR-0023 + E15** -- harness-friendly, agent-drivable kazi (`--json` + a
  versioned result contract; kazi self-conforms to ADR-0022). UC-033.
- **ADR-0022 + E14** -- onboard Codex/Antigravity/claw-code as profiles per a
  conformance contract (non-TTY subprocess-safe, structured stdout). UC-032.
- **ADR-0021 + E13** -- intended-vs-actual reconciliation: import intent
  (OpenAPI/gherkin/prose) + dead-code coverage meta-predicate; corrected an
  ADR-0015 contradiction (the bespoke capabilities importer was withdrawn). UC-025
  (un-deferred), UC-031.
- **ADR-0020 + E12** -- hierarchical predicate grouping via a declared taxonomy;
  per-group budgets are a DERIVED rollup. UC-030. Motivated by the external-service dogfood
  (`docs/devlog.md`).

### 2026-06-23 -- Change Summary (E11 shipped v0.3.0)
- **E11 SHIPPED.** Interactive `propose` (ADR-0019) merged; release-please cut
  **v0.3.0** and the auto-release chain built + tap-bumped it; verified live:
  `brew upgrade` -> `kazi 0.3.0`. Suite 855 -> 899.

## Hand-off Notes (cold start for a new session running `/apply --pool`)

1. **Verify the baseline first:** `mix test` should report **899 passing, 19
   excluded** (`:nats`/`:graphify`/`:opencode_live`); `mix format --check-formatted`
   and `mix compile --warnings-as-errors` clean. `git pull` `main` before starting.
2. **What is DONE (do NOT rebuild):** E0-E11 and the E6 release pipeline are
   shipped; `brew install kazi-org/tap/kazi` is live at **v0.3.0**; the website is
   live at https://kazi.sire.run. Releases are automatic (merge Conventional Commits
   -> merge the release PR -> tag + build + tap-bump).
3. **What is OPEN (this plan):** E9 leftovers (T9.5/T9.6), E12, E13, E14, E15, E16,
   E17. The **adoption spine is E15 -> E16 -> E17** (JSON contract -> the skill that
   teaches agents -> the docs/website). **E12 -> E13** and **E14** are independent
   parallel tracks. Cross-epic deps: T13.1/T13.2 need the E12 model (T12.1/T12.2);
   T15.7 needs T14.1; T16.* need the E15 JSON contract; T17.* need the skill (T16.2).
4. **Build order tip for a single pool:** start with **E15-1 + E14-1 + E12-1 + E9**
   (all dependency-free or near it), then follow the waves. Pure/loader tasks
   (T12.1-T12.3, T15.1, T14.1) are the safe first claims.
5. **House rules:** rebase-merge only; many small commits; never commit files from
   different directories together; **stage only your files** (a sibling session
   shares this tree). `/claim R-plan-md` before any full plan rewrite. The Burrito
   host binary CANNOT build on this macOS-26 box (R-E6-1) -- but E6 is done, so this
   only matters if you touch the release workflow.
6. **Do not relitigate frozen design** -- read `docs/concept.md` and the relevant
   ADR (`0001`..`0024`) before touching an area; write a superseding ADR to change a
   decision. Landmines are in `docs/lore.md`; findings in `docs/devlog.md`.

## Appendix

- Concept and architecture: `docs/concept.md` (frozen source of truth).
- Decisions: `docs/adr/0001`..`0024` (index at `docs/adr/README.md`). The open epics
  map to: E12 -> ADR-0020; E13 -> ADR-0021; E14 -> ADR-0016 + ADR-0022; E15 ->
  ADR-0023; E16 -> ADR-0024; E17 -> ADR-0023/0024.
- Operations / findings: `docs/devlog.md`; landmines: `docs/lore.md`.
- Use-case manifest: `.claude/scratch/usecases-manifest.json`.
- Harness layer (for E14/E15): `lib/kazi/harness/` (`profile.ex`, `registry.ex`,
  `cli_adapter.ex`, `profiles/`); authoring (for E13/E15): `lib/kazi/authoring.ex`
  + `lib/kazi/authoring/clarify.ex`; goal loader (for E12): `lib/kazi/goal/loader.ex`;
  CLI (for E15/E16): `lib/kazi/cli.ex`.

## Archived epics

Fully-done, released epics, trimmed from the live WBS (T31.2/ADR-0036 L1).
Their bodies live verbatim under `docs/plans/archive/`.

- E12 -- Hierarchical predicate grouping + Obsidian export (P3, ADR-0020) (archived 2026-06-25) -> plans/archive/E12.md
- E13 -- Intended-vs-actual reconciliation: import intent + detect dead code (P3, ADR-0021) (archived 2026-06-25) -> plans/archive/E13.md
- E14 -- Onboard more coding harnesses: Codex, Antigravity, claw-code, + any CLI harness (P3, ADR-0016 + ADR-0022) (archived 2026-06-25) -> plans/archive/E14.md
- E17 -- Adoption: lead EVERY surface with the agent-driven on-ramp (P1, ADR-0025) (archived 2026-06-25) -> plans/archive/E17.md
- E18 -- Bug fixes from the T15.9 token-benchmark dogfood (P2, no ADR) (archived 2026-06-25) -> plans/archive/E18.md
- E24 -- Remove the Telegram bridge (P2, ADR-0029; cleanup) (archived 2026-06-25) -> plans/archive/E24.md
- E16 -- kazi self-teaching to harnesses: skill + MCP + machine-readable help (P3, ADR-0024) (archived 2026-06-26) -> plans/archive/E16.md
