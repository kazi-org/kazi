# kazi -- Build Plan (handover: remaining work)

## Context

kazi is a reconciliation controller for software goals: declare a goal as
machine-checkable predicates; kazi drives a coding agent in a loop until the
predicates are objectively true, stuck, or over budget. It drives harnesses
(Claude Code, Codex); it is not a harness.

**This plan is a HANDOVER.** The walking-skeleton build (idea -> production) and
every epic through it are COMPLETE and merged on `main`:

- **E0 Slice 0** (convergence loop to a live, verified Cloud Run deploy) -- done;
  the T0.12 dogfood converged idea -> production live (PR #69).
- **E1 Slice 1** (regression / flake / budget / stuck / prod-log) -- done.
- **E2 Slice 2** (creation mode + self-hosting cutover) -- done.
- **E3 Slice 3** (NATS leases, graph partitioning, deploy deepening, standing
  reconcilers, idea->predicate authoring, LiveView dashboard, Telegram bridge)
  -- done.
- **E4** (context injection / re-exploration mitigation, ADR-0010) -- done,
  including the un-deferred pluggable retrieval-memory adapter (T4.9, ADR-0012).
- **E5** (`kazi init` adopt, ADR-0013) -- T5.1-T5.5 done; only **T5.6** (a
  stack-mode e2e + README "adopt an existing project" snippet) remains.
- **E7** (registry adapter + goal-set, ADR-0015) -- done; `kazi init --registry
  <file.json>` turns a capability registry into a runnable goal SET, verified to
  `:converged` through the real `Kazi.Runtime`.

State of `main` at handover: **785 tests pass** (62 doctests, 723 tests), 18
excluded (`:nats`/`:graphify` integration tags); `mix format --check-formatted`
clean; `mix compile --warnings-as-errors` clean. Distribution PRs #70-#75 merged
this session.

**What remains (the entire content of this plan):**

1. **T5.6** -- finish E5 with a hermetic stack-mode `kazi init` end-to-end test
   against `fixtures/deploy-target` plus a README adopt snippet. Fully hermetic,
   no external dependency -- the easiest next pickup.
2. **E6 (T6.2-T6.5)** -- binary distribution via Burrito + Homebrew (ADR-0014):
   ship `brew install kazi-org/tap/kazi` as a single self-contained binary with
   the full SQLite read-model (NIF bundled), superseding the escript. T6.1 (the
   `mix release` foundation) is already merged; the Burrito wrap config is merged
   but its host binary has not been built (see Risk R-E6-1).

**Frozen design (do NOT relitigate):** `docs/concept.md` (canonical architecture
+ source of truth -- this project keeps Tier-1 architecture here, not in a
separate design.md) and ADRs `0001`..`0015`. To change a decision, write a
superseding ADR.

## Use Case Summary

All use cases are tracked in `.claude/scratch/usecases-manifest.json`. Only two
have open work:

- **UC-023** (adopt an existing project via `kazi init`) -- delivered except the
  T5.6 worked example/e2e.
- **UC-024** (install kazi as a single binary via Homebrew, ADR-0014) -- OPEN;
  the whole of E6 below.

UC-001..UC-022 and UC-025 are delivered and verified on `main`.

## Checkable Work Breakdown

The WBS below is the single checkable source of truth; toggle `[ ]` to `[x]`.
Status `kind: agent` is implicit unless noted.

### E5 -- Adopt kazi on an existing project: `kazi init` (P2, see ADR-0013)

Acceptance: pointing `kazi init` at a working repo emits a loadable starter
goal-file capturing the project's test command + guard invariants, with TODO
placeholders for live predicates. T5.1-T5.5 are done (merged); only the worked
example remains.

- [ ] T5.6 End-to-end + example: `kazi init` against the `fixtures/deploy-target` repo produces a goal-file whose test_runner + guards load and whose live predicate is a TODO stub; commit a worked example + README "adopt an existing project" snippet  Owner: TBD  Est: 1h  verifies: [UC-023]  deps: []  acc: a hermetic e2e test asserts the generated goal loads via `Kazi.Goal.Loader` + names the detected `go test ./...` command for `fixtures/deploy-target`; the live predicate is a commented TODO; README shows the stack-detection adopt flow (distinct from the E7 registry snippet already in the README); `mix test` green; hermetic. NOTE: the CLI (`kazi init <path>`, T5.5), the writer (`Kazi.Adopt.to_toml/1`, T5.3), `Kazi.Adopt.detect/1` (T5.1), and `guards/1` (T5.2) are all merged on `main` -- this task only adds the e2e + example.

### E6 -- Binary distribution: Burrito + Homebrew (P2, see ADR-0014)

Acceptance: `brew install kazi-org/tap/kazi` installs a single self-contained
binary (no Erlang prerequisite) with the FULL read-model (NIF bundled), and
`kazi --help` / a fixture `kazi run` work from it. Supersedes
escript-as-distribution. **T6.1 (mix release) is merged.** The Burrito dep +
wrap config + arg-shim (`Kazi.Release.burrito_main/0`) are merged too, but a
fully-linked host binary has NOT been produced yet (Risk R-E6-1) -- T6.2's
acceptance is best proven on the T6.3 CI matrix (macOS-15 / Ubuntu runners) or a
macOS-15-or-earlier machine, not on this macOS-26 host.

- [ ] T6.2 Burrito wrap -- produce a built binary: the merged config declares targets macOS `aarch64`/`x86_64` + Linux `x86_64`/`aarch64`; build a binary for a supported host that bundles ERTS + the `exqlite` NIF; smoke-run it converging a fixture goal to prove the read-model persists (no escript degradation)  Owner: TBD  Est: 1.5h  verifies: [UC-024]  deps: []  acc: a Burrito binary for a supported host runs `kazi run` against a fixture and PERSISTS iterations to SQLite (read-model present); `--help` works; the build command + output documented. The config/dep/code wiring is already merged; this task is the actual build + smoke-run on a Zig-compatible runner (see R-E6-1).
- [ ] T6.3 Release CI + release-please: tag-triggered GitHub Actions matrix builds Burrito binaries on macOS + Ubuntu runners, uploads them + `.sha256` checksums to GitHub Releases; release-please manages versioning from Conventional Commits  Owner: TBD  Est: 2h  verifies: [UC-024]  deps: [T6.2]  acc: a release tag produces per-platform binaries + a `.sha256` each as Release assets; the workflow is green on a dry-run/test tag. This is also the most reliable way to satisfy T6.2's host-binary build (the runners are Zig-compatible).
- [ ] T6.4 Homebrew tap: create the `kazi-org/homebrew-tap` repo with a `kazi` formula that downloads the platform artifact + verifies its checksum; `brew install kazi-org/tap/kazi` installs a working `kazi`  Owner: TBD  Est: 1.5h  verifies: [UC-024]  kind: any  deps: [T6.3]  acc: `brew install kazi-org/tap/kazi` on macOS installs a runnable `kazi`; `brew audit --strict` passes; `kazi --help` works post-install. NEEDS the new `kazi-org/homebrew-tap` repo + a published GitHub Release to point the formula at (human-gated: repo creation + a real release).
- [ ] T6.5 Docs: README install section leads with `brew install` + the prebuilt binary; note the runtime requirement that a coding agent (`claude`) must be on PATH; reframe the escript as a contributor convenience  Owner: TBD  Est: 0.5h  verifies: [UC-024]  deps: [T6.4]  acc: README documents brew + binary install and the harness-on-PATH requirement; links the GitHub Releases page.

### Waves

Only the remaining tasks. T5.6 is independent and hermetic -- start it now in
parallel with E6. E6 is a strict chain (T6.2 -> T6.3 -> T6.4 -> T6.5).

- **Wave A (1 agent, now):** T5.6   (hermetic; no external dependency)
- **Wave B:** T6.2   (build + smoke-run a Burrito host binary on a Zig-compatible runner; or fold into T6.3 CI)
- **Wave C:** T6.3   (release CI + release-please; green on a test tag)
- **Wave D (kind: any, human-gated):** T6.4   (create `kazi-org/homebrew-tap` + cut a real Release) -> then T6.5 docs

## Risk Register

| ID | Risk | Impact | Likelihood | Mitigation |
|----|------|--------|------------|------------|
| R-E6-1 | Burrito host binary cannot be linked on the dev machine (Zig 0.15.2, the version Burrito 1.5.0 pins, fails to link against the macOS 26 / Xcode 26 SDK; Zig 0.16 links but is API-incompatible with Burrito 1.5.0's `build.zig`). | Med | High (observed this session) | Build on the T6.3 CI matrix (GitHub macOS-15 / Ubuntu runners are Zig-compatible) or a macOS-15-or-earlier host. The release assembles + bundles ERTS/NIFs fully; only the final Zig link fails on macOS 26. Do NOT block E6 on a local build. |
| R-E6-2 | T6.4 needs a second repo (`kazi-org/homebrew-tap`) and a published GitHub Release before `brew install` can work. | Med | Med | Sequence T6.4 after T6.3 produces real Release artifacts; repo creation + first release is human-gated (`kind: any`). |
| R-E6-3 | The shipped binary still requires the user's coding agent (`claude`/Codex) on PATH at runtime (kazi drives a harness by design, ADR-0001). | Low | High (inherent) | Document the runtime dependency in T6.5; it is not solved by packaging. |

## Operating Procedure

Definition of done (all must hold): ExUnit tests written and green for the
change; `mix format --check-formatted` clean; `mix compile --warnings-as-errors`
clean; PR merged to `main` via **rebase** (not squash, not a merge commit) with
CI green; for any user-facing/production surface, deployed and verified live (a
live probe passes), reported honestly. Make many small focused commits; never
commit files from different directories in one commit. Add tests with every
implementation task.

Execution model: work the plan with `/apply --pool` (atomic git-ref claims at
`refs/claims/*` via the global `~/.claude/skills/claim/scripts/claim.sh`). The
WBS above is the single checkable source of truth.

## Progress Log

### 2026-06-22 -- Change Summary (HANDOVER trim)
- **Trimmed all completed epics out of the plan** (E0-E4, E7, and E5 T5.1-T5.5).
  Every trimmed task was already `[x]` and merged; this plan now contains ONLY the
  open work: T5.6 and E6 (T6.2-T6.5).
- Knowledge routing (already in place; nothing lost by the trim):
  - **Tier-1 architecture** lives in `docs/concept.md` (this project's canonical
    architecture doc + source of truth; there is no separate `design.md` by
    convention).
  - **Tier-2 decisions** are ADRs `0001`..`0015` (`docs/adr/`). ADR-0015 (init
    source/output model: registry adapter + goal-set) was added this session.
  - **Tier-3 operations** are in `docs/devlog.md` (newest first), including the
    E7 registry-adapter entry and the T0.12 idea->production convergence; landmines
    in `docs/lore.md` (L-0001..L-0004).
- This session's merges (context for the next session): PRs #70 (T6.1 mix
  release), #71 (T5.1 detect), #72 (T5.2 guards), #73 (T5.4 enrichment), #74
  (T6.2 Burrito config/wiring -- binary NOT yet built, see R-E6-1), #75 (E7
  registry adapter + goal-set, which also delivered the T5.3 writer and T5.5 `init`
  CLI verb). ADR-0015 written; UC-025 added.
