# kazi -- Build Plan (remaining work)

## Context

kazi is a reconciliation controller for software goals: declare a goal as
machine-checkable predicates; kazi drives a coding agent in a loop until the
predicates are objectively true, stuck, or over budget. It drives harnesses
(Claude Code, Codex, opencode, ...); it is not a harness.

The walking-skeleton build (idea -> production) and every epic through it are
COMPLETE and merged on `main`:

- **E0-E4** (convergence loop to a live Cloud Run deploy; regression/flake/budget/
  stuck/prod-log; creation mode + self-hosting; NATS leases, graph partitioning,
  standing reconcilers, idea->predicate authoring, LiveView, Telegram; context
  injection + pluggable retrieval-memory) -- all done and merged.
- **E5** (`kazi init` adopt, ADR-0013) -- DONE. T5.1-T5.5 plus T5.6 (hermetic
  stack-mode e2e + committed worked example + README snippet) merged (T5.6 = PR
  #76).
- **E7** (registry adapter + goal-set) -- built, then WITHDRAWN before the
  open-source release (ADR-0015): the `capabilities.json` input was bespoke and did
  not generalize.

State of `main`: **760 tests pass** (62 doctests, 698 tests), 18 excluded
(`:nats`/`:graphify` integration tags); `mix format --check-formatted` clean;
`mix compile --warnings-as-errors` clean.

**What remains (the entire content of this plan):**

1. **E6 (T6.2-T6.5)** -- binary distribution via Burrito + Homebrew (ADR-0014):
   ship `brew install kazi-org/tap/kazi` as a single self-contained binary with
   the full SQLite read-model (NIF bundled), superseding the escript. T6.1 (the
   `mix release` foundation) is merged; the Burrito wrap config is merged but its
   host binary has not been built (Risk R-E6-1). Environment-sensitive; drive the
   build through CI, not this macOS-26 host.
2. **E8 (T8.1-T8.10)** -- generic multi-harness support (ADR-0016): generalize the
   single `Kazi.Harness.ClaudeAdapter` into a config-driven, profile-parameterized
   CLI adapter so kazi can drive **opencode** (wired to a local Qwen3.6 35B-A3B on
   the DGX) and any other CLI harness (Codex, gemini-cli, antigravity, claw-code)
   by declaring a profile -- no core code change. This is the live trigger: the
   operator has opencode installed (v1.17.9) and wants kazi to drive it.

**Frozen design (do NOT relitigate):** `docs/concept.md` (canonical architecture +
source of truth) and ADRs `0001`..`0016`. To change a decision, write a superseding
ADR.

## Use Case Summary

All use cases are tracked in `.claude/scratch/usecases-manifest.json`. Open work:

- **UC-024** (install kazi as a single binary via Homebrew, ADR-0014) -- OPEN; E6.
- **UC-026** (drive convergence with opencode + a local model on the DGX, ADR-0016)
  -- OPEN; E8.
- **UC-027** (select/configure the coding harness generically; add a harness by
  declaring a profile, ADR-0016) -- OPEN; E8.

UC-001..UC-023 are delivered and verified on `main`. UC-025 (import a standard
spec into a goal set) is **deferred backlog** (ADR-0015).

## Checkable Work Breakdown

The WBS below is the single checkable source of truth; toggle `[ ]` to `[x]`.
Status `kind: agent` is implicit unless noted.

### E6 -- Binary distribution: Burrito + Homebrew (P2, see ADR-0014)

Acceptance: `brew install kazi-org/tap/kazi` installs a single self-contained
binary (no Erlang prerequisite) with the FULL read-model (NIF bundled), and
`kazi --help` / a fixture `kazi run` work from it. Supersedes
escript-as-distribution. **T6.1 (mix release) is merged.** The Burrito dep + wrap
config + arg-shim (`Kazi.Release.burrito_main/0`) are merged too, but a
fully-linked host binary has NOT been produced yet (Risk R-E6-1) -- T6.2's
acceptance is best proven on the T6.3 CI matrix (macOS-15 / Ubuntu runners) or a
macOS-15-or-earlier machine, not on this macOS-26 host.

- [ ] T6.2 Burrito wrap -- produce a built binary: the merged config declares targets macOS `aarch64`/`x86_64` + Linux `x86_64`/`aarch64`; build a binary for a supported host that bundles ERTS + the `exqlite` NIF; smoke-run it converging a fixture goal to prove the read-model persists (no escript degradation)  Owner: TBD  Est: 1.5h  verifies: [UC-024]  deps: []  acc: a Burrito binary for a supported host runs `kazi run` against a fixture and PERSISTS iterations to SQLite (read-model present); `--help` works; the build command + output documented. The config/dep/code wiring is already merged; this task is the actual build + smoke-run on a Zig-compatible runner (see R-E6-1).
- [ ] T6.3 Release CI + release-please: tag-triggered GitHub Actions matrix builds Burrito binaries on macOS + Ubuntu runners, uploads them + `.sha256` checksums to GitHub Releases; release-please manages versioning from Conventional Commits  Owner: TBD  Est: 2h  verifies: [UC-024]  deps: [T6.2]  acc: a release tag produces per-platform binaries + a `.sha256` each as Release assets; the workflow is green on a dry-run/test tag. This is also the most reliable way to satisfy T6.2's host-binary build (the runners are Zig-compatible).
- [ ] T6.4 Homebrew tap: create the `kazi-org/homebrew-tap` repo with a `kazi` formula that downloads the platform artifact + verifies its checksum; `brew install kazi-org/tap/kazi` installs a working `kazi`  Owner: TBD  Est: 1.5h  verifies: [UC-024]  kind: any  deps: [T6.3]  acc: `brew install kazi-org/tap/kazi` on macOS installs a runnable `kazi`; `brew audit --strict` passes; `kazi --help` works post-install. NEEDS the new `kazi-org/homebrew-tap` repo + a published GitHub Release to point the formula at (human-gated: repo creation + a real release).
- [ ] T6.5 Docs: README install section leads with `brew install` + the prebuilt binary; note the runtime requirement that a coding agent (`claude`) must be on PATH; reframe the escript as a contributor convenience  Owner: TBD  Est: 0.5h  verifies: [UC-024]  deps: [T6.4]  acc: README documents brew + binary install and the harness-on-PATH requirement; links the GitHub Releases page.

### E8 -- Generic multi-harness support: harness profiles (P2, see ADR-0016)

Acceptance: kazi can drive a non-Claude CLI harness without a bespoke adapter
module. Concretely, `kazi run <goal> --harness opencode --model <provider/model>`
converges a goal by driving `opencode run` against the operator's local Qwen3.6 on
the DGX; the Claude path is byte-for-byte unchanged; and adding a further harness
(Codex, gemini-cli) is a profile DATA entry, not new core code. The boundary stays
headless + stateless per iteration (ADR-0008) and harness-agnostic (ADR-0001 R4).

Grounding (verified this session): `Kazi.HarnessAdapter` is a clean behaviour
(`run/3`); `Kazi.Loop` is already generic over the `:harness` module
(`loop.ex:1164`). The Claude coupling is only in the single concrete adapter and in
`Kazi.Runtime`'s hard-coded `@harness` (`runtime.ex:58`). opencode is installed
here (v1.17.9); its non-interactive surface is `opencode run "<msg>"` with
`--model provider/model` and `--format json` (a NDJSON **event stream**, not
Claude's single envelope; `opencode stats` reports usage).

- [ ] T8.1 Harness profile struct + registry: add `Kazi.Harness.Profile` (a struct: `id`, `command`, the argv-template spec for prompt/model/output-format/extra flags, the parser-strategy ref, and the set of supported optional hygiene flags) and a built-in registry whose `:claude` profile captures TODAY's exact claude argv (`-p`, `--output-format json`, the `--max-budget-usd`/`--allowed-tools`/`--permission-mode` hygiene flags) and envelope parser. Pure, no IO.  Owner: TBD  Est: 1.5h  verifies: [UC-027]  deps: []  acc: `Kazi.Harness.Profile` + `Kazi.Harness.Registry.fetch(:claude)` return a profile whose rendered argv for a given (prompt, opts) equals the current `ClaudeAdapter` argv byte-for-byte (golden unit test); `mix format`/`--warnings-as-errors` clean.
- [ ] T8.2 Generic CLI adapter: add `Kazi.Harness.CliAdapter` implementing `Kazi.HarnessAdapter`, parameterized by a resolved profile via `:profile`/`:harness` opt. It assembles argv from the profile, runs `System.cmd` with `cd:` workspace (ADR-0008, `stderr_to_stdout`), and maps stdout to the normalized result map (`output/exit/result/tokens/cost_usd/touched/cost: %{tokens}`) via the profile's parser; missing-binary -> `{:error, {:command_not_found, cmd}}`, empty prompt -> `{:error, :empty_prompt}`.  Owner: TBD  Est: 2h  verifies: [UC-027]  deps: [T8.1]  acc: a Tier-2 test drives CliAdapter with the `:claude` profile against a stub binary and asserts the SAME result map shape + the same argv the legacy ClaudeAdapter produced (golden); a stub-binary missing case returns `{:error, {:command_not_found, _}}`; `mix test` green.
- [ ] T8.3 Neutral prompt construction: extract `build_prompt/2,3`, `render_retrieval_section/1`, and `truncate_evidence/2` from `Kazi.Harness.ClaudeAdapter` into a harness-neutral `Kazi.Harness.Prompt`; have `ClaudeAdapter` (now a thin `:claude`-profile shim over CliAdapter) and `Kazi.Loop` call the neutral module, removing `loop.ex`'s `alias Kazi.Harness.ClaudeAdapter` coupling (`loop.ex:1238`).  Owner: TBD  Est: 1.5h  verifies: [UC-027]  deps: [T8.2]  acc: every existing prompt/retrieval/truncation doctest + test passes unchanged against `Kazi.Harness.Prompt`; `Kazi.Loop` no longer references `ClaudeAdapter`; build green, no behavior change (golden prompt strings identical).
- [ ] T8.4 opencode profile: add the `:opencode` built-in profile -- `opencode run "<prompt>" --model <provider/model> --format json` run with `cd:` workspace; a parser strategy that consumes opencode's NDJSON event stream to extract the final assistant/result text and (when present) token/cost, mapping to the normalized result map and degrading the token dimension to estimate when usage is absent (ADR-0008). Confirm the real flags against the installed opencode (v1.17.9), NOT assumed.  Owner: TBD  Est: 2h  verifies: [UC-026]  deps: [T8.1]  acc: a Tier-2 test drives CliAdapter+`:opencode` against a stub `opencode` binary emitting a representative `--format json` event stream and asserts the result map carries the final result text (and tokens when the stub emits usage); the rendered argv matches `opencode run <prompt> --model <m> --format json`; documented from `opencode run --help`.
- [ ] T8.5 Harness resolution seam: add `Kazi.Harness.resolve/1` returning `{adapter_module, adapter_opts}` with fixed precedence -- explicit `:harness` opt > goal-file `[harness]` table > app config `:kazi, :harness` > default `:claude`; carries `:profile`, `:model`, and any provider/endpoint env (so opencode points at the DGX model). Unknown harness id -> a clear `{:error, {:unknown_harness, id}}`.  Owner: TBD  Est: 1.5h  verifies: [UC-027]  deps: [T8.1]  acc: unit tests cover each precedence rung (opt beats goal-file beats config beats default), the default returns the `:claude` profile, and an unknown id errors clearly; pure, no IO.
- [ ] T8.6 Goal-file `[harness]` table: extend `Kazi.Goal` (additive field) + `Kazi.Goal.Loader.from_map/1` to load an optional `[harness]` table (`id`, optional `model`, optional `command` override), and `Kazi.Adopt.Writer` to optionally emit it; absent table -> today's behavior (default `:claude`).  Owner: TBD  Est: 1.5h  verifies: [UC-026, UC-027]  deps: [T8.5]  acc: a goal-file with `[harness] id = "opencode" model = "dgx/qwen3.6"` loads into the Goal and `Kazi.Harness.resolve/1` selects opencode + that model; a goal-file with no `[harness]` loads exactly as before (round-trip test); loader rejects an unknown-typed table with a clear error.
- [ ] T8.7 Wire Runtime + CLI + authoring/adopt: replace `Kazi.Runtime`'s hard-coded `@harness` with `Kazi.Harness.resolve/1` over (goal, config, opts); add `kazi run --harness <id> --model <m>` flags to `Kazi.CLI` threaded into `adapter_opts`; route `Kazi.Authoring` and `Kazi.Adopt.enrich` default harness through the same seam.  Owner: TBD  Est: 2h  verifies: [UC-026, UC-027]  deps: [T8.2, T8.4, T8.5, T8.6]  acc: `kazi run <fixture-goal> --harness opencode --model <m>` resolves CliAdapter+opencode and dispatches (verified against a stub harness in a Tier-2 CLI test); with no `--harness`, behavior is byte-identical to today (claude); CLI `--help` documents the flags; `mix test` green.
- [ ] T8.8 Local-provider config + env: support pointing opencode at the DGX-hosted Qwen via the profile (pass `--model <provider/model>` and any required env such as a base URL / `OPENCODE_*` var); document that opencode's own provider config (already wired by the operator) is the source of truth and kazi only selects the model.  Owner: TBD  Est: 1h  verifies: [UC-026]  deps: [T8.4]  acc: a test asserts the resolved opencode `adapter_opts` carry the configured model and forward declared env to `System.cmd`; README documents the DGX/Qwen setup expectation (opencode provider pre-configured; kazi selects `--model`).
- [ ] T8.9 Tests incl. live opencode smoke: full coverage -- unit (profile/registry/resolution/parsers), Tier-2 (CliAdapter per profile against stub binaries; golden claude-argv; opencode NDJSON parse), and a Tier-4 LIVE smoke that runs `kazi run <hermetic fixture goal> --harness opencode` end-to-end against the operator's DGX-hosted Qwen and asserts convergence + a persisted iteration; honestly SKIP (not fake-pass) with a logged reason when the DGX endpoint is unreachable.  Owner: TBD  Est: 2h  verifies: [UC-026, UC-027]  deps: [T8.7]  acc: stub-driven tests are green and hermetic in CI; the live smoke either converges a fixture goal through opencode->DGX (evidence recorded: iteration count + final vector) or is reported SKIPPED with the unreachable-endpoint reason -- never silently passed.
- [ ] T8.10 Docs + ADR reference: README gains a "Use a different coding harness" section -- claude is the default; `--harness opencode --model <provider/model>` for the local DGX model; the goal-file `[harness]` table; and "add a harness = declare a profile" pointing at `Kazi.Harness.Registry`; link ADR-0016. Update `docs/concept.md` only where the harness boundary is described (general terms, no model names).  Owner: TBD  Est: 1h  verifies: [UC-026, UC-027]  deps: [T8.7]  acc: README documents harness selection (flag, goal-file, config) + how to add a profile + the harness-on-PATH runtime requirement; ADR-0016 linked; concept.md harness section reflects multi-harness neutrality; no model-specific detail leaks into Tier-1 docs.

### Waves

E6 is a strict chain (T6.2 -> T6.3 -> T6.4 -> T6.5). E8 starts with a foundation
pair, then fans out, then converges on wiring + verification. E6 and E8 are
independent and can proceed in parallel.

- ~~**Wave A:** T5.6~~ -- DONE (PR #76).
- **Wave B (E6):** T6.2   (build + smoke-run a Burrito host binary on a Zig-compatible runner; or fold into T6.3 CI) -> T6.3 -> **(human-gated)** T6.4 -> T6.5.
- **Wave E8-1 (foundation, now; 1 agent serial-ish):** T8.1 -> T8.2   (profile/registry + the generic CLI adapter, claude pinned by a golden test).
- **Wave E8-2 (fan-out, after T8.1/T8.2):** T8.3, T8.4, T8.5   (neutral prompt refactor; opencode profile; resolution seam -- independent, parallel).
- **Wave E8-3 (integrate):** T8.6 -> T8.7, T8.8   (goal-file table; Runtime/CLI/authoring/adopt wiring; local-provider config).
- **Wave E8-4 (verify + ship):** T8.9, T8.10   (tests incl. live opencode->DGX smoke; docs + ADR link).

## Risk Register

| ID | Risk | Impact | Likelihood | Mitigation |
|----|------|--------|------------|------------|
| R-E6-1 | Burrito host binary cannot be linked on the dev machine (Zig 0.15.2, pinned by Burrito 1.5.0, fails to link against the macOS 26 / Xcode 26 SDK; Zig 0.16 links but is API-incompatible with Burrito 1.5.0's `build.zig`). | Med | High (observed) | Build on the T6.3 CI matrix (GitHub macOS-15 / Ubuntu runners are Zig-compatible) or a macOS-15-or-earlier host. Do NOT block E6 on a local build. |
| R-E6-2 | T6.4 needs a second repo (`kazi-org/homebrew-tap`) and a published GitHub Release before `brew install` can work. | Med | Med | Sequence T6.4 after T6.3 produces real Release artifacts; repo creation + first release is human-gated (`kind: any`). |
| R-E6-3 | The shipped binary still requires the user's coding agent (`claude`/Codex/opencode) on PATH at runtime (kazi drives a harness by design, ADR-0001). | Low | High (inherent) | Document the runtime dependency in T6.5/T8.10; packaging does not solve it. |
| R-E8-1 | opencode's exact non-interactive flags / `--format json` event schema differ from the assumption, breaking the parser. | Med | Med | opencode is installed here (v1.17.9); T8.4 confirms flags against `opencode run --help` and captures a REAL sample event stream as the parser fixture, not an assumed shape. |
| R-E8-2 | The DGX-hosted Qwen endpoint is unreachable from CI / this host, so the live smoke (T8.9) cannot run. | Med | Med | Stub-driven Tier-2 tests are hermetic and gate CI; the live smoke is a Tier-4 probe that SKIPS honestly with a logged reason when the endpoint is down -- never a silent pass (definition of done reported honestly). |
| R-E8-3 | opencode does not report token usage in a form kazi can read, so the budget ceiling's token dimension is unavailable. | Low | Med | ADR-0008 already permits degrading to an estimate; T8.4 surfaces "tokens: estimate" honestly rather than fabricating a count. |
| R-E8-4 | Generalizing the adapter silently regresses the Claude path. | High | Low | T8.1/T8.2 pin the `:claude` profile with a golden argv + result-map test; T8.3 keeps every existing prompt doctest byte-identical; default resolution stays `:claude`. |

## Operating Procedure

Definition of done (all must hold): ExUnit tests written and green for the change;
`mix format --check-formatted` clean; `mix compile --warnings-as-errors` clean; PR
merged to `main` via **rebase** (not squash, not a merge commit) with CI green; for
any user-facing/production surface, deployed and verified live (a live probe
passes), reported honestly. Make many small focused commits; never commit files
from different directories in one commit. Add tests with every implementation task.

Execution model: work the plan with `/apply --pool` (atomic git-ref claims at
`refs/claims/*` via the global `~/.claude/skills/claim/scripts/claim.sh`). The WBS
above is the single checkable source of truth.

House rules for E8: do NOT relitigate ADR-0001/0008 (stateless, headless,
harness-agnostic) -- E8 FULFILLS them. Keep each iteration a fresh subprocess; no
`--continue`/`--resume`/`--session` by default. The Claude path must stay
byte-for-byte unchanged (golden test). A new harness is profile DATA, not a new
adapter module.

## Progress Log

### 2026-06-22 -- Change Summary (add E8: generic multi-harness support)
- **Added E8 (T8.1-T8.10)** to drive non-Claude CLI harnesses generically
  (ADR-0016). Trigger: the operator wired `opencode` (installed v1.17.9) to a local
  Qwen3.6 35B-A3B on the DGX and wants kazi to drive it, generalized so Codex /
  gemini-cli / antigravity / claw-code drop in by declaring a profile.
- **Discovery (this session):** `Kazi.HarnessAdapter` is a clean behaviour and
  `Kazi.Loop` is already generic over the `:harness` module (`loop.ex:1164`); the
  only Claude coupling is the single concrete adapter's argv/parser/default-command
  and `Kazi.Runtime`'s hard-coded `@harness` (`runtime.ex:58`). opencode's real
  non-interactive surface was probed: `opencode run "<msg>" --model provider/model
  --format json` emits a NDJSON event stream (not Claude's single envelope), so a
  profile must carry both an argv template AND a parser strategy.
- **ADR created:** `docs/adr/0016-generic-harness-profiles.md` -- the config-driven
  profile + generic `Kazi.Harness.CliAdapter` + `Kazi.Harness.resolve/1` resolution
  order; preserves ADR-0001/0008 (stateless, neutral) and keeps Claude byte-for-byte.
- **Use cases added:** UC-026 (drive opencode + local DGX model), UC-027 (select
  the harness generically; add one by declaring a profile). Manifest updated.
- E6 (Burrito/Homebrew) is unchanged and still open; E6 and E8 are independent.

### 2026-06-22 -- Change Summary (T5.6 done, E5 closed)
- **T5.6 merged (PR #76):** hermetic `kazi init` e2e against `fixtures/deploy-target`
  + committed worked example `priv/examples/adopt_deploy_target.goal.toml` + README
  worked-example snippet. UC-023 fully delivered; E5 closed. Suite 755 -> 760.

## Hand-off Notes (cold start for a new session)

1. **Verify the baseline first:** `mix test` should report 760 passing, 18 excluded;
   `mix format --check-formatted` and `mix compile --warnings-as-errors` clean. If
   not, stop and diagnose before building.
2. **E8 is the most actionable next work** and is fully local/hermetic for most
   tasks. Start at T8.1 -> T8.2 (the profile + generic CLI adapter, with the
   `:claude` profile pinned by a golden argv test), then fan out (T8.3 neutral
   prompt refactor, T8.4 opencode profile, T8.5 resolution). opencode is installed
   (v1.17.9) -- confirm its flags against `opencode run --help` and capture a REAL
   `--format json` event stream as the parser fixture. The ONLY non-hermetic step
   is the T8.9 live smoke against the DGX-hosted Qwen, which must SKIP honestly if
   the endpoint is unreachable.
3. **E8 must not regress Claude.** The default harness stays `:claude`; T8.1/T8.2
   keep the claude argv + result map byte-for-byte; T8.3 keeps every prompt doctest
   identical. Read ADR-0016 (and ADR-0001/0008) before touching the harness layer;
   do not enable session continuity by default.
4. **E6 is a chain and environment-sensitive.** Do not build the Burrito host binary
   on a macOS-26 machine (R-E6-1, Zig link fails). Drive T6.2 through the T6.3 CI
   matrix. T6.4 (`brew install`) needs a new `kazi-org/homebrew-tap` repo + a
   published Release; human-gated.
5. **Do not relitigate frozen design** -- read `docs/concept.md` and the relevant
   ADR before touching an area; write a superseding ADR to change a decision.

## Appendix

- Concept and architecture: `docs/concept.md`
- Decisions: `docs/adr/0001`..`0016` (index at `docs/adr/README.md`)
- Operations / findings: `docs/devlog.md`; landmines: `docs/lore.md`
- Use-case manifest: `.claude/scratch/usecases-manifest.json`
- Harness layer (for E8): `lib/kazi/harness_adapter.ex` (behaviour),
  `lib/kazi/harness/claude_adapter.ex` (current sole adapter),
  `lib/kazi/runtime.ex:58` (hard-coded `@harness`), `lib/kazi/loop.ex:1164` (the
  generic `data.harness.run/3` call site).
