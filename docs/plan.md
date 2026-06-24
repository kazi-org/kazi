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

## Checkable Work Breakdown

The WBS below is the single checkable source of truth; toggle `[ ]` to `[x]`.
Status `kind: agent` is implicit unless noted. Completed epics (E0-E8, E11, and the
E9 core T9.1-T9.4/T9.7-T9.9) are removed from this WBS -- they are done on `main`;
their narrative lives in the ADRs and `docs/devlog.md`.

### E9 (leftovers) -- Website polish (P2, ADR-0018)

The site is LIVE at https://kazi.sire.run (T9.1-T9.4, T9.7-T9.9 DONE). Remaining:

- [x] T9.5 Playwright smoke test: add a minimal Playwright project under `site/` that loads the built site (or the live URL) and asserts the hero headline, the `brew install` command text, the GitHub link, and at least one edge case (mobile viewport renders the nav/CTA; no console errors).  Owner: pool  Done: 2026-06-23  verifies: [UC-028]  deps: []  acc: `npx playwright test` green against `site/dist` (served) and, when live, against `https://kazi.sire.run`; the test is wired into the pages workflow (or a `site` CI job) so a broken page fails CI.
- [x] T9.6 Polish + perf + a11y: Lighthouse >= 90 on performance/accessibility/best-practices/SEO; semantic HTML + alt text + sufficient contrast (the Electric Blue gradient on slate/white); OpenGraph/Twitter-card image (render from the logo); `<title>`/meta description; prefers-color-scheme support.  Owner: pool  Done: 2026-06-23  verifies: [UC-028]  deps: []  acc: a Lighthouse run (CI or local) reports >= 90 in all four categories on the deployed site; the OG image renders in a link-preview check.

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

- [x] T12.1 Declared `[[group]]` taxonomy in the goal-file + loader parsing: extend `Kazi.Goal.Loader.from_map/1` to parse a `[[group]]` array of `{id, name, parent?, budget?}` into a group set on the goal; ids are slugs, `name` is the display label.  Owner: pool  Done: 2026-06-23  verifies: [UC-030]  deps: []  acc: ExUnit -- a goal-file with `[[group]]` entries loads a validated group set; ids normalize (case/whitespace/`&`); a duplicate group id is a load error; round-trips through the loader.
- [x] T12.2 `Predicate.group` field + reference validation (the drift guard): add an optional `group :: String.t() | nil` to `Kazi.Predicate` (a declared group id, appended additively); the loader REJECTS a predicate whose `group` is not a declared id, a group whose `parent` is undeclared, and a parent cycle.  Owner: pool  Done: 2026-06-23  verifies: [UC-030]  deps: [T12.1]  acc: ExUnit -- a predicate referencing a declared group loads; an UNKNOWN group id is `{:error, ...}` at parse time (the typo guard); an undeclared parent and a cycle are load errors; `group: nil` is unchanged (backward compatible).
- [x] T12.3 Group tree + per-group status rollup (pure): build the tree from `parent` links and roll up predicate verdicts (acceptance-not-yet-true vs passing) into per-group intended/built/pending counts.  Owner: pool  Done: 2026-06-23  verifies: [UC-030]  deps: [T12.2]  acc: ExUnit -- pure functions reconstruct the tree to arbitrary depth and roll up counts per group; deterministic; no I/O.
- [ ] T12.4 Per-group budgets (DERIVED rollup) + reconciliation: a group's effective budget is the SUM of its descendants' budgets -- never a hand-maintained parent number; declare budgets only at leaves. An explicit `budget` on a non-leaf is a CAP that can only tighten the rollup (`effective = min(cap, sum)`). Scope convergence + reporting to a group's predicate partition (rides ADR-0006 partitioning), delivering per-pillar reconciliation without a separate `Goal`.  Owner: TBD  Est: 2h  verifies: [UC-030]  deps: [T12.2]  acc: ExUnit -- a parent group's budget equals the sum of its descendants' (no stored parent value); a declared parent cap below the sum tightens to the cap; a cap above the sum is a no-op (operator's choice, default: no-op); a leaf budget bounds its partition's iterations; per-group status reported; an ungrouped goal is unaffected.
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
- [x] T13.6 Dogfood sirerun via the GENERAL path: import sire's API surface (OpenAPI if present, else the T13.4 scanner) + key prose ADRs (T13.3); run the coverage meta-predicate to find `A \ I` (dead/undocumented) and compare against the manifest's `undocumented_discovered: 68`; export the grouped view (E12). Note the LIVE-predicate escalation (probe a running sire -- needs an instance + test creds) as deferred.  Owner: pool  Done: 2026-06-24  verifies: [UC-031, UC-030]  deps: [T13.1, T13.4, T13.5]  acc: observed evidence that the general importer + coverage meta-predicate reproduce/compare against the one-off analysis for sire; `mix format`/`--warnings-as-errors` clean; the live-predicate follow-on recorded in `docs/devlog.md`.

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
- [ ] T15.9 LIVE nested-loop dogfood (claude -> kazi -> claw/Qwen): as the orchestrator, author a tiny broken fixture goal's predicates via `kazi propose --json`, approve, then `kazi run --harness claw --model <DGX-Qwen> --json` to drive the cheap loop; parse the JSON result. Record evidence + the friction (HONEST: claw is best-effort/no-JSON per E14, local Qwen slow per T8.11 -- expect a wiring proof, maybe not fast convergence) in `docs/devlog.md`.  Owner: TBD  Est: 2h  verifies: [UC-033]  deps: [T15.3, T14.4]  acc: observed evidence of the full agent->kazi->cheap-harness loop driven over `--json`; every point where kazi was awkward to drive as a tool is logged as a follow-up; honest result reported.

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

