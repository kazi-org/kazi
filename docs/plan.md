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

1. **E6 -- automated brew release pipeline (T6.2-T6.9, ADR-0014 + ADR-0017).** The
   focus of this plan. Ship `brew install kazi-org/tap/kazi` as a single
   self-contained binary AND make releasing it **fully automatic**: merge
   Conventional Commits -> release-please cuts a version -> CI builds the four
   Burrito binaries -> the GitHub Release publishes them + checksums -> the
   Homebrew tap formula auto-updates. No manual tag, no hand-edited checksum.
2. **T8.11 -- E8 heterogeneous-harness dogfood** (the one open E8 item): Claude
   authors a tiny broken goal, opencode->DGX drives convergence. Independent of E6.

**Frozen design (do NOT relitigate):** `docs/concept.md` (canonical architecture +
source of truth) and ADRs `0001`..`0017`. To change a decision, write a superseding
ADR.

## Use Case Summary

All use cases are tracked in `.claude/scratch/usecases-manifest.json`. Open work:

- **UC-024** (install kazi as a single binary via Homebrew, ADR-0014; now with the
  fully-automated release pipeline of ADR-0017) -- OPEN; E6.

UC-001..UC-023 and **UC-026/UC-027** (generic multi-harness support, E8) are
delivered and verified on `main`. UC-025 (import a standard spec into a goal set)
is **deferred backlog** (ADR-0015).

## Checkable Work Breakdown

The WBS below is the single checkable source of truth; toggle `[ ]` to `[x]`.
Status `kind: agent` is implicit unless noted.

### E6 -- Automated brew release pipeline: Burrito + Homebrew (P2, ADR-0014 + ADR-0017)

Acceptance: merging Conventional Commits to `main` and merging the resulting
release PR causes, with NO further manual steps, a `vX.Y.Z` GitHub Release whose
assets are the four Burrito binaries (macOS `aarch64`/`x86_64`, Linux
`x86_64`/`aarch64`) each with a `.sha256`, and a `kazi-org/homebrew-tap` `kazi`
formula auto-updated to that release so `brew install kazi-org/tap/kazi` (and
`brew upgrade`) install a working single binary with the FULL read-model (no
Erlang prerequisite, NIF bundled). **T6.1 (`mix release`) and the Burrito wrap
config are merged.** The host binary cannot be linked on this macOS-26 dev box
(R-E6-1) -- the build is CI-driven by design.

- [ ] T6.2 Burrito build proven on CI: confirm `mix release` produces a runnable Burrito binary for at least one target on a Zig-compatible runner that bundles ERTS + the `exqlite` NIF, and a fixture `kazi run` PERSISTS iterations to SQLite (read-model present, no escript degradation)  Owner: TBD  Est: 1h  verifies: [UC-024]  deps: []  acc: a CI job (the T6.3 workflow on a test tag) yields a `burrito_out/kazi_<target>` that runs `--help` and converges/persists a fixture goal; evidence captured in the run log. Folded into T6.3's first green run rather than a separate local build (R-E6-1).
- [ ] T6.3 Release build workflow: `.github/workflows/release.yml` -- on a `v*` tag, a matrix builds the four Burrito targets (macOS on `macos-15` per R-E6-1, Linux on `ubuntu-latest`) with Zig 0.15.2 + xz, generates a `.sha256` per binary, and uploads all as GitHub Release assets  Owner: David (WIP, this session)  Est: 2h  verifies: [UC-024]  deps: []  acc: pushing a test tag (`v0.0.0-test1`) produces four `kazi_*` binaries + four `.sha256` as Release assets; the workflow is green; both macOS and Linux jobs succeed. A WIP `release.yml` is committed; this task is making it actually green on a test tag (the real validation -- expect CI iteration on BEAM/Zig/Burrito setup).
- [ ] T6.6 release-please versioning: add the release-please GitHub Action + config (manifest + `release-please-config.json`) so Conventional Commits on `main` maintain a release PR that bumps `mix.exs` version + `CHANGELOG.md` and, on merge, creates the `vX.Y.Z` tag + GitHub Release (which fires T6.3)  Owner: TBD  Est: 1.5h  verifies: [UC-024]  deps: []  acc: a `feat:`/`fix:` commit to `main` causes release-please to open/update a release PR with the correct semver bump; merging it tags + creates a Release; the version in `mix.exs` matches the tag. Validated on a real (or dry-run) cycle.
- [ ] T6.4 Homebrew tap repo + formula: create `kazi-org/homebrew-tap` (agent-doable -- session has `kazi-org` admin) with a `kazi` formula that, per platform, downloads the Release asset, verifies its `.sha256`, and installs the binary onto PATH; `brew install kazi-org/tap/kazi` installs a working `kazi`  Owner: TBD  kind: any  Est: 1.5h  verifies: [UC-024]  deps: [T6.3]  acc: `brew install kazi-org/tap/kazi` on macOS installs a runnable `kazi` (`kazi --help` works post-install); `brew audit --strict --tap kazi-org/homebrew-tap` passes. Needs a real T6.3 Release to point at; repo creation is no longer human-gated (R-E6-2).
- [ ] T6.7 Tap auto-bump workflow: a workflow (in `kazi-org/kazi`, triggered on `release: published`) regenerates the tap's `kazi` formula -- new version, per-platform asset URLs, and the published `.sha256` values -- and pushes it to `kazi-org/homebrew-tap`, authenticated with a fine-grained `HOMEBREW_TAP_TOKEN` secret (contents:write on the tap only). So `brew upgrade` serves the latest with zero manual steps (ADR-0017)  Owner: TBD  Est: 1.5h  verifies: [UC-024]  deps: [T6.4]  acc: publishing a Release updates the tap formula's version/urls/sha256 automatically (verified on a test release); the secret is scoped to the tap repo; a follow-up `brew upgrade` pulls the new version. Use a maintained action (e.g. `dawidd6/action-homebrew-bump-formula`) or an inline generator -- documented.
- [ ] T6.5 Docs: README install section leads with `brew install kazi-org/tap/kazi` + the prebuilt binary; note the runtime requirement that a coding agent (`claude`/`opencode`/...) must be on PATH; reframe the escript as a contributor convenience; link the GitHub Releases page and the auto-release flow (ADR-0017)  Owner: TBD  Est: 0.5h  verifies: [UC-024]  deps: [T6.4]  acc: README documents brew + binary install, the harness-on-PATH requirement, and how releases are cut (merge the release PR); links Releases + ADR-0017.

