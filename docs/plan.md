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

## Checkable Work Breakdown

The WBS below is the single checkable source of truth; toggle `[ ]` to `[x]`.
Status `kind: agent` is implicit unless noted. Completed epics (E0-E8, E11, and the
E9 core T9.1-T9.4/T9.7-T9.9) are removed from this WBS -- they are done on `main`;
their narrative lives in the ADRs and `docs/devlog.md`.

### E9 (leftovers) -- Website polish (P2, ADR-0018)

The site is LIVE at https://kazi.sire.run (T9.1-T9.4, T9.7-T9.9 DONE). Remaining:

- [x] T9.5 Playwright smoke test: add a minimal Playwright project under `site/` that loads the built site (or the live URL) and asserts the hero headline, the `brew install` command text, the GitHub link, and at least one edge case (mobile viewport renders the nav/CTA; no console errors).  Owner: pool  Done: 2026-06-23  verifies: [UC-028]  deps: []  acc: `npx playwright test` green against `site/dist` (served) and, when live, against `https://kazi.sire.run`; the test is wired into the pages workflow (or a `site` CI job) so a broken page fails CI.
- [x] T9.6 Polish + perf + a11y: Lighthouse >= 90 on performance/accessibility/best-practices/SEO; semantic HTML + alt text + sufficient contrast (the Electric Blue gradient on slate/white); OpenGraph/Twitter-card image (render from the logo); `<title>`/meta description; prefers-color-scheme support.  Owner: pool  Done: 2026-06-23  verifies: [UC-028]  deps: []  acc: a Lighthouse run (CI or local) reports >= 90 in all four categories on the deployed site; the OG image renders in a link-preview check.
- [x] T9.10 Fix the stale site version badge (deploy-trigger gap): the site bakes its version from `.release-please-manifest.json` at BUILD time (correct), but `pages.yml` only triggers on pushes touching `site/**`, so a release-please version bump (which touches `.release-please-manifest.json`, not `site/`) does NOT redeploy the site -- the live badge goes stale (observed 2026-06-24: live site shows v0.3.0 while the latest release/manifest is v0.4.0). FIX: add `.release-please-manifest.json` to the `pages.yml` `paths:` trigger (and/or add a `release: [published]` trigger) so a release rebuilds + redeploys the site. (Alternative considered: fetch the version client-side from the GitHub releases API -- never stale but adds a runtime fetch; the trigger fix is simpler and keeps the build-time source.) NOTE: the README release badge is the dynamic shields `github/v/release` endpoint -- already correct, untouched.  Owner: TBD  Est: 0.5h  verifies: [UC-028, infrastructure]  deps: []  acc: after a release bumps the manifest, the Pages deploy runs and https://kazi.sire.run shows the new version within one deploy; verified live; the README badge confirmed dynamic (no change).

### E12 -- Hierarchical predicate grouping + Obsidian export (P3, ADR-0020)

Acceptance: a `Kazi.Goal` can organize hundreds of predicates as a validated tree
(e.g. pillar -> domain -> capability), so a goal representing a whole product's
desired state is legible, sliceable, budgetable per group, and exportable to a
visualization tool (Obsidian) showing each node's state (intended / built /
pending). Grouping references a DECLARED taxonomy by id (NOT free text), validated
at load -- the structural guard against text drift (ADR-0020). Motivated by the
external-service dogfood (`docs/devlog.md` 2026-06-23): that service's
`capabilities.json` is 317 capabilities across 9 pillars; the one-off analysis
proved the value and revealed
the requirements. Backward compatible: `group`/`[[group]]` are optional; an
ungrouped goal behaves exactly as today.

- [x] T12.1 Declared `[[group]]` taxonomy in the goal-file + loader parsing: extend `Kazi.Goal.Loader.from_map/1` to parse a `[[group]]` array of `{id, name, parent?, budget?}` into a group set on the goal; ids are slugs, `name` is the display label.  Owner: pool  Done: 2026-06-23  verifies: [UC-030]  deps: []  acc: ExUnit -- a goal-file with `[[group]]` entries loads a validated group set; ids normalize (case/whitespace/`&`); a duplicate group id is a load error; round-trips through the loader.
- [x] T12.2 `Predicate.group` field + reference validation (the drift guard): add an optional `group :: String.t() | nil` to `Kazi.Predicate` (a declared group id, appended additively); the loader REJECTS a predicate whose `group` is not a declared id, a group whose `parent` is undeclared, and a parent cycle.  Owner: pool  Done: 2026-06-23  verifies: [UC-030]  deps: [T12.1]  acc: ExUnit -- a predicate referencing a declared group loads; an UNKNOWN group id is `{:error, ...}` at parse time (the typo guard); an undeclared parent and a cycle are load errors; `group: nil` is unchanged (backward compatible).
- [x] T12.3 Group tree + per-group status rollup (pure): build the tree from `parent` links and roll up predicate verdicts (acceptance-not-yet-true vs passing) into per-group intended/built/pending counts.  Owner: pool  Done: 2026-06-23  verifies: [UC-030]  deps: [T12.2]  acc: ExUnit -- pure functions reconstruct the tree to arbitrary depth and roll up counts per group; deterministic; no I/O.
- [x] T12.4 Per-group budgets (DERIVED rollup) + reconciliation: a group's effective budget is the SUM of its descendants' budgets -- never a hand-maintained parent number; declare budgets only at leaves. An explicit `budget` on a non-leaf is a CAP that can only tighten the rollup (`effective = min(cap, sum)`). Scope convergence + reporting to a group's predicate partition (rides ADR-0006 partitioning), delivering per-pillar reconciliation without a separate `Goal`.  Owner: pool  Done: 2026-06-24  verifies: [UC-030]  deps: [T12.2]  acc: ExUnit -- a parent group's budget equals the sum of its descendants' (no stored parent value); a declared parent cap below the sum tightens to the cap; a cap above the sum is a no-op (operator's choice, default: no-op); a leaf budget bounds its partition's iterations; per-group status reported; an ungrouped goal is unaffected.
- [x] T12.6 Obsidian/Mermaid exporter: `kazi export --obsidian <dir>` walks the group tree + predicate verdicts into a vault (one note per group/predicate, `[[wikilinked]]`, tagged intended/built/pending) and a Mermaid rollup.  Owner: pool  Done: 2026-06-24  verifies: [UC-030]  deps: [T12.3]  acc: ExUnit -- the exporter writes a vault for a fixture grouped goal; notes link parent<->child; tags reflect verdicts; an overview note carries per-group rollups. Live: open the vault in Obsidian and confirm the graph renders.
- [x] T12.7 `kazi lint` near-duplicate group-name warning (advisory second net): fuzzy-compare declared group NAMES and warn on near-duplicates (e.g. "Identity & Access" vs "Identity and Access") without failing the load.  Owner: pool  Done: 2026-06-24  verifies: [UC-030]  deps: [T12.1]  acc: ExUnit -- near-duplicate names emit a warning; exact/distinct names do not; advisory only (exit 0).

(T12.5 was WITHDRAWN -- the bespoke `--from-capabilities` importer contradicted
ADR-0015; the general importer is E13. T12.8 MOVED to E13/T13.6.)

### E13 -- Intended-vs-actual reconciliation: import intent + detect dead code (P3, ADR-0021)

Acceptance: kazi addresses BOTH halves of "correct software, no dead code" within
the predicate model. It imports the INTENDED set from GENERAL sources -- standard
machine specs (OpenAPI -> `http_probe`, gherkin -> acceptance) deterministically,
and prose docs (ADRs/requirements) drafted into predicates via the harness +
human review (the `propose`/authoring path, ADR-0011/0019) -- never a bespoke
catalog (ADR-0015). It detects DEAD code (`A \ I`) via a surface-coverage
META-PREDICATE: a scanner inventories the public surface and a predicate asserts
every element is owned by >=1 intended predicate; an unowned element FAILS (dead/
undocumented), surfaced and reconciled like any other predicate, held true by
standing mode. Both directions feed the grouped view (E12). `kazi init` stays the
small code-side bootstrap (ADR-0013).

- [x] T13.1 OpenAPI importer: parse an OpenAPI document into one `http_probe` acceptance predicate per path/operation, grouped (tag -> declared `[[group]]`, ADR-0020). Deterministic and hermetic.  Owner: pool  Done: 2026-06-23  verifies: [UC-025]  deps: [T12.1, T12.2]  acc: ExUnit on a fixture spec -- paths/operations become grouped `http_probe` acceptance predicates with method/path/expected-status config; same spec -> same goal-file; re-import upserts.
- [x] T13.2 Gherkin importer: parse Cucumber/gherkin feature files into one acceptance predicate per scenario, grouped by feature.  Owner: pool  Done: 2026-06-23  verifies: [UC-025]  deps: [T12.1, T12.2]  acc: ExUnit on fixture features -- scenarios become grouped acceptance predicates; deterministic.
- [x] T13.3 Prose-doc importer via the harness: drive the existing authoring/clarify path (`Kazi.Authoring`, ADR-0011/0019) over a prose doc (ADR/requirements) to draft candidate predicates, HUMAN-REVIEWED before acceptance; reuses the injectable harness seam (stub in tests).  Owner: pool  Done: 2026-06-23  verifies: [UC-025]  deps: []  acc: ExUnit with a stub harness -- a prose doc yields candidate predicates routed through the review/approve flow; nothing is accepted without approval; no real `claude`/network in tests.
- [x] T13.4 Surface-scanner provider: inventory a project's public surface (HTTP routes/handlers, exported symbols, CLI commands) for one language first (Elixir or Go), reusing the repo-introspection seam (ADR-0010).  Owner: pool  Done: 2026-06-23  verifies: [UC-031]  deps: []  acc: ExUnit on a fixture repo -- the scanner returns the public surface inventory; approximate-by-design (reflection/string-dispatch invisible -- documented, `docs/lore.md`).
- [x] T13.5 Surface-coverage meta-predicate: assert every scanned surface element is OWNED by >=1 intended predicate (match by route/path/symbol); an unowned element FAILS (dead/undocumented); supports an explicit allow-list; WARN-don't-auto-delete.  Owner: pool  Done: 2026-06-23  verifies: [UC-031]  deps: [T13.4]  acc: ExUnit -- a fixture with an un-predicated endpoint fails the meta-predicate and names it; allow-listed surface passes; a fully-owned surface passes; ungrouped goals unaffected.
- [x] T13.6 Dogfood an external service via the GENERAL path: import that service's API surface (OpenAPI if present, else the T13.4 scanner) + key prose ADRs (T13.3); run the coverage meta-predicate to find `A \ I` (dead/undocumented) and compare against the manifest's `undocumented_discovered: 68`; export the grouped view (E12). Note the LIVE-predicate escalation (probe a running service -- needs an instance + test creds) as deferred.  Owner: pool  Done: 2026-06-24  verifies: [UC-031, UC-030]  deps: [T13.1, T13.4, T13.5]  acc: observed evidence that the general importer + coverage meta-predicate reproduce/compare against the one-off analysis for that service; `mix format`/`--warnings-as-errors` clean; the live-predicate follow-on recorded in `docs/devlog.md`.

### E14 -- Onboard more coding harnesses: Codex, Antigravity, claw-code, + any CLI harness (P3, ADR-0016 + ADR-0022)

Acceptance: `kazi run <goal> --harness <id> [--model <m>]` drives Codex CLI,
Google Antigravity CLI (`agy`), and claw-code (and any major CLI harness) the same
way it drives `claude`/`opencode` -- added as PROFILE DATA, not new modules
(ADR-0016), each meeting the conformance contract (ADR-0022): non-interactive
single-prompt, machine-parseable stdout, correct under a non-TTY subprocess.
Researched contracts (`docs/devlog.md` 2026-06-23): **Codex** `codex exec
"<prompt>" --json [--model]` -> JSONL events (fully conformant; parser mirrors
opencode); **Antigravity** `agy/antigravity --prompt-file <f> --output json --yes`
(auth GEMINI_API_KEY/ANTIGRAVITY_API_KEY) but bug #76 drops stdout under non-TTY --
needs a workaround; **claw-code** `claw prompt "<text>"` (env API keys, NO JSON) --
best-effort/demo-grade only. Each profile is unit-tested (`build_args`), golden-
transcript-tested (`parse`), and live-smoked behind an excluded `:<id>_live` tag.