- Older Progress Log / Wave-history entries were removed per the trim policy; the
  full build history is reconstructable from `docs/devlog.md` and the merged PRs.

## Hand-off Notes (cold start for a new session)

1. **Verify the baseline first:** `mix test` should report ~785 passing, 18
   excluded; `mix format --check-formatted` and `mix compile
   --warnings-as-errors` clean. If not, stop and diagnose before building.
2. **Easiest next task: T5.6** -- fully hermetic, no external dependency. The
   `kazi init <path>` CLI, the `Kazi.Adopt` detect/guards/writer, and the
   `fixtures/deploy-target` Go repo all already exist on `main`. Add an e2e test
   that runs `kazi init` against that fixture and asserts the generated goal loads
   and names `go test ./...`, plus a README "adopt an existing project" snippet
   (the registry snippet from E7 is already in the README -- this is the
   stack-detection sibling).
3. **E6 is a chain, and the binary build is environment-sensitive.** Do not try to
   build the Burrito host binary on a macOS 26 machine -- it will fail at the Zig
   link step (R-E6-1). Drive T6.2's build through the T6.3 CI matrix (macOS-15 /
   Ubuntu runners) instead, or use a macOS-15-or-earlier host. T6.4 (`brew
   install`) needs a new `kazi-org/homebrew-tap` repo and a published GitHub
   Release; that is human-gated.
4. **Distribution context:** the escript stays as a contributor convenience
   (ADR-0014 keeps it); the binary becomes the shipping artifact. The binary fixes
   the escript's read-model gap (escripts cannot bundle the `exqlite` NIF; the
   release/binary can).
5. **Do not relitigate frozen design** -- read `docs/concept.md` and the relevant
   ADR before touching an area; write a superseding ADR to change a decision.

## Appendix

- Concept and architecture: `docs/concept.md`
- Decisions: `docs/adr/0001`..`0015` (index at `docs/adr/README.md`)
- Operations / findings: `docs/devlog.md`; landmines: `docs/lore.md`
- Use-case manifest: `.claude/scratch/usecases-manifest.json`
