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

## Checkable Work Breakdown

The WBS below is the single checkable source of truth; toggle `[ ]` to `[x]`.
Status `kind: agent` is implicit unless noted. Completed epics (E0-E8, E11, and the
E9 core T9.1-T9.4/T9.7-T9.9) are removed from this WBS -- they are done on `main`;
their narrative lives in the ADRs and `docs/devlog.md`.

### E9 (leftovers) -- Website polish (P2, ADR-0018)

The site is LIVE at https://kazi.sire.run (T9.1-T9.4, T9.7-T9.9 DONE). Remaining:

- [ ] T9.5 Playwright smoke test: add a minimal Playwright project under `site/` that loads the built site (or the live URL) and asserts the hero headline, the `brew install` command text, the GitHub link, and at least one edge case (mobile viewport renders the nav/CTA; no console errors).  Owner: TBD  Est: 1h  verifies: [UC-028]  deps: []  acc: `npx playwright test` green against `site/dist` (served) and, when live, against `https://kazi.sire.run`; the test is wired into the pages workflow (or a `site` CI job) so a broken page fails CI.
- [ ] T9.6 Polish + perf + a11y: Lighthouse >= 90 on performance/accessibility/best-practices/SEO; semantic HTML + alt text + sufficient contrast (the Electric Blue gradient on slate/white); OpenGraph/Twitter-card image (render from the logo); `<title>`/meta description; prefers-color-scheme support.  Owner: TBD  Est: 1.5h  verifies: [UC-028]  deps: []  acc: a Lighthouse run (CI or local) reports >= 90 in all four categories on the deployed site; the OG image renders in a link-preview check.

### E12 -- Hierarchical predicate grouping + Obsidian export (P3, ADR-0020)

Acceptance: a `Kazi.Goal` can organize hundreds of predicates as a validated tree
(e.g. pillar -> domain -> capability), so a goal representing a whole product's
desired state is legible, sliceable, budgetable per group, and exportable to a
visualization tool (Obsidian) showing each node's state (intended / built /
pending). Grouping references a DECLARED taxonomy by id (NOT free text), validated
at load -- the structural guard against text drift (ADR-0020). Motivated by the
sirerun dogfood (`docs/devlog.md` 2026-06-23): sire's `capabilities.json` is 317
capabilities across 9 pillars; the one-off analysis proved the value and revealed
the requirements. Backward compatible: `group`/`[[group]]` are optional; an
ungrouped goal behaves exactly as today.

- [ ] T12.1 Declared `[[group]]` taxonomy in the goal-file + loader parsing: extend `Kazi.Goal.Loader.from_map/1` to parse a `[[group]]` array of `{id, name, parent?, budget?}` into a group set on the goal; ids are slugs, `name` is the display label.  Owner: TBD  Est: 1.5h  verifies: [UC-030]  deps: []  acc: ExUnit -- a goal-file with `[[group]]` entries loads a validated group set; ids normalize (case/whitespace/`&`); a duplicate group id is a load error; round-trips through the loader.
- [ ] T12.2 `Predicate.group` field + reference validation (the drift guard): add an optional `group :: String.t() | nil` to `Kazi.Predicate` (a declared group id, appended additively); the loader REJECTS a predicate whose `group` is not a declared id, a group whose `parent` is undeclared, and a parent cycle.  Owner: TBD  Est: 1.5h  verifies: [UC-030]  deps: [T12.1]  acc: ExUnit -- a predicate referencing a declared group loads; an UNKNOWN group id is `{:error, ...}` at parse time (the typo guard); an undeclared parent and a cycle are load errors; `group: nil` is unchanged (backward compatible).
- [ ] T12.3 Group tree + per-group status rollup (pure): build the tree from `parent` links and roll up predicate verdicts (acceptance-not-yet-true vs passing) into per-group intended/built/pending counts.  Owner: TBD  Est: 1.5h  verifies: [UC-030]  deps: [T12.2]  acc: ExUnit -- pure functions reconstruct the tree to arbitrary depth and roll up counts per group; deterministic; no I/O.
- [ ] T12.4 Per-group budgets (DERIVED rollup) + reconciliation: a group's effective budget is the SUM of its descendants' budgets -- never a hand-maintained parent number; declare budgets only at leaves. An explicit `budget` on a non-leaf is a CAP that can only tighten the rollup (`effective = min(cap, sum)`). Scope convergence + reporting to a group's predicate partition (rides ADR-0006 partitioning), delivering per-pillar reconciliation without a separate `Goal`.  Owner: TBD  Est: 2h  verifies: [UC-030]  deps: [T12.2]  acc: ExUnit -- a parent group's budget equals the sum of its descendants' (no stored parent value); a declared parent cap below the sum tightens to the cap; a cap above the sum is a no-op (operator's choice, default: no-op); a leaf budget bounds its partition's iterations; per-group status reported; an ungrouped goal is unaffected.
- [ ] T12.6 Obsidian/Mermaid exporter: `kazi export --obsidian <dir>` walks the group tree + predicate verdicts into a vault (one note per group/predicate, `[[wikilinked]]`, tagged intended/built/pending) and a Mermaid rollup.  Owner: TBD  Est: 2h  verifies: [UC-030]  deps: [T12.3]  acc: ExUnit -- the exporter writes a vault for a fixture grouped goal; notes link parent<->child; tags reflect verdicts; an overview note carries per-group rollups. Live: open the vault in Obsidian and confirm the graph renders.
- [ ] T12.7 `kazi lint` near-duplicate group-name warning (advisory second net): fuzzy-compare declared group NAMES and warn on near-duplicates (e.g. "Identity & Access" vs "Identity and Access") without failing the load.  Owner: TBD  Est: 1h  verifies: [UC-030]  deps: [T12.1]  acc: ExUnit -- near-duplicate names emit a warning; exact/distinct names do not; advisory only (exit 0).

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

