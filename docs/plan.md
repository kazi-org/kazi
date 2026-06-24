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

- [ ] T17.1 README rewrite to the adoption-first IA (ADR-0025): new lead = (1) one-line value (KEEP the locked positioning canonical string), (2) the on-ramp code block, (3) the 3-layer story + the remote vignette (drive Claude Code from anywhere; kazi rides along on the same machine), (4) the proof-of-convergence SVG, (5) with/without + who-it's-for, then (6) a "Reference" section that DEMOTES the current Install/Quickstart/harness/build content (kept verbatim, reordered below). An honest cost paragraph links the benchmark devlog.  Owner: TBD  Est: 2h  verifies: [UC-035]  delivers: [a README whose first screen is the claude->kazi->cheap-harness on-ramp]  deps: [T17.4]  acc: the first code block is the agent on-ramp -- it may PROMISE `kazi install-skill` marked "coming" with the T17.4 works-today recipe alongside (no command presented as working unless it is); vanilla `kazi run` appears only under "Reference"; canonical strings byte-identical (T9.9 green); the cost claim matches the devlog; every command labelled available is verified against `kazi help --json`.
- [ ] T17.2 Website rewrite to match (ADR-0025): hero leads with the on-ramp + "keep Claude Code, add provable done + cheap grind"; a PRIMARY "Use kazi with Claude Code" section (recipe / `install-skill` + the 3-layer diagram + the remote vignette); vanilla install demoted to a secondary section; reuse the proof SVG. Update `site/src/canonical.mjs` + the coherence check in lockstep.  Owner: TBD  Est: 2.5h  verifies: [UC-035]  delivers: [a website whose hero is the agent on-ramp]  deps: [T17.1]  acc: hero + primary section render the agent on-ramp; vanilla is secondary; README<->site coherence (T9.9) green; deployed + verified live at https://kazi.sire.run (golden path + mobile viewport, no console errors).
- [x] T17.3 docs/concept positioning: record the 3-layer stack (orchestrator -> kazi -> cheap harness; kazi friendly in both directions, ADR-0023) as the canonical positioning.  Owner: pool  Done: 2026-06-23  verifies: [UC-035]  delivers: [updated concept positioning]  deps: []  acc: `docs/concept.md` describes the 3-layer stack without contradicting ADR-0001 (kazi is still the outer loop for the harness, AND a tool for the orchestrator).
- [ ] T17.4 "Drive kazi from Claude Code" quickstart (works TODAY): a docs section + a top-of-README link giving the copy-paste recipe that runs on the SHIPPED JSON CLI -- `kazi propose --json` (caller-drafts) -> `kazi approve` -> `kazi run --harness <cheap> --json [--stream]` -> branch on `next_action` -- so a reader drives kazi from any agent BEFORE `install-skill` exists. Becomes the interim on-ramp for T17.1/T17.2.  Owner: TBD  Est: 1h  verifies: [UC-033, UC-035]  delivers: [a copy-paste agent recipe that works on today's CLI]  deps: [T15.8]  acc: a reader pastes the recipe into a Claude Code session and drives a fixture goal end to end on the current release; every command verified against `kazi help --json`.
- [ ] T17.5 Link-preview / OG card for sharing (adoption): render an OG/Twitter card that shows the agent on-ramp (not just the logo) so HN/X/Reddit shares preview the easy path; wire into `site/src/layouts/Layout.astro`.  Owner: TBD  Est: 1h  verifies: [UC-035]  delivers: [an OG image that previews the agent on-ramp]  deps: [T17.2]  acc: a link-preview check renders the new card; Lighthouse SEO stays >= 90; deployed live.

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
- [ ] T19.5 Run the multi-iteration benchmark + record the verdict: run T19.4; compare B vs C (does the stable prefix raise cross-dispatch cache_read / cut cost, and do fewer orientation tool-calls offset the added prefix tokens?) and A vs C (kazi vs vanilla over multiple iterations). Record honest numbers + the net verdict in `docs/devlog.md`; if C is NOT a net win, say so and recommend keeping file-based orientation.  Owner: TBD  Est: 1h  verifies: [UC-033, infrastructure]  deps: [T19.4]  acc: a `docs/devlog.md` entry with the A/B/C multi-iteration table, the B-vs-C cache-hit delta, and a clear keep/revert recommendation for the prefix wiring; honest if inconclusive.
- [x] T19.6 Enable `--model` on the `claude` profile (ADR-0033 enabler): add `:model` to the `claude` profile's `supported_opts` and append `--model <m>` in `build_args` so `kazi apply --harness claude --model <cheap-claude>` selects a cheaper Claude model (Haiku/Sonnet). This unlocks in-family tiering with NO local model.  Owner: TBD  Est: 1h  verifies: [UC-043, UC-032]  deps: []  acc: ExUnit -- `build_args` appends `--model <m>` when given; `kazi apply --harness claude --model claude-haiku-4-5` resolves + passes the model to `claude -p`; absent `--model` the argv is byte-identical to today (back-compat); golden-transcript test updated.
- [ ] T19.7 Benchmark the in-family Claude-tiering cost arm (ADR-0033, the headline cost-proof): extend the T19.4 harness with a tiering arm -- a frontier model (Opus) authors predicates ONCE via `kazi plan`, then `kazi apply --harness claude --model <cheap-claude>` drives a >=3-dispatch grind -- vs a vanilla-frontier baseline. Capture real $/tokens AND the convergence rate + correctness (a cheaper-but-fails result must be visible). Record the verdict in `docs/devlog.md`.  Owner: TBD  Est: 2h  verifies: [UC-043, UC-033]  deps: [T19.6, T19.4]  acc: a `docs/devlog.md` table comparing frontier-authors->cheap-Claude-grinds vs vanilla-frontier on $/tokens/iterations AND convergence/correctness; honest if the cheap tier fails to converge; local-Qwen arm noted as the secondary (privacy) comparison.

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
- [ ] T22.2 README final pass (build on T17.1): after the adoption-first rewrite (T17.1) lands, ADD the native-parallelization section (E21: "kazi parallelizes your plan -- single machine, no NATS"), refresh the FULL CLI reference (all `--json` commands, `status`, `schema`, `help --json`, `run --parallel`, `install-skill`, `mcp`, propose caller-drafts), and FLIP every "coming" tag to "available". Canonical strings locked; coherence (T9.9) green.  Owner: TBD  Est: 2h  verifies: [UC-035, UC-037, UC-034]  deps: [T22.1, T17.1]  acc: README documents native parallelism + the complete CLI; no "coming" tags remain; every command verified against `kazi help --json`; canonical strings byte-identical; renders on GitHub.
- [ ] T22.3 `docs/concept.md` update to the final architecture: reflect the NATIVE parallel scheduler (E21/ADR-0027) as the parallelization model -- supersede the "one process per goal / external launcher" framing -- plus the agent-drivable + self-teaching stack (E15/E16) and the 3-layer + `/apply --pool` interop (E20/ADR-0026).  Owner: TBD  Est: 1.5h  verifies: [UC-037, UC-033]  deps: [T22.1]  acc: `docs/concept.md` describes the native scheduler (partition -> lease -> supervised reconcilers -> merge), single-node-NATS-free, without contradicting ADR-0001; references ADRs 0023/0026/0027; no stale "external orchestrator only" claim.
- [ ] T22.4 `docs/` guide set complete + indexed: ensure the orchestrator recipe (T15.8), `install-skill` guide (T16.2), `AGENTS.md` (T16.3), the `/apply --pool` interop guide (T20.10), the native-parallelization guide (T21.11), and the JSON `docs/schemas` are present, accurate, and cross-linked from a `docs/README.md` index.  Owner: TBD  Est: 1.5h  verifies: [UC-033, UC-034, UC-036, UC-037]  deps: [T22.1]  acc: a `docs/` index links every guide; each guide references only real commands (checked against `kazi help --json`); no orphan/missing guide for a shipped capability.
- [ ] T22.5 Website comprehensive refresh (build on T17.2/T17.5): fold the adoption-first hero (T17.2) + ADD a native-parallelization section + a feature overview reflecting the full set + the updated recipe/CLI + the OG card (T17.5); version sourced from the manifest; `site/src/canonical.mjs` + coherence in lockstep; deploy + verify live.  Owner: TBD  Est: 2.5h  verifies: [UC-035, UC-037]  deps: [T22.2]  acc: the site renders the agent on-ramp + native parallelism + the full feature set; README<->site coherence (T9.9) green; Playwright smoke (T9.5) passes incl. mobile + the new sections; deployed + verified live at https://kazi.sire.run.
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
- [ ] T23.8 Docs + positioning: document "predicate-graph waves" as kazi's codification of `/plan`'s `deps:` + `/apply`'s Waves -- authored `needs` edges -> computed, pipelined, objectively-gated schedule; honest about the authored-deps burden + that kazi does not DERIVE semantic order. Tie to E12/E21/E22 + ADR-0028.  Owner: TBD  Est: 1h  verifies: [UC-038, UC-035]  delivers: [docs explaining predicate-graph waves vs /apply waves]  deps: [T23.6]  acc: a reader sees how to express deps as `needs` and what kazi computes from them; references only real commands/fields; coherent with ADR-0028.
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

- [ ] T25.1 Tagline -- DECIDED (operator 2026-06-24): the line-1 hook is **Your coding agent says "done." kazi proves it.** (the precise category -- "the outer/reconciliation loop for coding agents" -- is the second beat). No longer a choice; POOL wires it verbatim into `site/src/canonical.mjs` (hero tagline) + the README H1 in lockstep.  Owner: TBD  Est: 0.5h  verifies: [UC-039]  delivers: [the decided tagline wired into the canonical strings]  deps: []  acc: README H1 + the site hero render `Your coding agent says "done." kazi proves it.` byte-identically; canonical strings match (coherence T9.9 green); the precise category appears as the second line.
- [ ] T25.2 Hero asset -- the loop transcript -- DECIDED (operator 2026-06-24): RECORD A REAL CAST (no static fallback). Drive a real `claude -> kazi -> harness` run on a fixture (E18 shows clean runs work) with PREDICATES flipping false -> true ending at "goal objectively true"; capture as an asciinema cast + render an SVG/GIF. NEEDS A LIVE RUN (the operator or a live-capable session drives it; the headless pool likely cannot). This is kazi's benchmark-chart equivalent.  Owner: TBD  Est: 2h  verifies: [UC-039]  delivers: [a REAL asciinema cast (+ rendered SVG) of the loop reaching objective-true]  deps: []  acc: the asset is a genuine recording of a real reconcile run (NOT a mockup), reused in README (above install) + site hero; the underlying cast file is committed so it is reproducible/verifiable.
- [ ] T25.3 README rewrite to the paradigm (supersedes T17.1): lead = tagline (T25.1) -> hero transcript (T25.2) -> a "without kazi / with kazi" before-after block (Context7 device) -> "give your agent X" framing + the invocation phrase (T25.6) -> copy-paste wiring (the skill/`mcp` one-liner) -> agent-native social-proof row. Vanilla `kazi run` demoted to "Reference". No "coming" shown as working.  Owner: TBD  Est: 2h  verifies: [UC-039, UC-035]  delivers: [a README whose first screen sells the agent-drives-kazi paradigm]  deps: [T25.1, T25.2, T25.6]  acc: the first screen shows the agent paradigm + hero + before-after; human -> kazi appears only under "Reference"; every command verified against `kazi help --json`; coherence green; renders on GitHub.
- [ ] T25.4 Website rewrite to match (supersedes T17.2): hero = the transcript (T25.2) + the tagline; a primary "Chat with Claude Code, it drives kazi" section; without/with block; an agent-voiced testimonial (T25.5); two-layer proof (heavier on the site); vanilla demoted. Update `canonical.mjs` + coherence; deploy + verify live.  Owner: TBD  Est: 2.5h  verifies: [UC-039, UC-035]  delivers: [a website hero that leads with the agent paradigm]  deps: [T25.3, T25.5]  acc: hero + primary section render the agent paradigm + hero asset; README<->site coherence (T9.9) green; Playwright smoke (T9.5) passes incl. mobile + the new sections; deployed + verified live at https://kazi.sire.run.
- [ ] T25.5 Agent-voiced testimonial(s) (Serena pattern, uniquely on-brand): capture a coding agent describing -- in its own words -- what kazi lets it do (e.g. "I stop claiming done when it isn't"); HONEST + labelled as agent-authored. Use on README social-proof row + site.  Owner: TBD  Est: 1h  verifies: [UC-039]  delivers: [1-2 agent-authored testimonials, labelled]  deps: []  acc: the testimonial is clearly attributed to the agent that produced it; not fabricated human quotes; renders on both surfaces.
- [ ] T25.6 The invocation phrase -- DECIDED (operator 2026-06-24): the phrase is **"have kazi drive this until done"** (Context7 "use context7" pattern). POOL: document it identically across README/site/skill (`kazi install-skill` SKILL.md)/`AGENTS.md`, and ensure the skill trigger recognizes it so it actually drives kazi.  Owner: TBD  Est: 1h  verifies: [UC-039, UC-034]  delivers: [the decided invocation phrase, documented + wired]  deps: []  acc: "have kazi drive this until done" appears identically across README/site/skill/`AGENTS.md`; a real Claude Code session given the phrase drives kazi (or honest "coming" if the trigger is not wired yet); coherence (T16.4) green.
- [ ] T25.7 Dogfood "done" leaderboard/gallery (the recurring growth engine): a page/section listing goals a prose pipeline left subtly broken that kazi converged -- built from the dogfood fixtures (T0.12/T1.8) + the live production probe -- with a REPRODUCIBLE methodology (the number must hold up; risk #1). Self-updating where feasible; each new fixture = a new entry.  Owner: TBD  Est: 2h  verifies: [UC-039]  delivers: [a dogfood "done" gallery/leaderboard page + methodology]  deps: []  acc: the page shows >=2 real converged cases with before/after evidence + a reproducible method; no unverifiable claims; linked from README + site.
- [ ] T25.8 Docs quickstart-first (tutorial-then-reference): the first `docs/` page is a Quickstart that wires kazi into Claude Code (`install-skill`/`mcp`) and converges ONE real goal end-to-end via the agent; reference (predicate DSL, budget/stuck, `--json` schemas) follows. Cross-linked from a `docs/` index.  Owner: TBD  Est: 1.5h  verifies: [UC-039, UC-033]  delivers: [an agent-first Quickstart as the docs entry page]  deps: [T25.6]  acc: a reader follows the Quickstart and drives kazi from Claude Code end-to-end on the current release; reference pages follow; only real commands.
- [ ] T25.9 Launch kit + OG card (HN-first): an OG/Twitter card showing the agent paradigm (wire into `site/src/layouts/Layout.astro`); a Show HN title (`kazi - drive your coding agent in a loop until the goal is objectively true`) + post draft + an X thread, framed against "agents claim done but aren't"; honest, no unshipped command as working.  Owner: TBD  Est: 1.5h  verifies: [UC-039, UC-035]  delivers: [an OG card + a Show HN/X launch kit draft]  deps: [T25.3, T25.7]  acc: a link-preview check renders the card; the launch kit leads with the agent paradigm + a reproducible hook; Lighthouse SEO stays >= 90; ready for the operator to post.
- [ ] T25.10 Accuracy gate + live publish: every command across README/docs/site verified against `kazi help --json`; README<->site coherence (T9.9) + skill/`AGENTS.md` coherence (T16.4) green; version current; no dead links; deploy + verify live at https://kazi.sire.run and README renders on GitHub. Record the publish honestly.  Owner: TBD  Est: 1.5h  verifies: [UC-039, infrastructure]  deps: [T25.3, T25.4, T25.7, T25.8, T25.9]  acc: zero unshipped-command references; coherence green; live site shows the agent paradigm; README renders on GitHub; any skipped item flagged, not hidden.
- [ ] T25.11 "Token economy without local models" content (ADR-0033, the broad-appeal cost story): a README/site section + a worked example showing the in-family Claude tiering -- you chat with Claude Code, it drives kazi, EASY iterations run on a cheap Claude model (e.g. Haiku 4.5), HARD reasoning on a frontier model (e.g. Opus 4.8), and predicates keep the cheap model honest -- so any Claude Code user gets better token economy with NO local model / local GPU host. Frame local/BYOM (opencode) as the secondary PRIVACY option. HONEST: the cost number is "designed for / being measured" until T19.7 runs (no unproven figure); model ids checked against the claude-api reference.  Owner: TBD  Est: 1.5h  verifies: [UC-043, UC-039]  delivers: [a "token economy without local models" section + a worked frontier->cheap-Claude example]  deps: [T19.6]  acc: README + site show the in-family tiering example (`kazi plan` with a frontier model -> `kazi apply --harness claude --model <cheap>`); local/BYOM is the secondary privacy note; no unproven cost number stated; commands verified against `kazi help --json`; coherence (T9.9) green.

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
- [ ] T27.6 README/site/concept/docs to the new verbs: replace `kazi run`/`kazi propose` with `kazi apply`/`kazi plan` across README, site, `docs/concept.md`, and `docs/` guides (note the aliases once); update `site/src/canonical.mjs` if any verb is canonical; README<->site coherence (T9.9) green; deploy + verify live.  Owner: TBD  Est: 1.5h  verifies: [UC-041, UC-035]  deps: [T27.4]  acc: no `kazi run`/`kazi propose` as the PRIMARY verb in docs (aliases mentioned once); coherence (T9.9) green; site deployed + verified live at https://kazi.sire.run.
- [x] T27.7 Deprecation policy note -- removal version DECIDED (operator 2026-06-24): `run`/`propose`/`mix kazi.run` are deprecated aliases removed in **v0.6.0** (the next minor). Write a short `docs/` note (+ CHANGELOG entry) stating the aliases, the rationale (verb unification, ADR-0032), and the v0.6.0 removal.  Owner: TBD  Est: 0.5h  verifies: [UC-041]  delivers: [a documented v0.6.0 deprecation window for run/propose]  deps: [T27.1]  acc: the note names the aliases + the ADR-0032 rationale + the concrete v0.6.0 removal; linked from the CHANGELOG; the deprecation hint (T27.1) mentions removal in v0.6.0.
- [ ] T27.8 LIVE verify: drive a fixture goal via `kazi plan` -> approve -> `kazi apply` end to end on the built binary; confirm `kazi run`/`kazi propose` still work (with the deprecation hint); record in `docs/devlog.md`. `mix format --check-formatted` + `--warnings-as-errors` clean.  Owner: TBD  Est: 1h  verifies: [UC-041]  deps: [T27.1, T27.2, T27.3]  acc: a real run converges via the new verbs; the aliases still converge with a stderr hint; format + warnings-as-errors clean; devlog updated.
- [ ] T27.9 REMOVE the deprecated aliases in the v0.6.0 cycle (the tail of ADR-0032's deprecation window): delete the `run`/`propose` CLI verbs + the `mix kazi.run` alias task + their deprecation-hint code; remove/repoint the alias back-compat tests; mark them removed in `docs/deprecations.md` + a CHANGELOG note; bump the result-contract notes if needed. DO NOT do this until **v0.5.0 has shipped** (the rename + aliases release, PR #228) so the deprecation window is real; this is a BREAKING change scheduled for the v0.6.0 release. NOTE: this is the only OPEN item from the v0.5.0/alias collision -- the version reconciliation itself (removal target v0.5.0 -> v0.6.0) is already done across `docs/deprecations.md`, `cli.ex`, and `mix kazi.run`, so PR #228 (release 0.5.0) is safe to merge as-is.  Owner: TBD  Est: 1.5h  verifies: [UC-041]  deps: [T27.8]  acc: in a v0.6.0 branch/cycle ONLY -- `kazi run`/`kazi propose`/`mix kazi.run` no longer dispatch (they error with a clear "use `kazi apply`/`kazi plan`" message, not silently); `docs/deprecations.md` marks them removed; the alias back-compat tests are gone/repointed; `mix format`/`--warnings-as-errors` clean; not landed before v0.5.0 is released.

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
- [ ] T28.3 README "How it works" + ADR-index summary current through ADR-0032: update README's architecture/how-it-works summary + its ADR reference list to span 0021-0032 (scheduler, waves, agent-drivable, self-teaching, router, verb rename); use the new verbs (`kazi plan`/`kazi apply`), coordinating with T27.6 so verb strings match. Keep canonical strings + README<->site coherence (T9.9).  Owner: TBD  Est: 1.5h  verifies: [UC-042, UC-035]  delivers: [a README architecture summary current to ADR-0032]  deps: [T27.6]  acc: README how-it-works references the current ADRs through 0032 and the new verbs; coherence (T9.9) green; no stale "Telegram bridge"/old-verb mentions.
- [ ] T28.4 Accuracy + coherence gate: every command/flag in `concept.md` + README + `docs/` matches `kazi help --json` (apply/plan + aliases, --parallel, --explain, status, schema, install-skill, mcp); the README<->site (T9.9) + skill/AGENTS.md (T16.4) coherence checks pass; deploy + verify live if any site-rendered doc changed.  Owner: TBD  Est: 1h  verifies: [UC-042, infrastructure]  deps: [T28.1, T28.2, T28.3]  acc: zero references to non-existent commands; coherence green; if the site changed, deployed + verified live at https://kazi.sire.run.

### E29 -- OSS contribution gates: docs-with-code + no-internal-leak (P1, ADR-0034)

Enforce the two contribution rules (ADR-0034) for the PUBLIC repo. The rules are
already in the local + global CLAUDE.md and the `/apply` wave gate; E29 adds the CI
guards that make them stick, plus a one-time scrub of the existing leaks (~48 hits in
`docs/` + README found 2026-06-24: private IPs, an internal GPU host, internal
tool/codenames, personal paths).

- [x] T29.1 Docs-with-code CI guard: a CI check (script + GitHub Actions step) that FAILS a PR which changes a user-facing/behavioral surface in `lib/` (a command/flag in `cli.ex`, a predicate provider, a public API) without a corresponding `docs/`/README/`kazi help` change -- unless the PR carries a justified `[no-docs]` marker. Start strict-but-warn, then ratchet to blocking.  Owner: TBD  Est: 2h  verifies: [UC-044, infrastructure]  deps: []  acc: a PR that adds a CLI flag with no doc change fails (or warns, phase 1); a `[no-docs]` justified PR passes; a docs-included PR passes; the check is documented.
- [x] T29.2 No-internal-leak CI guard: a CI check that greps the diff (and optionally the tree) for internal-marker patterns -- private IPs (`192.168.*`, `10.*`, `172.16-31.*`), internal infra/tool/codenames, personal usernames + absolute home paths -- and FAILS on a hit, with an allow-list for legitimate cases (e.g. RFC-5737 example IPs in a fixture). Tune to avoid false positives.  Owner: TBD  Est: 2h  verifies: [UC-044, infrastructure]  deps: []  acc: a diff introducing `192.168.x.x` or an internal hostname fails; an allow-listed example IP passes; the marker list + allow-list are documented; runs in CI on every PR.
- [ ] T29.3 Scrub existing leaks from public docs/code: replace the ~48 internal-specific references in `docs/` (devlog, pool-model-tiering, drive-kazi-pooled-task, lore, concept) + README with generic terms ("a local model", "a deploy target", "an internal host") WITHOUT losing the honest engineering finding; keep history accurate. Re-run T29.2 to confirm zero hits.  Owner: TBD  Est: 2h  verifies: [UC-044]  deps: [T29.2]  acc: the no-leak guard (T29.2) reports zero hits across the repo; the engineering findings (e.g. "a local 35B was too slow") survive in genericized form; no internal IP/host/codename/personal-path remains.

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
- **Wave E17 (adoption rewrite, P1 -- can start NOW):** T17.4 (the works-today recipe) -> T17.1 (README rewrite, leads with the on-ramp; promised commands marked "coming") -> T17.2 (website rewrite + coherence + deploy) -> T17.5 (OG card). NOT gated on T16.2/T16.5: the docs may PROMISE the one-command on-ramp ahead of shipping (clearly marked), with the working recipe shown alongside (operator decision 2026-06-24; ADR-0025).
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
- **Wave E26-1 (router):** T26.1 (router SKILL.md + dispatch) -> T26.2 (`kazi plan`), T26.3 (`kazi apply`), T26.4 (`status`/`adopt`) in parallel -> T26.5 (coherence + retire loop/qualify from the code on-ramp).
- **Wave E26-2 (prove):** T26.6 (live router dogfood; subsumption claim gated on T21.12/T23.9).
- **Wave E27-1 (CLI rename, autonomous -- start now):** T27.1 (verbs + aliases) -> T27.3 (schema bump) -> T27.4 (help/schema); T27.2 (mix task) in parallel after T27.1.
- **Wave E27-2 (surfaces):** T27.5 (skill/AGENTS/MCP), T27.6 (README/site/docs), T27.7 (deprecation note) in parallel after T27.4.
- **Wave E27-3 (prove):** T27.8 (live verify new verbs + aliases) after T27.1-T27.3.
- **Wave E28 (doc-sync, autonomous -- start now):** T28.1 (concept scheduler), T28.2 (concept waves + agent/router) in PARALLEL now (no deps) -> T28.3 (README how-it-works + ADRs, after T27.6 for verb consistency) -> T28.4 (accuracy + coherence gate).
- **Wave E29 (OSS gates, autonomous):** T29.1 (docs-with-code CI guard), T29.2 (no-leak CI guard) in PARALLEL -> T29.3 (scrub existing leaks, after T29.2). Independent of feature epics; safe to land early.

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
| R-E22-3 | E22 duplicates/conflicts with E17 (both touch README/site). | Low | Med | E22 BUILDS ON E17 (T22.2 deps T17.1, T22.5 builds on T17.2/T17.5) -- it adds full coverage + the audit + the launch gate, it does not redo the IA reframe. |
| R-E23-1 | `needs` edges are AUTHORED (kazi cannot derive semantic order); the burden + the chance of wrong/missing edges fall on the operator. | Med | Med | `needs` is OPTIONAL (absent = full parallel); the edges are the irreducible semantic input (ADR-0028); `--explain` (T23.6) surfaces the resulting order so wrong/over-constrained deps are visible before a run. |
| R-E23-2 | Over-declaring `needs` re-serializes and loses kazi's parallelism advantage. | Med | Med | Declare only true precedence; T23.6 `--explain` + T23.7 dashboard show realized parallelism; spatial partitioning still parallelizes within each frontier. |
| R-E23-3 | A cycle or a stuck dep makes a sub-DAG unsatisfiable / hangs dependents. | Med | Low | Cycles rejected at load (T23.1, like ADR-0020's parent-cycle guard); a stuck/over-budget dep escalates and is NAMED (T23.5), never a silent hang. |
| R-E23-4 | E23 depends on E21 (the scheduler), which is not built yet. | High | Low | Sequencing is explicit: T23.3+ deps T21.1/T21.2; E23-1 (the pure model T23.1/T23.2) can proceed against E12 alone, ahead of the scheduler. |
| R-E25-1 | "Done" is harder to make falsifiable than "fast" (research risk #1) -- the agent-paradigm pitch misfires without a reproducible number. | High | Med | T25.7 builds the dogfood "done" leaderboard with a REPRODUCIBLE methodology (the number must hold up, the Ruff lesson); the hero transcript (T25.2) makes "objective done" visible; lead with the outcome, not the abstraction. |
| R-E25-2 | "Reconciliation controller" is a new category (education tax); the agent-driven framing may read as me-too in a crowded harness field. | Med | Med | ADR-0030: borrowed frame ("CI for coding agents") in line 1 with the precise category as the second beat; position as a different LAYER (verification), not another harness. |
| R-E25-3 | E25 duplicates/contradicts the open E17 + E22 README/site tasks. | Med | Med | E25 is the CANONICAL content epic and SUPERSEDES the messaging of T17.1/2/4/5 + E22's README/site tasks (execute per ADR-0030); the wave note + this row record it so a pool session does not run both. |
| R-E25-4 | The hero transcript (T25.2) needs a real recordable end-to-end run; if unavailable, a mockup could mislead. | Low | Med | A static fallback is allowed ONLY if HONESTLY labelled as a mockup (ADR-0030); never presented as a recorded run; replace with a real asciinema cast once a clean run exists (the E18 re-verify shows clean runs are now achievable). |
| R-E25-5 | Distribution rides the Claude Code / MCP host; a host change breaks the install/invocation story. | Med | Low | Keep multi-harness (Codex/opencode) in the on-ramp (the Cline lesson); the invocation phrase (T25.6) is documented + coherence-checked (T16.4); instrument downloads/retention, not stars. |
| R-E26-1 | The router claims `kazi apply` replaces `/apply --pool` before the native scheduler is proven at scale (E21/E23 dogfoods open). | High | Med | ADR-0031 decision 6 + T26.6: the subsumption claim is GATED on T21.12/T23.9 passing; until then the on-ramp marks it "coming" and keeps `/apply --pool` as the documented interop fallback (ADR-0026). |
| R-E26-2 | Skill-verb vs CLI-verb mismatch (apply->run, plan->propose) confuses users or drifts from the CLI. | Med | Med | The verb map is documented in the router SKILL.md (T26.1); the skill<->CLI coherence guard (T16.4/T26.5) asserts every sub-skill routes to a real `kazi help --json` command; `kazi run` is not renamed. |
| R-E26-3 | Retiring loop/qualify from the code on-ramp loses capability for non-code or edge cases. | Low | Med | They are retired only from the CODE on-ramp; both remain general skills for non-code work; `/plan` (intent) + `/tidy` (hygiene) are explicitly kept (ADR-0031). |
| R-E27-1 | The verb rename breaks the shipped agent-drivable JSON contract / skill / MCP for existing callers. | High | Low | `run`/`propose` (+ `mix kazi.run`) stay as DEPRECATED ALIASES dispatching identically (T27.1/T27.2); the `schema_version` bump (T27.3) makes the contract change explicit; a deprecation-window note (T27.7); alias tests pin back-compat. |
| R-E27-2 | A broad rename misses a reference, leaving an inconsistent surface. | Med | Med | Coherence guards cover it: skill<->CLI (T16.4), README<->site (T9.9), self-conformance (T15.7); `kazi help --json` is generated from the real command table; T27.8 live-verifies both verbs. |
| R-E27-3 | The `schema_version` bump breaks orchestrators pinning the old version. | Med | Low | Documented as a breaking contract change (ADR-0032/T27.3), not silent; the old command names remain valid aliases so only the pinned version (not the call) must update. |

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