### E8 dogfood -- heterogeneous harness (Claude plans, opencode/DGX implements)

The capstone live exercise for E8: prove kazi's core division of labor -- a strong
model authors the predicate set (the "direction"), a cheap LOCAL model drives the
convergence loop (the "keystrokes"), and objective termination keeps the weak
implementer honest. Completes the live verification the T8.9 smoke deferred.

- [ ] T8.11 Heterogeneous-harness dogfood: Claude authors a tiny deliberately-broken fixture goal-file (a single `test_runner` predicate failing at t0); `kazi run <goal> --harness opencode --model dgx-ollama/qwen3.6:35b-a3b-q8_0 --workspace <trusted repo>` drives the DGX-hosted Qwen to converge it; record the result in `docs/devlog.md`  Owner: David (in progress, this session)  Est: 1h  verifies: [UC-026, UC-027]  deps: []  acc: a real `kazi run` converges a broken fixture driven ENTIRELY by opencode->DGX (Claude only authored the goal); evidence recorded (iterations, final vector); OR an honest failure with the environmental cause (per the T8.9 finding: opencode auto-rejects edits outside a trusted workspace -- fixed with a project-local `opencode.json` permission grant -- and the 35B model is slow). Throwaway workspace; not committed to the kazi repo.

### Waves

E6 is the automated-release pipeline; the two independent entry points (T6.3 build
workflow, T6.6 release-please) can go in parallel, then converge on the tap. T8.11
is independent of E6 and already running.

- **Wave E6-1 (parallel entry points):** T6.3 (release build workflow -- make it green on a test tag; this also proves T6.2) and T6.6 (release-please versioning). Independent.
- **Wave E6-2 (tap):** T6.4 (create `kazi-org/homebrew-tap` + formula; needs a real T6.3 Release) -> T6.7 (auto-bump workflow + `HOMEBREW_TAP_TOKEN`).
- **Wave E6-3 (docs):** T6.5 (README install + auto-release flow). deps T6.4.
- **Dogfood (running):** T8.11 -- opencode->DGX converging a broken fixture.

## Risk Register

| ID | Risk | Impact | Likelihood | Mitigation |
|----|------|--------|------------|------------|
| R-E6-1 | Burrito host binary cannot be linked on the dev machine (Zig 0.15.2, pinned by Burrito 1.5.0, fails to link against macOS 26 / Xcode 26; Zig 0.16 links but is API-incompatible with Burrito 1.5.0's `build.zig`). | Med | High (observed) | The build is CI-driven by design (ADR-0017): T6.3 builds on `macos-15` + `ubuntu-latest`. Do NOT attempt a local build on this macOS-26 host. |
| R-E6-2 | T6.4 needs a second repo (`kazi-org/homebrew-tap`) and a published Release. | Low | Med | Repo creation is agent-doable (session has `kazi-org` admin via `gh`); no longer human-gated. Sequence T6.4 after T6.3 produces real Release artifacts. |
| R-E6-3 | The shipped binary still requires the user's coding agent (`claude`/`opencode`/...) on PATH at runtime (kazi drives a harness by design, ADR-0001). | Low | High (inherent) | Documented in T6.5; packaging does not solve it. |
| R-E6-4 | `erlef/setup-beam` / Zig 0.15.2 / Burrito setup is fragile on the macOS-15 runner (BEAM install, xz, the Zig link). | Med | Med | Validate T6.3 on a throwaway `v*-test` tag and iterate on the runner (the only place it can be proven, R-E6-1); pin exact Elixir/OTP/Zig versions; `fail-fast: false` so macOS and Linux jobs report independently. |
| R-E6-5 | The cross-repo formula push needs auth the default `GITHUB_TOKEN` lacks. | Med | High (inherent) | A fine-grained `HOMEBREW_TAP_TOKEN` PAT scoped to `contents:write` on `homebrew-tap` only (ADR-0017); created + stored as a repo secret as part of T6.7. Rotate like any deploy credential. |
| R-E6-6 | release-please computes the wrong version from a mistyped commit. | Low | Med | Conventional Commits are already mandated (operating procedure); release-please's release PR is the human review gate before a tag is cut. |

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
- Decisions: `docs/adr/0001`..`0017` (index at `docs/adr/README.md`); the release
  pipeline is ADR-0014 (distribution) + ADR-0017 (automation).
- Operations / findings: `docs/devlog.md`; landmines: `docs/lore.md`
- Use-case manifest: `.claude/scratch/usecases-manifest.json`
- Release surface (for E6): `mix.exs` (`releases/0` + the `burrito:` targets),
  `lib/kazi/release.ex` (`cli/1`, `burrito_main/0`), `.github/workflows/release.yml`
  (T6.3, WIP), `.github/workflows/ci.yml` (the test workflow to mirror setup from).