- [x] T14.1 Profile conformance test helper + golden-transcript pattern: a reusable ExUnit helper that, given a profile + a recorded sample transcript, asserts `build_args` renders the expected argv and `parse` extracts the expected additive fields; mirrors the existing `claude`/`opencode` stub-binary seam (`test/support/stub_claude_args.sh`).  Owner: pool  Done: 2026-06-23  verifies: [infrastructure]  deps: []  acc: ExUnit -- the helper drives `:claude` + `:opencode` against fixture transcripts and passes; it is the uniform harness every new profile reuses.
- [x] T14.2 Codex profile (`:codex`, fully conformant): add `defp codex` to `Kazi.Harness.Registry` (command `codex`, `build_args` -> `exec <prompt> --json` + optional `--model <m>`, `parse` the JSONL event stream -> `:result`/`:cost` additively, reusing the opencode NDJSON approach); register in `fetch/1` + `ids/0`; unit + golden-transcript tests; a live smoke tagged `:codex_live` (excluded).  Owner: pool  Done: 2026-06-23  verifies: [UC-032]  deps: [T14.1]  acc: ExUnit -- `build_args` yields `["exec", prompt, "--json"]` (+`--model` when given); `parse` extracts the final result + token cost from a recorded codex JSONL sample; `kazi run --harness codex` resolves the profile (resolve/1); `mix format`/`--warnings-as-errors` clean.
- [x] T14.3 Antigravity profile (`:antigravity`, conformant WITH workaround): add `defp antigravity` (command `antigravity`/`agy`, `build_args` -> `run --prompt-file <tmp> --output json --yes` writing the prompt to a temp file and reading JSON back to dodge the non-TTY stdout bug #76; env GEMINI_API_KEY/ANTIGRAVITY_API_KEY passthrough); register; unit + golden-transcript tests; live smoke `:antigravity_live`. Document the non-TTY workaround + version pin in `docs/lore.md`.  Owner: pool  Done: 2026-06-23  verifies: [UC-032]  deps: [T14.1]  acc: ExUnit -- argv uses the prompt-file + `--output json` workaround (NOT bare `-p`); `parse` reads the JSON result; the non-TTY landmine is recorded in `docs/lore.md`; a maintainer live-smoke converges a fixture (or an honest skip with the cause, like the opencode smoke).
- [x] T14.4 claw-code profile (`:claw`, BEST-EFFORT/demo-grade): add `defp claw` (command `claw`, `build_args` -> `prompt <text>`, `parse` = best-effort raw stdout -> `:result`, NO cost/structured extraction since claw emits no JSON); register; unit test + a raw-output golden transcript; mark demo-grade in the profile doc + README.  Owner: pool  Done: 2026-06-24  verifies: [UC-032]  deps: [T14.1]  acc: ExUnit -- `build_args` yields `["prompt", text]`; `parse` returns the raw stdout as `:result` with no invented cost; the profile + README label it best-effort/demo-grade (no structured output, per ADR-0022).
- [x] T14.5 CLI + coherence + docs: confirm `--harness codex|antigravity|claw` works end to end (resolve precedence, the unknown-harness error lists the new ids); update the README harness section AND `site/src/canonical.mjs` HARNESSES in the SAME change so the T9.9 drift-check stays green; document each harness's auth/setup.  Owner: pool  Done: 2026-06-24  verifies: [UC-032, infrastructure]  deps: [T14.2, T14.3, T14.4]  acc: `kazi run --harness <new> --help`/resolve works; the coherence check passes with the expanded harness list; README documents the per-harness auth (OPENAI_API_KEY / GEMINI_API_KEY / claw env keys) and conformance tier.
- [x] T14.6 "Add your own harness" contributor recipe: a short doc (README or `docs/`) that walks the ADR-0022 recipe -- author a `defp <id>` profile (build_args + additive parse), register it, add the three tests (build_args unit, golden transcript, `:<id>_live` smoke), update the canonical harness list -- proven by the fact that T14.2-T14.4 each followed it.  Owner: pool  Done: 2026-06-24  verifies: [UC-032]  deps: [T14.5]  acc: a new contributor can add a CLI harness as profile DATA by following the recipe; it references the conformance contract (ADR-0022) and the test helper (T14.1); no architecture change required.

### E15 -- Harness-friendly, agent-drivable kazi: JSON CLI + result contract (P3, ADR-0023)

Acceptance: an orchestrating agent (claude code today) drives kazi end to end --
plan/design (`kazi propose`) -> approve -> converge (`kazi run`) -> release -- by
parsing JSON, never prose. kazi SELF-CONFORMS to the harness conformance contract
it imposes (ADR-0022): every command has a `--json` mode emitting a single JSON
object (or JSONL stream for long runs), is non-interactive under `--json`/no-TTY/
`--yes` (never blocks on stdin), and returns stable exit codes. The two-tier
economics (strong model authors predicates via `kazi propose`; cheap model runs the
loop via `kazi run --harness claw --model <local>`) live in the ORCHESTRATOR, not
kazi. **`kazi propose` is the SINGLE agent authoring path** (ADR-0023; no
hand-authoring) -- so the clarify floor + review/approve gate are never bypassed.
Human-readable output stays the DEFAULT; `--json` is the machine surface. MCP server
(`kazi mcp`) is E16.

- [x] T15.1 JSON output framework + non-interactive guarantee: a `--json` flag + a small renderer seam so each command emits a single JSON object to stdout; under `--json` kazi NEVER prompts/blocks on stdin (it errors loudly if input is required), and exit codes are stable. Unit-tested.  Owner: pool  Done: 2026-06-23  verifies: [UC-033, infrastructure]  deps: []  acc: ExUnit -- a command in `--json` mode emits valid JSON only (no human prose interleaved) and never reads stdin; non-`--json` is unchanged; piped/non-TTY `--json` works headlessly.
- [x] T15.2 `kazi propose --json` with TWO drive modes (the single authoring path, ADR-0023): emit the draft -- goal id, `proposal_ref`, predicates[], rationale, any clarify questions -- as one JSON object. (a) **kazi-drafts**: `propose "<idea>" --harness <model>` spawns a model to draft (existing). (b) **caller-drafts**: `propose --json` with predicates supplied on stdin/flag -- the orchestrator (which already reasoned) supplies the draft and kazi applies the deterministic FLOOR + persists + gates WITHOUT spawning an inner model (avoids the redundant claude->kazi->claude). Both go through `Kazi.Authoring` (the one write path, ADR-0011); no parallel mechanism.  Owner: pool  Done: 2026-06-23  verifies: [UC-033, UC-029]  deps: [T15.1]  acc: ExUnit with a stub harness -- kazi-drafts returns a parseable draft; caller-drafts accepts supplied predicates, applies the floor (flags a missing live-verification target + scope), persists, and spawns NO inner model; the floor applies in both; no second authoring path.
- [x] T15.3 `kazi run --json` result contract (versioned): on termination emit a JSON object with `status` (`converged`/`stuck`/`over_budget`/`error`), the PREDICATE VECTOR (id + verdict per predicate), `iterations`, `budget_spent`, a `next_action` hint, and `schema_version`. Document + version the schema.  Owner: pool  Done: 2026-06-23  verifies: [UC-033]  deps: [T15.1]  acc: ExUnit against fixture runs -- each terminal status yields the documented object with the predicate vector; `schema_version` present; a schema doc is committed.
- [x] T15.4 `kazi run --json --stream` JSONL progress: emit one JSON event per iteration (iteration n, dispatched harness, predicate-vector delta), terminated by the final T15.3 result object, so an orchestrator monitors a long run without blocking. Mirrors how kazi parses opencode/codex JSONL.  Owner: pool  Done: 2026-06-24  verifies: [UC-033]  deps: [T15.3]  acc: ExUnit -- a multi-iteration fixture run emits a valid JSONL event stream ending in the result object; each line parses independently.
- [x] T15.5 `kazi status --json` (new command): report a run/proposal's current state from the read-model as JSON (status, predicate vector, last iteration, timestamps).  Owner: pool  Done: 2026-06-24  verifies: [UC-033]  deps: [T15.1]  acc: ExUnit -- after a propose/run, `status --json <ref>` returns the persisted state; an unknown ref is a clear JSON error + non-zero exit.
- [x] T15.6 `kazi list-proposed/approve/reject --json`: structured output for the authoring state machine so the orchestrator drives propose -> approve -> run programmatically.  Owner: pool  Done: 2026-06-24  verifies: [UC-033]  deps: [T15.1]  acc: ExUnit -- each command emits a parseable JSON result; transitions report machine-readable success/error.
- [x] T15.7 kazi self-conformance test: assert kazi ITSELF passes the ADR-0022 conformance helper (E14 T14.1) -- non-interactive, JSON-only stdout under `--json`, subprocess-safe under a non-TTY -- so kazi meets the bar it imposes on harnesses.  Owner: pool  Done: 2026-06-24  verifies: [UC-033, infrastructure]  deps: [T15.2, T15.3, T15.5, T15.6, T14.1]  acc: ExUnit -- kazi's `--json` commands satisfy the conformance helper; a regression (prose leaking into `--json`, a stdin block) fails the test.
- [x] T15.8 Docs + the orchestrator recipe: document the versioned JSON schemas and a "drive kazi from an agent" recipe -- orchestrator: `kazi propose --json` -> `kazi approve --json` -> `kazi run --harness <cheap> --json [--stream]` -> parse the result -> branch on `next_action`. Note the `kazi mcp` follow-on (E16).  Owner: pool  Done: 2026-06-24  verifies: [UC-033]  deps: [T15.7]  acc: a new orchestrator can drive the full loop from the recipe + schemas; `schema_version` pinning is documented.
- [ ] T15.9 LIVE nested-loop dogfood (claude -> kazi -> claw/Qwen): as the orchestrator, author a tiny broken fixture goal's predicates via `kazi propose --json`, approve, then `kazi run --harness claw --model <local-Qwen> --json` to drive the cheap loop; parse the JSON result. Record evidence + the friction (HONEST: claw is best-effort/no-JSON per E14, local Qwen slow per T8.11 -- expect a wiring proof, maybe not fast convergence) in `docs/devlog.md`.  Owner: TBD  Est: 2h  verifies: [UC-033]  deps: [T15.3, T14.4]  acc: observed evidence of the full agent->kazi->cheap-harness loop driven over `--json`; every point where kazi was awkward to drive as a tool is logged as a follow-up; honest result reported.

### E16 -- kazi self-teaching to harnesses: skill + MCP + machine-readable help (P3, ADR-0024)

Acceptance: an orchestrating harness knows how to drive kazi out of the box.
`brew install kazi-org/tap/kazi && kazi install-skill` teaches Claude Code the
orchestrator recipe; `kazi help --json`/`kazi schema` let ANY agent introspect the
CLI; an `AGENTS.md` covers convention-reading harnesses; a `kazi mcp` server is the
self-describing tool surface. Opt-in, consent-first (no auto-writes to `~/.claude`).
Depends on the E15 JSON contract.

- [x] T16.1 `kazi help --json` + `kazi schema`: emit the command/flag surface and the versioned result schemas (ADR-0023) as JSON, GENERATED from the real command table (not hand-maintained).  Owner: pool  Done: 2026-06-24  verifies: [UC-034]  deps: [T15.3]  acc: ExUnit -- `help --json` lists every command/flag; `schema run` returns the documented run-result schema with `schema_version`; both parse.
- [x] T16.2 The kazi Claude Code skill + `kazi install-skill` (opt-in): `kazi install-skill` writes `~/.claude/skills/kazi/SKILL.md` teaching the recipe (caller-drafts `propose --json` -> `approve` -> `run --harness <cheap> --json [--stream]` -> parse -> branch on `next_action`) + the two-tier economics; `brew install` PRINTS a hint to run it (no auto-write).  Owner: pool  Done: 2026-06-24  verifies: [UC-034]  deps: [T15.8]  acc: `kazi install-skill` writes the SKILL.md to a target dir (injectable in tests); the brew formula caveats the hint; the skill content references only real commands (checked by T16.4).
- [x] T16.3 Generic `AGENTS.md` teachability doc: a harness-neutral recipe doc in the repo, droppable into a target repo, for convention-reading harnesses (Cursor rules, etc.).  Owner: pool  Done: 2026-06-24  verifies: [UC-034]  deps: [T15.8]  acc: `AGENTS.md` documents the same recipe + JSON contract; references only real commands.
- [x] T16.4 Skill/AGENTS.md <-> CLI coherence test: assert the skill + `AGENTS.md` reference only commands/flags that `kazi help --json` reports (the drift guard, mirroring T9.9).  Owner: pool  Done: 2026-06-24  verifies: [UC-034, infrastructure]  deps: [T16.1, T16.2, T16.3]  acc: ExUnit/CI -- a command named in the skill but absent from `help --json` fails the check.
- [x] T16.5 `kazi mcp` server: expose propose/run/status/approve as self-describing MCP tools (descriptions + schemas) wrapping the JSON CLI, for MCP-native drive (no shelling/parsing).  Owner: pool  Done: 2026-06-24  verifies: [UC-034]  deps: [T15.7]  acc: an MCP client lists kazi's tools with descriptions + input/output schemas and can drive propose->approve->run; built on the proven JSON contract.
- [ ] T16.6 LIVE: Claude Code drives kazi via the installed skill: install the skill, then in a real Claude Code session drive a fixture goal end to end (propose -> approve -> run); record evidence.  Owner: TBD  Est: 1.5h  verifies: [UC-034]  deps: [T16.2]  acc: observed evidence that a Claude Code user who ran `kazi install-skill` can drive kazi without further instruction; honest result.

### E17 -- Adoption: lead EVERY surface with the agent-driven on-ramp (P1, ADR-0025)

> **SUPERSEDED (do not execute the open content tasks here).** E17's open content
> tasks (T17.1/T17.2/T17.4/T17.5) are superseded by **E25** (ADR-0030, the
> research-grounded content rewrite) and the engineering-accuracy sync **E28**;
> execute the content there. T17.3 is done. Kept for history; the apply pool should
> SKIP T17.1/2/4/5.

The adoption-first documentation rewrite. Today the README/site lead with VANILLA
kazi (install -> `mix kazi.run goal.toml` -> `propose`); the agent-driven path
(claude -> kazi -> claude/cheap-harness, ADR-0023) -- the lowest-friction, most
likely way people adopt, since they already live in Claude Code (often remotely:
phone -> a Mac in the office) -- is absent. ADR-0025 fixes the lead order.

Acceptance: README, website, and the docs entry all LEAD with the on-ramp -- keep
Claude Code, add kazi so its work is OBJECTIVELY done and the grind runs CHEAP. The
first code block is the on-ramp (`brew install` + `kazi install-skill`, then "in
Claude Code: use kazi to build X"); vanilla `kazi run`/`propose`/harness-config/
build-from-source become the REFERENCE tier below. Cost framing is HONEST per the
benchmark (`docs/devlog.md` 2026-06-24): no token overhead vs vanilla at the same
model; "cheaper" is model-tiering, gated by local-model speed -- no unearned number.
Canonical strings locked; README<->site coherence (T9.9) green; deployed + verified
live. PROMISING PLANNED WORK IS OK (operator decision 2026-06-24): the docs may lead
with the one-command `kazi install-skill` / `kazi mcp` on-ramp BEFORE it ships,
clearly MARKED as the intended/coming experience (e.g. a "coming in vNext" tag),
with the works-today recipe (T17.4) shown alongside so a reader can act now. The
guard is honesty-by-labelling, not omission: never present unshipped commands as
already working. Mixed content + engineering.

E17 is P1 -- the star/adoption lever -- and is UNBLOCKED now (it no longer waits on
T16.2/T16.5). T16.2 (`install-skill`), T16.3 (`AGENTS.md`), and T16.5 (`kazi mcp`)
upgrade the on-ramp from promised to one-command as they land; the docs flip the
"coming" tag to "available" at that point.

- [~] T17.1 **[SUPERSEDED by T25.3 -- do NOT execute standalone; the README rewrite is owned by E25/ADR-0030]** README rewrite to the adoption-first IA (ADR-0025): new lead = (1) one-line value (KEEP the locked positioning canonical string), (2) the on-ramp code block, (3) the 3-layer story + the remote vignette (drive Claude Code from anywhere; kazi rides along on the same machine), (4) the proof-of-convergence SVG, (5) with/without + who-it's-for, then (6) a "Reference" section that DEMOTES the current Install/Quickstart/harness/build content (kept verbatim, reordered below). An honest cost paragraph links the benchmark devlog.  Owner: TBD  Est: 2h  verifies: [UC-035]  delivers: [a README whose first screen is the claude->kazi->cheap-harness on-ramp]  deps: [T17.4]  acc: the first code block is the agent on-ramp -- it may PROMISE `kazi install-skill` marked "coming" with the T17.4 works-today recipe alongside (no command presented as working unless it is); vanilla `kazi run` appears only under "Reference"; canonical strings byte-identical (T9.9 green); the cost claim matches the devlog; every command labelled available is verified against `kazi help --json`.
- [~] T17.2 **[SUPERSEDED by T25.4 -- do NOT execute standalone; the website rewrite is owned by E25/ADR-0030]** Website rewrite to match (ADR-0025): hero leads with the on-ramp + "keep Claude Code, add provable done + cheap grind"; a PRIMARY "Use kazi with Claude Code" section (recipe / `install-skill` + the 3-layer diagram + the remote vignette); vanilla install demoted to a secondary section; reuse the proof SVG. Update `site/src/canonical.mjs` + the coherence check in lockstep.  Owner: TBD  Est: 2.5h  verifies: [UC-035]  delivers: [a website whose hero is the agent on-ramp]  deps: [T17.1]  acc: hero + primary section render the agent on-ramp; vanilla is secondary; README<->site coherence (T9.9) green; deployed + verified live at https://kazi.sire.run (golden path + mobile viewport, no console errors).
- [x] T17.3 docs/concept positioning: record the 3-layer stack (orchestrator -> kazi -> cheap harness; kazi friendly in both directions, ADR-0023) as the canonical positioning.  Owner: pool  Done: 2026-06-23  verifies: [UC-035]  delivers: [updated concept positioning]  deps: []  acc: `docs/concept.md` describes the 3-layer stack without contradicting ADR-0001 (kazi is still the outer loop for the harness, AND a tool for the orchestrator).
- [~] T17.4 **[SUPERSEDED by T25.8 -- do NOT execute standalone; the agent-first quickstart is owned by E25/ADR-0030]** "Drive kazi from Claude Code" quickstart (works TODAY): a docs section + a top-of-README link giving the copy-paste recipe that runs on the SHIPPED JSON CLI -- `kazi propose --json` (caller-drafts) -> `kazi approve` -> `kazi run --harness <cheap> --json [--stream]` -> branch on `next_action` -- so a reader drives kazi from any agent BEFORE `install-skill` exists. Becomes the interim on-ramp for T17.1/T17.2.  Owner: TBD  Est: 1h  verifies: [UC-033, UC-035]  delivers: [a copy-paste agent recipe that works on today's CLI]  deps: [T15.8]  acc: a reader pastes the recipe into a Claude Code session and drives a fixture goal end to end on the current release; every command verified against `kazi help --json`.
- [~] T17.5 **[SUPERSEDED by T25.9 -- do NOT execute standalone; the OG card is owned by E25/ADR-0030]** Link-preview / OG card for sharing (adoption): render an OG/Twitter card that shows the agent on-ramp (not just the logo) so HN/X/Reddit shares preview the easy path; wire into `site/src/layouts/Layout.astro`.  Owner: TBD  Est: 1h  verifies: [UC-035]  delivers: [an OG image that previews the agent on-ramp]  deps: [T17.2]  acc: a link-preview check renders the new card; Lighthouse SEO stays >= 90; deployed live.

### E18 -- Bug fixes from the T15.9 token-benchmark dogfood (P2, no ADR)

Acceptance: the four defects surfaced while running the token benchmark
(`docs/devlog.md` 2026-06-24, "token benchmark (T15.9)") are fixed with regression
tests, so the run loop persists errored and terminal iterations without crashing
and the shipped example goal-file actually runs. These are reliability fixes to
DELIVERED capability (the convergence core + read-model that `kazi run --json` /
`status --json` build on); no ADR (bug fixes, per the ADR policy). T18.1-T18.4 are
independent (different files) and run in parallel; T18.5 verifies after.

- [x] T18.1 Fix the stale shipped example + add a runnability guard: in `priv/examples/deploy_target.toml` change the `test_runner` predicate from `cmd = "go test ./..."` (the whole command parsed as one executable -> `System.cmd` `{:cmd_unrunnable, :enoent}`) to `cmd = "go"`, `args = ["test", "./..."]`; audit every file under `priv/examples/` for the same multi-word-`cmd` antipattern and fix. Add an ExUnit test that loads each shipped example goal-file and asserts every `test_runner` predicate's `cmd` resolves via `System.find_executable/1` with `args` as a list.  Owner: solo  Done: 2026-06-24  verifies: [UC-024, infrastructure]  deps: []  acc: ExUnit -- each `priv/examples/*.toml` loads; no example uses a multi-word `cmd`; the guard fails if a future example reintroduces `cmd = "go test ./..."`; `mix format` clean.
- [x] T18.2 Deep-sanitize read-model evidence so errored predicates persist: `Kazi.ReadModel.serialize_vector/1` (`read_model.ex:550`) stores `evidence` verbatim, so an `:error` `PredicateResult` whose evidence holds a tuple (`reason: {:cmd_unrunnable, ...}`) or atom keys fails the `Iteration.predicate_vector` `:map` Ecto cast and `record_iteration/1` raises (observed in the benchmark). Make serialization JSON-safe (stringify atom keys; render tuples/non-encodable terms to strings) and preserve the deserialize round-trip (`read_model.ex:373`).  Owner: solo  Done: 2026-06-24  verifies: [UC-033, infrastructure]  deps: []  acc: ExUnit -- recording an iteration whose vector has an `:error` result with tuple evidence returns `{:ok, _}` (no raise) and round-trips to a JSON-safe map; existing `:pass`/`:fail` serialization stays byte-compatible.
- [x] T18.3 Make terminal/budget-stop iteration persistence idempotent: the loop's per-iteration callback AND the terminal/budget-stop callback both persist the SAME `(goal_ref, iteration_index)`, so the second insert hits `iterations_goal_ref_iteration_index_index` ("has already been taken") and is logged as a failure (observed in the benchmark). Either skip re-recording an already-recorded index or use `Repo.insert(..., on_conflict: {:replace, [...]}, conflict_target: [:goal_ref, :iteration_index])` so the terminal state upserts.  Owner: solo  Done: 2026-06-24  verifies: [UC-033, infrastructure]  deps: []  acc: ExUnit -- a run that fires the terminal/budget-stop callback persists each `iteration_index` exactly once with the final state; no unique-constraint error is logged; a deliberate double-record is an idempotent upsert, not a crash.
- [x] T18.4 Reproduce + close the over-budget CLI crash: with `max_iterations = 1` on an unconvergeable fixture goal, confirm whether `Kazi.CLI.run_goal/4` still raises `CaseClauseError` on the `{:ok, %{outcome: :over_budget, reason: :max_iterations, ...}}` result (observed during the benchmark). `cli.ex:544` now HAS an `:over_budget` clause, so this may already be fixed by T15.3 -- if it reproduces, fix the case; either way add a regression test.  Owner: solo  Done: 2026-06-24  verifies: [UC-033]  deps: [T18.2]  acc: ExUnit/CLI -- an over-budget run prints the over-budget verdict, exits 1, raises nothing; under `--json` it emits the versioned `over_budget` result object; a regression that drops the clause fails the test.
- [x] T18.5 Re-verify on the benchmark fixture + lint: after T18.1-T18.4, re-run the code-only benchmark goal (a broken Go fixture, `mix kazi.run`) end to end and confirm convergence with zero persistence warnings, plus an over-budget variant exits cleanly. Run `mix format --check-formatted` and `mix compile --warnings-as-errors`. Record the clean re-run in `docs/devlog.md`.  Owner: solo  Done: 2026-06-24  verifies: [infrastructure]  deps: [T18.1, T18.2, T18.3, T18.4]  acc: a real `mix kazi.run` on the fixture converges with no `failed to persist` warning, no `:map` cast error, no unique-constraint log; format + warnings-as-errors clean; devlog updated.

### E19 -- Realize the unwired token-efficiency levers + measure (P2, ADR-0010)

Context: the token audit (`docs/devlog.md` 2026-06-23) + benchmark (2026-06-24)
found kazi adds ~0% overhead vs vanilla at single-dispatch, but the orientation
pack ships as a `.kazi/context.md` FILE the agent must READ rather than a stable
prompt PREFIX, and the live dispatch path renders evidence via raw `inspect/1`
(bypassing `truncate_evidence/2`). ADR-0010 decided prefix-injection (T4.3) +
caching; the prefix path (`Kazi.Harness.Prompt.build_prompt/3`) is built and tested
but the live loop's `dispatch_prompt/2` (`loop.ex:1208`) does not call it. KEY
CONSTRAINT: kazi drives `claude -p` as a SUBPROCESS and makes no raw Anthropic API
calls, so it CANNOT set `cache_control` headers; the caching win is realized by
making the injected prefix BYTE-STABLE across iterations so the inner harness's OWN
prompt cache (5-min TTL) hits across kazi's separate dispatches (ADR-0010 already
frames caching as stable-prefix-dependent -- no new ADR). The multi-iteration
benchmark TESTS whether the wiring is net-positive (the prefix adds per-dispatch
input tokens; the win is fewer orientation tool-calls + cross-iteration cache hits)
-- a hypothesis to MEASURE, not assume; T19.5 may recommend reverting if C is not a
net win.

- [x] T19.1 Wire the cached orientation pack into the live dispatch prompt (realize T4.3): route `dispatch_prompt/2` (`loop.ex:1208`) through `Kazi.Harness.Prompt.build_prompt/3`'s prefix path (or prepend `Kazi.Context.cached_orientation_pack/4` output) so each stateless dispatch carries the ranked blast-radius pack as a prefix, keeping the failing-evidence + working-set-digest sections. Keep `.kazi/context.md` as the fallback for file-reading harnesses.  Owner: pool  Done: 2026-06-24  verifies: [UC-033, infrastructure]  deps: [T18.2]  acc: ExUnit -- a dispatch on a fixture with a graph/repo-map injects the orientation pack as a prefix; the prefix is byte-identical for the same `(workspace, git-SHA, failing-set)` across iterations; evidence + digest sections still present; nil-workspace/no-graph degrades to today's prompt.
- [x] T19.2 Stable-prefix discipline for inner-harness cache hits: front-load the prompt (orientation + work-item first, volatile evidence/digest last) and keep ordering deterministic so the inner harness's own prompt cache maximally hits across successive `claude -p` dispatches within the TTL. (kazi sets no `cache_control` -- it drives a CLI; this is purely prefix stability.) Document the constraint at the `build_prompt` seam.  Owner: pool  Done: 2026-06-24  verifies: [UC-033, infrastructure]  deps: [T19.1]  acc: ExUnit -- for two iterations with the same failing-set + SHA the prompt's leading bytes (orientation + work-item) are identical; reordering volatile sections does not perturb the stable head; a moduledoc note records the subprocess-cache rationale (ADR-0010).
- [x] T19.3 Use `truncate_evidence/2` on the live dispatch path: `dispatch_prompt/2` renders evidence via raw `inspect/1`, so large evidence bypasses the T4.8 cap. Render evidence through `Kazi.Harness.Prompt.truncate_evidence/2` (default 8 KiB, head+tail window) on the live path.  Owner: pool  Done: 2026-06-24  verifies: [UC-033, infrastructure]  deps: [T19.1]  acc: ExUnit -- a dispatch with oversized predicate evidence truncates to the cap with a head+tail window; small evidence is unchanged.
- [x] T19.4 Multi-iteration benchmark harness: build a repeatable bench (a `mix` task or script under `bench/`) that converges a fixture needing >=3 dispatches three ways -- (A) vanilla `claude -p` session, (B) kazi->claude WITHOUT the prefix (pre-T19.1 behavior behind a flag/config), (C) kazi->claude WITH the prefix + stable head (T19.1/T19.2) -- capturing per-dispatch input/output/cache-read tokens + cost via the harness shim (the docs/devlog.md 2026-06-24 method).  Owner: pool  Done: 2026-06-24 (harness built; live 3-arm run = T19.5)  verifies: [infrastructure]  deps: [T19.1, T19.2, T19.3]  acc: the bench runs all three arms on a real fixture and emits a per-arm token + cost + iteration table; the shim captures every dispatch; the method is documented and repeatable.
- [~] T19.5 **[SUBSUMED by T34.7 -- do NOT execute standalone; the multi-iteration benchmark is run by T34.7 with the economy envelope (ADR-0046), which reports cached-vs-fresh deltas + cost/converged-predicate]** Run the multi-iteration benchmark + record the verdict: run T19.4; compare B vs C (does the stable prefix raise cross-dispatch cache_read / cut cost, and do fewer orientation tool-calls offset the added prefix tokens?) and A vs C (kazi vs vanilla over multiple iterations). Record honest numbers + the net verdict in `docs/devlog.md`; if C is NOT a net win, say so and recommend keeping file-based orientation.  Owner: TBD  Est: 1h  verifies: [UC-033, infrastructure]  deps: [T19.4]  acc: a `docs/devlog.md` entry with the A/B/C multi-iteration table, the B-vs-C cache-hit delta, and a clear keep/revert recommendation for the prefix wiring; honest if inconclusive.
- [x] T19.6 Enable `--model` on the `claude` profile (ADR-0033 enabler): add `:model` to the `claude` profile's `supported_opts` and append `--model <m>` in `build_args` so `kazi apply --harness claude --model <cheap-claude>` selects a cheaper Claude model (Haiku/Sonnet). This unlocks in-family tiering with NO local model.  Owner: TBD  Est: 1h  verifies: [UC-043, UC-032]  deps: []  acc: ExUnit -- `build_args` appends `--model <m>` when given; `kazi apply --harness claude --model claude-haiku-4-5` resolves + passes the model to `claude -p`; absent `--model` the argv is byte-identical to today (back-compat); golden-transcript test updated.
- [ ] T19.7 Benchmark the in-family Claude-tiering cost arm (ADR-0033/0035, the headline cost-proof): extend the T19.4 harness with THREE cost arms -- (a) vanilla-frontier baseline; (b) STATIC tier: a frontier model (Opus) authors predicates ONCE via `kazi plan`, then `kazi apply --harness claude --model <cheap-claude>` drives a >=3-dispatch grind; (c) ESCALATING tier (ADR-0035): start on the cheapest model and step up the ladder (Haiku->Sonnet->Opus) on a kazi-reported stuck signal. Capture real $/tokens AND the convergence rate + correctness per arm (a cheaper-but-fails or always-escalates-to-frontier result must be visible). Record the verdict in `docs/devlog.md`.  Owner: TBD  Est: 2.5h  verifies: [UC-043, UC-045, UC-033]  deps: [T19.6, T19.4, T30.2]  acc: a `docs/devlog.md` table comparing vanilla-frontier vs static-cheap-grind vs escalating-grind on $/tokens/iterations AND convergence/correctness; honest if a tier fails to converge or collapses to always-frontier; local-Qwen arm noted as the secondary (privacy) comparison.

### E20 -- kazi UNDER /apply --pool: objective-done + coordination + observability beneath pooled sessions (P1, ADR-0026)

The operator runs several Claude Code sessions on one tree via `/loop /apply --pool`,
picking tasks from this plan with `/claim` git-ref locks. That workflow is a
hand-rolled kazi; ADR-0026 integrates kazi UNDER each pool session (shape a) to
harden its documented failure modes (session-asserted/false "done", ~5/10 wave
stalls, silent logical conflicts) WITHOUT replacing `/apply --pool`. Adoption is
LAYERED: L1 verification gate -> L2 objective-done loop per task -> L3 blast-radius
leasing across sessions (NATS) -> L4 shared observability + phone direction. L1-L2
need git-refs only; NATS (ADR-0004) is required only at L3.

Bridge: `/claim` stays the OUTER coordination (task selection); kazi's blast-radius
leases (`Kazi.Partition.partition/3` + `Kazi.Coordination.PartitionLease.lease_keys/3`,
ADR-0006) are the INNER coordination. The authoring bridge is caller-drafts
(`kazi propose --json --predicates <json>`, ADR-0023) turning a task's `acc:` line
into predicates; `kazi run --json` is the objective-done gate. No new authoring path;
ADR-0001 intact (kazi is the inner controller beneath the session-as-orchestrator).

- [x] T20.1 `acc:` -> predicates bridge (L1): a documented procedure + a thin helper (a script under `priv/` or a `kazi` flag) that converts a plan task's `acc:` line into a caller-drafts predicates JSON suitable for `kazi propose --json --predicates`. Deterministic, hermetic.  Owner: pool  Done: 2026-06-24  verifies: [UC-036]  deps: []  acc: ExUnit on fixture tasks -- an `acc:` line yields a parseable predicates payload that `propose --json --predicates` accepts (floor applied, no inner model spawned); same input -> same output.
- [x] T20.2 Pool verification-gate recipe (L1): a repo-side recipe (`docs/` + an `AGENTS.md` addition) for a pool session to run `kazi run --json` on its task's predicates BEFORE merge and BLOCK the merge unless `converged`; on `stuck`/`over_budget` it escalates (does not merge). Works git-refs only (no NATS).  Owner: pool  Done: 2026-06-24  verifies: [UC-036, UC-033]  deps: [T20.1, T15.8]  acc: a documented, copy-pasteable gate a session runs pre-merge; a fixture non-converged task is BLOCKED with a clear reason; a converged one passes; every command verified against `kazi help --json`.
- [ ] T20.3 Opt-in kazi gate in the GLOBAL `/apply` skill (L1, cross-repo, enhance-globally): add `/apply --verify-with-kazi` that, after a task's work, runs the T20.2 gate; OFF by default; the skill stays global (`~/.claude/skills/apply`), not project-local. Keep it in sync with kazi via `kazi help --json`.  Owner: TBD  Est: 1.5h  verifies: [UC-036, infrastructure]  deps: [T20.2]  acc: `/apply --verify-with-kazi` blocks a merge when kazi is non-converged and is a no-op without the flag; the skill references only real kazi commands; documented as cross-repo.
- [x] T20.4 "Drive kazi for a pooled task" orchestrator recipe (L2): the full per-task loop -- `kazi propose --json --predicates` (caller-drafts) -> `approve` -> `run --json [--stream]` -> branch on `next_action` -- so a session drives kazi to objective done with the loop's guards (stuck/regression/flake/budget), not a single pass. Reuses T15.8/T17.4.  Owner: pool  Done: 2026-06-24  verifies: [UC-036, UC-033]  deps: [T20.1]  acc: a session drives a fixture task end to end via the recipe on the current release; a deliberately-insufficient first dispatch is RE-dispatched by the loop, not merged; honest result.
- [x] T20.5 Per-task model tiering (L2, optional): run the inner loop on a cheap/local harness (`--harness opencode/claw --model <local>`) so the pool runs cheaper; objective predicates keep the cheap model honest. HONEST about local-model speed (devlog T8.11/2026-06-24).  Owner: pool  Done: 2026-06-24  verifies: [UC-036]  deps: [T20.4]  acc: a documented tiered invocation; a fixture task converges via a cheap harness OR an honest "wiring proven, too slow" note (like the opencode smoke); no false convergence claim.
- [x] T20.6 Per-task blast-radius lease for a pooled run (L3, NATS): a pool session acquires a kazi lease for its task's blast radius (`Kazi.Partition.partition/3` -> `PartitionLease.lease_keys/3`) BEFORE editing; overlapping radii serialize, disjoint run free. Lease is scoped to the run and released on terminal state.  Owner: pool  Done: 2026-06-24  verifies: [UC-036]  deps: [T20.4]  acc: ExUnit + a 2-session sim -- two tasks with overlapping blast radii serialize on the lease; disjoint radii proceed concurrently; lease released on converged/stuck/over_budget; requires a running NATS (skips honestly without one).
- [x] T20.7 `/claim` <-> kazi-lease compose-boundary + deadlock safety (L3): document and TEST the contract -- claim (task) acquired first, then the kazi blast-radius lease; lease TTL bounds a crashed holder; release ordering (lease before claim) -- so two sessions each holding a claim + a lease cannot deadlock.  Owner: pool  Done: 2026-06-24  verifies: [UC-036, infrastructure]  deps: [T20.6]  acc: ExUnit -- a constructed cross-acquire scenario does not deadlock (TTL/ordering breaks it); the contract is documented in `docs/` and referenced by the recipe.
- [ ] T20.8 Live pool observability (L4): point the LiveView dashboard + presence + lease map at a shared kazi instance so every session's leases + per-goal convergence history are visible in real time; verify in a browser against a live 2+ session pool.  Owner: TBD  Est: 1.5h  verifies: [UC-036]  deps: [T20.6]  acc: the dashboard shows >=2 concurrent sessions' leases + convergence live; exercised in a real browser (agent-browser); read-only, decoupled from the loop (ADR-0011).
- [~] T20.9 WITHDRAWN (ADR-0029): phone-driven pool via Telegram is redundant -- the orchestrating agent (Claude) is the human's mobile interface, and the agent's own push pings the phone on terminal states. The Telegram bridge is being REMOVED (E24); a headless-autonomous pinger, if ever needed, is a future generic webhook, not Telegram.
- [ ] T20.10 "Harden /apply --pool with kazi" guide (docs): a `docs/` guide covering the 4 layers, the `/claim`<->lease boundary, NATS-only-at-L3, the failure modes it fixes (false-completion, 5/10 stall, silent logical conflict), and honest maturity (shape b deferred).  Owner: TBD  Est: 1.5h  verifies: [UC-036]  deps: [T20.3, T20.7, T20.8]  acc: a reader can adopt L1 today and understand the path to L3/L4; references only real commands/modules; coherent with ADR-0026.
- [ ] T20.11 LIVE dogfood (the honest proof): run a REAL multi-session `/apply --pool` with kazi as the L1 gate on a real plan slice (e.g. the E18 bug fixes); record evidence -- did the gate BLOCK a non-converged task? -- in `docs/devlog.md`. After L3, extend to a leasing dogfood (two sessions, overlapping blast radius, serialized).  Owner: TBD  Est: 2h  verifies: [UC-036]  deps: [T20.3]  acc: observed evidence in `docs/devlog.md` that the kazi gate caught (or cleanly passed) real pooled tasks; every claim is observed, not asserted; honest if a layer was skipped.

> **Note (ADR-0027):** E20 is the INTEROP story (kazi as a good citizen under an
> existing external orchestrator). The PRIMARY parallelization story is now **E21**
> below -- kazi's own native scheduler -- which codifies `/apply --pool` + `/claim`
> INTO kazi so new users need no personal skills.

### E21 -- kazi owns parallelization: a native scheduler over a partitioned goal-set (P1, ADR-0027)

This codifies the third and final piece of the founding workflow. kazi already
codified the Definition of Done (predicates) and the per-task loop (reconcile), and
built the parallelization SUBSTRATE (`Kazi.Partition` blast-radius partitioning +
`PartitionLease` leases, ADR-0006) -- but never the SCHEDULER that spawns and drives
the parallel agents. That scheduler lived in the operator's `/apply --pool` +
`/claim`. E21 builds it INTO kazi so `kazi run` on a goal-set parallelizes itself --
no external orchestrator, no personal skills.

Design (ADR-0027): partition by blast radius -> lease each partition -> spawn one
supervised reconciler (the existing serial per-goal loop) per partition under a
`DynamicSupervisor`, each in its own git worktree -> drive to COLLECTIVE convergence
-> integrate with merge convergence -> observe/escalate via the dashboard. SINGLE-NODE
IS NATS-FREE (in-memory lease `Kazi.Coordination.Lease.Memory`); NATS is the
multi-machine upgrade only. Single-goal stays the serial simple on-ramp; parallelism
is opt-in scale. The serial-single-goal design is unchanged -- parallelism is ACROSS
partitions, each its own serial reconciler.

- [x] T21.1 Parallel scheduler + `DynamicSupervisor` skeleton: a coordinator process that, given a partitioned goal-set, starts one supervised reconciler per partition, tracks each terminal state, and reports COLLECTIVE status (all `converged` / any `stuck` / any `over_budget`). In-memory lease (single-node, NATS-free).  Owner: pool  Done: 2026-06-24  verifies: [UC-037]  deps: []  acc: ExUnit with stub reconcilers -- N partitions start under the supervisor, run concurrently, and the coordinator reports the correct collective verdict; a single-partition goal-set behaves exactly like today's serial run.
- [x] T21.2 Wire `Kazi.Partition` into the scheduler: partition the goal-set by blast radius (graph/repo-map `graph_source`) into disjoint partitions, one per reconciler; degenerate to one partition when there is a single goal or no graph.  Owner: pool  Done: 2026-06-24  verifies: [UC-037]  deps: [T21.1]  acc: ExUnit -- a multi-goal set with disjoint blast radii yields >=2 partitions each driven concurrently; overlapping radii collapse into one partition (serialized); same input -> same partitioning.
- [x] T21.3 Per-partition lease lifecycle: each reconciler acquires its `PartitionLease` on start and releases on terminal; the in-memory backend is the single-node default, the NATS backend is config-selected for multi-node; residual mid-run overlap serializes on the lease.  Owner: pool  Done: 2026-06-24  verifies: [UC-037]  deps: [T21.1]  acc: ExUnit -- concurrent partitions hold distinct leases; a forced overlap serializes; a crashed reconciler's lease frees via TTL; no NATS needed for the memory backend.
- [x] T21.4 Isolated git worktree per partition: each parallel fixer works in its own worktree (concept sec 9), created on start and removed on terminal; honor the worktree-guard landmine (never `rm -r` a cwd worktree).  Owner: pool  Done: 2026-06-24  verifies: [UC-037]  deps: [T21.1]  acc: ExUnit/integration on a fixture repo -- N reconcilers edit in N worktrees without touching each other's tree; worktrees are cleaned up on every terminal path (converged/stuck/over_budget/crash).
- [x] T21.5 Collective integration + merge convergence: after partitions converge, integrate each (branch -> PR -> rebase-merge) in a safe order; detect residual cross-partition conflicts and re-dispatch the affected partition until the merged whole is green.  Owner: pool  Done: 2026-06-24  verifies: [UC-037]  deps: [T21.4]  acc: ExUnit/integration -- two disjoint partitions both merge clean; an injected cross-partition conflict is detected and the affected partition re-dispatched, not silently merged.
- [x] T21.6 Dynamic blast-radius overlap policy: when a partition's edits expand its radius into another's (a lease conflict mid-run), serialize the overlapping pair (or re-partition); documented + tested so growth never corrupts a sibling.  Owner: pool  Done: 2026-06-24  verifies: [UC-037]  deps: [T21.3]  acc: ExUnit -- a partition that grows into a neighbor's radius blocks on the lease and proceeds only when free; no two reconcilers edit the same file concurrently; the policy is documented.
- [x] T21.7 Per-partition budgets (derived rollup, ADR-0020/E12): split the goal budget across partitions; a partition going over-budget ESCALATES without killing siblings; the collective verdict reflects per-partition outcomes.  Owner: pool  Done: 2026-06-24  verifies: [UC-037, UC-030]  deps: [T21.1]  acc: ExUnit -- per-partition budgets sum to the goal budget; one partition's `over_budget` does not stop the others; the collective report names which partition escalated.
- [x] T21.8 CLI + `--json` collective contract: `kazi run --parallel [N]` (or auto from a multi-partition goal-set) drives the scheduler; `--json` emits a versioned collective result (per-partition status + overall + `next_action`); non-interactive/non-TTY safe (ADR-0022/0023).  Owner: pool  Done: 2026-06-24  verifies: [UC-037, UC-033]  deps: [T21.1]  acc: ExUnit -- `--parallel` runs the scheduler; `--json` yields a parseable collective object with each partition's verdict + the overall status + `schema_version`; serial single-goal output is unchanged.
- [ ] T21.9 Live dashboard for the parallel run: the LiveView console shows the N partition reconcilers + their leases + per-partition convergence in real time (extends the multi-goal dashboard); verified in a browser against a live native-parallel run.  Owner: TBD  Est: 1.5h  verifies: [UC-037]  deps: [T21.1]  acc: the dashboard shows >=2 concurrent partition reconcilers + leases + convergence live; exercised with agent-browser; read-only, decoupled from the loop (ADR-0011).
- [x] T21.10 Supervision/restart + escalation: a crashed partition reconciler restarts (or escalates `stuck`) WITHOUT corrupting lease or worktree state; the coordinator survives a child crash.  Owner: pool  Done: 2026-06-24  verifies: [UC-037, infrastructure]  deps: [T21.3, T21.4]  acc: ExUnit -- killing a child reconciler triggers clean restart-or-escalate; its lease frees and worktree is reconciled; siblings are unaffected; the coordinator never crashes on a child failure.
- [ ] T21.11 Docs + positioning (native parallelism is the headline): README/concept/site present kazi as the native parallel reconciler ("kazi parallelizes your plan -- no external orchestrator; single machine, no NATS"); `/apply --pool` (E20) is shown as interop. Coherent with E17/ADR-0025 + ADR-0027.  Owner: TBD  Est: 1.5h  verifies: [UC-037, UC-035]  delivers: [docs/site that lead the parallel story with kazi-native, interop as secondary]  deps: [T21.8]  acc: a newcomer sees "kazi parallelizes for you" (no personal skills); `/apply --pool` is clearly the interop path; canonical strings + coherence (T9.9) intact.
- [ ] T21.12 LIVE dogfood (the proof): run kazi natively-parallel on a real multi-partition goal in THIS repo on one machine (NATS-free) -- several independent fixes converged concurrently in isolated worktrees, then merged. Record evidence in `docs/devlog.md`: partition count, concurrency observed, collective convergence, merge result; honest if it falls short.  Owner: TBD  Est: 2.5h  verifies: [UC-037]  deps: [T21.5, T21.8]  acc: observed evidence of >=2 partitions converging concurrently under one kazi run with no external orchestrator and no NATS; every claim observed, not asserted.

### E22 -- Pre-publish documentation refresh: README + docs + website reflect the FINAL shipped product (P1, ADR-0025/0018; content + engineering)

The launch documentation pass. ASSUMES all feature + ADR work has LANDED before
publishing: E15 (agent-drivable JSON CLI), E16 (skill/MCP/self-teaching), E17
(adoption-first IA), E18 (benchmark bug fixes), E19 (token-efficiency wiring), E20
(/apply --pool interop), E21 (native parallelization). At that point the README,
`docs/`, and website are refreshed to reflect the COMPLETE product accurately and
publishably: every shipped capability documented, every "coming" tag flipped to
"available" (no vaporware -- everything is real by now), native parallelization is
the headline parallel story, coherence/version/links audited, deployed + verified
live. Builds ON E17 (does NOT redo T17.x); adds full coverage + the launch gate.

Acceptance for the epic: a newcomer landing on the README or `kazi.sire.run` can
understand and adopt the full product (agent on-ramp, native parallelism, objective
done, BYOM) with every command real; `mix`/coherence/Lighthouse checks green;
deployed live; nothing documents an unshipped feature.

- [ ] T22.1 Feature-coverage audit (the map): enumerate every shipped capability from the use-case manifest (UC-001..UC-037) + ADRs 0001-0027 and map each to where it MUST appear (README section / `docs/` file / website section); produce a coverage matrix and flag gaps. Gates the rest of E22.  Owner: TBD  Est: 1.5h  delivers: [a doc-coverage matrix: capability -> README/docs/site location, with gaps]  deps: [E15, E16, E18, E19, E20, E21]  acc: a committed matrix in `docs/` (or the devlog) covering every UC + ADR; each row marks present/missing across README, docs, site; the gap list seeds T22.2-T22.5.
- [ ] T22.2 README COVERAGE pass (build on T25.3; E17's T17.1 superseded): after the E25 README rewrite (T25.3) lands, ADD the native-parallelization section (E21: "kazi parallelizes your plan -- single machine, no NATS"), refresh the FULL CLI reference (all `--json` commands, `status`, `schema`, `help --json`, `run --parallel`, `install-skill`, `mcp`, propose caller-drafts), and FLIP every "coming" tag to "available". Do NOT re-theme or re-message (E25/T25.3 owns the lead). Canonical strings locked; coherence (T9.9) green.  Owner: TBD  Est: 1h  verifies: [UC-035, UC-037, UC-034]  deps: [T22.1, T25.3]  acc: README documents native parallelism + the complete CLI; no "coming" tags remain; every command verified against `kazi help --json`; canonical strings byte-identical; renders on GitHub; E25's lead/messaging left intact.
- [ ] T22.3 `docs/concept.md` update to the final architecture: reflect the NATIVE parallel scheduler (E21/ADR-0027) as the parallelization model -- supersede the "one process per goal / external launcher" framing -- plus the agent-drivable + self-teaching stack (E15/E16) and the 3-layer + `/apply --pool` interop (E20/ADR-0026).  Owner: TBD  Est: 1.5h  verifies: [UC-037, UC-033]  deps: [T22.1]  acc: `docs/concept.md` describes the native scheduler (partition -> lease -> supervised reconcilers -> merge), single-node-NATS-free, without contradicting ADR-0001; references ADRs 0023/0026/0027; no stale "external orchestrator only" claim.
- [ ] T22.4 `docs/` guide set complete + indexed: ensure the orchestrator recipe (T15.8), `install-skill` guide (T16.2), `AGENTS.md` (T16.3), the `/apply --pool` interop guide (T20.10), the native-parallelization guide (T21.11), and the JSON `docs/schemas` are present, accurate, and cross-linked from a `docs/README.md` index.  Owner: TBD  Est: 1.5h  verifies: [UC-033, UC-034, UC-036, UC-037]  deps: [T22.1]  acc: a `docs/` index links every guide; each guide references only real commands (checked against `kazi help --json`); no orphan/missing guide for a shipped capability.
- [ ] T22.5 Website COVERAGE pass (build on T25.4/T25.9; E17's T17.2/T17.5 superseded): on top of the E25 hero (T25.4) + OG card (T25.9), ADD a native-parallelization section + a feature overview reflecting the full set + the updated recipe/CLI; version sourced from the manifest; do NOT re-theme the hero; `site/src/canonical.mjs` + coherence in lockstep; deploy + verify live.  Owner: TBD  Est: 1.5h  verifies: [UC-035, UC-037]  deps: [T22.2, T25.4]  acc: the site carries native parallelism + the full feature set ON TOP of E25's hero (left intact); README<->site coherence (T9.9) green; Playwright smoke (T9.5) passes incl. mobile + the new sections; deployed + verified live at https://kazi.sire.run.
- [ ] T22.6 Docs-presentation decision (+ optional `/docs` on the site): decide whether `docs/` stays repo-only or gets a rendered `/docs` section on `kazi.sire.run` (Ruff-style); if rendered, build it from the `docs/` guides. Write an ADR if the choice is non-trivial.  Owner: TBD  Est: 2h  verifies: [UC-035]  deps: [T22.4, T22.5]  acc: a recorded decision (plan note or ADR); if a `/docs` section is built, it renders the guides, is linked from the nav, and deploys live; if repo-only, the README/site clearly point to `docs/`.
- [ ] T22.7 Accuracy + coherence + freshness audit (the no-vaporware gate): every command shown across README/docs/site verified against `kazi help --json`; the README<->site coherence check green; version current; no dead links; the proof-of-convergence visual still matches real output; the skill/`AGENTS.md` coherence (T16.4) green.  Owner: TBD  Est: 1.5h  verifies: [UC-035, infrastructure]  deps: [T22.2, T22.3, T22.4, T22.5]  acc: a CI/script pass reports zero unshipped-command references, zero coherence failures, zero dead links, current version; a regression (a doc naming a non-existent command) fails the check.
- [ ] T22.8 Launch checklist + publish (the done gate): a final checklist (every UC documented, all "coming" flipped, coherence + audit green, deployed live, OG renders, README renders on GitHub) and the publish -- merge -> deploy -> verify live at https://kazi.sire.run + the README on GitHub.  Owner: TBD  Est: 1h  verifies: [UC-035]  deps: [T22.6, T22.7]  acc: the checklist is fully green and recorded; the site is live with the final docs; the README renders correctly on GitHub; reported honestly (any skipped item flagged, not hidden).
- [ ] T22.9 Launch announcement content (adoption push, optional): a short launch blog/announcement + social copy (HN/X/Reddit) reflecting the final feature set and the agent on-ramp, for the star/adoption push.  Owner: TBD  Est: 1.5h  delivers: [a launch announcement draft + social copy]  deps: [T22.8]  acc: a drafted announcement leads with the agent on-ramp + native parallelism + objective done; every claim matches the shipped product; ready for the operator to post.

### E23 -- Dependency-aware partitioning: predicate-graph waves (P2, ADR-0028)

The fourth axis that lets kazi COMPUTE the operator's `/plan` `deps:` + `/apply`
Waves instead of the operator hand-authoring them. kazi already has objective done
(ADR-0002), spatial parallelism (blast-radius partitioning, ADR-0006), and the
native scheduler (ADR-0027) -- but NO semantic ordering: it cannot sequence "group B
after group A" when B logically depends on A's output. E23 adds a dependency DAG over
predicate groups (extends the ADR-0020 `[[group]]` taxonomy with `needs` edges) and
makes the scheduler execute it TOPOLOGICALLY -- blast-radius parallelism inside each
frontier, objective-convergence as the gate, pipelined (a group runs the moment ITS
deps converge, no global barrier). Builds on E12 (taxonomy) + E21 (scheduler); no new
loop. The irreducible input is the authored `needs` edges (semantic precedence is
human/LLM judgment; kazi computes everything downstream).

- [x] T23.1 `needs` dependency edges in the group taxonomy (loader): extend the `[[group]]` entry (ADR-0020) with an optional `needs = ["group-id", ...]` "must-converge-before" edge set, DISTINCT from `parent` (budget rollup only). Validate at load: every `needs` id exists, no self-edge, no cycle over `needs`; `needs` absent = fully parallel (ADR-0027 default).  Owner: pool  Done: 2026-06-24  verifies: [UC-038]  deps: [T12.1, T12.2]  acc: ExUnit -- a goal-file with `needs` loads a validated edge set; an unknown id / self-edge / cycle is a load error; a goal with no `needs` is unchanged (backward compatible).
- [x] T23.2 Dependency DAG + ready-set computation (pure): from `needs` edges + each group's convergence state, compute the READY SET (groups whose every `needs` dep has OBJECTIVELY converged) and identify blocked/unsatisfiable sub-DAGs. Pure, deterministic, no I/O.  Owner: pool  Done: 2026-06-24  verifies: [UC-038]  deps: [T23.1]  acc: ExUnit -- ready set is correct as convergence state advances; a blocked dep removes its dependents from ready; topological order is respected; deterministic.
- [x] T23.3 Topological + spatial scheduling, pipelined (extends ADR-0027 coordinator): the scheduler dispatches only ELIGIBLE groups (the ready set), partitions that set by blast radius (T21.2), runs partitions concurrently, and RE-EVALUATES the ready set as each group converges -- newly-eligible groups dispatch immediately (no global barrier).  NOTE: authoring serialize_group/1 does not yet emit `needs` (T23.1 follow-up) -- if a needs-bearing goal must round-trip through propose/approve persistence, add `needs` to serialize_group + a round-trip test here.  Owner: pool  Done: 2026-06-24  verifies: [UC-038]  deps: [T23.2, T21.1, T21.2]  acc: ExUnit + sim -- a DAG with `A -> {B,C}` runs B and C only after A converges, B and C concurrently if disjoint; a downstream group starts the instant its deps converge, not when a sibling does; single-goal/no-`needs` behaves like ADR-0027.
- [x] T23.4 Objective re-gating on regression: a converged dep that later REGRESSES (the regression guard fires) re-gates its dependents -- they return to not-ready and re-converge; the DAG is re-evaluated against observed state each cycle.  Owner: pool  Done: 2026-06-24  verifies: [UC-038]  deps: [T23.3]  acc: ExUnit -- forcing a converged dep back to failing pauses/re-runs its dependents; once the dep re-converges, dependents resume; no dependent merges against a regressed dep.
- [x] T23.5 Blocked-dependency escalation: if a dep group goes `stuck`/`over_budget`, its dependents can never become ready -- escalate the affected sub-DAG and NAME the blocking dep in the collective report (don't hang silently).  Owner: pool  Done: 2026-06-24  verifies: [UC-038]  deps: [T23.3]  acc: ExUnit -- a stuck dep yields a collective verdict that names it and the blocked dependents; the scheduler does not hang; siblings outside the sub-DAG still finish.
- [x] T23.6 CLI + `--json` schedule reporting + dry-run: the collective result (T21.8) reports per-group readiness/convergence + the topological order taken + any blocked sub-DAG; add a `kazi run --explain` (or `--dry-run`) that PRINTS the computed wave/partition schedule without executing, so over-constraint is visible.  Owner: pool  Done: 2026-06-24  verifies: [UC-038, UC-033]  deps: [T23.3, T21.8]  acc: ExUnit -- `--json` includes the schedule + per-group state; `--explain` prints the frontier order + the parallelism within each frontier without dispatching; non-TTY safe.
- [ ] T23.7 Dashboard: live dependency-DAG view -- which groups are running / ready / blocked / converged, the edges, and per-group convergence; the live "wave" view.  Owner: TBD  Est: 1.5h  verifies: [UC-038]  deps: [T23.3]  acc: the dashboard renders the DAG with live per-group state during a real run; exercised with agent-browser; read-only (ADR-0011).
- [x] T23.8 Docs + positioning: document "predicate-graph waves" as kazi's codification of `/plan`'s `deps:` + `/apply`'s Waves -- authored `needs` edges -> computed, pipelined, objectively-gated schedule; honest about the authored-deps burden + that kazi does not DERIVE semantic order. Tie to E12/E21/E22 + ADR-0028.  Owner: TBD  Est: 1h  verifies: [UC-038, UC-035]  delivers: [docs explaining predicate-graph waves vs /apply waves]  deps: [T23.6]  acc: a reader sees how to express deps as `needs` and what kazi computes from them; references only real commands/fields; coherent with ADR-0028.
- [ ] T23.9 LIVE dogfood: encode a real multi-group goal with `needs` (e.g. a result-contract group before a streaming group) and show kazi computing + executing the pipelined topological schedule to collective convergence; record evidence in `docs/devlog.md` (order taken, intra-frontier parallelism, a blocked-dep escalation).  Owner: TBD  Est: 2h  verifies: [UC-038]  deps: [T23.6]  acc: observed evidence that kazi sequenced dependent groups correctly AND parallelized disjoint ones, gated objectively; honest if it falls short.

### E24 -- Remove the Telegram bridge (P2, ADR-0029; cleanup)

Acceptance: the Telegram bridge is removed so the codebase matches the agent-driven
architecture (Claude is the human's mobile interface, ADR-0029). The LiveView
dashboard and the `Kazi.Authoring` write path (ADR-0011) are UNAFFECTED. There is
no Telegram-specific dependency, so `mix.exs` does not change; `mix test` stays
green (the suite shrinks only by the Telegram tests). Removing a now-dead surface
is kazi's own no-dead-code thesis (ADR-0021) applied to itself.

- [x] T24.1 Remove the bridge modules + tests: delete `lib/kazi/telegram.ex`, `lib/kazi/telegram/client.ex`, `lib/kazi/telegram/message.ex`, `test/support/in_memory_telegram_client.ex`, `test/kazi/telegram_test.exs`, `test/kazi/telegram_e2e_test.exs`; remove any supervision-tree start/registration of the bridge in `lib/kazi/application.ex` + config.  Owner: pool  Done: 2026-06-24  verifies: [infrastructure]  deps: []  acc: the files are gone; `mix compile --warnings-as-errors` + `mix test` green (suite shrinks by the Telegram tests, nothing else breaks); no dangling references (grep for `Kazi.Telegram` is clean outside the ADRs).
- [x] T24.2 Scrub Telegram from moduledocs + docs + surfaces: remove the "Telegram" surface mentions in `Kazi.Authoring`, `Kazi.ReadModel`, `lib/kazi/authoring/draft.ex`, `lib/kazi/read_model/proposed_goal.ex` moduledocs; drop Telegram from the operator-surfaces list in `docs/concept.md`, `README.md`, and the site (KEEP the LiveView dashboard); the agent-driven on-ramp states the mobile interface is Claude.  Owner: pool  Done: 2026-06-24  verifies: [infrastructure]  deps: [T24.1]  acc: no "Telegram" reference remains except the historical ADR-0011/0029 records; README<->site coherence (T9.9) green; `mix format --check-formatted` + `--warnings-as-errors` clean.

### E25 -- Content-marketing refocus: lead with the agent-drives-kazi paradigm (P1, ADR-0030)

The research-grounded content rewrite. The shipped paradigm is "you CHAT with Claude
Code and the AGENT drives kazi" (the skill / `kazi mcp` / `--json` CLI -- E16 shipped),
but the README/site still LEAD with the legacy human -> kazi route. Deep research of
the fastest-growing OSS AI tools (docs/devlog.md 2026-06-24; ADR-0030) gives the
playbook: kazi's analogs are agent-FACING tools the user does not operate (Serena,
Context7) + Astral's proof discipline. This epic applies ADR-0030 to every surface.

It is the CANONICAL content epic: it SUPERSEDES the messaging in the still-open
E17 content tasks (T17.1/T17.2/T17.4/T17.5 -- which predate the research and the
shipped skill/mcp) and the README/site tasks of E22; execute those per ADR-0030
here. ADR-0025's lead-order (agent first, vanilla as reference) holds. No invented
features -- agent-driving (skill/mcp/`--json`) is REAL now; promised work labelled
"coming" (ADR-0025). Mixed content + engineering.

- [x] T25.1 Tagline -- DECIDED (operator 2026-06-24): the line-1 hook is **Your coding agent says "done." kazi proves it.** (the precise category -- "the outer/reconciliation loop for coding agents" -- is the second beat). No longer a choice; POOL wires it verbatim into `site/src/canonical.mjs` (hero tagline) + the README H1 in lockstep.  Done 2026-06-25 (PR #454; coherence gate extended to enforce HERO_TAGLINE; verified live at https://kazi.sire.run -- hero H1 byte-identical).  Owner: TBD  Est: 0.5h  verifies: [UC-039]  delivers: [the decided tagline wired into the canonical strings]  deps: []  acc: README H1 + the site hero render `Your coding agent says "done." kazi proves it.` byte-identically; canonical strings match (coherence T9.9 green); the precise category appears as the second line.
- [ ] T25.2 Hero asset -- the loop transcript -- DECIDED (operator 2026-06-24): RECORD A REAL CAST (no static fallback). Drive a real `claude -> kazi -> harness` run on a fixture (E18 shows clean runs work) with PREDICATES flipping false -> true ending at "goal objectively true"; capture as an asciinema cast + render an SVG/GIF. NEEDS A LIVE RUN (the operator or a live-capable session drives it; the headless pool likely cannot). This is kazi's benchmark-chart equivalent.  CONFIRMED LIVE BUG 2026-06-25: the CURRENT `proof-loop.svg` shows the REMOVED `kazi run my-goal.toml` verb on https://kazi.sire.run -- replacing the asset here also remedies that stale-verb bug (guarded going forward by T29.4).  Owner: TBD  Est: 2h  verifies: [UC-039]  delivers: [a REAL asciinema cast (+ rendered SVG) of the loop reaching objective-true]  deps: []  acc: the asset is a genuine recording of a real reconcile run (NOT a mockup), reused in README (above install) + site hero; the underlying cast file is committed so it is reproducible/verifiable; no stale `kazi run` verb remains in the rendered asset.
- [ ] T25.3 README rewrite to the paradigm (supersedes T17.1): lead = tagline (T25.1) -> hero transcript (T25.2) -> a "without kazi / with kazi" before-after block (Context7 device) -> "give your agent X" framing + the invocation phrase (T25.6) -> copy-paste wiring (the skill/`mcp` one-liner) -> agent-native social-proof row. Vanilla `kazi run` demoted to "Reference". No "coming" shown as working.  Owner: TBD  Est: 2h  verifies: [UC-039, UC-035]  delivers: [a README whose first screen sells the agent-drives-kazi paradigm]  deps: [T25.1, T25.2, T25.6]  acc: the first screen shows the agent paradigm + hero + before-after; human -> kazi appears only under "Reference"; every command verified against `kazi help --json`; coherence green; renders on GitHub.
- [ ] T25.4 Website rewrite to match (supersedes T17.2): hero = the transcript (T25.2) + the tagline; a primary "Chat with Claude Code, it drives kazi" section; without/with block; an agent-voiced testimonial (T25.5); two-layer proof (heavier on the site); vanilla demoted. Update `canonical.mjs` + coherence; deploy + verify live.  Owner: TBD  Est: 2.5h  verifies: [UC-039, UC-035]  delivers: [a website hero that leads with the agent paradigm]  deps: [T25.3, T25.5]  acc: hero + primary section render the agent paradigm + hero asset; README<->site coherence (T9.9) green; Playwright smoke (T9.5) passes incl. mobile + the new sections; deployed + verified live at https://kazi.sire.run.
- [x] T25.5 Agent-voiced testimonial(s) (Serena pattern, uniquely on-brand): capture a coding agent describing -- in its own words -- what kazi lets it do (e.g. "I stop claiming done when it isn't"); HONEST + labelled as agent-authored. Use on README social-proof row + site.  Done 2026-06-25 (PR #454; one Claude-authored testimonial, labelled agent-authored; renders on README + site, verified live).  Owner: TBD  Est: 1h  verifies: [UC-039]  delivers: [1-2 agent-authored testimonials, labelled]  deps: []  acc: the testimonial is clearly attributed to the agent that produced it; not fabricated human quotes; renders on both surfaces.
- [x] T25.6 The invocation phrase -- DECIDED (operator 2026-06-24): the phrase is **"have kazi drive this until done"** (Context7 "use context7" pattern). POOL: document it identically across README/site/skill (`kazi install-skill` SKILL.md)/`AGENTS.md`, and ensure the skill trigger recognizes it so it actually drives kazi.  Done 2026-06-25 (PR #454; phrase identical across README/site/skill/AGENTS.md; trigger wired into the install-skill SKILL.md description so it routes once installed; T16.4 coherence green).  Owner: TBD  Est: 1h  verifies: [UC-039, UC-034]  delivers: [the decided invocation phrase, documented + wired]  deps: []  acc: "have kazi drive this until done" appears identically across README/site/skill/`AGENTS.md`; a real Claude Code session given the phrase drives kazi (or honest "coming" if the trigger is not wired yet); coherence (T16.4) green.
- [ ] T25.7 Dogfood "done" leaderboard/gallery (the recurring growth engine): a page/section listing goals a prose pipeline left subtly broken that kazi converged -- built from the dogfood fixtures (T0.12/T1.8) + the live production probe -- with a REPRODUCIBLE methodology (the number must hold up; risk #1). Self-updating where feasible; each new fixture = a new entry.  Owner: TBD  Est: 2h  verifies: [UC-039]  delivers: [a dogfood "done" gallery/leaderboard page + methodology]  deps: []  acc: the page shows >=2 real converged cases with before/after evidence + a reproducible method; no unverifiable claims; linked from README + site.
- [x] T25.8 Docs quickstart-first (tutorial-then-reference): the first `docs/` page is a Quickstart that wires kazi into Claude Code (`install-skill`/`mcp`) and converges ONE real goal end-to-end via the agent; reference (predicate DSL, budget/stuck, `--json` schemas) follows. Cross-linked from a `docs/` index.  Done 2026-06-25 (PR #459; `docs/quickstart.md` + new `docs/README.md` index, tutorial-then-reference; invocation phrase consistent with T25.6; only real verbs (`kazi plan`/`apply`/`install-skill`), also fixed `kazi mcp`/`adopt` drift in existing docs; docs-fresh + leak gates green).  Owner: TBD  Est: 1.5h  verifies: [UC-039, UC-033]  delivers: [an agent-first Quickstart as the docs entry page]  deps: [T25.6]  acc: a reader follows the Quickstart and drives kazi from Claude Code end-to-end on the current release; reference pages follow; only real commands.
- [ ] T25.9 Launch kit + OG card (HN-first): an OG/Twitter card showing the agent paradigm (wire into `site/src/layouts/Layout.astro`); a Show HN title (`kazi - drive your coding agent in a loop until the goal is objectively true`) + post draft + an X thread, framed against "agents claim done but aren't"; honest, no unshipped command as working.  Owner: TBD  Est: 1.5h  verifies: [UC-039, UC-035]  delivers: [an OG card + a Show HN/X launch kit draft]  deps: [T25.3, T25.7]  acc: a link-preview check renders the card; the launch kit leads with the agent paradigm + a reproducible hook; Lighthouse SEO stays >= 90; ready for the operator to post.
- [ ] T25.10 Accuracy gate + live publish: every command across README/docs/site verified against `kazi help --json`; README<->site coherence (T9.9) + skill/`AGENTS.md` coherence (T16.4) green; version current; no dead links; deploy + verify live at https://kazi.sire.run and README renders on GitHub. Record the publish honestly.  Owner: TBD  Est: 1.5h  verifies: [UC-039, infrastructure]  deps: [T25.3, T25.4, T25.7, T25.8, T25.9]  acc: zero unshipped-command references; coherence green; live site shows the agent paradigm; README renders on GitHub; any skipped item flagged, not hidden.
- [ ] T25.11 "Token economy without local models" content (ADR-0033, the broad-appeal cost story): a README/site section + a worked example showing the in-family Claude tiering -- you chat with Claude Code, it drives kazi, EASY iterations run on a cheap Claude model (e.g. Haiku 4.5), HARD reasoning on a frontier model (e.g. Opus 4.8), and predicates keep the cheap model honest -- so any Claude Code user gets better token economy with NO local model / local GPU host. Frame local/BYOM (opencode) as the secondary PRIVACY option, and reference the ADAPTIVE escalation recipe (ADR-0035/E30: start cheap, escalate on stuck) as the smart default. HONEST: the cost number is "designed for / being measured" until T19.7 runs (no unproven figure); model ids checked against the claude-api reference.  Owner: TBD  Est: 1.5h  verifies: [UC-043, UC-045, UC-039]  delivers: [a "token economy without local models" section + a worked frontier->cheap-Claude example + a pointer to the escalation recipe]  deps: [T19.6, T30.1]  acc: README + site show the in-family tiering example (`kazi plan` with a frontier model -> `kazi apply --harness claude --model <cheap>`) and mention the escalate-on-stuck behavior; local/BYOM is the secondary privacy note; no unproven cost number stated; commands verified against `kazi help --json`; coherence (T9.9) green.
- [x] T25.12 Community + getting-help links (closes the all-stars.md growth-playbook gap #10, the last unaddressed item): the only fast-growing-OSS pattern still missing from kazi's surfaces. (a) Enable GitHub Discussions on `kazi-org/kazi` (a repo setting); if Discussions stays off, fall back to Issues. (b) README: add a one-line footer pointer -- "Questions? Start a [GitHub Discussion](.../discussions) | Read [concept.md](docs/concept.md) for the architecture". (c) Site: add a "Docs" (or "Community") nav link in `site/src/pages/index.astro` -- point it at `docs/concept.md` on GitHub until a rendered `/docs` exists (the T22.6 decision), plus a help link in the footer. Keep README<->site coherence (T9.9) green; update the Playwright smoke (T9.5) to assert the new nav link.  Owner: TBD  Est: 1h  verifies: [UC-039, UC-035]  delivers: [a Discussions/help link in the README footer + a Docs/Community nav + footer link on the site]  deps: []  acc: Discussions enabled (or an Issues fallback documented); README footer links to Discussions (or Issues) + concept.md; the site nav shows a Docs/Community link and the footer a help link, all resolving (HTTP 200); the Playwright smoke (T9.5) covers the new nav link; coherence (T9.9) green; deployed + verified live at https://kazi.sire.run.  Done 2026-06-25 (PR #467; README "Community & help" footer + site Docs nav + Discussions footer link; GitHub Discussions enabled; Pages deploy run 28148420990 success; verified live: root 200, Docs->concept.md 200, Discussions 200; Playwright 18 passed incl. 2 new assertions, T9.9 coherence green).

### E26 -- The kazi skill becomes a router: plan/apply/status/adopt (P1, ADR-0031)

Make kazi's day-to-day UX beat the operator's hand-assembled `loop -> plan -> apply
-> tidy -> qualify` pipeline by collapsing it onto the kazi skill. The five-skill
loop IS a reconcile loop; kazi now performs it natively (E21 scheduler + E23 waves +
objective predicates + standing mode). Restructure the GLOBAL `kazi` skill
(`~/.claude/skills/kazi/`) into a router whose sub-skill verbs match the operator's
vocabulary (plan/apply) and drive the real CLI commands underneath (propose/run);
`kazi apply` subsumes loop+apply+qualify for code goals; `/plan` is re-seated as the
intent layer that emits a goal-set; `/tidy` stays. Skill changes only -- no kazi CLI
rename (`kazi run` stays). Per the global-skills rule, enhance the skill in place.

- [x] T26.1 Router SKILL.md + dispatch: rewrite `~/.claude/skills/kazi/SKILL.md` (the one `kazi install-skill` writes) as a router that recognizes `plan`/`apply`/`status`/`adopt` and routes to the matching CLI. Document the skill-verb -> CLI-verb map (plan->`propose`, apply->`run`, status->`status`, adopt->`init`) and that `kazi run` is NOT renamed.  Owner: TBD  Est: 1.5h  verifies: [UC-040, UC-034]  delivers: [a router SKILL.md with the 4 sub-skills + verb map]  deps: []  acc: the skill recognizes the 4 sub-skill verbs and routes each to the correct real CLI command; references only commands `kazi help --json` reports; a non-kazi repo degrades cleanly ("use /plan + /apply").
- [x] T26.2 `kazi plan` sub-skill: author/refine a goal-set (predicates + `[[groups]]` + `needs` edges) via `kazi propose --json` caller-drafts (ADR-0023). When a `/plan` strategy doc exists, derive predicates from its `acc:` lines (the E20 T20.1 bridge); else draft from the idea. Holds for human approval.  Owner: TBD  Est: 1.5h  verifies: [UC-040, UC-033]  delivers: [a `kazi plan` sub-skill that emits a reviewable goal-set]  deps: [T26.1]  acc: `kazi plan "<idea>"` produces a parseable proposal via caller-drafts (no second model spawned), floor applied; documented to feed from a `/plan` doc when present; nothing runs pre-approval.
- [x] T26.3 `kazi apply` sub-skill (subsumes loop+apply+qualify): drive `kazi run [--parallel] [--standing] --json` to converge the goal-set via the native scheduler; parse the collective result; branch on `next_action`. Document that this replaces `/loop /apply --pool` + the qualify pass for code goals (objective predicates = the launch gate).  Owner: TBD  Est: 1.5h  verifies: [UC-040, UC-037]  delivers: [a `kazi apply` sub-skill that converges + objectively gates]  deps: [T26.1]  acc: `kazi apply` runs `kazi run` to a terminal verdict on the current release; the skill names the loop/apply/qualify subsumption + the `--explain` read-only gate; only real flags.
- [x] T26.4 `kazi status`/`watch` + `kazi adopt` sub-skills: `status` reports convergence from the read-model / opens the dashboard; `adopt` wraps `kazi init` to reverse-engineer a starter goal-set. Both reference only real commands.  Owner: TBD  Est: 1h  verifies: [UC-040]  delivers: [`status` and `adopt` sub-skills]  deps: [T26.1]  acc: `kazi status <ref>` returns persisted state (or the dashboard URL); `kazi adopt <repo>` produces a starter goal-set via `kazi init`; coherence-checked.
- [x] T26.5 Coherence + retire loop/qualify from the code on-ramp: extend the skill<->CLI coherence guard (T16.4) to the router's sub-skills; the kazi on-ramp (README/AGENTS.md/skill) no longer routes code goals to `loop`/`qualify` (kept as general skills for non-code). `/plan` + `/tidy` references re-seated per ADR-0031.  Owner: TBD  Est: 1h  verifies: [UC-040, infrastructure]  deps: [T26.2, T26.3, T26.4]  acc: the coherence test covers every sub-skill verb -> real command; the code on-ramp shows plan/apply/status/adopt, not loop/qualify; `/plan` is shown as the intent layer, `/tidy` as hygiene.
- [ ] T26.6 LIVE dogfood + subsumption gate: in a real Claude Code session, drive a fixture goal end-to-end through the router (`kazi plan` -> approve -> `kazi apply`) with NO `/loop`,`/apply`,`/qualify`; record evidence in `docs/devlog.md`. Assert the "`kazi apply` replaces `/apply --pool`" claim ONLY after the E21/E23 dogfoods (T21.12/T23.9) pass; otherwise mark it "coming" (ADR-0031 decision 6).  Owner: TBD  Est: 2h  verifies: [UC-040]  deps: [T26.5, T21.12, T23.9]  acc: observed evidence that the router drives a goal to objective done with no legacy skills; the subsumption claim is gated on the dogfoods; honest result.

### E27 -- Rename the CLI verbs: run -> apply, propose -> plan (P1, ADR-0032)

Unify the human/skill/CLI vocabulary: the CLI verbs become `apply` (was `run`) and
`plan` (was `propose`), so the word is the same at the agent prompt, the skill, and
the CLI. `run`/`propose` stay as DEPRECATED ALIASES (back-compat for the shipped
JSON contract + skill/MCP). Broad, mechanical, well-specified ENGINEERING work the
apply pool can execute autonomously -- and it refills the pool's queue (which was
starved of pure-code tasks). This SIMPLIFIES E26 (router verbs now equal CLI verbs
1:1; T26.1's verb-map becomes an identity + the alias note).

- [x] T27.1 CLI: `apply`/`plan` as primary verbs + `run`/`propose` as deprecated aliases: in `lib/kazi/cli.ex` add `apply`/`plan` parsing dispatching to the same handlers as `run`/`propose`; keep `run`/`propose` working but emit a one-line deprecation hint to STDERR (never into `--json` stdout). Unit tests: both new and old verbs resolve identically; `--json` stdout stays pure under the alias.  Owner: TBD  Est: 1.5h  verifies: [UC-041, UC-033]  deps: []  acc: ExUnit -- `kazi apply <goal>` and `kazi run <goal>` dispatch identically; `kazi plan "<idea>"` == `kazi propose "<idea>"`; the deprecation hint is stderr-only; `--json` output is unchanged + prose-free.
- [x] T27.2 `mix kazi.apply` task (+ `mix kazi.run` deprecated alias): add `Mix.Tasks.Kazi.Apply` delegating to the same entrypoint as `Mix.Tasks.Kazi.Run`; keep `mix kazi.run` as a deprecated alias task. Update internal/doc references to the new task name.  Owner: TBD  Est: 1h  verifies: [UC-041, infrastructure]  deps: []  acc: ExUnit/CLI -- `mix kazi.apply <goal>` runs the loop; `mix kazi.run` still works with a deprecation note; both reach the same `Kazi.CLI` core.
- [x] T27.3 JSON result contract + `schema_version` bump: rename the contract's command key `run`->`apply`, `propose`->`plan` in `docs/schemas` + the emitter; bump `schema_version`; document the old names as deprecated aliases. Update the conformance + self-conformance (T15.7) fixtures.  Owner: TBD  Est: 1.5h  verifies: [UC-041, UC-033]  deps: [T27.1]  acc: ExUnit -- `kazi apply --json` emits the documented object keyed `apply` with the bumped `schema_version`; the schema doc lists the alias; self-conformance (T15.7) passes against the new schema.
- [x] T27.4 `kazi help --json` + `kazi schema` updated (generated): `help --json` lists `apply`/`plan` as primary and `run`/`propose` as deprecated aliases; `schema apply`/`schema plan` resolve (with `run`/`propose` aliased). Generated from the real command table, not hand-maintained.  Owner: TBD  Est: 1h  verifies: [UC-041, UC-034]  deps: [T27.1, T27.3]  acc: ExUnit -- `help --json` shows the 4 primary verbs + the 2 deprecated aliases; `schema apply` returns the run-result schema; both parse.
- [x] T27.5 Skill + `AGENTS.md` + `kazi mcp` to the new verbs (E26 alignment): update the `install-skill` SKILL.md (router sub-skills now map 1:1 to CLI `apply`/`plan`), `AGENTS.md`, and the `kazi mcp` tool names to `apply`/`plan`; keep alias mentions. Coherence guard (T16.4) covers the new verbs.  Owner: TBD  Est: 1.5h  verifies: [UC-041, UC-040, UC-034]  deps: [T27.4]  acc: skill/`AGENTS.md`/MCP reference `apply`/`plan` (aliases noted); the skill<->CLI coherence test (T16.4) passes; E26's verb-map note reflects the 1:1 identity.
- [x] T27.6 README/site/concept/docs to the new verbs: replace `kazi run`/`kazi propose` with `kazi apply`/`kazi plan` across README, site, `docs/concept.md`, and `docs/` guides (note the aliases once); update `site/src/canonical.mjs` if any verb is canonical; README<->site coherence (T9.9) green; deploy + verify live.  READY NOW (dep T27.4 is [x]) + this is the direct fix for a CONFIRMED LIVE BUG 2026-06-25: the Install section of `site/src/pages/index.astro` (step 2) still shows the REMOVED `kazi propose`->`kazi approve` flow on https://kazi.sire.run. Pair with T29.4 (the standing guard) so this cannot regress.  Owner: TBD  Est: 1.5h  verifies: [UC-041, UC-035]  deps: [T27.4]  acc: no `kazi run`/`kazi propose` as the PRIMARY verb in docs OR on the site (incl. `index.astro` Install section) (aliases mentioned once); coherence (T9.9) green; the T29.4 site-verb guard passes; site deployed + verified live at https://kazi.sire.run.
- [x] T27.7 Deprecation policy note -- removal version DECIDED (operator 2026-06-24): `run`/`propose`/`mix kazi.run` are deprecated aliases removed in **v0.6.0** (the next minor). Write a short `docs/` note (+ CHANGELOG entry) stating the aliases, the rationale (verb unification, ADR-0032), and the v0.6.0 removal.  Owner: TBD  Est: 0.5h  verifies: [UC-041]  delivers: [a documented v0.6.0 deprecation window for run/propose]  deps: [T27.1]  acc: the note names the aliases + the ADR-0032 rationale + the concrete v0.6.0 removal; linked from the CHANGELOG; the deprecation hint (T27.1) mentions removal in v0.6.0.
- [ ] T27.8 LIVE verify: drive a fixture goal via `kazi plan` -> approve -> `kazi apply` end to end on the built binary; confirm `kazi run`/`kazi propose` still work (with the deprecation hint); record in `docs/devlog.md`. `mix format --check-formatted` + `--warnings-as-errors` clean.  Owner: TBD  Est: 1h  verifies: [UC-041]  deps: [T27.1, T27.2, T27.3]  acc: a real run converges via the new verbs; the aliases still converge with a stderr hint; format + warnings-as-errors clean; devlog updated.
- [x] T27.9 REMOVE the deprecated aliases in the v0.6.0 cycle (the tail of ADR-0032's deprecation window): delete the `run`/`propose` CLI verbs + the `mix kazi.run` alias task + their deprecation-hint code; remove/repoint the alias back-compat tests; mark them removed in `docs/deprecations.md` + a CHANGELOG note; bump the result-contract notes if needed. DO NOT do this until **v0.5.0 has shipped** (the rename + aliases release, PR #228) so the deprecation window is real; this is a BREAKING change scheduled for the v0.6.0 release. NOTE: this is the only OPEN item from the v0.5.0/alias collision -- the version reconciliation itself (removal target v0.5.0 -> v0.6.0) is already done across `docs/deprecations.md`, `cli.ex`, and `mix kazi.run`, so PR #228 (release 0.5.0) is safe to merge as-is.  Owner: TBD  Est: 1.5h  verifies: [UC-041]  deps: [T27.8]  acc: in a v0.6.0 branch/cycle ONLY -- `kazi run`/`kazi propose`/`mix kazi.run` no longer dispatch (they error with a clear "use `kazi apply`/`kazi plan`" message, not silently); `docs/deprecations.md` marks them removed; the alias back-compat tests are gone/repointed; `mix format`/`--warnings-as-errors` clean; not landed before v0.5.0 is released.

### E28 -- Doc-sync: bring concept.md + the architecture docs to current reality (P1, no ADR)

The ENGINEERING-accuracy doc pass, and the answer to "doc work is blocked": E22 is
gated on whole feature epics, E25's open tasks need human/creative input, and E27's
doc tasks chain behind the CLI code -- so NO unblocked, autonomous task keeps the
DESIGN docs honest. `docs/concept.md` stops at ADR-0023 and README's how-it-works at
ADR-0022, ~10 ADRs behind: they do not describe the native scheduler (E21/ADR-0027),
predicate-graph waves (E23/ADR-0028), the agent-driven + router model (E16/E26,
ADR-0024/0031), or the renamed verbs (E27/ADR-0032). E28 syncs them. AUTONOMOUS
(prose edited to match shipped ADRs/code -- no human decision, no live env), so the
pool can do it NOW. No new ADR (executes existing decisions 0021-0032).

NON-OVERLAP: E28 is the ONGOING engineering-accuracy sync (now); E22 is the final
LAUNCH polish (gated, later); E25 is MARKETING content (the agent paradigm, tagline,
leaderboard); T27.6 owns the literal verb-STRING rename across docs. E28 owns the
DESIGN NARRATIVE; where commands appear it uses the new verbs and coordinates with
T27.6 so strings stay consistent.

- [x] T28.1 concept.md -- native parallel scheduler (E21/ADR-0027): add/replace the parallelism section so it describes the native scheduler (partition by blast radius -> lease each partition -> N supervised reconcilers -> collective convergence -> merge; single-node NATS-free), reconciling the older "one supervised process per active goal / external launcher" framing. Reference ADR-0027.  Owner: TBD  Est: 1.5h  verifies: [UC-042]  delivers: [a concept.md parallelism section matching the shipped scheduler]  deps: []  acc: `docs/concept.md` describes the native scheduler without contradicting ADR-0001; the stale "external launcher only" framing is gone; references ADR-0027; no command-verb literals that T27.6 has not yet renamed (use new verbs or verb-neutral prose).
- [x] T28.2 concept.md -- predicate-graph waves + agent-driven/router model: add a "dependency-aware waves" section (E23/ADR-0028: `needs` edges -> topological pipelined scheduling) and an "agent drives kazi" section (E16/E26, ADR-0024/0031: you chat with Claude Code, it drives kazi; the plan/apply/status/adopt router). Confirm Telegram is absent (E24/ADR-0029) and the mobile interface is the agent.  Owner: TBD  Est: 1.5h  verifies: [UC-042]  delivers: [concept.md sections for waves + the agent-driven/router paradigm]  deps: []  acc: concept.md describes `needs`-edge waves + the agent-driven router model; no Telegram surface remains; references ADR-0028/0031; coherent with ADR-0001.
- [x] T28.3 README "How it works" + ADR-index summary current through ADR-0032: update README's architecture/how-it-works summary + its ADR reference list to span 0021-0032 (scheduler, waves, agent-drivable, self-teaching, router, verb rename); use the new verbs (`kazi plan`/`kazi apply`), coordinating with T27.6 so verb strings match. Keep canonical strings + README<->site coherence (T9.9).  Owner: TBD  Est: 1.5h  verifies: [UC-042, UC-035]  delivers: [a README architecture summary current to ADR-0032]  deps: [T27.6]  acc: README how-it-works references the current ADRs through 0032 and the new verbs; coherence (T9.9) green; no stale "Telegram bridge"/old-verb mentions.
- [x] T28.4 Accuracy + coherence gate: every command/flag in `concept.md` + README + `docs/` matches `kazi help --json` (apply/plan + aliases, --parallel, --explain, status, schema, install-skill, mcp); the README<->site (T9.9) + skill/AGENTS.md (T16.4) coherence checks pass; deploy + verify live if any site-rendered doc changed.  Owner: TBD  Est: 1h  verifies: [UC-042, infrastructure]  deps: [T28.1, T28.2, T28.3]  acc: zero references to non-existent commands; coherence green; if the site changed, deployed + verified live at https://kazi.sire.run.

### E29 -- OSS contribution gates: docs-with-code + no-internal-leak (P1, ADR-0034)

Enforce the two contribution rules (ADR-0034) for the PUBLIC repo. The rules are
already in the local + global CLAUDE.md and the `/apply` wave gate; E29 adds the CI
guards that make them stick, plus a one-time scrub of the existing leaks (~48 hits in
`docs/` + README found 2026-06-24: private IPs, an internal GPU host, internal
tool/codenames, personal paths).

- [x] T29.1 Docs-with-code CI guard: a CI check (script + GitHub Actions step) that FAILS a PR which changes a user-facing/behavioral surface in `lib/` (a command/flag in `cli.ex`, a predicate provider, a public API) without a corresponding `docs/`/README/`kazi help` change -- unless the PR carries a justified `[no-docs]` marker. Start strict-but-warn, then ratchet to blocking.  Owner: TBD  Est: 2h  verifies: [UC-044, infrastructure]  deps: []  acc: a PR that adds a CLI flag with no doc change fails (or warns, phase 1); a `[no-docs]` justified PR passes; a docs-included PR passes; the check is documented.
- [x] T29.2 No-internal-leak CI guard: a CI check that greps the diff (and optionally the tree) for internal-marker patterns -- private IPs (`192.168.*`, `10.*`, `172.16-31.*`), internal infra/tool/codenames, personal usernames + absolute home paths -- and FAILS on a hit, with an allow-list for legitimate cases (e.g. RFC-5737 example IPs in a fixture). Tune to avoid false positives.  Owner: TBD  Est: 2h  verifies: [UC-044, infrastructure]  deps: []  acc: a diff introducing `192.168.x.x` or an internal hostname fails; an allow-listed example IP passes; the marker list + allow-list are documented; runs in CI on every PR.
- [x] T29.3 Scrub existing leaks from public docs/code: replace the ~48 internal-specific references in `docs/` (devlog, pool-model-tiering, drive-kazi-pooled-task, lore, concept) + README with generic terms ("a local model", "a deploy target", "an internal host") WITHOUT losing the honest engineering finding; keep history accurate. Re-run T29.2 to confirm zero hits.  Owner: TBD  Est: 2h  verifies: [UC-044]  deps: [T29.2]  acc: the no-leak guard (T29.2) reports zero hits across the repo; the engineering findings (e.g. "a local 35B was too slow") survive in genericized form; no internal IP/host/codename/personal-path remains.
- [x] T29.4 Site command-accuracy CI guard (NEW 2026-06-25; closes the gap that let stale verbs ship live): a CI check (extend `site/scripts/check-coherence.mjs` or add a sibling script + an `oss-gates.yml` job) that scans `site/` source -- `.astro`, `.mjs`, `.md`, AND `.svg` assets (the proof asset is XML text, so a text grep reaches it) -- for DEPRECATED/removed kazi verbs (`kazi run`, `kazi propose`, the old `propose`->`approve` proposal flow) used as a PRIMARY command, and FAILS the PR on a hit (a single labelled "deprecated alias" mention is allow-listed). This is the MISSING guard: T9.9 only diffs canonical strings and T16.4 only scans `SKILL.md`/`AGENTS.md`, so NEITHER catches site verb-drift -- which is why `kazi propose`/`kazi approve` (Install section, `site/src/pages/index.astro` step 2) and `kazi run my-goal.toml` (`proof-loop.svg`) are LIVE on https://kazi.sire.run as of 2026-06-25. Ship strict-but-WARN first (the site is currently dirty); ratchet to BLOCKING after T27.6 + T25.2 clean the site.  Owner: TBD  Est: 1.5h  verifies: [UC-035, infrastructure]  deps: []  acc: a site file (incl. an `.svg`) naming `kazi run`/`kazi propose` as a primary verb is flagged (warn phase) and, post-ratchet, fails the PR; an allow-listed single deprecated-alias mention passes; the marker list + warn->block phase are documented in `docs/oss-gates.md`; runs in CI on every PR touching `site/`.

### E30 -- Adaptive in-family model tiering, skill-driven (P1, ADR-0035)

The token-economy headline, executed at the SKILL layer (never kazi-core). ADR-0033
made in-family Claude tiering the default cost story and shipped the `claude --model`
enabler (T19.6, done); ADR-0035 adds the ADAPTIVE policy: the kazi Claude Code skill
starts the grind on the cheapest capable Claude model and ESCALATES the model
(Haiku -> Sonnet -> Opus, capped) only when kazi reports the loop stuck. The policy is
a skill state machine over kazi's existing `--json` signals; kazi stays a pure tool
(exposes `--model`, reports state). The skill/AGENTS.md worked examples are flipped
from the legacy local/opencode-first framing to the in-family-Claude default.

Acceptance for the epic: the installed skill defaults to in-family tiering AND
escalates on stuck; the escalation ladder is bounded + capped (degenerates to static
when disabled); kazi's reported state is verified SUFFICIENT for the skill to drive
escalation (any kazi change is a read-only signal enrichment, never policy); the
benchmark (T19.7) shows the escalating arm; a live fixture proves escalation fires
and converges; skill/AGENTS.md/README/site model ids are real (claude-api checked)
and coherent (T9.9, T16.4 green). No auto-tiering inside kazi (ADR-0035 reject).

- [x] T30.1 Skill + AGENTS.md default to in-family Claude tiering: replace the local/opencode-first worked examples (`--harness opencode --model local/qwen3.6`) in `lib/kazi/teach/install_skill.ex` AND `AGENTS.md` with the ADR-0033 default -- author predicates on the session's frontier model, then `kazi apply --harness claude --model <cheap-claude>` for the grind. Keep local/BYOM as the explicitly-secondary PRIVACY note. Model ids are real (claude-api reference). Update both surfaces in lockstep; skill/AGENTS.md coherence (T16.4) green.  Owner: TBD  Est: 1.5h  verifies: [UC-045, UC-043, UC-034]  deps: []  acc: the installed skill + `AGENTS.md` lead the worked example with frontier-author -> cheap-Claude-grind via `--harness claude --model <id>`; local/BYOM is clearly secondary; every model id is a real current id; coherence (T16.4) green; commands verified against `kazi help --json`.
- [x] T30.2 Define + document the escalate-on-stuck recipe in the skill (the headline): add a bounded escalation state machine to the skill -- start on the cheapest model; on a kazi-reported stuck / no-progress / regression for the SAME slice, re-dispatch the next `kazi apply` with the next model up a CAPPED ladder (Haiku -> Sonnet -> Opus, stop at frontier); reset to cheap on a fresh slice; respect kazi's budget/stuck termination so it cannot loop unboundedly. Document the ladder + the trigger as a copy-paste recipe.  Owner: TBD  Est: 2h  verifies: [UC-045, UC-033]  deps: [T30.1, T30.3]  acc: the skill recipe shows how to parse the `--json` stuck signal and step the `--model` up a capped ladder; the ladder tops out at the frontier and stops; disabling escalation degenerates to T30.1 static tiering; only real commands/ids; coherence (T16.4) green.
- [x] T30.3 Verify kazi's `--json` signal is SUFFICIENT for skill-side escalation (and ONLY then a thin read-only enrichment): confirm `kazi apply --json` (+ `--stream`) already exposes enough state for the skill to detect "stuck on this slice N times" (e.g. `next_action`, stuck/regression flags, per-slice progress). If sufficient, NO kazi change. If a gap exists, add ONLY a read-only signal field (never model-selection logic); keep `schema_version` discipline + a self-conformance test.  Owner: TBD  Est: 1.5h  verifies: [UC-045, infrastructure]  deps: []  acc: a documented mapping from the `--json` result/stream fields to the escalation trigger; if no gap, an explicit "no kazi-core change needed" note; if a gap, a read-only field added with a schema bump + round-trip test and NO policy in core (ADR-0035).
- [ ] T30.4 LIVE dogfood: escalation fires and converges: drive a self-contained fixture goal with the recipe -- start on the cheapest model, force/observe a stuck slice, watch the skill escalate the `--model`, and reach objective-true. Report honestly (did escalation trigger? did it converge? what did it cost vs static?). Gated by the feature-complete dogfood policy (run on the released binary).  Owner: TBD  Est: 2h  verifies: [UC-045, UC-033]  deps: [T30.2, T19.7]  acc: a recorded run where the cheap tier stalls, the skill escalates per the ladder, and the goal converges to objective-true; honest result (including if escalation did NOT help); evidence persisted; uses the released binary.
- [ ] T30.5 Accuracy + coherence gate for the tiering surfaces: every model id across skill/`AGENTS.md`/README/site verified against the claude-api reference (real current ids only -- e.g. Opus 4.8 / Sonnet 4.6 / Haiku 4.5); commands verified against `kazi help --json`; README<->site (T9.9) + skill/`AGENTS.md` (T16.4) coherence green; the cost claim stays "being measured" until T19.7 lands (no unproven number).  Owner: TBD  Est: 1h  verifies: [UC-045, infrastructure]  deps: [T30.1, T30.2, T25.11]  acc: zero invented/stale model ids; zero unshipped-command references; coherence (T9.9 + T16.4) green; no unproven cost figure stated as measured.

### E31 -- Self-maintaining docs: plan trim + freshness as a kazi standing goal (P1, ADR-0036)

The flagship self-dogfood. `plan.md` is kazi's `goal.toml`; as the project grows it
bloats (1,142 lines, monolithic today) and the stable docs drift. ADR-0036 makes the
documentation lifecycle a kazi-reconciled standing goal in THREE layers, with the
logic in the skill + CI layer and kazi only DRIVING it (no doc engine in core).
kazi's tier map is fixed: architecture -> `concept.md`, decisions -> `docs/adr/`,
operations/findings -> `devlog.md`, invariants/landmines -> `lore.md`, raw completed
plan -> `plan-archive.md` (no `design.md`).

Acceptance for the epic: completed+released epics are trimmed from the live plan
LOSSLESSLY (verbatim in an append-only archive) by a deterministic tool; their
durable knowledge is lifted to the tier docs via a gated (propose-then-confirm)
pass; a doc-freshness predicate set fails CI on drift; the whole lifecycle is
encoded as a kazi standing goal and PROVEN by running it on this repo. No
doc-specific logic in kazi core (ADR-0036 reject).

- [ ] T31.1 Split-plan migration (master + epic files): convert the monolithic `docs/plan.md` to the master + include-pointer layout the parser already supports (`### ENN -- Title -> docs/plans/ENN.md`), one file per epic, content byte-identical. This is the structural precondition for clean per-epic archival.  Owner: TBD  Est: 2h  verifies: [UC-046, infrastructure]  deps: []  acc: `plan.md` becomes a master index of `### ENN -- Title -> docs/plans/ENN.md` pointers; each epic body lives in its own file; `parse_plan.py` expands them so the GitHub-sync + WBS still parse identically (same task/epic counts as before the split); `mix`/coherence unaffected.
- [ ] T31.2 Deterministic, lossless trim tool (Layer 1): a script that, for an epic that is 100% `[x]` AND covered by a release tag, moves its block verbatim from the live plan into an append-only, git-tracked `docs/plan-archive.md` (or archives its epic file), leaving a one-line pointer. Idempotent + reversible; refuses to trim an epic with any open/blocked task or no release. Unit-tested on fixtures.  Owner: TBD  Est: 2.5h  verifies: [UC-046]  deps: [T31.1]  acc: running the tool on a done+released epic moves it to the archive verbatim and leaves a pointer; a partially-done or unreleased epic is left untouched; re-running is a no-op; an ExUnit/script test pins lossless round-trip (archive content == original block).
- [ ] T31.3 Gated knowledge extraction (Layer 2): a propose-then-confirm pass (the `/ingest` pattern) that, AFTER T31.2 archives a block, lifts only durable nuggets to the correct tier -- invariant/landmine -> `lore.md`, finding/benchmark -> `devlog.md`, decision -> `docs/adr/`, architecture -> `concept.md` -- never deleting from the archive. Routing is reviewed before write.  Owner: TBD  Est: 2h  verifies: [UC-046]  deps: [T31.2]  acc: extraction proposes tier-routed edits for human confirm; nothing is removed from `plan-archive.md`; a mis-route loses no knowledge (archive is the backstop); the tier map matches ADR-0036 (concept.md, not design.md).
- [x] T31.4 Doc-freshness predicate set (Layer 3, definition): define machine-checkable predicates -- (a) every shipped CLI command appears in README + `kazi help --json`; (b) no doc references a symbol/command absent from the code; (c) every ADR referenced by a doc exists; (d) no `[x]` task older than the last release remains in the live plan; plus the existing README<->site (T9.9) and skill<->CLI (T16.4) checks folded in. Expressed as kazi predicates.  Owner: TBD  Est: 2h  verifies: [UC-046, UC-037]  deps: []  acc: each predicate is a runnable check returning pass/fail with the offending location; the set is documented; a deliberately-stale doc (names a non-existent command) fails; coherence checks (T9.9/T16.4) are subsumed, not duplicated.
- [x] T31.5 Freshness CI gate (Layer 3, enforcement): wire the T31.4 predicates into CI -- warn first, then ratchet to blocking (the E29 gate pattern) -- so doc drift fails the build.  Owner: TBD  Est: 1h  verifies: [UC-046, infrastructure]  deps: [T31.4]  acc: a PR that ships a command without documenting it (or names a dead symbol) fails the freshness job; a clean PR passes; the warn->blocking ratchet is documented; runs on every PR.
- [ ] T31.6 Encode the lifecycle as a kazi STANDING goal, built on the E32 predicate paradigm (ADR-0040/0041/0042): author a standing goal-file whose predicates are "plan trimmed (no done+released epic in the live plan)" + the freshness set, authored as `custom_script` predicates (ADR-0040 / T32.1) that WRAP the T31.4 checker scripts -- NOT a bespoke mechanism. Use envelope-v2 (ADR-0041 / T32.2): the doc-coverage check is a `ratchet` predicate (% shipped commands documented, signal-vs-baseline, T32.3), not boolean; "stale tasks in live plan" is a count that ratchets to 0. Apply anti-gaming enforcement (ADR-0042 / T32.4): the freshness checkers run in CI outside the agent's reach. Actions wired to the T31.2 trim + T31.3 extraction; Layer 1/3 auto, Layer 2 keeps the human-confirm gate. kazi DRIVES it (no doc logic in core).  Owner: TBD  Est: 2h  verifies: [UC-046]  deps: [T31.2, T31.4, T32.1, T32.2]  acc: a committed standing goal-file kazi can reconcile; freshness predicates are `custom_script` (ADR-0040) wrapping the T31.4 scripts, with a doc-coverage `ratchet` (ADR-0041) and CI-side anti-gaming (ADR-0042) -- no bespoke predicate engine and no doc-specific code in kazi core; Layer-2 writes require confirm.
- [ ] T31.7 LIVE dogfood -- run the standing goal on THIS repo: drive the E31 standing goal against kazi itself -- trim the already-done+released epics (e.g. E12/E13/E14/E18/E24/E29), extract their knowledge to the tier docs, and bring the freshness predicates green. Report honestly (what trimmed, what extracted, did freshness pass). Uses the released binary per the feature-complete dogfood policy.  Owner: TBD  Est: 2h  verifies: [UC-046, UC-033]  deps: [T31.6]  acc: a recorded run where the live plan shrinks (done epics archived losslessly), knowledge lands in the tier docs, and the freshness gate is green; honest result incl. anything skipped; evidence persisted.
- [ ] T31.8 Docs + positioning (self-maintaining docs as a kazi capability): document the doc-lifecycle in `concept.md` + README (kazi keeps its own plan/docs healthy -- the dogfood), and cross-link the tier map (ADR-0036). Coherence (T9.9/T16.4) green.  Owner: TBD  Est: 1h  verifies: [UC-046, UC-035]  deps: [T31.7]  acc: `concept.md`/README describe the trim+freshness lifecycle and the tier map; only real commands; coherence green; deployed live if the site changes.

### E32 -- Predicate catalog & evidence v2: the verification workhorse (P1, ADR-0040/0041/0042/0043)

Turn kazi's four-provider checker set into a real software-development verification
layer. Grounded in `docs/research/predicate-verification-landscape.md` (three deep
research streams: verification beyond unit tests, live/prod verification, agentic
anti-gaming). The headline insight: BREADTH is the smaller half -- four FRAMEWORK
changes improve every checker (existing, new, user-written) more than a longer list.
Build the framework first (the generic protocol + the score/evidence/ratchet envelope
+ anti-gaming enforcement), THEN the concrete providers that prove it. The convergence
gate is unchanged: `:converged` still requires the whole predicate vector `:pass`
(ADR-0002).

Acceptance for the epic: a `custom_script` provider lets a NEW check ship as config
with a safe-by-default verdict, AND it is the single command-runner -- `test_runner`/
`prod_log` fold in as deprecated presets (non-breaking now; removed in v2.0.0)
(ADR-0040); every predicate carries `{pass, score, prior_score, direction, evidence[]}`
with SARIF/JUnit/LSP-shaped evidence and a first-class `ratchet` mode, on an additive
non-breaking schema bump (ADR-0041); the anti-gaming guarantees are enforced (default-on
for creation mode) at the clean-tree + separate-process isolation level + reported
(ADR-0042); the first-class providers `:static`/`:coverage`/`:property`/`:mutation`/
`:cve` land with docs, plus the live upgrades (sustained-health -> `:metrics` ->
burn-rate -> journey) and documented contract/perf/security-tail recipes (ADR-0043).
Each surface lands with its docs (ADR-0034) and is verified against `kazi help --json`.
NOTE (precondition): before T32.4 the clean-tree + separate-process "checker outside the
agent's reach" seam must be verified against `lib/kazi/loop.ex` + the worktree wiring
(flagged in ADR-0042, not assumed).

- [x] T32.1 `custom_script` generic predicate provider -- the UNIFIED command-runner (ADR-0040, the keystone): add `Kazi.Providers.CustomScript` (kind `:custom_script`) registered in `lib/kazi/runtime.ex`; runs a declared `cmd`/`args` in the workspace and maps the result via a DECLARED `verdict` (`exit_zero` default | `exit_code` map | `json` JSONPath+comparison over stdout), so a SARIF-emitting tool that exits 0 with findings is gated on its parsed findings, not its exit code. Distinguish `:error` (checker could not run -- declared `error_codes`/parse failure) from `:fail`. Loader validates the new keys; `kazi schema custom_script` documents them; ship `priv/examples` recipes (SARIF via Semgrep, JUnit via a test runner, JSON via a mutation tester).  Owner: TBD  Est: 3h  verifies: [UC-047, infrastructure]  deps: []  acc: ExUnit -- a tool exiting 0 WITH findings (json verdict) yields `:fail`; a missing-binary exit yields `:error` not `:fail`; exit_zero/exit_code/json verdicts each covered; the three example recipes parse + evaluate; `kazi schema custom_script` lists every key; documented in `docs/`.
- [x] T32.1b Fold `test_runner`/`prod_log` onto the unified core + DEPRECATE the names (ADR-0040 decision 1+7, operator decision 2026-06-24): reimplement `test_runner` as a `custom_script` preset (`verdict = "exit_zero"` + JUnit evidence) and `prod_log` as a preset (regex-match-count verdict over output); the loader rewrites both names to the unified provider and emits a one-line STDERR deprecation hint (never into `--json` stdout). Record the aliases + the near-mechanical goal-file migration + the v2.0.0 removal target in `docs/deprecations.md` + the CHANGELOG. SHIPS NON-BREAKING (a minor bump -- both names still resolve); actual REMOVAL is a separate future v2.0.0 task (the 0.x->1.x landmine: next breaking commit auto-bumps the major). `http_probe`/`browser` are out of scope (not command-runners).  Owner: TBD  Est: 2h  verifies: [UC-047, infrastructure]  deps: [T32.1]  acc: ExUnit -- an existing `provider = "test_runner"`/`"prod_log"` goal file still loads + evaluates identically (byte-compatible result) via the preset, with a stderr deprecation hint and pure `--json` stdout; `docs/deprecations.md` names the aliases + the migration + the v2.0.0 removal; no goal file is broken by this change.
- [x] T32.2 Predicate envelope v2 -- score + direction + structured evidence (ADR-0041): extend `Kazi.PredicateResult` to carry `score` (optional float), `direction` (`:higher_better | :lower_better`, so the controller reads progress without per-provider knowledge), `prior_score` (threaded by the loop from the previous iteration's same-id result), and `evidence[]` as LSP-Diagnostic-shaped items (`{file, line, col, rule, level, message, expected, got}`); add a shared SARIF/JUnit-XML parser the providers map onto, raw stdout kept only as a truncated fallback. Boolean predicates set `score = nil` and behave byte-identically to today (back-compat). The loop threads `prior_score` and exposes the direction-interpreted delta to the progress classifier + stuck-detector (T1.5) WITHOUT changing the `:converged` gate. The `--json`/`schema_version` change is ADDITIVE -- a NON-BREAKING minor bump, not a v2.0.0 trigger.  Owner: TBD  Est: 3h  verifies: [UC-048, infrastructure]  deps: []  acc: ExUnit -- a result with `score`/`direction`/`prior_score`/structured `evidence` round-trips through the read-model; a `:lower_better` count improving (going down) registers as progress; a boolean (score=nil) predicate's stored shape is unchanged; the stuck-detector sees the delta; `:converged` still requires the whole vector `:pass`; SARIF + JUnit fixtures parse into evidence items; the schema bump is additive/non-breaking.
- [x] T32.3 First-class `ratchet` predicate mode (ADR-0041): add `mode = "ratchet"` with `metric`, `baseline` (git ref or stored prior value), `allowed_regression`; passes iff `signal - baseline <= allowed_regression`, reports `score = signal`. Build the baseline-comparison machinery ONCE (resolve baseline, diff-scope, store the new value) so coverage/perf/size are configs of one mode. Doubles as the ADR-0042 guard substrate (a metric that may only improve).  Owner: TBD  Est: 2.5h  verifies: [UC-048, UC-050]  deps: [T32.2]  acc: ExUnit -- a ratchet predicate passes when signal improves, fails on a regression beyond `allowed_regression`, and stores the new baseline; an absolute-threshold predicate is unaffected; the same mode services a coverage AND a size example.
- [x] T32.4 Anti-gaming enforcement profile (ADR-0042, the thesis hardening): add an `enforcement` goal profile -- DEFAULT-ON for kazi-authored creation-mode goals, opt-in for repair goals (operator decision) -- that (a) runs the checker at the CLEAN-TREE + SEPARATE-PROCESS isolation level: evidence-bearing checker definitions/inputs resolved from a CLEAN tree (not the agent's working copy) AND the checker executed in a separate OS process the agent cannot introspect/monkey-patch (closes the operator-overloading / in-process-grader-edit class; full container isolation DEFERRED); (b) leases the goal's predicate + executed-test paths READ-ONLY to fixer agents (a write attempt is a flagged event); (c) maps skipped/errored/xfail sub-results to `:fail`; (d) enforces test-count + coverage RATCHETS as guards (via T32.3); (e) surfaces the active guarantees + any flagged gaming event in `kazi status`/`--json`. PRECONDITION: verify the clean-tree + separate-process seam against `loop.ex` + worktree wiring first.  Owner: TBD  Est: 4.5h  verifies: [UC-049, infrastructure]  deps: [T32.2, T32.3]  acc: ExUnit -- a skipped test counts as `:fail` not `:pass`; deleting a test trips the count ratchet (guard regression, not progress); a write to a read-only-leased predicate file is flagged; the checker runs in a separate process resolved from a clean tree (an in-iteration edit to the checker file does not affect the verdict); the active enforcement guarantees appear in `--json`; the isolation seam is documented with a `loop.ex` reference.
- [x] T32.5 Diff-inspection gaming guard (ADR-0042, advisory): before crediting an iteration as progress, run a cheap structural check on the agent's diff for gaming signatures -- edits to predicate/grader files, `if input == <test_case>` special-casing, newly-added `skip`/`xfail` markers -- and downgrade the iteration + surface evidence on a hit rather than crediting a false pass. Advisory (surface, don't hard-block) at first; the T32.4 ratchets are the hard guard.  Owner: TBD  Est: 2h  verifies: [UC-049]  deps: [T32.4]  acc: ExUnit -- a diff that adds `@pytest.mark.skip` or special-cases a test input is flagged with evidence; a legitimate refactor diff is not flagged (low false-positive on the fixture set); the flag downgrades progress, it does not crash the loop.
- [x] T32.6 Optional held-out acceptance subset (ADR-0042): let a goal mark acceptance predicates `held_out = true` -- evaluated by the controller but their definitions/inputs are NOT placed in the agent's dispatch context (visible-for-iteration vs hidden-for-acceptance). Convergence requires the held-out set to pass too.  Owner: TBD  Est: 2h  verifies: [UC-049]  deps: [T32.2]  acc: ExUnit -- a `held_out` predicate is absent from the dispatch prompt/context but present in the observe vector; `:converged` requires it `:pass`; the visible predicates still seed fix context.
- [x] T32.7 `:static` provider -- analysis/type-check/lint, Dialyzer-led (ADR-0043): add `Kazi.Providers.Static` (kind `:static`); lead with Dialyzer (kazi-native, zero false positives), generalize to tsc/mypy/golangci-lint/Semgrep via SARIF; baseline-ratchet on NEW findings (T32.3). SARIF evidence (`ruleId`/`level`/`file:line:col`).  Owner: TBD  Est: 2.5h  verifies: [UC-050, infrastructure]  deps: [T32.2, T32.3]  acc: ExUnit -- a Dialyzer run with a fresh warning yields `:fail` with a localized evidence item; a clean run yields `:pass`; the baseline ratchet ignores pre-existing findings and fails only on new ones; `kazi schema static` + a `docs/` how-to ship.
- [x] T32.8 `:coverage` + `:property` + `:mutation` + `:cve` first-class providers (ADR-0043): `:coverage` = patch coverage >= target AND no project regression (a T32.3 ratchet instance, already named in the behaviour docstring); `:property` = PropCheck under `mix test`, score = cases-passed/N, shrunk counterexample as evidence; `:mutation` = score 0-1 gated on a threshold (NEVER 100%), scope to changed lines, surviving-mutant evidence; `:cve` = dependency vulnerability scan led by `govulncheck` REACHABILITY (fail only on a transitively-called vuln, call stack as proof -- a demonstration; trivy/grype/npm-audit manifest-only as tier-2 CLAIMS ratcheted vs a baseline), encoding the exit-0-under-json gotcha (promoted from a recipe to first-class, operator decision). Each with `kazi schema <kind>` + a `docs/` how-to.  Owner: TBD  Est: 5h  verifies: [UC-050, infrastructure]  deps: [T32.3]  acc: ExUnit -- coverage fails on a patch-coverage drop, passes the walking skeleton; a PropCheck counterexample surfaces SHRUNK input + score; a mutation run reports a 0-1 score + surviving mutants and is gated on a threshold not 100%; a `:cve` run fails on a reachable known-vuln dep with the call stack as evidence and is gated on parsed output not the exit code; all four documented.
- [x] T32.9 Documented `custom_script` recipes -- contract/perf/security-tail (ADR-0043, config not code): ship + document `priv/examples` recipes over T32.1 for contract/schema compat (`buf breaking`, `oasdiff`, `pact can-i-deploy`), perf/size ratchets (Criterion/bencher.dev, size-limit/bloaty), secret scanning (trufflehog `Verified:true`), a11y + Lighthouse CI, IaC/container scan, and visual-regression. (Dependency CVE is NOT here -- it was promoted to the first-class `:cve` provider, T32.8.) Encode the two evidence tiers: verified findings fail directly; presence-based findings ratchet against a baseline. Bake in the exit-code gotchas (trivy/semgrep need `--exit-code`; grype exits 2; nuclei/ZAP have no findings exit code).  Owner: TBD  Est: 2.5h  verifies: [UC-047, UC-050]  deps: [T32.1, T32.3]  acc: each recipe runs the real tool and yields the correct verdict on a fixture (a breaking proto change fails `buf breaking`; a size regression trips the ratchet; a planted verified secret fails); the exit-code-gotcha tools are gated on parsed output not exit code; `docs/` lists the recipes + the two evidence tiers.
- [x] T32.10 Live provider upgrades -- sustained-health + `:metrics` + burn-rate + journey (ADR-0043): upgrade `http_probe` to "N consecutive healthy samples over window W" (the K8s `failureThreshold` model, not a single 200); add `:metrics` (PromQL/RED: error-rate + p95/p99 over W via `histogram_quantile` over `rate(..._bucket[W])` by `(le)`); add an SLO multiwindow multi-burn-rate gate over `:metrics`; re-use the `browser` provider as a post-deploy synthetic journey requiring X consecutive passes. `prod_log` stays as a coarse safety net. Each degrades to "not applicable" when no metrics endpoint is configured; document the bake-window discipline (never converge on a single sample).  Owner: TBD  Est: 4h  verifies: [UC-050, infrastructure]  deps: [T32.2]  acc: ExUnit/fixtures -- a single transient 200 does NOT pass sustained-health (requires N consecutive); a `:metrics` predicate computes a windowed quantile and gates on it; a burn-rate gate fires only when both long+short windows breach; a journey requiring X consecutive passes rejects a one-off success; absent a metrics endpoint the live metric predicates report not-applicable, not a false pass; the bake-window rule is documented.
- [ ] T32.11 LIVE dogfood -- the expanded catalog converges a real fixture (gated on feature-complete): drive a self-contained fixture goal that exercises the new framework end-to-end -- a `:static` (Dialyzer) + `:coverage` ratchet + a `:mutation` score gate + the `:cve` provider + a sustained-health live predicate -- starting RED and converging to objective-true on the released binary, with the anti-gaming guarantees active (creation-mode default-on). Report honestly (did each predicate gate correctly? did enforcement flag anything? did it converge?). Gated by the feature-complete dogfood policy.  Owner: TBD  Est: 2.5h  verifies: [UC-047, UC-048, UC-049, UC-050]  deps: [T32.4, T32.7, T32.8, T32.9, T32.10]  acc: a recorded run where the fixture starts with failing new-kind predicates, the fixer converges them to objective-true under active enforcement, and the score gradient is visible in the iteration log; honest result (including any predicate that did NOT gate as intended); evidence persisted to `docs/devlog.md`; uses the released binary.

### E33 -- `kazi mcp` as a first-class installed subcommand (P1, ADR-0044)

ADR-0024 named a `kazi mcp` server as a self-teaching surface, but the installed
binary never grew the verb: `Kazi.MCP.Server` is reachable only via `mix kazi.mcp`,
which a `brew install`ed agent cannot run. This promotes the existing server to a
binary verb so an outer agent learns the surface from tool schemas, not prose. No new
tools; a packaging/entry-point decision. The quick, low-risk win that completes the
ADR-0025 on-ramp.

- [x] T33.1 Add the `kazi mcp` verb: dispatch `["mcp"]` in `Kazi.CLI` to the existing `Kazi.MCP.Server` over stdio; same server `mix kazi.mcp` starts (shared module, no fork).  Owner: TBD  Est: 1h  verifies: [UC-035, infrastructure]  deps: []  acc: ExUnit -- `kazi mcp` starts the server, lists the same tools as `mix kazi.mcp`, and answers a `kazi_status` call; non-TTY/stdio-framed; absent the verb, argv handling is unchanged.  Done 2026-06-25 (PR #485; shipped in release v1.10.0; ExUnit: `kazi mcp` boots the shared server, lists the same tools as `mix kazi.mcp`, answers kazi_status; argv unchanged when verb absent; no production URL surface -- verified by the stdio/CLI test suite via green CI).
- [x] T33.2 Document the verb + self-conformance: `kazi help --json` lists `mcp`; the harness-onboarding self-conformance test (ADR-0022/0023) asserts every advertised verb -- including `mcp` -- is dispatchable on the installed binary; doc-freshness gate (ADR-0036) covers it.  Owner: TBD  Est: 1h  verifies: [UC-035, infrastructure]  deps: [T33.1]  acc: ExUnit -- `help --json` contains `mcp`; a test fails if an advertised verb is not dispatchable; freshness gate green.  Done 2026-06-25 (PR #495; `kazi help --json` lists `mcp`; self-conformance test fails if any advertised verb is undispatchable; doc-freshness gate green; no production URL surface -- verified by the help-json + conformance + freshness tests via green CI).
- [x] T33.3 Emit the canonical client config everywhere: `kazi install-skill` / `kazi init --with-mcp` / generated skill / `AGENTS.md` / README reference `{command:"kazi",args:["mcp"]}`; trim the prose that taught the JSON-CLI shell-out to a fallback note.  Owner: TBD  Est: 1.5h  verifies: [UC-035, UC-036]  deps: [T33.1]  acc: the generated config + docs reference the binary verb; the on-ramp text leads with MCP, JSON-CLI demoted to fallback; canonical-strings/coherence intact.  Done 2026-06-25 (PR #521; install-skill / generated skill / AGENTS.md / README now emit the canonical `{command:"kazi",args:["mcp"]}` client config, on-ramp leads with MCP and demotes the JSON-CLI shell-out to a fallback note; canonical-strings/coherence + doc-freshness green; no production URL surface -- verified by the generated-config + coherence tests via green CI).
- [x] T33.4 Release-parity smoke: the Burrito release includes the MCP server path; a post-build smoke (start via the installed `kazi mcp`, list tools, call `kazi_status`) runs in CI/release.  Owner: TBD  Est: 1h  verifies: [UC-035, infrastructure]  deps: [T33.1]  acc: the installed binary (not `mix`) starts `kazi mcp` and answers a tool call in a release-stage smoke; failure blocks the release.  Done 2026-06-25 (PR #515; `.github/scripts/mcp_release_smoke.sh` + a release.yml step start the INSTALLED `kazi mcp`, list tools, call `kazi_status`, failure blocks the release; documented in docs/oss-gates.md + ADR-0044. The release-stage smoke is wired as a release gate and first executes on the next release cut -- not yet observed in a live release run (honest).

### E34 -- Economy accounting envelope: cached-vs-fresh tokens + cost-per-converged-predicate (P1, ADR-0046)

Harness profiles collapse usage into one `tokens` integer, hiding cached-read vs
fresh input -- so the caching wins (T19.2 stable prefix, E35 stuck-bundle) look like
a cost on the books and the whole token-economy thesis is unfalsifiable. This splits
usage into a per-iteration envelope, stops budgeting cached reads as fresh input, and
makes the KPI cost-per-converged-predicate. Foundational: E35/E36 need it to report
their wins. Additive schema, `budget_spent.tokens` kept.

- [x] T34.1 Define the `usage` envelope (additive): `{input_tokens, cached_input_tokens, cache_write_tokens, output_tokens, reasoning_tokens, cost_usd}` in the `--json` result; optional fields (absent = unreported); minor `schema_version` bump; `budget_spent.tokens` preserved.  Owner: TBD  Est: 1.5h  verifies: [UC-033, infrastructure]  deps: []  acc: ExUnit -- the emitter renders the envelope when fields are present and omits absent fields; an orchestrator pinning the old contract still reads `budget_spent.tokens`; schema bump is non-breaking (not v2.0.0).  Done 2026-06-25 (PR #486; shipped in release v1.11.0 via new `Kazi.CLI.Usage` renderer, present-fields-only/absent-omitted, `budget_spent.tokens` back-compat rollup, MCP run result mirrored, run-result.md + `kazi schema` updated). DEVIATION (flagged): kept `schema_version = 2` (NOT bumped) -- bumping the integer would break an orchestrator pinning `== 2`, violating the acc; the package release is the minor bump (1.10.0->1.11.0). The cached/fresh token SPLIT is deferred to T34.2.
- [x] T34.2 Parse the breakdown per profile + fidelity marker: stop `claude.ex` `total_tokens/1` from summing the four Anthropic fields away -- map `input_tokens`/`output_tokens`/`cache_creation_input_tokens` (-> `cache_write_tokens`)/`cache_read_input_tokens` (-> `cached_input_tokens`) onto the envelope (preserve raw usage alongside); do the same for the `codex` cached-token usage; add `usage_fidelity: full|partial|none`; a harness that cannot report a field omits it.  Owner: TBD  Est: 2h  verifies: [UC-033, infrastructure]  deps: [T34.1]  acc: ExUnit on fixture provider output -- claude/codex usage maps to the envelope; a profile with no usage reports `none` (not zeros); raw usage retained; a live smoke asserts the current provider shape still maps.  Done 2026-06-25 (PR #501, ships in v1.16.0 autorelease #503; new `Kazi.Harness.Usage` mapper -> T34.1 envelope + `usage_fidelity` (:full/:partial/:none); :claude maps the 4 Anthropic fields (cache_creation->cache_write, cache_read->cached_input) instead of summing, raw retained, back-compat rollup untouched; :codex split mapped the same; unreported fields OMITTED, no-usage turn -> :none (never zeros). `usage_fidelity` is INTERNAL, schema_version stays 2. HONEST-SKIP: the `:codex_live`-tagged smoke (current codex usage shape) is default-excluded and was not run (no codex creds in env); fixture tests cover the mapping.
- [x] T34.3 Per-iteration `context` + `tools` counters: `{orientation_cache, retrieval_cache, orientation_tokens, evidence_tokens, retrieval_tokens}` and `{tool_calls, file_reads, search_calls, graph_calls}` in the iteration event, so a working stable prefix shows rising cached reads + falling file/search calls.  Owner: TBD  Est: 2h  verifies: [UC-033, infrastructure]  deps: [T34.1]  acc: ExUnit -- an iteration records cache hit/miss + the token/tool counters; the E19 arms can attribute outcomes to them.  Done 2026-06-25 (PR #549; per-iteration `context` {orientation_cache, retrieval_cache, orientation_tokens, evidence_tokens, retrieval_tokens} + `tools` {tool_calls, file_reads, search_calls, graph_calls} counters added additively to the iteration event/read-model; cache hit/miss + token/tool counters recorded so the E19 arms can attribute outcomes; no production URL surface -- verified by the Tier 1/2 iteration tests via green CI).
- [x] T34.4 Budget guard discounts cached reads: account `cached_input_tokens` at a configurable discount (provider cache-read ratio, or a low flat weight when unknown) so a cache-hit-heavy run is not falsely `over_budget`; the terminal gate logic is unchanged, only the cost arithmetic.  Owner: TBD  Est: 1.5h  verifies: [UC-033, UC-030]  deps: [T34.2]  acc: ExUnit -- a run that is fresh-cheap but cached-heavy stays under budget where the old all-equal arithmetic would trip `over_budget`; the gate behaviour otherwise identical.
- [x] T34.5 `cost_usd` via a dated, versioned price map: a single price table (model -> input/cached/output/reasoning prices, dated); when a model is absent, report tokens with `cost_usd` omitted -- never a guessed cost.  Owner: TBD  Est: 1.5h  verifies: [UC-033]  deps: [T34.2]  acc: ExUnit -- a known model yields `cost_usd`; an unknown model omits it; the price map is dated and lives in one place.
- [x] T34.6 Run-end economy KPIs: derive cost/converged-predicate, wall-clock/converged-predicate, iterations-to-convergence, fresh-input-avoided, rediscovery-tool-calls-avoided, and stuck-rate by harness/model/context-tier from the per-iteration envelopes; surface in the run result + benchmark output.  Owner: TBD  Est: 2h  verifies: [UC-033]  deps: [T34.3]  acc: ExUnit/bench -- the KPIs compute from a recorded run; the T19.5/T19.7 benchmark consumes them; honest when a field is unreported.  Done 2026-06-25 (PR #560; new `Kazi.Economy.KPIs` pure fold derives cost/wall-clock per converged-predicate, iterations-to-convergence, fresh-input-avoided, rediscovery-tool-calls-avoided, stuck-rate, broken down by harness/model/context-tier from the recorded per-iteration envelopes (T34.1/T34.2/T34.3); additive `economy` object on `apply --json` + MCP + `kazi schema`; `mix kazi.bench --kpis` consumes them (T19.5/T19.7); unreported inputs -> KPI omitted/n-a (never fabricated, no div-by-zero), recorded-but-unhit counter is a real 0; docs/schemas/run-result.md updated. No production URL surface -- verified by Tier 1/2 incl. read-model + bench tests via green CI.
- [ ] T34.7 Finish T19.5 with the envelope: run the multi-iteration benchmark (T19.4) reporting cached-vs-fresh deltas + cost/converged-predicate; record the keep/revert verdict for the stable-prefix wiring in `docs/devlog.md`.  Owner: TBD  Est: 1.5h  verifies: [UC-033, infrastructure]  deps: [T34.6, T19.4]  acc: a devlog entry with the A/B/C table in cost/converged-predicate + cached-read terms and a clear verdict; honest if inconclusive. (Subsumes/unblocks T19.5.)

### E35 -- Context-store layer + Gist provider: evidence compression + stuck-bundle replay (P2, ADR-0045)

A `context_store` layer distinct from structural orientation (ADR-0010) and embedding
retrieval (ADR-0012): budget-fitted retrieval over heavy TEXT artifacts and repeated
loop evidence, `sirerun/gist` as the first provider. The payoff is not indexing
source -- it is compressing repeated loop evidence between iterations and a compact
stuck-bundle so ADR-0035 escalation does not re-pay for the lower rung's transcript.
Opt-in until the byte-reduction ratio is proven on real kazi runs. Phased: MVP flag
-> stuck-bundle -> `kazi context` wrapper -> `init --with-gist`.

- [x] T35.1 `Kazi.ContextStore` behaviour + source labels: `index/3`, `search/3`, `stats/1`; SHA-scoped label helpers (`kazi:run:<goal_id>:iter:<n>:test-log`, ...) keyed by goal/iteration/predicate/git-SHA so changed files invalidate cleanly.  Owner: TBD  Est: 2h  verifies: [UC-033, infrastructure]  deps: []  acc: ExUnit -- the behaviour + label helpers produce stable, SHA-scoped labels; same input -> same label; a changed SHA yields a new label.
- [x] T35.2 `Kazi.ContextStore.GistCLI` adapter: shell to `gist index`/`gist search --budget N`/`gist stats`; PATH-detect `gist`; in-memory default, PostgreSQL when `KAZI_GIST_DSN` is set; a fake `gist` executable fixture so CI needs no Postgres/network.  Owner: TBD  Est: 2.5h  verifies: [UC-033, infrastructure]  deps: [T35.1]  acc: ExUnit against the fake `gist` -- index then search returns budget-fitting snippets + stats; missing `gist` on PATH degrades gracefully (store disabled, run unaffected).
- [x] T35.3 Redact-before-index (non-negotiable): apply the SAME secret redaction kazi applies to harness prompts (ADR-0009) to every artifact BEFORE indexing; an un-redacted store is a credential store.  Owner: TBD  Est: 1.5h  verifies: [UC-033, infrastructure]  deps: [T35.1]  acc: ExUnit -- a planted credential in a test log is redacted before it reaches the store; a search never returns the secret; redaction parity with the prompt path is asserted.
- [x] T35.4 Loop integration -- evidence compression: index any artifact over the threshold (default 5 KB) under its label; keep only label+checksum+byte-count+short-summary in loop state (not bytes); before the next harness turn, query for the failing predicate + changed files + recent error signature and inject only returned snippets under the budget.  Owner: TBD  Est: 3h  verifies: [UC-033, infrastructure]  deps: [T35.2, T35.3]  acc: ExUnit -- a >5 KB test log is indexed, loop state holds the label not the bytes, and the next dispatch carries ranked snippets under the budget; sub-threshold artifacts inline as today.
- [ ] T35.5 `kazi apply --context-store gist --context-budget N` + additive stats: the opt-in flag wires the store into dispatch; the result gains an additive `context_store` object (`indexed_bytes`/`returned_bytes`/`saved_bytes`/`budget`).  Owner: TBD  Est: 1.5h  verifies: [UC-033, infrastructure]  deps: [T35.4, T34.1]  acc: ExUnit -- the flag enables the store; `--json` carries `context_store` stats; absent the flag the result is byte-identical to today.
- [ ] T35.6 Stuck-bundle replay for escalation: on `stuck`, assemble a compact bundle (failing predicates, last changed files, top store snippets for error signatures, last test command + normalized failure, minimal diff summary) and have the ADR-0035 escalation hand THAT to the higher rung, not the lower-rung transcript.  Owner: TBD  Est: 2.5h  verifies: [UC-033, UC-043]  deps: [T35.4]  acc: ExUnit -- a stuck run produces a bounded bundle within the stuck budget; the escalation prompt carries the bundle, not the full transcript; bundle size is bounded + reported.
- [x] T35.7 `kazi context index|search|stats` wrapper CLI: a thin wrapper so users learn one CLI; `--provider gist`, `--budget N`, `--json`; Gist stays independently usable.  Owner: TBD  Est: 1.5h  verifies: [UC-033, infrastructure]  deps: [T35.2]  acc: ExUnit -- `kazi context index/search/stats` proxy to the provider; `--json` output is parseable; documented in `kazi help --json`.
- [x] T35.8 `kazi init --with-gist`: verify `gist doctor`, write `.kazi/context.toml`, create project-local MCP config if supported, recommend `KAZI_GIST_DSN`; do NOT mutate global agent config unless explicitly asked.  Owner: TBD  Est: 1.5h  verifies: [UC-033, UC-036]  deps: [T35.2]  acc: ExUnit -- `init --with-gist` on a fixture writes `.kazi/context.toml` + project MCP config and leaves global config untouched; absent `gist`, it reports the missing dep, not a crash.
- [ ] T35.9 Inner-prompt contract + outer-indexes/inner-searches: add the inner rule ("use provided snippets as evidence; request a targeted source/query; do not ask for whole logs/docs"); inner harnesses get `gist_search` but not arbitrary indexing unless the goal opts in.  Owner: TBD  Est: 1h  verifies: [UC-033, infrastructure]  deps: [T35.4]  acc: ExUnit/docs -- the inner prompt carries the rule; an inner harness's index attempt is denied by default; the contract is documented.
- [ ] T35.10 LIVE dogfood + promote-or-keep verdict: run kazi with the store on real multi-iteration goals in this repo; record the real `indexed->returned` ratio + cost/converged-predicate (E34) in `docs/devlog.md`; decide opt-in-default only if the measured ratio holds (honest if it does not).  Owner: TBD  Est: 2h  verifies: [UC-033]  deps: [T35.5, T35.6, T34.6]  acc: a devlog entry with the real ratio + cost deltas on >=2 real runs and a clear keep-opt-in / promote-to-default recommendation; every number observed, not asserted.

### E36 -- Inner-harness minimalism: tool-surface restriction now, context tiers measured (P2, ADR-0047)

Two inner-loop levers. Tool-surface restriction is low-risk and committed now (fewer
tool schemas in context, narrower action space). Context-budget tiers 0-4 are defined
(default tier 1, escalate on non-progress) but the ladder thresholds are GATED on the
E19/E34 benchmark, not hardcoded -- the repo's own discipline says measure first. KPI
is cost-per-converged-predicate; any change that lowers tokens but raises stuck-rate
enough to raise that KPI is reverted.

- [x] T36.1 Claude profile economy flags (commit now): extend `supported_opts`/`build_args` with `:tools -> --tools`, `:disallowed_tools -> --disallowedTools`, `:strict_mcp_config -> --strict-mcp-config`, `:mcp_config -> --mcp-config`, `:max_turns -> --max-turns`, `:exclude_dynamic_system_prompt_sections`, `:no_session_persistence`; absent the opts, argv is byte-identical to today.  Owner: TBD  Est: 1.5h  verifies: [UC-033, infrastructure]  deps: []  acc: ExUnit -- each opt appends its flag; absent all of them the golden transcript is unchanged; a version-gated capability check drops an unsupported flag rather than erroring.  Done 2026-06-25 (PR #476; shipped in release v1.8.0; ExUnit golden-transcript unchanged when opts absent, each opt appends its flag, version-gated drop covered; no production URL surface -- verified by the test suite via green CI).
- [x] T36.2 Minimal default surface per dispatch: default a reconcile dispatch to `--strict-mcp-config` exposing only the MCP servers kazi injected (orientation/graph + the E35 store in search-only mode) plus the edit/shell tools the task needs -- not the ambient set.  Owner: TBD  Est: 2h  verifies: [UC-033, infrastructure]  deps: [T36.1]  acc: ExUnit -- a dispatch carries only the injected servers + needed tools; an irrelevant ambient MCP server's schemas are absent from the prompt; the default surface is "injected + standard edit/shell", never empty.  Done 2026-06-25 (PR #499; default reconcile dispatch sets `--strict-mcp-config` to only kazi-injected servers + needed edit/shell tools, ambient MCP schemas excluded, surface never empty; E35 store left as a documented seam (not built yet); no production URL surface -- verified by the Tier 1 dispatch-surface tests via green CI).
- [x] T36.3 Context-tier scaffolding (define, default tier 1): name tiers 0-4 (evidence-only / +cached orientation / +graph / +retrieval snippets / +compact snapshot); default tier 1; record the active tier in the ADR-0046 `context` envelope.  Owner: TBD  Est: 2h  verifies: [UC-033, infrastructure]  deps: [T34.3]  acc: ExUnit -- a dispatch defaults to tier 1; the active tier is recorded per iteration; tier 0 and tier 2 can be selected and change the assembled context as specified.  Done 2026-06-25 (PR #562; context tiers 0-4 named (evidence-only / +cached orientation / +graph / +retrieval / +compact snapshot), default tier 1, active tier recorded per iteration in the ADR-0046 `context` envelope; tier 0/1/2 assemble demonstrably different context; no production URL surface -- verified by the Tier 1 default/selection/recording tests via green CI).
- [x] T36.4 Escalate context on non-progress (thresholds = config, benchmark-derived): on non-progress against the same failing set (the ADR-0041 score gradient), step the tier up; the ladder thresholds are config with E19/E34-derived defaults, NOT hardcoded; a stop rule reverts any net-negative change.  Owner: TBD  Est: 2h  verifies: [UC-033, UC-043]  deps: [T36.3, T34.6]  acc: ExUnit -- a stalled run escalates the tier; thresholds load from config; a change that raises cost/converged-predicate is reverted by the stop rule; no guessed ladder shipped as proven.  Done 2026-06-25 (PR #571; on non-progress against the same failing set (ADR-0041 score gradient) the loop steps the context tier up; ladder thresholds load from config with E19/E34-derived defaults (not hardcoded); a stop rule reverts a cost-up/no-progress escalation; no production URL surface -- verified by the Tier 1 escalation/config/stop-rule tests via green CI).
- [ ] T36.5 Benchmark arms map to the knobs: extend the T19.4 harness with arms for tier 0-4 and tool-surface on/off; record the verdict (which tier/surface minimizes cost/converged-predicate per task class) in `docs/devlog.md`.  Owner: TBD  Est: 2h  verifies: [UC-033]  deps: [T36.2, T36.3, T34.6]  acc: a devlog table comparing the arms on cost/converged-predicate + stuck-rate; the tier defaults are set FROM this data, honest if a lever is net-neutral.

### Waves

Recommended order. The two independent tracks (E12->E13 and E14) can run alongside
the adoption spine (E15->E16->E17). E9 leftovers are tiny and independent.

- **Wave E9 (polish, parallel):** T9.5 (Playwright smoke), T9.6 (perf/a11y). Independent of everything else.
- **Wave E12-1 (model + guard):** T12.1 (declared `[[group]]` taxonomy) -> T12.2 (`Predicate.group` + reference/cycle validation -- the drift guard). Pure loader work.
- **Wave E12-2 (tree + budgets):** T12.3 (tree + per-group rollup), T12.4 (derived per-group budgets) -- after the model.
- **Wave E12-3 (export):** T12.6 (Obsidian/Mermaid exporter), T12.7 (lint near-duplicate names).
- **Wave E13-1 (import intent):** T13.1 (OpenAPI), T13.2 (gherkin), T13.3 (prose via harness) -- emit grouped predicates (depends on the E12 model: T12.1/T12.2).
- **Wave E13-2 (dead code):** T13.4 (surface scanner) -> T13.5 (coverage meta-predicate).
- **Wave E13-3 (dogfood):** T13.6 (an external service via the general path; note the live-predicate escalation).
- **Wave E14-1 (harness onboarding):** T14.1 (conformance test helper) -> then T14.2 (Codex), T14.3 (Antigravity), T14.4 (claw-code) in PARALLEL (independent profiles).
- **Wave E14-2 (wire + document):** T14.5 (CLI + coherence + docs) -> T14.6 (contributor recipe).
- **Wave E15-1 (JSON surface):** T15.1 (JSON framework + non-interactive guarantee) -> then T15.2 (propose), T15.3 (run result contract), T15.5 (status), T15.6 (authoring state machine) in PARALLEL.
- **Wave E15-2 (stream + conform):** T15.4 (JSONL streaming) -> T15.7 (kazi self-conformance; needs T14.1).
- **Wave E15-3 (recipe + dogfood):** T15.8 (orchestrator recipe + schemas) -> T15.9 (live claude->kazi->claw/Qwen nested loop; honest result).
- **Wave E16-1 (self-description):** T16.1 (`help --json`/`schema`) -> T16.2 (skill + `install-skill`), T16.3 (`AGENTS.md`) -> T16.4 (coherence guard).
- **Wave E16-2 (MCP + live):** T16.5 (`kazi mcp`), T16.6 (Claude Code drives kazi via the skill, live).
- **Wave E17 (adoption rewrite) -- SUPERSEDED by Wave E25 (ADR-0030); do NOT dispatch.** The README/site/OG/quickstart content (T17.1/T17.2/T17.4/T17.5) is executed under E25 (and the doc-sync E28); only T17.3 (concept positioning, done) belonged to E17. ADR-0025's lead-order still governs E25. (Pool sessions: skip this wave -- see the E17 epic banner.)
- **Wave E18 (benchmark bug fixes, parallel):** T18.1, T18.2, T18.3, T18.4 are independent (different files) and run in PARALLEL -> T18.5 (re-verify + lint) after all. Independent of E12-E17; safe to land first since they harden the run loop everything else exercises.
- **Wave E19-1 (token-efficiency wiring):** T19.1 (inject the cached orientation pack as a stable prompt prefix on the live loop) -> T19.2 (Anthropic `cache_control` on the stable prefix) -> T19.3 (use `truncate_evidence/2` on the live dispatch path). Sequential: each refines `dispatch_prompt`/the adapter.
- **Wave E19-2 (measure):** T19.4 (multi-iteration benchmark harness) -> T19.5 (run + record A/B/cached numbers). After E18 (clean persistence) and E19-1.
- **Wave E19-3 (in-family tiering, ADR-0033):** T19.6 (`claude --model` enabler -- unblocked now) -> T19.7 (Claude-tiering cost benchmark: frontier-authors -> cheap-Claude-grinds vs vanilla-frontier).
- **Wave E20-L1 (gate, no NATS -- start here):** T20.1 (`acc:`->predicates) -> T20.2 (pool gate recipe) -> T20.3 (opt-in `/apply --verify-with-kazi`); T20.11 (live L1 dogfood) after T20.3. Independently valuable; ships before any NATS.
- **Wave E20-L2 (objective-done loop):** T20.4 (orchestrator recipe) -> T20.5 (per-task tiering, optional).
- **Wave E20-L3 (blast-radius leases, NATS):** T20.6 (per-task lease) -> T20.7 (`/claim`<->lease boundary + deadlock safety).
- **Wave E20-L4 (observability):** T20.8 (live dashboard/lease map) after T20.6/T20.4. (T20.9 Telegram WITHDRAWN -- ADR-0029, removed in E24.)
- **Wave E20-docs:** T20.10 (the adoption guide) after L1+L3+L4 land.
- **Wave E21-1 (native scheduler core, single-node NATS-free):** T21.1 (scheduler + DynamicSupervisor) -> T21.2 (wire Partition), T21.3 (lease lifecycle), T21.4 (worktree per partition) in parallel after T21.1.
- **Wave E21-2 (integration + correctness):** T21.5 (merge convergence), T21.6 (overlap policy), T21.7 (per-partition budgets).
- **Wave E21-3 (surface + resilience):** T21.8 (CLI + `--json` collective), T21.9 (dashboard), T21.10 (supervision/restart).
- **Wave E21-4 (position + prove):** T21.11 (docs lead with native parallelism) -> T21.12 (live NATS-free multi-partition dogfood).
- **Wave E22 (pre-publish docs -- LAST, gated on E15-E21):** T22.1 (coverage audit) -> T22.2 (README), T22.3 (concept), T22.4 (docs index) in parallel -> T22.5 (website) -> T22.6 (docs presentation) -> T22.7 (accuracy audit) -> T22.8 (launch+publish) -> T22.9 (announcement). This wave runs only after every feature epic has landed.
- **Wave E23-1 (dep model):** T23.1 (`needs` edges in the taxonomy) -> T23.2 (DAG + ready-set, pure). Needs E12 (T12.1/T12.2, done).
- **Wave E23-2 (scheduling):** T23.3 (topological + spatial, pipelined) -> T23.4 (regression re-gating), T23.5 (blocked-dep escalation). Needs E21 (T21.1/T21.2).
- **Wave E23-3 (surface):** T23.6 (CLI/`--json`/`--explain`), T23.7 (DAG dashboard).
- **Wave E23-4 (position + prove):** T23.8 (docs/positioning) -> T23.9 (live dep-DAG dogfood).
- **Wave E25-1 (assets, parallel -- can start now):** T25.1 (tagline/noun), T25.2 (hero transcript), T25.5 (agent-voiced testimonial), T25.6 (invocation phrase), T25.7 (dogfood "done" leaderboard) are independent and run in parallel.
- **Wave E25-2 (surfaces):** T25.3 (README) -> T25.4 (website) ; T25.8 (docs quickstart) alongside.
- **Wave E25-3 (launch):** T25.9 (OG + Show HN/X kit) -> T25.10 (accuracy gate + live publish). Supersedes the messaging of the open E17 + E22 README/site tasks (execute those per ADR-0030 here).
- **Wave E25-4 (token economy, ADR-0033):** T25.11 ("token economy without local models" content) after T19.6 (the `claude --model` enabler); the cost number stays "designed for / being measured" until T19.7.
- **Wave E25-5 (community links, quick win):** T25.12 (Discussions + Docs/Community links on README + site; closes all-stars.md gap #10). Unblocked now (deps []); independent of the E25 content rewrite.
- **Wave E26-1 (router):** T26.1 (router SKILL.md + dispatch) -> T26.2 (`kazi plan`), T26.3 (`kazi apply`), T26.4 (`status`/`adopt`) in parallel -> T26.5 (coherence + retire loop/qualify from the code on-ramp).
- **Wave E26-2 (prove):** T26.6 (live router dogfood; subsumption claim gated on T21.12/T23.9).
- **Wave E27-1 (CLI rename, autonomous -- start now):** T27.1 (verbs + aliases) -> T27.3 (schema bump) -> T27.4 (help/schema); T27.2 (mix task) in parallel after T27.1.
- **Wave E27-2 (surfaces):** T27.5 (skill/AGENTS/MCP), T27.6 (README/site/docs), T27.7 (deprecation note) in parallel after T27.4.
- **Wave E27-3 (prove):** T27.8 (live verify new verbs + aliases) after T27.1-T27.3.
- **Wave E28 (doc-sync, autonomous -- start now):** T28.1 (concept scheduler), T28.2 (concept waves + agent/router) in PARALLEL now (no deps) -> T28.3 (README how-it-works + ADRs, after T27.6 for verb consistency) -> T28.4 (accuracy + coherence gate).
- **Wave E29 (OSS gates, autonomous):** T29.1 (docs-with-code CI guard), T29.2 (no-leak CI guard) in PARALLEL -> T29.3 (scrub existing leaks, after T29.2). Independent of feature epics; safe to land early.
- **Wave E30 (adaptive tiering, skill-driven, ADR-0035):** T30.1 (skill+AGENTS.md default to in-family tiering) + T30.3 (verify `--json` signal sufficiency) in PARALLEL -> T30.2 (escalate-on-stuck recipe) -> T19.7 (3-arm benchmark incl. escalating) -> T30.4 (live escalation dogfood) ; T30.5 (accuracy+coherence gate) + T25.11 (content) after T30.1/T30.2. Skill-layer only; no kazi-core policy. T30.1/T30.3 unblocked now.
- **Wave E31 (self-maintaining docs, ADR-0036):** T31.1 (split-plan migration) -> T31.2 (deterministic trim tool) -> T31.3 (gated extraction) ; T31.4 (freshness predicates, parallel/unblocked) -> T31.5 (freshness CI gate) ; T31.6 (standing goal) after T31.2+T31.4 AND the E32 keystones (T32.1 `custom_script` + T32.2 envelope-v2) -- the freshness predicates WRAP the T31.4 scripts via E32's protocol, not a bespoke engine -> T31.7 (live dogfood on this repo) -> T31.8 (docs/positioning). Logic in skill+CI; kazi drives. T31.1/T31.4 unblocked now.
- **Wave E32-1 (framework first -- the keystones):** T32.1 (`custom_script` generic protocol) + T32.2 (envelope v2: score + direction + structured evidence) in PARALLEL (independent: a new provider vs the result shape) -> T32.1b (fold `test_runner`/`prod_log` onto the unified core + deprecate, after T32.1) + T32.3 (first-class `ratchet` mode, after T32.2). These unlock everything else; build before any concrete provider. T32.1b ships non-breaking (presets + deprecation hint); the v2.0.0 removal of the names is a separate future task.
- **Wave E32-2 (anti-gaming enforcement -- the thesis):** T32.4 (enforcement profile: clean-tree checker + read-only leasing + skipped-as-failed + ratchet guards) after T32.2/T32.3 -> T32.5 (diff-inspection guard) + T32.6 (held-out acceptance subset) in PARALLEL after T32.4. PRECONDITION for T32.4: verify the "checker outside the agent's reach" seam against `loop.ex` (ADR-0042).
- **Wave E32-3 (concrete providers -- prove the framework):** T32.7 (`:static`, Dialyzer-led) + T32.8 (`:coverage`/`:property`/`:mutation`) in PARALLEL after T32.3 ; T32.9 (security/contract/perf `custom_script` recipes) after T32.1/T32.3 ; T32.10 (live upgrades: sustained-health/`:metrics`/burn-rate/journey) after T32.2. All independent of each other.
- **Wave E32-4 (prove):** T32.11 (live dogfood: the expanded catalog converges a real fixture under enforcement) after T32.4/T32.7/T32.8/T32.9/T32.10. Gated by the feature-complete dogfood policy (released binary).
- **Wave E33 (`kazi mcp` installed, ADR-0044):** T33.1 (add the verb) -> T33.2 (help + self-conformance) + T33.3 (canonical config everywhere) + T33.4 (release-parity smoke) in PARALLEL after T33.1. Small, independent, unblocked now; completes the ADR-0025 on-ramp.
- **Wave E34 (economy accounting, ADR-0046):** T34.1 (usage envelope) -> T34.2 (parse per profile + fidelity) + T34.3 (context/tools counters) in PARALLEL -> T34.4 (cached-read discount, after T34.2) + T34.5 (price map, after T34.2) -> T34.6 (run-end KPIs, after T34.3) -> T34.7 (finish T19.5 with the envelope). Foundational + unblocked now; E35/E36 report their wins through it.
- **Wave E35 (context-store + Gist, ADR-0045):** T35.1 (behaviour + labels) -> T35.2 (GistCLI adapter) + T35.3 (redact-before-index) in PARALLEL -> T35.4 (loop evidence compression) -> T35.5 (`--context-store` flag + stats, also needs T34.1) + T35.6 (stuck-bundle) + T35.7 (`kazi context` wrapper) + T35.8 (`init --with-gist`) + T35.9 (inner-prompt contract) -> T35.10 (live dogfood + promote-or-keep verdict, needs T34.6). Opt-in until measured; depends on E34 to report savings.
- **Wave E36 (inner-harness minimalism, ADR-0047):** T36.1 (Claude economy flags, commit now, unblocked) -> T36.2 (minimal default surface) ; T36.3 (tier scaffolding, after T34.3) -> T36.4 (escalate-on-non-progress, thresholds from the benchmark, after T34.6) -> T36.5 (benchmark arms map to the knobs). Tool-surface lands first; the tier ladder is GATED on the E19/E34 benchmark, not hardcoded.

## Risk Register

| ID | Risk | Impact | Likelihood | Mitigation |
|----|------|--------|------------|------------|
| R-E12-1 | Free-text grouping fragments the hierarchy on inconsistent spelling. | Med | Med | The taxonomy is DECLARED and referenced by id, validated at load (T12.1/T12.2); slug normalization + a `kazi lint` near-duplicate-name warning (T12.7) are the second net. ADR-0020. |
| R-E13-1 | The prose->predicate path (T13.3) is non-deterministic (an LLM extracts intent). | Med | High (inherent) | Route through the existing HUMAN-REVIEWED authoring/clarify flow (nothing accepted without approval); the deterministic spec path (OpenAPI/gherkin) is the trustworthy backbone. ADR-0021. |
| R-E13-2 | The surface scanner (T13.4) is language-specific and blind to reflection/string-dispatch, risking false dead-code flags. | Med | High (inherent) | Approximate-by-design + an explicit allow-list + WARN-don't-auto-delete (T13.5); documented in `docs/lore.md`. ADR-0021. |
| R-E14-1 | Antigravity `agy -p` SILENTLY drops stdout under a non-TTY subprocess (issue #76) -- exactly kazi's mode. | High | High (observed in research) | T14.3 uses the `--prompt-file` + `--output json` (read a file) workaround, NOT bare `-p`; pin a version; record the landmine in `docs/lore.md`. ADR-0022. |
| R-E14-2 | claw-code emits no structured output ("museum exhibit"), so cost/parse fidelity is degraded. | Low | High (inherent) | T14.4 is BEST-EFFORT only (raw-stdout parse, no invented cost), explicitly labelled demo-grade. ADR-0022. |
| R-E15-1 | The `--json` result schema is a compatibility surface an orchestrator pins against; a breaking change silently breaks callers. | Med | Med | Version it (`schema_version`, T15.3); the orchestrator recipe documents pinning; a self-conformance test (T15.7) guards regressions. ADR-0023. |
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
| R-E25-3 | E25 duplicates/contradicts the open E17 + E22 README/site tasks. | Med | Med | E25 is the CANONICAL content epic and SUPERSEDES the messaging of T17.1/2/4/5 + E22's README/site tasks (execute per ADR-0030); the wave note + this row record it so a pool session does not run both. |
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