- [ ] T18.1 Fix the stale shipped example + add a runnability guard: in `priv/examples/deploy_target.toml` change the `test_runner` predicate from `cmd = "go test ./..."` (the whole command parsed as one executable -> `System.cmd` `{:cmd_unrunnable, :enoent}`) to `cmd = "go"`, `args = ["test", "./..."]`; audit every file under `priv/examples/` for the same multi-word-`cmd` antipattern and fix. Add an ExUnit test that loads each shipped example goal-file and asserts every `test_runner` predicate's `cmd` resolves via `System.find_executable/1` with `args` as a list.  Owner: TBD  Est: 1h  verifies: [UC-024, infrastructure]  deps: []  acc: ExUnit -- each `priv/examples/*.toml` loads; no example uses a multi-word `cmd`; the guard fails if a future example reintroduces `cmd = "go test ./..."`; `mix format` clean.
- [ ] T18.2 Deep-sanitize read-model evidence so errored predicates persist: `Kazi.ReadModel.serialize_vector/1` (`read_model.ex:550`) stores `evidence` verbatim, so an `:error` `PredicateResult` whose evidence holds a tuple (`reason: {:cmd_unrunnable, ...}`) or atom keys fails the `Iteration.predicate_vector` `:map` Ecto cast and `record_iteration/1` raises (observed in the benchmark). Make serialization JSON-safe (stringify atom keys; render tuples/non-encodable terms to strings) and preserve the deserialize round-trip (`read_model.ex:373`).  Owner: TBD  Est: 1.5h  verifies: [UC-033, infrastructure]  deps: []  acc: ExUnit -- recording an iteration whose vector has an `:error` result with tuple evidence returns `{:ok, _}` (no raise) and round-trips to a JSON-safe map; existing `:pass`/`:fail` serialization stays byte-compatible.
- [ ] T18.3 Make terminal/budget-stop iteration persistence idempotent: the loop's per-iteration callback AND the terminal/budget-stop callback both persist the SAME `(goal_ref, iteration_index)`, so the second insert hits `iterations_goal_ref_iteration_index_index` ("has already been taken") and is logged as a failure (observed in the benchmark). Either skip re-recording an already-recorded index or use `Repo.insert(..., on_conflict: {:replace, [...]}, conflict_target: [:goal_ref, :iteration_index])` so the terminal state upserts.  Owner: TBD  Est: 1.5h  verifies: [UC-033, infrastructure]  deps: []  acc: ExUnit -- a run that fires the terminal/budget-stop callback persists each `iteration_index` exactly once with the final state; no unique-constraint error is logged; a deliberate double-record is an idempotent upsert, not a crash.
- [ ] T18.4 Reproduce + close the over-budget CLI crash: with `max_iterations = 1` on an unconvergeable fixture goal, confirm whether `Kazi.CLI.run_goal/4` still raises `CaseClauseError` on the `{:ok, %{outcome: :over_budget, reason: :max_iterations, ...}}` result (observed during the benchmark). `cli.ex:544` now HAS an `:over_budget` clause, so this may already be fixed by T15.3 -- if it reproduces, fix the case; either way add a regression test.  Owner: TBD  Est: 1h  verifies: [UC-033]  deps: [T18.2]  acc: ExUnit/CLI -- an over-budget run prints the over-budget verdict, exits 1, raises nothing; under `--json` it emits the versioned `over_budget` result object; a regression that drops the clause fails the test.
- [ ] T18.5 Re-verify on the benchmark fixture + lint: after T18.1-T18.4, re-run the code-only benchmark goal (a broken Go fixture, `mix kazi.run`) end to end and confirm convergence with zero persistence warnings, plus an over-budget variant exits cleanly. Run `mix format --check-formatted` and `mix compile --warnings-as-errors`. Record the clean re-run in `docs/devlog.md`.  Owner: TBD  Est: 0.5h  verifies: [infrastructure]  deps: [T18.1, T18.2, T18.3, T18.4]  acc: a real `mix kazi.run` on the fixture converges with no `failed to persist` warning, no `:map` cast error, no unique-constraint log; format + warnings-as-errors clean; devlog updated.

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

