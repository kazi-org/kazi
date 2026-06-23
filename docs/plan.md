# kazi -- Build Plan (remaining work)

## Context

kazi is a reconciliation controller for software goals: declare a goal as
machine-checkable predicates; kazi drives a coding agent in a loop until the
predicates are objectively true, stuck, or over budget. It drives harnesses
(Claude Code, Codex, opencode, ...); it is not a harness.

The walking-skeleton build (idea -> production) and every epic through it are
COMPLETE and merged on `main`:

- **E0-E5** -- the convergence loop to a live Cloud Run deploy; regression/flake/
  budget/stuck/prod-log; creation mode + self-hosting; NATS leases, graph
  partitioning, standing reconcilers, idea->predicate authoring, LiveView,
  Telegram; context injection + pluggable retrieval-memory; and `kazi init` adopt
  (E5, ADR-0013) -- all merged.
- **E7** (registry adapter) -- built, then WITHDRAWN before open-source release
  (ADR-0015): the `capabilities.json` input was bespoke and did not generalize.
- **E8** (generic multi-harness support, ADR-0016) -- COMPLETE (PRs
  #80/#82/#83/#84/#86/#87/#88/#90/#92/#93). The single `Kazi.Harness.ClaudeAdapter`
  was generalized into config-driven harness **profiles** + a
  `Kazi.Harness.CliAdapter` + `Kazi.Harness.resolve/1`, so `kazi run --harness
  opencode --model <m>` drives the operator's local Qwen3.6-on-DGX (and any CLI
  harness drops in as profile DATA, no new module). Details in `docs/devlog.md`;
  the decision is ADR-0016.

State of `main`: **853 tests pass** (66 doctests, 787 tests), 19 excluded
(`:nats`/`:graphify`/`:opencode_live` tags); `mix format --check-formatted` clean;
`mix compile --warnings-as-errors` clean.

**What remains (the entire content of this plan):**

1. **E9 -- the public website (T9.1-T9.7, ADR-0018).** The PRIMARY open work: a
   live Astro + Tailwind landing site at **https://kazi.sire.run** (GitHub Pages),
   explaining kazi and getting a visitor to `brew install` + a first goal. Mixed
   engineering + content; on-brand (the Electric Blue logo). The only operator-gated
   step is one DNS `CNAME` record.
2. **E6 / E8 -- DONE** except **T6.7** (tap auto-bump), which is implemented but
   blocked on the operator-created `HOMEBREW_TAP_TOKEN` secret + the org
   "Actions-can-create-PRs" activation (R-E6-7). `brew install kazi-org/tap/kazi`
   is LIVE (v0.1.1, 3 platforms); the auto-release pipeline is wired and gated.

**Frozen design (do NOT relitigate):** `docs/concept.md` (canonical architecture +
source of truth) and ADRs `0001`..`0018`. To change a decision, write a superseding
ADR.

## Use Case Summary

All use cases are tracked in `.claude/scratch/usecases-manifest.json`. Open work:

- **UC-024** (install kazi as a single binary via Homebrew, ADR-0014; now with the
  fully-automated release pipeline of ADR-0017) -- OPEN; E6.
- **UC-029** (interactive `propose`: kazi asks clarifying questions before drafting
  a goal so acceptance predicates are precise, ADR-0019) -- OPEN; E11.

UC-001..UC-023 and **UC-026/UC-027** (generic multi-harness support, E8) are
delivered and verified on `main`. UC-025 (import a standard spec into a goal set)
is **deferred backlog** (ADR-0015).

## Checkable Work Breakdown

The WBS below is the single checkable source of truth; toggle `[ ]` to `[x]`.
Status `kind: agent` is implicit unless noted.

### E6 -- Automated brew release pipeline: Burrito + Homebrew (P2, ADR-0014 + ADR-0017)

Acceptance: merging Conventional Commits to `main` and merging the resulting
release PR causes, with NO further manual steps, a `vX.Y.Z` GitHub Release whose
assets are the Burrito binaries each with a `.sha256`, and a
`kazi-org/homebrew-tap` `kazi` formula auto-updated to that release so
`brew install kazi-org/tap/kazi` (and `brew upgrade`) install a working single
binary with the FULL read-model (no Erlang prerequisite, NIF bundled). **T6.1
(`mix release`) and the Burrito wrap config are merged.** The host binary cannot
be linked on this macOS-26 dev box (R-E6-1) -- the build is CI-driven by design.

**SHIPPED:** `brew install kazi-org/tap/kazi` is live (verified) for **3
platforms** -- macOS `aarch64`, Linux `x86_64`, Linux `aarch64` -- on the `v0.1.0`
Release. macOS `x86_64` (Intel) is the only deferred target (GitHub's macos-13
Intel runners are deprecated/scarce). The full auto-release chain is wired but
gated on the one-time human activation in T6.6/T6.7.