- [ ] T13.1 OpenAPI importer: parse an OpenAPI document into one `http_probe` acceptance predicate per path/operation, grouped (tag -> declared `[[group]]`, ADR-0020). Deterministic and hermetic.  Owner: TBD  Est: 2h  verifies: [UC-025]  deps: [T12.1, T12.2]  acc: ExUnit on a fixture spec -- paths/operations become grouped `http_probe` acceptance predicates with method/path/expected-status config; same spec -> same goal-file; re-import upserts.
- [ ] T13.2 Gherkin importer: parse Cucumber/gherkin feature files into one acceptance predicate per scenario, grouped by feature.  Owner: TBD  Est: 1.5h  verifies: [UC-025]  deps: [T12.1, T12.2]  acc: ExUnit on fixture features -- scenarios become grouped acceptance predicates; deterministic.
- [ ] T13.3 Prose-doc importer via the harness: drive the existing authoring/clarify path (`Kazi.Authoring`, ADR-0011/0019) over a prose doc (ADR/requirements) to draft candidate predicates, HUMAN-REVIEWED before acceptance; reuses the injectable harness seam (stub in tests).  Owner: TBD  Est: 2h  verifies: [UC-025]  deps: []  acc: ExUnit with a stub harness -- a prose doc yields candidate predicates routed through the review/approve flow; nothing is accepted without approval; no real `claude`/network in tests.
- [ ] T13.4 Surface-scanner provider: inventory a project's public surface (HTTP routes/handlers, exported symbols, CLI commands) for one language first (Elixir or Go), reusing the repo-introspection seam (ADR-0010).  Owner: TBD  Est: 2h  verifies: [UC-031]  deps: []  acc: ExUnit on a fixture repo -- the scanner returns the public surface inventory; approximate-by-design (reflection/string-dispatch invisible -- documented, `docs/lore.md`).
- [ ] T13.5 Surface-coverage meta-predicate: assert every scanned surface element is OWNED by >=1 intended predicate (match by route/path/symbol); an unowned element FAILS (dead/undocumented); supports an explicit allow-list; WARN-don't-auto-delete.  Owner: TBD  Est: 2h  verifies: [UC-031]  deps: [T13.4]  acc: ExUnit -- a fixture with an un-predicated endpoint fails the meta-predicate and names it; allow-listed surface passes; a fully-owned surface passes; ungrouped goals unaffected.
- [ ] T13.6 Dogfood sirerun via the GENERAL path: import sire's API surface (OpenAPI if present, else the T13.4 scanner) + key prose ADRs (T13.3); run the coverage meta-predicate to find `A \ I` (dead/undocumented) and compare against the manifest's `undocumented_discovered: 68`; export the grouped view (E12). Note the LIVE-predicate escalation (probe a running sire -- needs an instance + test creds) as deferred.  Owner: TBD  Est: 2h  verifies: [UC-031, UC-030]  deps: [T13.1, T13.4, T13.5]  acc: observed evidence that the general importer + coverage meta-predicate reproduce/compare against the one-off analysis for sire; `mix format`/`--warnings-as-errors` clean; the live-predicate follow-on recorded in `docs/devlog.md`.

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