- [ ] T19.1 Wire the cached orientation pack into the live dispatch prompt (realize T4.3): route `dispatch_prompt/2` (`loop.ex:1208`) through `Kazi.Harness.Prompt.build_prompt/3`'s prefix path (or prepend `Kazi.Context.cached_orientation_pack/4` output) so each stateless dispatch carries the ranked blast-radius pack as a prefix, keeping the failing-evidence + working-set-digest sections. Keep `.kazi/context.md` as the fallback for file-reading harnesses.  Owner: TBD  Est: 2h  verifies: [UC-033, infrastructure]  deps: [T18.2]  acc: ExUnit -- a dispatch on a fixture with a graph/repo-map injects the orientation pack as a prefix; the prefix is byte-identical for the same `(workspace, git-SHA, failing-set)` across iterations; evidence + digest sections still present; nil-workspace/no-graph degrades to today's prompt.
- [ ] T19.2 Stable-prefix discipline for inner-harness cache hits: front-load the prompt (orientation + work-item first, volatile evidence/digest last) and keep ordering deterministic so the inner harness's own prompt cache maximally hits across successive `claude -p` dispatches within the TTL. (kazi sets no `cache_control` -- it drives a CLI; this is purely prefix stability.) Document the constraint at the `build_prompt` seam.  Owner: TBD  Est: 1h  verifies: [UC-033, infrastructure]  deps: [T19.1]  acc: ExUnit -- for two iterations with the same failing-set + SHA the prompt's leading bytes (orientation + work-item) are identical; reordering volatile sections does not perturb the stable head; a moduledoc note records the subprocess-cache rationale (ADR-0010).
- [ ] T19.3 Use `truncate_evidence/2` on the live dispatch path: `dispatch_prompt/2` renders evidence via raw `inspect/1`, so large evidence bypasses the T4.8 cap. Render evidence through `Kazi.Harness.Prompt.truncate_evidence/2` (default 8 KiB, head+tail window) on the live path.  Owner: TBD  Est: 0.5h  verifies: [UC-033, infrastructure]  deps: [T19.1]  acc: ExUnit -- a dispatch with oversized predicate evidence truncates to the cap with a head+tail window; small evidence is unchanged.
- [ ] T19.4 Multi-iteration benchmark harness: build a repeatable bench (a `mix` task or script under `bench/`) that converges a fixture needing >=3 dispatches three ways -- (A) vanilla `claude -p` session, (B) kazi->claude WITHOUT the prefix (pre-T19.1 behavior behind a flag/config), (C) kazi->claude WITH the prefix + stable head (T19.1/T19.2) -- capturing per-dispatch input/output/cache-read tokens + cost via the harness shim (the docs/devlog.md 2026-06-24 method).  Owner: TBD  Est: 2h  verifies: [infrastructure]  deps: [T19.1, T19.2, T19.3]  acc: the bench runs all three arms on a real fixture and emits a per-arm token + cost + iteration table; the shim captures every dispatch; the method is documented and repeatable.
- [ ] T19.5 Run the multi-iteration benchmark + record the verdict: run T19.4; compare B vs C (does the stable prefix raise cross-dispatch cache_read / cut cost, and do fewer orientation tool-calls offset the added prefix tokens?) and A vs C (kazi vs vanilla over multiple iterations). Record honest numbers + the net verdict in `docs/devlog.md`; if C is NOT a net win, say so and recommend keeping file-based orientation.  Owner: TBD  Est: 1h  verifies: [UC-033, infrastructure]  deps: [T19.4]  acc: a `docs/devlog.md` entry with the A/B/C multi-iteration table, the B-vs-C cache-hit delta, and a clear keep/revert recommendation for the prefix wiring; honest if inconclusive.

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
- [ ] T20.6 Per-task blast-radius lease for a pooled run (L3, NATS): a pool session acquires a kazi lease for its task's blast radius (`Kazi.Partition.partition/3` -> `PartitionLease.lease_keys/3`) BEFORE editing; overlapping radii serialize, disjoint run free. Lease is scoped to the run and released on terminal state.  Owner: TBD  Est: 2h  verifies: [UC-036]  deps: [T20.4]  acc: ExUnit + a 2-session sim -- two tasks with overlapping blast radii serialize on the lease; disjoint radii proceed concurrently; lease released on converged/stuck/over_budget; requires a running NATS (skips honestly without one).
- [ ] T20.7 `/claim` <-> kazi-lease compose-boundary + deadlock safety (L3): document and TEST the contract -- claim (task) acquired first, then the kazi blast-radius lease; lease TTL bounds a crashed holder; release ordering (lease before claim) -- so two sessions each holding a claim + a lease cannot deadlock.  Owner: TBD  Est: 2h  verifies: [UC-036, infrastructure]  deps: [T20.6]  acc: ExUnit -- a constructed cross-acquire scenario does not deadlock (TTL/ordering breaks it); the contract is documented in `docs/` and referenced by the recipe.
- [ ] T20.8 Live pool observability (L4): point the LiveView dashboard + presence + lease map at a shared kazi instance so every session's leases + per-goal convergence history are visible in real time; verify in a browser against a live 2+ session pool.  Owner: TBD  Est: 1.5h  verifies: [UC-036]  deps: [T20.6]  acc: the dashboard shows >=2 concurrent sessions' leases + convergence live; exercised in a real browser (agent-browser); read-only, decoupled from the loop (ADR-0011).
- [ ] T20.9 Phone-driven pool direction (L4): use the Telegram bridge to declare/approve goals and receive pings on `converged`/`stuck`/`over_budget` from the pool, fitting the remote setup (phone -> a Mac running the pool).  Owner: TBD  Est: 1h  verifies: [UC-036]  deps: [T20.4]  acc: a declared/approved goal from Telegram runs in the pool and pings the phone on each terminal state; honest result.
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
- [ ] T21.2 Wire `Kazi.Partition` into the scheduler: partition the goal-set by blast radius (graph/repo-map `graph_source`) into disjoint partitions, one per reconciler; degenerate to one partition when there is a single goal or no graph.  Owner: TBD  Est: 1.5h  verifies: [UC-037]  deps: [T21.1]  acc: ExUnit -- a multi-goal set with disjoint blast radii yields >=2 partitions each driven concurrently; overlapping radii collapse into one partition (serialized); same input -> same partitioning.
- [ ] T21.3 Per-partition lease lifecycle: each reconciler acquires its `PartitionLease` on start and releases on terminal; the in-memory backend is the single-node default, the NATS backend is config-selected for multi-node; residual mid-run overlap serializes on the lease.  Owner: TBD  Est: 2h  verifies: [UC-037]  deps: [T21.1]  acc: ExUnit -- concurrent partitions hold distinct leases; a forced overlap serializes; a crashed reconciler's lease frees via TTL; no NATS needed for the memory backend.
- [ ] T21.4 Isolated git worktree per partition: each parallel fixer works in its own worktree (concept sec 9), created on start and removed on terminal; honor the worktree-guard landmine (never `rm -r` a cwd worktree).  Owner: TBD  Est: 2h  verifies: [UC-037]  deps: [T21.1]  acc: ExUnit/integration on a fixture repo -- N reconcilers edit in N worktrees without touching each other's tree; worktrees are cleaned up on every terminal path (converged/stuck/over_budget/crash).
- [ ] T21.5 Collective integration + merge convergence: after partitions converge, integrate each (branch -> PR -> rebase-merge) in a safe order; detect residual cross-partition conflicts and re-dispatch the affected partition until the merged whole is green.  Owner: TBD  Est: 2.5h  verifies: [UC-037]  deps: [T21.4]  acc: ExUnit/integration -- two disjoint partitions both merge clean; an injected cross-partition conflict is detected and the affected partition re-dispatched, not silently merged.
- [ ] T21.6 Dynamic blast-radius overlap policy: when a partition's edits expand its radius into another's (a lease conflict mid-run), serialize the overlapping pair (or re-partition); documented + tested so growth never corrupts a sibling.  Owner: TBD  Est: 1.5h  verifies: [UC-037]  deps: [T21.3]  acc: ExUnit -- a partition that grows into a neighbor's radius blocks on the lease and proceeds only when free; no two reconcilers edit the same file concurrently; the policy is documented.
- [ ] T21.7 Per-partition budgets (derived rollup, ADR-0020/E12): split the goal budget across partitions; a partition going over-budget ESCALATES without killing siblings; the collective verdict reflects per-partition outcomes.  Owner: TBD  Est: 1.5h  verifies: [UC-037, UC-030]  deps: [T21.1]  acc: ExUnit -- per-partition budgets sum to the goal budget; one partition's `over_budget` does not stop the others; the collective report names which partition escalated.
- [ ] T21.8 CLI + `--json` collective contract: `kazi run --parallel [N]` (or auto from a multi-partition goal-set) drives the scheduler; `--json` emits a versioned collective result (per-partition status + overall + `next_action`); non-interactive/non-TTY safe (ADR-0022/0023).  Owner: TBD  Est: 1.5h  verifies: [UC-037, UC-033]  deps: [T21.1]  acc: ExUnit -- `--parallel` runs the scheduler; `--json` yields a parseable collective object with each partition's verdict + the overall status + `schema_version`; serial single-goal output is unchanged.
- [ ] T21.9 Live dashboard for the parallel run: the LiveView console shows the N partition reconcilers + their leases + per-partition convergence in real time (extends the multi-goal dashboard); verified in a browser against a live native-parallel run.  Owner: TBD  Est: 1.5h  verifies: [UC-037]  deps: [T21.1]  acc: the dashboard shows >=2 concurrent partition reconcilers + leases + convergence live; exercised with agent-browser; read-only, decoupled from the loop (ADR-0011).
- [ ] T21.10 Supervision/restart + escalation: a crashed partition reconciler restarts (or escalates `stuck`) WITHOUT corrupting lease or worktree state; the coordinator survives a child crash.  Owner: TBD  Est: 1.5h  verifies: [UC-037, infrastructure]  deps: [T21.3, T21.4]  acc: ExUnit -- killing a child reconciler triggers clean restart-or-escalate; its lease frees and worktree is reconciled; siblings are unaffected; the coordinator never crashes on a child failure.
- [ ] T21.11 Docs + positioning (native parallelism is the headline): README/concept/site present kazi as the native parallel reconciler ("kazi parallelizes your plan -- no external orchestrator; single machine, no NATS"); `/apply --pool` (E20) is shown as interop. Coherent with E17/ADR-0025 + ADR-0027.  Owner: TBD  Est: 1.5h  verifies: [UC-037, UC-035]  delivers: [docs/site that lead the parallel story with kazi-native, interop as secondary]  deps: [T21.8]  acc: a newcomer sees "kazi parallelizes for you" (no personal skills); `/apply --pool` is clearly the interop path; canonical strings + coherence (T9.9) intact.
- [ ] T21.12 LIVE dogfood (the proof): run kazi natively-parallel on a real multi-partition goal in THIS repo on one machine (NATS-free) -- several independent fixes converged concurrently in isolated worktrees, then merged. Record evidence in `docs/devlog.md`: partition count, concurrency observed, collective convergence, merge result; honest if it falls short.  Owner: TBD  Est: 2.5h  verifies: [UC-037]  deps: [T21.5, T21.8]  acc: observed evidence of >=2 partitions converging concurrently under one kazi run with no external orchestrator and no NATS; every claim observed, not asserted.

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
- **Wave E17 (adoption rewrite, P1 -- can start NOW):** T17.4 (the works-today recipe) -> T17.1 (README rewrite, leads with the on-ramp; promised commands marked "coming") -> T17.2 (website rewrite + coherence + deploy) -> T17.5 (OG card). NOT gated on T16.2/T16.5: the docs may PROMISE the one-command on-ramp ahead of shipping (clearly marked), with the working recipe shown alongside (operator decision 2026-06-24; ADR-0025).
- **Wave E18 (benchmark bug fixes, parallel):** T18.1, T18.2, T18.3, T18.4 are independent (different files) and run in PARALLEL -> T18.5 (re-verify + lint) after all. Independent of E12-E17; safe to land first since they harden the run loop everything else exercises.
- **Wave E19-1 (token-efficiency wiring):** T19.1 (inject the cached orientation pack as a stable prompt prefix on the live loop) -> T19.2 (Anthropic `cache_control` on the stable prefix) -> T19.3 (use `truncate_evidence/2` on the live dispatch path). Sequential: each refines `dispatch_prompt`/the adapter.
- **Wave E19-2 (measure):** T19.4 (multi-iteration benchmark harness) -> T19.5 (run + record A/B/cached numbers). After E18 (clean persistence) and E19-1.
- **Wave E20-L1 (gate, no NATS -- start here):** T20.1 (`acc:`->predicates) -> T20.2 (pool gate recipe) -> T20.3 (opt-in `/apply --verify-with-kazi`); T20.11 (live L1 dogfood) after T20.3. Independently valuable; ships before any NATS.
- **Wave E20-L2 (objective-done loop):** T20.4 (orchestrator recipe) -> T20.5 (per-task tiering, optional).
- **Wave E20-L3 (blast-radius leases, NATS):** T20.6 (per-task lease) -> T20.7 (`/claim`<->lease boundary + deadlock safety).
- **Wave E20-L4 (observability + direction):** T20.8 (live dashboard/lease map), T20.9 (Telegram direction) in parallel after T20.6/T20.4.
- **Wave E20-docs:** T20.10 (the adoption guide) after L1+L3+L4 land.
- **Wave E21-1 (native scheduler core, single-node NATS-free):** T21.1 (scheduler + DynamicSupervisor) -> T21.2 (wire Partition), T21.3 (lease lifecycle), T21.4 (worktree per partition) in parallel after T21.1.
- **Wave E21-2 (integration + correctness):** T21.5 (merge convergence), T21.6 (overlap policy), T21.7 (per-partition budgets).
- **Wave E21-3 (surface + resilience):** T21.8 (CLI + `--json` collective), T21.9 (dashboard), T21.10 (supervision/restart).
- **Wave E21-4 (position + prove):** T21.11 (docs lead with native parallelism) -> T21.12 (live NATS-free multi-partition dogfood).

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
  - L4 observability + direction: T20.8 live dashboard/lease map, T20.9 Telegram.
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