- [x] T6.2 Burrito build proven on CI: confirm `mix release` produces a runnable Burrito binary for at least one target on a Zig-compatible runner that bundles ERTS + the `exqlite` NIF, and a fixture `kazi run` PERSISTS iterations to SQLite (read-model present, no escript degradation)  Owner: David  Done: 2026-06-22 (CI run on v0.1.0)  verifies: [UC-024]  deps: []  acc: a CI job (the T6.3 workflow on a test tag) yields a `burrito_out/kazi_<target>` that runs `--help` and converges/persists a fixture goal; evidence captured in the run log. Folded into T6.3's first green run rather than a separate local build (R-E6-1).
- [x] T6.3 Release build workflow: `.github/workflows/release.yml` -- on a `v*` tag, a matrix builds the four Burrito targets (macOS on `macos-15` per R-E6-1, Linux on `ubuntu-latest`) with Zig 0.15.2 + xz, generates a `.sha256` per binary, and uploads all as GitHub Release assets  Owner: David  Done: 2026-06-22 (PR #98; validated on v0.0.0-test5 + v0.1.0)  verifies: [UC-024]  deps: []  acc: pushing a test tag (`v0.0.0-test1`) produces four `kazi_*` binaries + four `.sha256` as Release assets; the workflow is green; both macOS and Linux jobs succeed. A WIP `release.yml` is committed; this task is making it actually green on a test tag (the real validation -- expect CI iteration on BEAM/Zig/Burrito setup).
- [x] T6.6 release-please versioning (CONFIGURED; gated OFF pending a human one-time activation): the release-please Action + config + the format-stable `x-release-please-start/end-version` markers in `mix.exs` are merged and the build chain is token-free. **It is gated behind the repo variable `RELEASE_AUTOMATION=true`** because release-please ALSO needs the org/repo setting "Allow GitHub Actions to create and approve pull requests" — currently DISABLED org-wide for `kazi-org` (the session will NOT flip an org-wide security setting). To activate: (1) enable that org/repo setting OR give release-please a PAT `token:`; (2) add the `HOMEBREW_TAP_TOKEN` secret (T6.7); (3) set `RELEASE_AUTOMATION=true`. Owner: David  Done: 2026-06-22 (config); activation = human  verifies: [UC-024]  deps: []  acc: a `feat:`/`fix:` commit to `main` causes release-please to open/update a release PR with the correct semver bump; merging it tags + creates a Release; the version in `mix.exs` matches the tag. Validated on a real (or dry-run) cycle.
- [x] T6.4 Homebrew tap repo + formula: create `kazi-org/homebrew-tap` (agent-doable -- session has `kazi-org` admin) with a `kazi` formula that, per platform, downloads the Release asset, verifies its `.sha256`, and installs the binary onto PATH; `brew install kazi-org/tap/kazi` installs a working `kazi`  Owner: David  Done: 2026-06-22 (brew install verified live)  verifies: [UC-024]  deps: [T6.3]  acc: `brew install kazi-org/tap/kazi` on macOS installs a runnable `kazi` (`kazi --help` works post-install); `brew audit --strict --tap kazi-org/homebrew-tap` passes. Needs a real T6.3 Release to point at; repo creation is no longer human-gated (R-E6-2).
- [x] T6.7 Tap auto-bump workflow (IMPLEMENTED; BLOCKED on one human step): the `tap-bump` job in `.github/workflows/release-please.yml` regenerates the tap's `kazi` formula from the published `.sha256` values and pushes it to `kazi-org/homebrew-tap`. **It is fully written and wired into the release chain, but inert until the operator creates a fine-grained `HOMEBREW_TAP_TOKEN` secret** (PAT with contents:write on `kazi-org/homebrew-tap` only) -- the one step the session cannot do (a PAT cannot be minted via `gh`). The job SKIPS with a warning when the secret is absent, so the rest of the pipeline works.  Owner: TBD  blocked: needs HOMEBREW_TAP_TOKEN secret (human)  Est: 0.25h to add the secret  verifies: [UC-024]  deps: [T6.4]  acc: publishing a Release updates the tap formula's version/urls/sha256 automatically (verified on a test release); the secret is scoped to the tap repo; a follow-up `brew upgrade` pulls the new version. Use a maintained action (e.g. `dawidd6/action-homebrew-bump-formula`) or an inline generator -- documented.
- [x] T6.5 Docs: README install section leads with `brew install kazi-org/tap/kazi` + the prebuilt binary; note the runtime requirement that a coding agent (`claude`/`opencode`/...) must be on PATH; reframe the escript as a contributor convenience; link the GitHub Releases page and the auto-release flow (ADR-0017)  Owner: David  Done: 2026-06-22  verifies: [UC-024]  deps: [T6.4]  acc: README documents brew + binary install, the harness-on-PATH requirement, and how releases are cut (merge the release PR); links Releases + ADR-0017.

### E8 dogfood -- heterogeneous harness (Claude plans, opencode/DGX implements)

The capstone live exercise for E8: prove kazi's core division of labor -- a strong
model authors the predicate set (the "direction"), a cheap LOCAL model drives the
convergence loop (the "keystrokes"), and objective termination keeps the weak
implementer honest. Completes the live verification the T8.9 smoke deferred.

- [x] T8.11 Heterogeneous-harness dogfood: Claude authors a tiny deliberately-broken fixture goal-file (a single `test_runner` predicate failing at t0); `kazi run <goal> --harness opencode --model dgx-ollama/qwen3.6:35b-a3b-q8_0 --workspace <trusted repo>` drives the DGX-hosted Qwen to converge it; record the result in `docs/devlog.md`  Owner: David  Done: 2026-06-22 (wiring proven; honest non-convergence -- local 35B too slow; see devlog)  Est: 1h  verifies: [UC-026, UC-027]  deps: []  acc: a real `kazi run` converges a broken fixture driven ENTIRELY by opencode->DGX (Claude only authored the goal); evidence recorded (iterations, final vector); OR an honest failure with the environmental cause (per the T8.9 finding: opencode auto-rejects edits outside a trusted workspace -- fixed with a project-local `opencode.json` permission grant -- and the 35B model is slow). Throwaway workspace; not committed to the kazi repo.

### E9 -- Public website: Astro + Tailwind on GitHub Pages at kazi.sire.run (P2, ADR-0018)

Acceptance: a live, fast, single-page (with room to grow) marketing/landing site
at **https://kazi.sire.run** that explains kazi ("the outer loop existing agents
lack"), shows the 60-second mental model, and gets a visitor to `brew install
kazi-org/tap/kazi` + a first goal -- on-brand (Electric Blue, the logo assets),
deployed automatically from `main` via GitHub Actions, HTTPS-enforced, Lighthouse
>= 90, and **coherent with `README.md`** (shared canonical strings verbatim, the
README links the site, a CI drift-check guards against divergence -- T9.8/T9.9).
Stack/hosting/domain decided in ADR-0018
(Astro + Tailwind, site in `site/`, GitHub Pages, `kazi.sire.run` -- free, single
DNS CNAME, reversible). This is **mixed work**: engineering (scaffold, deploy,
tests) + content (the copy, reused from `README.md`/`docs/concept.md`).

- [x] T9.1 Scaffold the Astro + Tailwind site in `site/`: `npm create astro` (minimal/empty template), add `@astrojs/tailwind`, a base `Layout.astro` with the kazi brand (Electric Blue gradient, import the SVGs from `assets/logo/`), meta/OG tags, and a favicon generated from `kazi-badge.svg`. Set `site`/`base` in `astro.config` for the custom domain (base `/`).  Owner: David  Done: 2026-06-23  verifies: [UC-028]  deps: []  acc: `npm --prefix site run build` produces a static `site/dist/`; `npm --prefix site run dev` serves a branded empty page locally; `.gitignore` excludes `site/node_modules` and `site/dist`.
- [x] T9.2 Landing page sections (content + UI): build `index.astro` with hero (headline + subhead + primary `brew install` CTA + GitHub link), the 60-second mental model (the loop -> checkmark, reuse the README diagram/idea), a features/why-kazi grid (objective termination, multi-harness, single-binary install), an install + first-goal quickstart (copy-pasteable), and a footer (Apache-2.0, Sire Run, GitHub, links). Copy is DERIVED from `README.md`/`docs/concept.md` and must stay accurate.  Owner: David  Done: 2026-06-23  verifies: [UC-028]  delivers: [kazi landing-page copy + sections]  deps: [T9.1]  acc: every claim on the page is true to the README/concept (no invented features); the install command is the real `brew install kazi-org/tap/kazi`; responsive (mobile + desktop) and works in light AND dark; no Lorem Ipsum.
- [x] T9.3 Deploy workflow (GitHub Actions -> Pages): add `.github/workflows/pages.yml` -- on push to `main` touching `site/**`, build Astro and deploy via `actions/upload-pages-artifact` + `actions/deploy-pages` (with the `pages: write`/`id-token: write` permissions + a `github-pages` environment). Enable Pages (source = GitHub Actions) in repo settings.  Owner: David  Done: 2026-06-23 (Pages deploy green; kazi-org.github.io/kazi)  verifies: [UC-028, infrastructure]  deps: [T9.1]  acc: a push to `main` deploys the built site; the run is green; the site is reachable at the default `kazi-org.github.io/kazi` URL before the custom domain is wired.
- [x] T9.4 Custom domain kazi.sire.run + HTTPS: commit `site/public/CNAME` containing `kazi.sire.run`; set the custom domain in repo Pages settings; **operator adds one DNS `CNAME` record `kazi -> kazi-org.github.io` at the sire.run provider** (human-gated, like the other infra secrets); enable "Enforce HTTPS".  Owner: David  Done: 2026-06-23 (DNS via sirerun/foundation PR #120; HTTPS enforced; live)  verifies: [UC-028, infrastructure]  deps: [T9.3]  acc: `https://kazi.sire.run` serves the site with a valid auto-provisioned certificate; the apex/`www` is not claimed (subdomain only); the GitHub Pages "DNS check" passes. Operator step: the CNAME DNS record (the session does not control sire.run DNS).
- [ ] T9.5 Playwright smoke test: add a minimal Playwright project under `site/` that loads the built site (or the live URL) and asserts the hero headline, the `brew install` command text, the GitHub link, and at least one edge case (mobile viewport renders the nav/CTA; no console errors).  Owner: TBD  Est: 1h  verifies: [UC-028]  deps: [T9.2]  acc: `npx playwright test` green against `site/dist` (served) and, when live, against `https://kazi.sire.run`; the test is wired into the pages workflow (or a `site` CI job) so a broken page fails CI.
- [ ] T9.6 Polish + perf + a11y: Lighthouse >= 90 on performance/accessibility/best-practices/SEO; semantic HTML + alt text + sufficient contrast (the Electric Blue gradient on slate/white); OpenGraph/Twitter-card image (render from the logo); `<title>`/meta description; prefers-color-scheme support.  Owner: TBD  Est: 1.5h  verifies: [UC-028]  deps: [T9.2]  acc: a Lighthouse run (CI or local) reports >= 90 in all four categories on the deployed site; the OG image renders in a link-preview check.
- [x] T9.7 Verify live: load `https://kazi.sire.run` in a real browser (agent-browser), exercise the golden path (read hero -> copy the install command) plus one edge case (mobile), confirm no console errors and the cert is valid.  Owner: David  Done: 2026-06-23 (browser-verified at https://kazi.sire.run)  verifies: [UC-028]  deps: [T9.4]  acc: observed-not-expected evidence (a screenshot of the live `kazi.sire.run` + the install command working); reported honestly.
- [x] T9.8 Enhance the README for website coherence (content): make `README.md` and the site one coherent story from a single source (ADR-0018). (a) Add a prominent website link/badge in the header (under the wordmark) pointing to `https://kazi.sire.run`. (b) Make the SHARED CANONICAL STRINGS verbatim-consistent across README + site: the one-line positioning/hero ("the missing outer loop for coding agents" / "Kubernetes for coding goals"), the install command `brew install kazi-org/tap/kazi`, the 60-second mental model, and the harness list. (c) Reframe the README as the developer companion to the marketing site -- same pitch up top, then install/quickstarts/harness config/contributor build -- with NO contradictions of the site (claims, commands, version). Do NOT delete the contributor build detail; the site is the newcomer surface, the README the full reference.  Owner: David  Done: 2026-06-23  delivers: [a README coherent with kazi.sire.run; shared canonical strings aligned]  deps: [T9.2]  acc: every shared canonical string is byte-identical in `README.md` and the site content; the README header links the site; a newcomer reading either surface gets the same positioning + install; no claim on one contradicts the other.
- [x] T9.9 Coherence drift-check (CI guardrail): add a tiny check (a shell/JS script or a Playwright/unit assertion run in the `site`/pages CI) that asserts the shared canonical strings (the install command, the positioning one-liner, the harness list) appear IDENTICALLY in `README.md` and the site's content source; fail CI if they diverge.  Owner: David  Done: 2026-06-23  verifies: [UC-028, infrastructure]  deps: [T9.8]  acc: the check is green when README + site agree; deliberately editing one canonical string in only one file makes the check (and CI) RED; wired into the pages workflow or a `site` CI job.

### E11 -- Interactive clarify phase for `kazi propose` (P3, ADR-0019)

Acceptance: `kazi propose "<idea>"` asks 2-4 high-leverage clarifying questions
BEFORE drafting, so the resulting acceptance predicates are precise (especially a
live-verification predicate), then drafts the goal + an inline rationale and lets
the operator refine before it runs -- matching or beating the operator's current
Claude-Code-CLI authoring of plans/ADRs, but ending in an executable,
machine-checkable goal. Decided in ADR-0019: question generation is **HYBRID**
(harness drafts candidate questions; kazi enforces a deterministic, unit-tested
floor of gap-checks), the surface is the **CLI TTY first** (non-interactive/piped/
`--yes` skips clarification and drafts best-effort; `--strict` fails loudly when
too underspecified), and the rationale is **inline by default** with an optional
`--adr` flag that also writes an ADR-lite doc. This EXTENDS the Authoring write
path (ADR-0011) and predicates-as-done (ADR-0002); the clarify phase sits strictly
before the existing `proposed` state and the approval state machine is unchanged.
It reuses the injectable harness seam (`Kazi.Authoring` `:harness` opt -> `run/3`)
so every new harness interaction is stubbable -- no real `claude`/network in tests.
Telegram/dashboard clarify surfaces are OUT OF SCOPE (deferred follow-ups); the
core is built surface-agnostic.

- [x] T11.1 Clarify core + question schema (`Kazi.Authoring.Clarify`): define the pure data shapes -- a clarifying question (`id`, `prompt`, `options` [label/value], `recommended`, `allow_free_text`) and an answer -- plus a pure `fold_answers/2` that deterministically merges answers into the draft-prompt context. No I/O.  Owner: David  Done: 2026-06-23  verifies: [UC-029]  deps: []  acc: ExUnit covers building/serializing a question set and folding answers into a prompt string DETERMINISTICALLY (same answers -> same prompt); pure functions, no harness call, no stdin; `mix format`/`--warnings-as-errors` clean.
- [x] T11.2 Deterministic gap-detection floor (`gaps/1`): a pure function over (idea, optional harness draft) returning the MANDATORY floor questions -- always ask the live-verification target and the scope boundary when absent; derive provider-specific gaps from the known provider set (`test_runner`/`http_probe`/`prod_log`/`browser`) and missing predicate `config`.  Owner: David  Done: 2026-06-23  verifies: [UC-029]  deps: [T11.1]  acc: ExUnit -- an idea with no live target yields a live-verification question; an idea naming an HTTP endpoint yields a status/auth question; a fully-specified idea yields zero floor questions; pure (no harness, no I/O).
- [x] T11.3 Harness-drafted candidate questions (same seam): extend the clarify core to drive the injectable harness (`run/3` behind the `:harness` opt, mirroring `drive_harness/2`) with a prompt asking for candidate clarifying questions as a JSON array matching the T11.1 schema; parse + validate; MERGE with the deterministic floor (floor is authoritative; dedup).  Owner: David  Done: 2026-06-23  verifies: [UC-029]  deps: [T11.1, T11.2]  acc: ExUnit with a STUB harness -- candidate questions are parsed, validated, and merged with the floor; a malformed/empty harness response degrades to the floor alone (fail-soft); no real `claude`/network.
- [x] T11.4 Two-phase `propose/2` wiring: thread the clarify phase into `Kazi.Authoring.propose/2` BEFORE the draft -- gather questions (T11.2+T11.3), accept answers via an INJECTED `:ask` callback (the CLI supplies interactive I/O; tests inject a function), fold answers into the draft prompt, then run the existing draft+persist path. Add an `interactive?: false`/answers-supplied path that skips clarification.  Owner: David  Done: 2026-06-23  verifies: [UC-029]  deps: [T11.1, T11.2, T11.3]  acc: ExUnit -- propose with an injected ask-callback persists a draft whose predicates reflect the answers; `interactive?: false` with no answers drafts best-effort (current one-shot behavior preserved); existing `propose` tests stay green; harness seam still stubbable.
- [x] T11.5 Inline rationale on the draft goal: capture a concise rationale (why these predicates / what is deliberately out of scope) from the draft and store it on `goal.metadata` so `serialize_goal/1` round-trips it through `Kazi.Goal.Loader.from_map/1`; surface it at review time.  Owner: David  Done: 2026-06-23  verifies: [UC-029]  deps: [T11.4]  acc: ExUnit -- a proposal carrying a rationale persists it in `goal.metadata` and it round-trips through the loader; the review output prints the rationale.
- [x] T11.6 CLI interactive rendering + flags (`lib/kazi/cli.ex`): render the clarify questions as terminal multiple-choice (numbered options + a free-text escape), wire answers back as the `:ask` callback; add `--strict` (exit non-zero when the idea is too underspecified) and `--adr` (also write an ADR-lite doc); honor `--yes`/non-TTY (skip clarification, draft best-effort). Detect a non-interactive stdin and never block on it.  Owner: David  Done: 2026-06-23  verifies: [UC-029]  deps: [T11.4, T11.5]  acc: integration over CLI parse + scripted stdin -- interactive run asks then drafts; `--yes`/piped stdin drafts WITHOUT asking; `--strict` on an empty/underspecified idea exits non-zero with a clear message; `--adr` writes a `docs/adr/` file.
- [x] T11.7 `--adr` ADR-lite writer: a small module that renders the proposal's rationale into the repo's ADR format under `docs/adr/` (next sequence number), only when `--adr` is passed.  Owner: David  Done: 2026-06-23  verifies: [UC-029]  deps: [T11.5]  acc: ExUnit -- given a draft with a rationale, the writer produces a well-formed ADR markdown file at the next number; idempotent for the same `proposal_ref`; absent without the flag.
- [x] T11.8 Review loop (refine via `edit/3`): after the draft is shown, offer "looks right / too much / too little / refine"; "refine" re-prompts with a sharper sentence and re-runs clarify+draft, persisting via the existing `edit/3` transition (stays `proposed`).  Owner: David  Done: 2026-06-23  verifies: [UC-029]  deps: [T11.6]  acc: ExUnit with injected I/O -- "refine" with a new sentence updates the proposed goal via `edit/3` (stays `proposed`); "looks right" leaves it `proposed` for `approve`; golden path covered.  NOTE (deviation): implemented as a propose-UPSERT on the same `proposal_ref` (re-runs clarify+draft, row stays `proposed`) rather than a literal `edit/3` call -- equivalent end-state, fewer moving parts; covered by a CLI test asserting a single proposal row after a refine.
- [x] T11.9 Docs + LIVE CLI verification: update the README/`docs/concept.md` authoring section to describe interactive `propose`; run `kazi propose "<idea>"` in a REAL TTY (stub or real harness) and observe questions -> draft -> rationale, plus the `--yes` non-interactive path and `--strict` on an underspecified idea; record the transcript evidence in `docs/devlog.md`.  Owner: David  Done: 2026-06-23  verifies: [UC-029]  deps: [T11.6, T11.8]  acc: observed-not-expected evidence (a terminal transcript) for the interactive path, the non-interactive path, and the `--strict` failure; README authoring section matches behavior; `mix format --check-formatted` + `mix compile --warnings-as-errors` clean.

### Waves

E6 (brew release pipeline) and E8 (multi-harness + dogfood) are DONE; E9 (website)
is LIVE at https://kazi.sire.run with the auto-release pipeline active (only T9.5
Playwright + T9.6 perf/a11y polish remain). **E11 (interactive `propose`) is the
primary open feature work.**

- **Wave E11-1 (pure core):** T11.1 (schema + `fold_answers`) -> T11.2 (deterministic gap floor). Pure, fully unit-tested, no I/O.
- **Wave E11-2 (seam + wiring):** T11.3 (harness-drafted candidates on the stub seam), T11.4 (two-phase `propose/2`), T11.5 (inline rationale) -- after the core.
- **Wave E11-3 (CLI + flags):** T11.6 (interactive rendering + `--strict`/`--adr`/`--yes`), T11.7 (`--adr` writer), T11.8 (refine loop via `edit/3`).
- **Wave E11-4 (verify live):** T11.9 (docs + real-TTY verification, transcript in `docs/devlog.md`).

- ~~**E6 / E8**~~ -- DONE except T6.7 (tap auto-bump, operator secret) -- see the WBS.
- **Wave E9-1 (foundation):** T9.1 (scaffold Astro+Tailwind in `site/`) -> then T9.3 (deploy workflow) and T9.2 (landing content) can proceed in parallel.
- **Wave E9-2 (build out):** T9.2 (landing sections), T9.5 (Playwright), T9.6 (polish/perf/a11y) -- parallel after T9.1.
- **Wave E9-3 (coherence):** T9.8 (enhance the README to be coherent with the site -- shared canonical strings, website link, dev-companion framing) -> T9.9 (CI drift-check so README + site can't diverge). Pairs with T9.2.
- **Wave E9-4 (go live):** T9.4 (custom domain + DNS -- **operator adds the CNAME record**) -> T9.7 (verify live at `kazi.sire.run`).

## Risk Register

| ID | Risk | Impact | Likelihood | Mitigation |
|----|------|--------|------------|------------|
| R-E6-1 | Burrito host binary cannot be linked on the dev machine (Zig 0.15.2, pinned by Burrito 1.5.0, fails to link against macOS 26 / Xcode 26; Zig 0.16 links but is API-incompatible with Burrito 1.5.0's `build.zig`). | Med | High (observed) | The build is CI-driven by design (ADR-0017): T6.3 builds on `macos-15` + `ubuntu-latest`. Do NOT attempt a local build on this macOS-26 host. |
| R-E6-2 | T6.4 needs a second repo (`kazi-org/homebrew-tap`) and a published Release. | Low | Med | Repo creation is agent-doable (session has `kazi-org` admin via `gh`); no longer human-gated. Sequence T6.4 after T6.3 produces real Release artifacts. |
| R-E6-3 | The shipped binary still requires the user's coding agent (`claude`/`opencode`/...) on PATH at runtime (kazi drives a harness by design, ADR-0001). | Low | High (inherent) | Documented in T6.5; packaging does not solve it. |
| R-E6-4 | `erlef/setup-beam` / Zig 0.15.2 / Burrito setup is fragile on the macOS-15 runner (BEAM install, xz, the Zig link). | Med | Med | Validate T6.3 on a throwaway `v*-test` tag and iterate on the runner (the only place it can be proven, R-E6-1); pin exact Elixir/OTP/Zig versions; `fail-fast: false` so macOS and Linux jobs report independently. |
| R-E6-5 | The cross-repo formula push needs auth the default `GITHUB_TOKEN` lacks. | Med | High (inherent) | A fine-grained `HOMEBREW_TAP_TOKEN` PAT scoped to `contents:write` on `homebrew-tap` only (ADR-0017); created + stored as a repo secret as part of T6.7. Rotate like any deploy credential. |
| R-E6-6 | release-please computes the wrong version from a mistyped commit. | Low | Med | Conventional Commits are already mandated (operating procedure); release-please's release PR is the human review gate before a tag is cut. |
| R-E6-7 | release-please cannot open its release PR: `kazi-org` disables "Allow GitHub Actions to create and approve pull requests" org-wide (verified -- the repo + org API return `can_approve_pull_request_reviews: false`, and the repo PUT is rejected with "the organization does not allow..."). | High (blocks auto-release) | High (current state) | Flipping an org-wide security setting is the operator's decision, not the session's. Two unblock paths: enable that org/repo setting, OR pass a fine-grained PAT as release-please's `token:`. The workflow is gated `if: vars.RELEASE_AUTOMATION == 'true'` so it does not fail red while disabled. |
| R-E9-1 | `kazi.sire.run` needs a DNS `CNAME` record at the `sire.run` provider, which the session does not control. | Med | High (inherent) | T9.4 is `kind: any` (operator). Until the record exists, the site is still LIVE at the default `kazi-org.github.io/kazi` URL (T9.3) -- the custom domain is the last, non-blocking step. The CNAME file + repo Pages setting are agent-doable; only the DNS record is operator-gated. |
| R-E9-2 | Website copy drifts from what kazi actually does (claims a feature it lacks). | Med | Med | Copy is DERIVED from `README.md`/`docs/concept.md` (T9.2 acc forbids invented features); the site lives in the same repo so a docs change and a site change land together. The install command on the page is the real `brew install` string, smoke-tested by T9.5. |
| R-E9-3 | GitHub Pages must be enabled with source = "GitHub Actions" for the deploy workflow to publish. | Low | Med | T9.3 enables it (repo Settings -> Pages); agent-doable via `gh api` or the UI. The first deploy run surfaces this immediately if missing. |
| R-E11-1 | Interactive stdin in the CLI is hard to unit-test and risks blocking. | Med | Med | The clarify CORE takes an injected `:ask` callback, so it is tested with a function (no real TTY); only the thin rendering layer (T11.6) needs a scripted-stdin integration test. |
| R-E11-2 | Harness-drafted candidate questions are non-deterministic and may be malformed. | Med | Med | The deterministic floor (T11.2) is AUTHORITATIVE; harness questions are merged on top and fail-soft -- a malformed/empty harness response degrades to the floor alone (T11.3). |
| R-E11-3 | A non-interactive/piped `propose` must never block waiting on stdin. | High | Med | Explicit `--yes`/no-TTY path drafts best-effort without asking; `--strict` fails loudly instead. Both get dedicated tests (T11.6). |

## Operating Procedure

Definition of done (all must hold): for code changes, ExUnit tests written and
green; `mix format --check-formatted` clean; `mix compile --warnings-as-errors`
clean; PR merged to `main` via **rebase** (not squash, not a merge commit) with CI
green. For CI/release workflows, the workflow is proven GREEN on a real trigger
(a test tag / a dry-run release), not just authored. For any user-facing surface,
verified live and reported honestly. Make many small focused commits; never commit
files from different directories in one commit.

Execution model: work the plan with `/apply --pool` (atomic git-ref claims at
`refs/claims/*` via the global `~/.claude/skills/claim/scripts/claim.sh`). The WBS
above is the single checkable source of truth.

House rules for E6: the binary build is CI-only (R-E6-1) -- never claim a release
works without a green CI run that produced the assets. Validate workflows on a
throwaway `v*-test` tag before wiring them into the release-please flow. Keep the
`HOMEBREW_TAP_TOKEN` minimal-scope (ADR-0017). Conventional Commits are
load-bearing for versioning -- type every commit correctly.

## Progress Log

### 2026-06-23 -- Change Summary (E11 BUILT: interactive `propose` shipped on a feature branch)
- **E11 (T11.1-T11.9) implemented, tested, and verified** on `feat/e11-interactive-propose`
  (suite 855 -> 899, +44 tests; `mix format`/`--warnings-as-errors` clean). Pure clarify
  core + deterministic gap floor (`Kazi.Authoring.Clarify`), harness-drafted candidate
  questions on the existing stub seam, two-phase `propose/2` with answers folded into the
  draft, inline rationale on `goal.metadata`, the `--adr` ADR-lite writer
  (`Kazi.Authoring.RationaleAdr`), and CLI `--yes`/`--strict`/`--adr` + a refine loop.
- **Live-verified** (real app + SQLite): the `--strict` non-interactive refusal, and the
  interactive clarify phase (questions rendered, a stdin answer folded into a `prod_log`
  predicate, rationale printed, proposal persisted). One honest caveat -- the `:io.rows()`
  TTY autodetect could not be exercised in this dev env (mix-run noshell / escript no-NIF /
  Burrito can't build on macOS-26, R-E6-1); the rendering it gates is pure + unit-tested.
  Evidence in `docs/devlog.md`.
- **T11.8 deviation**: the refine loop upserts the same `proposal_ref` rather than calling
  `edit/3` literally -- equivalent end-state, fewer moving parts.

### 2026-06-23 -- Change Summary (add E11: interactive clarify phase for `propose`)
- **Added E11 (T11.1-T11.9)** -- an interactive clarify phase for `kazi propose`:
  it asks 2-4 high-leverage clarifying questions BEFORE drafting so acceptance
  predicates (especially a live-verification predicate) are precise, drafts the
  goal + an inline rationale, and lets the operator refine before it runs. Built as
  a walking skeleton: pure clarify core + deterministic gap floor first (E11-1),
  then harness-drafted candidate questions on the existing stub seam + two-phase
  `propose/2` wiring + inline rationale (E11-2), then CLI interactive rendering +
  `--strict`/`--adr`/`--yes` flags + the refine loop (E11-3), then live-TTY
  verification (E11-4).
- **ADR created:** `docs/adr/0019-interactive-clarify-phase-for-propose.md` --
  records the three operator decisions (HYBRID question generation = harness
  candidates + a deterministic unit-tested floor; CLI-TTY-first surface with a
  non-interactive `--yes`/no-TTY fallback and a `--strict` fail-loud; inline
  rationale by default + an optional `--adr` doc). Extends ADR-0011 (the Authoring
  write path; the clarify phase sits before the existing `proposed` state, state
  machine unchanged) and ADR-0002 (predicates make "done" machine-checkable).
  Telegram/dashboard clarify surfaces are deferred; the core is surface-agnostic.
- **Use case added:** UC-029 (interactive propose). Manifest updated.
- No code changed yet -- this is the plan + ADR for E11; build with `/apply --pool`.

### 2026-06-23 -- Change Summary (E9: README <-> website coherence)
- **Added T9.8 + T9.9** to E9: enhance `README.md` so it and the website are one
  coherent story (T9.8 -- shared canonical strings verbatim, a prominent website
  link in the header, README reframed as the developer companion to the marketing
  site, no contradictions), and a CI drift-check (T9.9) that fails when the shared
  canonical strings (install command, positioning one-liner, harness list) diverge
  between `README.md` and the site content. T9.7 narrowed to live-verify only (the
  README link moved to T9.8). New wave E9-3 (coherence) before E9-4 (go live).
- **ADR-0018 updated** with a "README <-> website coherence" section: README +
  concept are the canonical source the site derives from; shared strings are
  verbatim; the surfaces are complementary (site = newcomer pitch, README = full
  reference incl. contributor build); a drift-check guards them. No new ADR.
- Same use case (UC-028) -- coherence is part of "explain kazi + drive to install".

### 2026-06-23 -- Change Summary (add E9: public website at kazi.sire.run)
- **Added E9 (T9.1-T9.7)** -- a public Astro + Tailwind landing site on GitHub
  Pages at `kazi.sire.run`, explaining kazi and driving to `brew install` + a first
  goal. Mixed engineering + content; on-brand with the Electric Blue logo. Copy is
  derived from `README.md`/`docs/concept.md` (no invented features).
- **ADR created:** `docs/adr/0018-website-stack-hosting-domain.md` -- chose Astro +
  Tailwind, site in `site/` of this repo, GitHub Pages via Actions, and the domain
  `kazi.sire.run`. The domain recommendation (the operator's question): YES for v1
  -- free + already owned (Sire Run owns `sire.run`), the simplest GitHub Pages
  setup (one DNS CNAME vs apex A/AAAA), honest `<product>.<company>` branding, and
  fully reversible if kazi later wants a standalone domain. Trade-off noted: a
  subdomain frames kazi as a Sire Run product rather than an independent project.
- **Use case added:** UC-028 (the website). Manifest updated.
- The only operator-gated E9 step is one DNS `CNAME` record (R-E9-1); everything
  else (scaffold, deploy workflow, content, tests, Pages enablement) is agent-doable.
- E6/E8 are otherwise done (only T6.7 remains, gated on the operator).

### 2026-06-22 -- Change Summary (auto-release the brew packages: E6 -> ADR-0017)
- **Reframed E6 as a fully-automated release pipeline** (ADR-0017): release-please
  versioning (T6.6) + the tag-triggered Burrito build workflow (T6.3) + a tap
  auto-bump workflow (T6.7) so merging Conventional Commits ships brew packages with
  no manual tag/checksum/formula edits. T6.2 folded into T6.3's first green run;
  T6.4 (tap repo) reclassified agent-doable; T6.5 docs updated to cover the flow.
- **ADR created:** `docs/adr/0017-automated-brew-release-pipeline.md` -- the
  release-please -> CI build -> tap auto-bump design, the `HOMEBREW_TAP_TOKEN`
  cross-repo secret, and why the release PR stays a human gate.
- **A WIP `release.yml`** (T6.3) is committed this session; making it green on a
  test tag is the next step (CI iteration expected on BEAM/Zig/Burrito setup).
- **Trimmed the completed E8 epic** (T8.1-T8.10, all merged) out of the WBS to a
  one-line Context record; the full narrative is in `docs/devlog.md` and ADR-0016.
  Kept T8.11 (the dogfood, in progress).

### 2026-06-22 -- Change Summary (E8 complete; multi-harness shipped)
- **E8 (generic multi-harness support) merged end to end** (ADR-0016): harness
  profiles, `Kazi.Harness.CliAdapter`, `Kazi.Harness.resolve/1`, the `:opencode`
  profile (NDJSON parser), goal-file `[harness]` table, env forwarding, and the
  Runtime/CLI/authoring/adopt wiring. `kazi run --harness opencode --model <m>`
  works. The live opencode->DGX smoke is an honest-skip (excluded by default;
  finding in `docs/devlog.md`). Suite 760 -> 853. UC-026/UC-027 delivered.

## Hand-off Notes (cold start for a new session)

1. **Verify the baseline first:** `mix test` should report 853 passing, 19 excluded;
   `mix format --check-formatted` and `mix compile --warnings-as-errors` clean.
2. **E6 is the only epic left, and it is CI-driven.** Do NOT build the Burrito host
   binary on this macOS-26 box (R-E6-1). The path: get `release.yml` (T6.3) green on
   a throwaway `v*-test` tag (this proves T6.2 too), add release-please (T6.6), then
   create `kazi-org/homebrew-tap` (agent-doable -- `kazi-org` admin) + the formula
   (T6.4) and the auto-bump workflow + `HOMEBREW_TAP_TOKEN` (T6.7), then docs (T6.5).
   Read ADR-0014 + ADR-0017 before touching the pipeline.
3. **T8.11 dogfood** (Claude plans, opencode/DGX implements) is in progress this
   session; record its outcome in `docs/devlog.md`. It is independent of E6.
4. **Do not relitigate frozen design** -- read `docs/concept.md` and the relevant
   ADR before touching an area; write a superseding ADR to change a decision.

## Appendix

- Concept and architecture: `docs/concept.md`
- Decisions: `docs/adr/0001`..`0019` (index at `docs/adr/README.md`); the release
  pipeline is ADR-0014 (distribution) + ADR-0017 (automation); the website is
  ADR-0018; interactive `propose` is ADR-0019.
- Operations / findings: `docs/devlog.md`; landmines: `docs/lore.md`
- Use-case manifest: `.claude/scratch/usecases-manifest.json`
- Release surface (for E6): `mix.exs` (`releases/0` + the `burrito:` targets),
  `lib/kazi/release.ex` (`cli/1`, `burrito_main/0`), `.github/workflows/release.yml`
  (T6.3, WIP), `.github/workflows/ci.yml` (the test workflow to mirror setup from).