- [ ] T14.1 Profile conformance test helper + golden-transcript pattern: a reusable ExUnit helper that, given a profile + a recorded sample transcript, asserts `build_args` renders the expected argv and `parse` extracts the expected additive fields; mirrors the existing `claude`/`opencode` stub-binary seam (`test/support/stub_claude_args.sh`).  Owner: TBD  Est: 1.5h  verifies: [infrastructure]  deps: []  acc: ExUnit -- the helper drives `:claude` + `:opencode` against fixture transcripts and passes; it is the uniform harness every new profile reuses.
- [ ] T14.2 Codex profile (`:codex`, fully conformant): add `defp codex` to `Kazi.Harness.Registry` (command `codex`, `build_args` -> `exec <prompt> --json` + optional `--model <m>`, `parse` the JSONL event stream -> `:result`/`:cost` additively, reusing the opencode NDJSON approach); register in `fetch/1` + `ids/0`; unit + golden-transcript tests; a live smoke tagged `:codex_live` (excluded).  Owner: TBD  Est: 2h  verifies: [UC-032]  deps: [T14.1]  acc: ExUnit -- `build_args` yields `["exec", prompt, "--json"]` (+`--model` when given); `parse` extracts the final result + token cost from a recorded codex JSONL sample; `kazi run --harness codex` resolves the profile (resolve/1); `mix format`/`--warnings-as-errors` clean.
- [ ] T14.3 Antigravity profile (`:antigravity`, conformant WITH workaround): add `defp antigravity` (command `antigravity`/`agy`, `build_args` -> `run --prompt-file <tmp> --output json --yes` writing the prompt to a temp file and reading JSON back to dodge the non-TTY stdout bug #76; env GEMINI_API_KEY/ANTIGRAVITY_API_KEY passthrough); register; unit + golden-transcript tests; live smoke `:antigravity_live`. Document the non-TTY workaround + version pin in `docs/lore.md`.  Owner: TBD  Est: 2.5h  verifies: [UC-032]  deps: [T14.1]  acc: ExUnit -- argv uses the prompt-file + `--output json` workaround (NOT bare `-p`); `parse` reads the JSON result; the non-TTY landmine is recorded in `docs/lore.md`; a maintainer live-smoke converges a fixture (or an honest skip with the cause, like the opencode smoke).
- [ ] T14.4 claw-code profile (`:claw`, BEST-EFFORT/demo-grade): add `defp claw` (command `claw`, `build_args` -> `prompt <text>`, `parse` = best-effort raw stdout -> `:result`, NO cost/structured extraction since claw emits no JSON); register; unit test + a raw-output golden transcript; mark demo-grade in the profile doc + README.  Owner: TBD  Est: 1.5h  verifies: [UC-032]  deps: [T14.1]  acc: ExUnit -- `build_args` yields `["prompt", text]`; `parse` returns the raw stdout as `:result` with no invented cost; the profile + README label it best-effort/demo-grade (no structured output, per ADR-0022).
- [ ] T14.5 CLI + coherence + docs: confirm `--harness codex|antigravity|claw` works end to end (resolve precedence, the unknown-harness error lists the new ids); update the README harness section AND `site/src/canonical.mjs` HARNESSES in the SAME change so the T9.9 drift-check stays green; document each harness's auth/setup.  Owner: TBD  Est: 1.5h  verifies: [UC-032, infrastructure]  deps: [T14.2, T14.3, T14.4]  acc: `kazi run --harness <new> --help`/resolve works; the coherence check passes with the expanded harness list; README documents the per-harness auth (OPENAI_API_KEY / GEMINI_API_KEY / claw env keys) and conformance tier.
- [ ] T14.6 "Add your own harness" contributor recipe: a short doc (README or `docs/`) that walks the ADR-0022 recipe -- author a `defp <id>` profile (build_args + additive parse), register it, add the three tests (build_args unit, golden transcript, `:<id>_live` smoke), update the canonical harness list -- proven by the fact that T14.2-T14.4 each followed it.  Owner: TBD  Est: 1h  verifies: [UC-032]  deps: [T14.5]  acc: a new contributor can add a CLI harness as profile DATA by following the recipe; it references the conformance contract (ADR-0022) and the test helper (T14.1); no architecture change required.

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

- [ ] T15.1 JSON output framework + non-interactive guarantee: a `--json` flag + a small renderer seam so each command emits a single JSON object to stdout; under `--json` kazi NEVER prompts/blocks on stdin (it errors loudly if input is required), and exit codes are stable. Unit-tested.  Owner: TBD  Est: 1.5h  verifies: [UC-033, infrastructure]  deps: []  acc: ExUnit -- a command in `--json` mode emits valid JSON only (no human prose interleaved) and never reads stdin; non-`--json` is unchanged; piped/non-TTY `--json` works headlessly.
- [ ] T15.2 `kazi propose --json` with TWO drive modes (the single authoring path, ADR-0023): emit the draft -- goal id, `proposal_ref`, predicates[], rationale, any clarify questions -- as one JSON object. (a) **kazi-drafts**: `propose "<idea>" --harness <model>` spawns a model to draft (existing). (b) **caller-drafts**: `propose --json` with predicates supplied on stdin/flag -- the orchestrator (which already reasoned) supplies the draft and kazi applies the deterministic FLOOR + persists + gates WITHOUT spawning an inner model (avoids the redundant claude->kazi->claude). Both go through `Kazi.Authoring` (the one write path, ADR-0011); no parallel mechanism.  Owner: TBD  Est: 2h  verifies: [UC-033, UC-029]  deps: [T15.1]  acc: ExUnit with a stub harness -- kazi-drafts returns a parseable draft; caller-drafts accepts supplied predicates, applies the floor (flags a missing live-verification target + scope), persists, and spawns NO inner model; the floor applies in both; no second authoring path.
- [ ] T15.3 `kazi run --json` result contract (versioned): on termination emit a JSON object with `status` (`converged`/`stuck`/`over_budget`/`error`), the PREDICATE VECTOR (id + verdict per predicate), `iterations`, `budget_spent`, a `next_action` hint, and `schema_version`. Document + version the schema.  Owner: TBD  Est: 2h  verifies: [UC-033]  deps: [T15.1]  acc: ExUnit against fixture runs -- each terminal status yields the documented object with the predicate vector; `schema_version` present; a schema doc is committed.
- [ ] T15.4 `kazi run --json --stream` JSONL progress: emit one JSON event per iteration (iteration n, dispatched harness, predicate-vector delta), terminated by the final T15.3 result object, so an orchestrator monitors a long run without blocking. Mirrors how kazi parses opencode/codex JSONL.  Owner: TBD  Est: 1.5h  verifies: [UC-033]  deps: [T15.3]  acc: ExUnit -- a multi-iteration fixture run emits a valid JSONL event stream ending in the result object; each line parses independently.
- [ ] T15.5 `kazi status --json` (new command): report a run/proposal's current state from the read-model as JSON (status, predicate vector, last iteration, timestamps).  Owner: TBD  Est: 1.5h  verifies: [UC-033]  deps: [T15.1]  acc: ExUnit -- after a propose/run, `status --json <ref>` returns the persisted state; an unknown ref is a clear JSON error + non-zero exit.
- [ ] T15.6 `kazi list-proposed/approve/reject --json`: structured output for the authoring state machine so the orchestrator drives propose -> approve -> run programmatically.  Owner: TBD  Est: 1h  verifies: [UC-033]  deps: [T15.1]  acc: ExUnit -- each command emits a parseable JSON result; transitions report machine-readable success/error.
- [ ] T15.7 kazi self-conformance test: assert kazi ITSELF passes the ADR-0022 conformance helper (E14 T14.1) -- non-interactive, JSON-only stdout under `--json`, subprocess-safe under a non-TTY -- so kazi meets the bar it imposes on harnesses.  Owner: TBD  Est: 1h  verifies: [UC-033, infrastructure]  deps: [T15.2, T15.3, T15.5, T15.6, T14.1]  acc: ExUnit -- kazi's `--json` commands satisfy the conformance helper; a regression (prose leaking into `--json`, a stdin block) fails the test.
- [ ] T15.8 Docs + the orchestrator recipe: document the versioned JSON schemas and a "drive kazi from an agent" recipe -- orchestrator: `kazi propose --json` -> `kazi approve --json` -> `kazi run --harness <cheap> --json [--stream]` -> parse the result -> branch on `next_action`. Note the `kazi mcp` follow-on (E16).  Owner: TBD  Est: 1h  verifies: [UC-033]  deps: [T15.7]  acc: a new orchestrator can drive the full loop from the recipe + schemas; `schema_version` pinning is documented.
- [ ] T15.9 LIVE nested-loop dogfood (claude -> kazi -> claw/Qwen): as the orchestrator, author a tiny broken fixture goal's predicates via `kazi propose --json`, approve, then `kazi run --harness claw --model <DGX-Qwen> --json` to drive the cheap loop; parse the JSON result. Record evidence + the friction (HONEST: claw is best-effort/no-JSON per E14, local Qwen slow per T8.11 -- expect a wiring proof, maybe not fast convergence) in `docs/devlog.md`.  Owner: TBD  Est: 2h  verifies: [UC-033]  deps: [T15.3, T14.4]  acc: observed evidence of the full agent->kazi->cheap-harness loop driven over `--json`; every point where kazi was awkward to drive as a tool is logged as a follow-up; honest result reported.

### E16 -- kazi self-teaching to harnesses: skill + MCP + machine-readable help (P3, ADR-0024)

Acceptance: an orchestrating harness knows how to drive kazi out of the box.
`brew install kazi-org/tap/kazi && kazi install-skill` teaches Claude Code the
orchestrator recipe; `kazi help --json`/`kazi schema` let ANY agent introspect the
CLI; an `AGENTS.md` covers convention-reading harnesses; a `kazi mcp` server is the
self-describing tool surface. Opt-in, consent-first (no auto-writes to `~/.claude`).
Depends on the E15 JSON contract.

- [ ] T16.1 `kazi help --json` + `kazi schema`: emit the command/flag surface and the versioned result schemas (ADR-0023) as JSON, GENERATED from the real command table (not hand-maintained).  Owner: TBD  Est: 1.5h  verifies: [UC-034]  deps: [T15.3]  acc: ExUnit -- `help --json` lists every command/flag; `schema run` returns the documented run-result schema with `schema_version`; both parse.
- [ ] T16.2 The kazi Claude Code skill + `kazi install-skill` (opt-in): `kazi install-skill` writes `~/.claude/skills/kazi/SKILL.md` teaching the recipe (caller-drafts `propose --json` -> `approve` -> `run --harness <cheap> --json [--stream]` -> parse -> branch on `next_action`) + the two-tier economics; `brew install` PRINTS a hint to run it (no auto-write).  Owner: TBD  Est: 2h  verifies: [UC-034]  deps: [T15.8]  acc: `kazi install-skill` writes the SKILL.md to a target dir (injectable in tests); the brew formula caveats the hint; the skill content references only real commands (checked by T16.4).
- [ ] T16.3 Generic `AGENTS.md` teachability doc: a harness-neutral recipe doc in the repo, droppable into a target repo, for convention-reading harnesses (Cursor rules, etc.).  Owner: TBD  Est: 1h  verifies: [UC-034]  deps: [T15.8]  acc: `AGENTS.md` documents the same recipe + JSON contract; references only real commands.
- [ ] T16.4 Skill/AGENTS.md <-> CLI coherence test: assert the skill + `AGENTS.md` reference only commands/flags that `kazi help --json` reports (the drift guard, mirroring T9.9).  Owner: TBD  Est: 1h  verifies: [UC-034, infrastructure]  deps: [T16.1, T16.2, T16.3]  acc: ExUnit/CI -- a command named in the skill but absent from `help --json` fails the check.
- [ ] T16.5 `kazi mcp` server: expose propose/run/status/approve as self-describing MCP tools (descriptions + schemas) wrapping the JSON CLI, for MCP-native drive (no shelling/parsing).  Owner: TBD  Est: 2.5h  verifies: [UC-034]  deps: [T15.7]  acc: an MCP client lists kazi's tools with descriptions + input/output schemas and can drive propose->approve->run; built on the proven JSON contract.
- [ ] T16.6 LIVE: Claude Code drives kazi via the installed skill: install the skill, then in a real Claude Code session drive a fixture goal end to end (propose -> approve -> run); record evidence.  Owner: TBD  Est: 1.5h  verifies: [UC-034]  deps: [T16.2]  acc: observed evidence that a Claude Code user who ran `kazi install-skill` can drive kazi without further instruction; honest result.

### E17 -- Adoption: README/docs/website lead with the agent-driven workflow (P2, ADR-0023/0024)

Acceptance: the README, website, and docs lead with the EASY on-ramp -- `brew
install + kazi install-skill`, then "tell Claude Code to build X with kazi" -- and
the two-tier economics (plan with a strong model, code with a cheap/local model,
kazi keeps it honest objectively) as the differentiator, to grow GitHub stars and
adoption. The goal-file/`kazi run` reference stays, below the agent on-ramp. Mixed
content + engineering; coherence-checked (T9.9).

- [ ] T17.1 README reframe (content): lead with the agent-driven workflow + `kazi install-skill` + the two-tier economics; keep install/quickstart/harness-config/goal-file below as the reference. No invented features; coherent with the site.  Owner: TBD  Est: 1.5h  verifies: [UC-035]  delivers: [a README that leads with the claude->kazi->cheap-harness on-ramp]  deps: [T16.2]  acc: a newcomer sees the agent on-ramp first; every command shown is real; canonical strings unchanged or updated in lockstep with the site.
- [ ] T17.2 Website: a "Use kazi with Claude Code" section/page (the on-ramp + the two-tier story), on-brand; update `site/src/canonical.mjs` + the coherence check in lockstep.  Owner: TBD  Est: 2h  verifies: [UC-035]  delivers: [a website section on the agent-driven workflow]  deps: [T16.2]  acc: the page renders the on-ramp + two-tier story; README<->site coherence (T9.9) stays green; deployed live + verified at https://kazi.sire.run.
- [ ] T17.3 docs/concept positioning: record the 3-layer stack (orchestrator -> kazi -> cheap harness; kazi friendly in both directions, ADR-0023) as the canonical positioning.  Owner: TBD  Est: 1h  verifies: [UC-035]  delivers: [updated concept positioning]  deps: []  acc: `docs/concept.md` describes the 3-layer stack without contradicting ADR-0001 (kazi is still the outer loop for the harness, AND a tool for the orchestrator).

### Waves

Recommended order. The two independent tracks (E12->E13 and E14) can run alongside
the adoption spine (E15->E16->E17). E9 leftovers are tiny and independent.

- **Wave E9 (polish, parallel):** T9.5 (Playwright smoke), T9.6 (perf/a11y). Independent of everything else.
- **Wave E12-1 (model + guard):** T12.1 (declared `[[group]]` taxonomy) -> T12.2 (`Predicate.group` + reference/cycle validation -- the drift guard). Pure loader work.
- **Wave E12-2 (tree + budgets):** T12.3 (tree + per-group rollup), T12.4 (derived per-group budgets) -- after the model.
- **Wave E12-3 (export):** T12.6 (Obsidian/Mermaid exporter), T12.7 (lint near-duplicate names).
- **Wave E13-1 (import intent):** T13.1 (OpenAPI), T13.2 (gherkin), T13.3 (prose via harness) -- emit grouped predicates (depends on the E12 model: T12.1/T12.2).
- **Wave E13-2 (dead code):** T13.4 (surface scanner) -> T13.5 (coverage meta-predicate).
- **Wave E13-3 (dogfood):** T13.6 (sirerun via the general path; note the live-predicate escalation).
- **Wave E14-1 (harness onboarding):** T14.1 (conformance test helper) -> then T14.2 (Codex), T14.3 (Antigravity), T14.4 (claw-code) in PARALLEL (independent profiles).
- **Wave E14-2 (wire + document):** T14.5 (CLI + coherence + docs) -> T14.6 (contributor recipe).
- **Wave E15-1 (JSON surface):** T15.1 (JSON framework + non-interactive guarantee) -> then T15.2 (propose), T15.3 (run result contract), T15.5 (status), T15.6 (authoring state machine) in PARALLEL.
- **Wave E15-2 (stream + conform):** T15.4 (JSONL streaming) -> T15.7 (kazi self-conformance; needs T14.1).
- **Wave E15-3 (recipe + dogfood):** T15.8 (orchestrator recipe + schemas) -> T15.9 (live claude->kazi->claw/Qwen nested loop; honest result).
- **Wave E16-1 (self-description):** T16.1 (`help --json`/`schema`) -> T16.2 (skill + `install-skill`), T16.3 (`AGENTS.md`) -> T16.4 (coherence guard).
- **Wave E16-2 (MCP + live):** T16.5 (`kazi mcp`), T16.6 (Claude Code drives kazi via the skill, live).
- **Wave E17 (adoption docs):** T17.1 (README reframe), T17.2 (website section + coherence + deploy), T17.3 (concept positioning) -- after the skill (T16.2) exists to point at.

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
  per-group budgets are a DERIVED rollup. UC-030. Motivated by the sirerun dogfood
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
