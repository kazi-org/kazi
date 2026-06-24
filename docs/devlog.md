# kazi devlog

Session findings, dogfood results, and benchmarks. Append-only; newest entries
at the top. For invariants/landmines see `docs/lore.md`; for decisions see
`docs/adr/`.

## 2026-06-23 — token-efficiency audit: is claude→kazi→claude cheaper than vanilla?

Audited whether the orchestrator→kazi→implementer stack (ADR-0023) actually
beats vanilla Claude on cost, and where kazi leaks tokens today. Verified against
the live dispatch path (`lib/kazi/loop.ex:1208 dispatch_prompt/2`), not the ADR
prose.

**The honest framing.** "Cheaper" ≠ "fewer tokens". The naive setup — claude →
kazi → claude with the SAME big model on every layer, stateless per iteration
(ADR-0008) — is *more* tokens than vanilla: vanilla amortizes orientation across
one growing context, while kazi re-pays per-iteration orientation N times AND
adds the orchestrator on top. kazi wins on **cost**, not token count, via two
levers that are intrinsic, not yet proven:
1. **Model tiering (ADR-0023).** Expensive model authors predicates ONCE; a cheap
   LOCAL model (Qwen/DGX via opencode/claw) does the N grind iterations; objective
   predicates keep the cheap model honest. The expensive tokens are paid once; the
   N iterations run on near-free compute.
2. **"Right the first time."** Objective termination removes the hidden cost of a
   human re-prompting an agent that *thought* it was done. That cost is real but
   uncounted in a naive token diff.

**What's already shipped well (verified):** real token/cost capture from
`claude --output-format json` (`harness/profiles/claude.ex`); code-review-graph
MCP registered + refreshed in the target `.mcp.json` before every dispatch
(`workspace.ex` — gives the inner agent ~10× cheaper structural queries per
ADR-0010 research); bounded working-set digest carried across iterations as map
memory (`loop/digest.ex`); graphify retrieval adapter present (off by default,
SHA-cached); SHA-keyed orientation-pack cache keyed on `(workspace, git_sha,
failing_set)` (`context.ex:165`).

**Where kazi leaks tokens TODAY (gaps found):**
1. **Orientation pack is delivered as a file, not a cached prompt prefix.** The
   live loop's `dispatch_prompt/2` builds digest + `inspect(evidence)` + optional
   retrieval, and writes the pack to `.kazi/context.md`. The inner agent must READ
   that file (tool calls + input tokens, no cache discount) instead of receiving
   it as a stable, prompt-cacheable prefix. The prefix-injection path
   (`Harness.Prompt.build_prompt/3`, T4.3 — marked done, tested) EXISTS but is NOT
   called by the loop. Wiring it + Anthropic `cache_control` on the stable prefix
   is the single highest-leverage fix and the code is already written — realizes
   the 50–90% input savings ADR-0010 cites. **Landmine: T4.3 is "done" but unwired
   on the live path.**
2. **No Anthropic prompt caching (`cache_control`) anywhere.** Even the workspace
   file approach forfeits the cache discount on the stable goal/orientation prefix.
3. **Evidence rendered via raw `inspect/1`** in `dispatch_prompt/2`, bypassing
   `Prompt.truncate_evidence/2` (T4.8) — large evidence maps go in untruncated on
   the live path.
4. **caller-drafts mode absent (T15.2 open).** If `propose` spawns its own model to
   draft predicates while the orchestrator already reasoned about the idea, that is
   the redundant expensive call ADR-0023 §4 warns about. T15.2 caller-drafts
   removes it; until then the agent-drivable path double-pays authoring.
5. **No benchmark exists.** The "cheaper" claim is UNMEASURED — there are zero
   token A/B numbers in this repo. ADR-0010 promised "the first self-hosted run
   becomes the benchmark"; T15.9 (live claude→kazi→claw/Qwen dogfood) is the slot
   and is still open. Until run, "cheaper" must NOT appear on the README/site.

**Prioritized levers (brainstorm, not yet decided):**
- **P0 — Run the benchmark (T15.9).** Same broken fixture converged three ways:
  (a) vanilla Claude, (b) claude→kazi→Opus, (c) Opus-authors→kazi→local-Qwen.
  Record input/output/cache tokens, $, iterations, and correctness. This turns
  "we think it's cheaper" into the headline marketing line — or exposes the leaks.
- **P0 — Wire the orientation prefix + prompt caching** (realize T4.3 on the live
  loop; add `cache_control`). Highest token-per-hour win; code largely exists.
- **P1 — Ship caller-drafts (T15.2)** to kill the redundant authoring call.
- **P1 — Feed more blast-radius from the graph INTO the prompt** (impact radius /
  detect-changes symbols) so the cheap agent never greps to orient.
- **P2 — Auto-enable graphify retrieval above a repo-size threshold** (cache built);
  differential evidence (send only the delta vs last iteration); predicate-level
  memoization so expensive live/browser predicates don't re-run when their blast
  radius is unchanged.

**Bottom line:** the architecture is DESIGNED to be cheaper and the hard parts
(graph integration, token capture, caching infra) are built — but the two levers
that prove it (prompt-cache prefix, caller-drafts) are unwired and the benchmark
is unrun. "Cheaper" is the right north star; it is not yet earned in numbers.

## 2026-06-23 — harness CLI contracts researched (motivates E14 / ADR-0022)

Researched the CLI contracts of three coding harnesses to onboard as profiles
(ADR-0016 makes a harness data, not a module). The load-bearing criterion for kazi:
it drives a harness as a NON-INTERACTIVE SUBPROCESS (no TTY) and parses stdout.

- **Codex** — `codex exec "<prompt>" --json [--model <m>]` (or `codex e`) emits a
  newline-delimited JSON (JSONL) event stream (`thread.started`, `turn.completed`,
  `item.*`, `error`); `--output-schema` for a structured final; auth `OPENAI_API_KEY`
  / `codex login`. FULLY conformant — the parser mirrors the opencode NDJSON path.
  Priority addition. (developers.openai.com/codex/exec; openai/codex docs/exec.md)
- **Antigravity** (`agy` / `antigravity`) — non-interactive via `--prompt` / `-p` /
  `--prompt-file`; structured via `--output json`; `--yes` auto-approves; auth
  `GEMINI_API_KEY` / `ANTIGRAVITY_API_KEY`. LANDMINE: `agy -p` SILENTLY DROPS stdout
  under a non-TTY (pipe/subprocess/redirect) — issue google-antigravity/
  antigravity-cli#76 — exactly kazi's mode. Workaround: `--prompt-file` +
  `--output json` written to a file we read back; may need version pinning.
- **claw-code** — `claw prompt "<text>"`, env API keys (ANTHROPIC_API_KEY/
  OPENAI_API_KEY), NO documented JSON output, no model flag; the repo calls itself
  "an agent-managed museum exhibit rather than a production tool." Fails the
  structured-output bar → best-effort/demo-grade profile only (raw-stdout parse, no
  cost extraction). (github.com/ultraworkers/claw-code)

Decision recorded in ADR-0022 (conformance contract + onboarding recipe + tiered
support); built as E14. The Antigravity non-TTY landmine should also go to
docs/lore.md when T14.3 lands.

## 2026-06-23 — sirerun dogfood: capability-manifest adjudication (motivates E12)

Dogfooded kazi's reconciliation thesis against sire's `docs/capabilities.json`
(`sire-capability-manifest/v1`): 317 capabilities across 9 pillars, each carrying
machine-checkable evidence (`file:line`). One-off code-level adjudication (no
running sire) -- does each capability's CLAIMED evidence still exist?

- **Claimed (manifest):** WIRED 205, BACKEND_ONLY 55, FLAG_GATED 48, REMOVED 6,
  PLANNED 1.
- **kazi-verified (evidence exists now):** 307 built, 6 partial, 3 drift, 1
  no-evidence. The manifest is largely HONEST at the file-existence level.
- **Real production-readiness gaps are not "is the code there" (it mostly is)** but
  48 FLAG_GATED (not GA), 55 BACKEND_ONLY (no UI), and the manifest's own 178
  `with_drift` -- contract/behavior drift a file-existence check CANNOT see.
- Specific finds: **UC-242** evidence points at a transient `.claude/worktrees/...`
  path (never merged to main, or manifest built against a worktree); **UC-220**
  `referral.go` gone; **5 duplicate capability rows** (UC-095/096/178/209/210).

Lessons baked into ADR-0020 / E12: (1) the natural hierarchy is pillar -> domain ->
capability and the manifest already declares pillars as a closed list -> grouping
must reference a DECLARED taxonomy by id, not free text; (2) per-pillar budgets fall
out of per-group budgets + existing partitioning (no sub-goals needed); (3) the
honest next step to answer "production ready" is LIVE predicates against a running
sire (needs an instance + test creds) -- code-existence != "it works". Output: an
Obsidian vault at `sirerun/tmp/sire-state-vault/` (gitignored scratch).

## 2026-06-23 — E11 interactive `propose`: clarify phase verified live (T11.9)

Built the interactive clarify phase for `kazi propose` (E11, UC-029, ADR-0019):
a deterministic gap-detection FLOOR (`Kazi.Authoring.Clarify.gaps/2`) merged with
harness-drafted candidate questions on the existing stub seam, asked before the
draft, with answers folded into the draft prompt; an inline rationale on the goal
metadata (`--adr` also writes an ADR-lite doc); a refine loop via the existing
upsert. Suite 855 -> 899 (+44 tests).

LIVE VERIFICATION (real app, real SQLite read-model):

- **Strict, non-interactive, harness-free** — `propose "add a widgets feature"
  --strict` piped (no TTY): exit 1, `error: idea is underspecified (missing:
  live-target, scope); answer the clarify questions interactively or add detail`.
  The gap floor + `--strict` short-circuit fire BEFORE the harness.
- **Interactive clarify (forced via the `tty:` inject seam, answers over stdin)**
  — the real `terminal_ask` rendered the live-target question (3 numbered options,
  recommended starred `*`), read `2` (Production logs) from stdin, then the scope
  question (Enter = default), then the refine prompt (Enter = accept). The drafted
  predicate came back `live (prod_log)` — i.e. the chosen answer FOLDED into the
  draft (render -> IO.gets -> resolve_answer -> fold_answers -> draft), and the
  rationale printed. Proposal persisted (`prop-add-a-widgets-feature-...`).

CAVEAT (honest): the `:io.rows()` TTY AUTODETECT (`tty?/0`, the one line that
decides whether to enter the interactive path) could not be exercised in this dev
env — `mix run` runs the BEAM in noshell mode so `:io.rows()` returns
`{:error,:enotsup}`, the escript cannot bundle the SQLite NIF (so authoring has no
read-model there), and the Burrito binary cannot build on this macOS-26 host
(R-E6-1). In a real terminal launching the binary, `:io.rows()` returns `{:ok,_}`
and the verified flow runs. The rendering + choice-resolution it gates are pure
and fully unit-tested (`Clarify.render_question/1`, `Clarify.resolve_answer/2`);
the real claude harness, driven live, produced non-strict-JSON on the DRAFT call
(`proposal is not valid JSON`) — a PRE-EXISTING one-shot-parser limitation, not
E11; the clarify wiring around it ran correctly.

## 2026-06-22 — brew distribution lifecycle proven end to end (v0.1.0 -> v0.1.1)

The full release-to-upgrade chain was exercised against the live tap (E6,
ADR-0014/0017): bump `mix.exs` + the release-please manifest -> push `vX.Y.Z` ->
`release.yml` builds the three native-arch Burrito binaries (macOS arm64, Linux
x86_64, Linux arm64), SMOKE-TESTS each (`kazi_<target> --help` on its own arch)
before publishing, uploads them + `.sha256` -> regenerate `Formula/kazi.rb` ->
`brew upgrade kazi-org/tap/kazi`. Verified live: `brew upgrade` moved 0.1.0 ->
0.1.1 and the upgraded binary reports `kazi 0.1.1` (the new `kazi --version`
flag added this session). Shipping platforms: 3; only Intel macOS deferred
(GitHub macos-13 runner scarcity). The auto-release pipeline (release-please ->
build -> tap auto-bump) is wired but gated on the operator enabling
Actions-create-PRs + a `HOMEBREW_TAP_TOKEN` secret; until then releases are this
manual bump+tag. See lore L-0005 for the `mix release --overwrite` cache gotcha.

## 2026-06-22 — T8.11 heterogeneous dogfood: wiring proven, local 35B too slow to converge

**Setup.** The capstone E8 exercise: Claude (the planner) authored a tiny broken Go
fixture goal (`Add` used subtraction; `go test ./...` fails), and kazi drove
`opencode --model dgx-ollama/qwen3.6:35b-a3b-q8_0` (the implementer) to converge it.
The T8.9 finding was addressed first: a project-local `opencode.json` in the
workspace granting `permission.edit/bash` = `allow`, in a REAL git repo (not a
`/tmp` scratch), so opencode would no longer auto-reject edits.

**What was PROVEN (the heterogeneous loop works end to end).** kazi observed the
objective failure (`go test` exit 1, recorded the FAIL output), persisted iteration
0 to the SQLite read-model, and dispatched opencode->the DGX. Objective termination
held throughout: kazi could not and did not declare success while the predicate
failed. The plan/implement split (strong model authors the predicate set, cheap
local model drives the loop, predicates keep it honest) is demonstrated.

**What did NOT happen (the honest result).** opencode ran for ~40 minutes on
iteration 1 against the 35B-a3b-q8_0 and never produced an edit to `add.go`, so the
goal did not converge in a usable window. The bottleneck is the LOCAL MODEL's
agentic throughput, not kazi: opencode's loop makes several model calls per turn
(survey the repo, reason, propose the edit), each very slow on the q8_0 35B, and the
permission fix meant the blocker this time was purely speed (no auto-reject). The run
was capped manually.

**Takeaway / landmine.** "Claude plans, local model implements" is mechanically
sound and kazi's correctness guarantee holds regardless of implementer quality. Its
PRACTICALITY is gated by local-model speed: the DGX 35B-q8_0 via opencode is too slow
for an interactive convergence loop. To make this dogfood converge, use a faster
local model (smaller/lower-quant, or a faster server), or accept long wall-clock for
batch-style runs. The throwaway workspace is `~/kazi-dogfood` (a single-predicate
`go test` goal); rerun `kazi run ~/kazi-dogfood/dogfood.goal.toml --harness opencode
--model <faster-model> --workspace ~/kazi-dogfood` to retry.

## 2026-06-22 — E8 generic multi-harness support shipped; opencode->DGX live smoke skips

**What shipped (ADR-0016).** The single `Kazi.Harness.ClaudeAdapter` was generalized
into config-driven harness **profiles**: `Kazi.Harness.Profile` (a `command` + a pure
argv renderer + a pure stdout parser + supported opts), a `Kazi.Harness.Registry`
(`:claude`, `:opencode`), one generic `Kazi.Harness.CliAdapter`, and a
`Kazi.Harness.resolve/1` seam (CLI `--harness`/`--model` > goal-file `[harness]`
table > `config :kazi, :harness` > default `:claude`). `Kazi.Runtime`, `Kazi.CLI`,
`Kazi.Authoring`, and `Kazi.Adopt.enrich` all route through it; the Claude path is
pinned byte-for-byte by a golden test (CliAdapter+claude == the old adapter). Adding a
harness is now profile DATA, not a new module. Suite 755 → 853.

**opencode specifics.** opencode's non-interactive surface is
`opencode run "<msg>" --model <provider/model> --format json`, where `--format json`
emits an **NDJSON event stream** (not Claude's single envelope) — which is exactly
why a profile carries a parser strategy, not just an argv template.

**Live opencode->DGX smoke: ATTEMPTED, did not converge, SKIPS honestly.** With
opencode v1.17.9 wired to the DGX-hosted Qwen3.6 35B-A3B, a `kazi run --harness
opencode` against a fixture goal returned `{:error, :await_timeout}` after ~480s. The
endpoint and model were reachable (~100s/turn via a direct probe); the non-convergence
is environmental, not a kazi defect, with two causes:
1. the 35B model on the DGX is slow (~100s/turn), so a multi-iteration converge blows
   the loop's await window;
2. **opencode auto-rejects tool calls when run in an external/scratch workspace** —
   `external_directory; auto-rejecting` — so the agent never edits and the predicate
   never flips. The target workspace must be one opencode's permission policy treats
   as in-scope (not a bare `/tmp` dir).
The live test is tagged `:opencode_live` and EXCLUDED by default (it never gates CI);
run it manually with `mix test --only opencode_live` against a responsive endpoint and
a permitted workspace. No convergence was claimed.

## 2026-06-22 — WITHDRAWN: the E7 registry adapter (the entry below is now history)

The capability-registry adapter described in the next entry was **removed** before
the open-source release. `capabilities.json` was a bespoke artifact of one internal
product; it did not generalize, and shipping a `--registry` flag whose input format
nothing public produces is a liability for a v1 OSS tool. Deleted
`Kazi.Adopt.Registry`, the `kazi init --registry` CLI mode + tests, the
`capabilities.json` fixture, and the goal-set writer path. Kept the general pieces:
stack-detection `kazi init <repo-dir>` (ADR-0013) and the goal-file writer
`Kazi.Adopt.to_toml/1`. ADR-0015 rewritten to record the withdrawal and to point at
the generalizable replacement — a future importer for a STANDARD spec (OpenAPI
paths → `http_probe`; gherkin scenarios → acceptance predicates) under its own ADR
when there is demand (UC-025, deferred). Suite 785 → 755. The entry below remains as
a record of what was built and why the cardinality decision was made.

## 2026-06-22 — E7: registry adapter + goal-set (`kazi init --registry`), ADR-0015

**What shipped.** `kazi init` grew a second deterministic source: a capability
registry (`capabilities.json`) -> a goal SET, one goal-file per capability
(ADR-0015). Delivered in PR #75 alongside the two prerequisites that did not yet
exist on main — the goal-file writer `Kazi.Adopt.to_toml/1` (T5.3) and the `kazi
init` CLI verb (T5.5). New modules: `Kazi.Adopt.Writer` (deterministic hand-rolled
TOML renderer + commented `http_probe` live-predicate scaffold; no TOML-encoder
dep) and `Kazi.Adopt.Registry` (`parse/2`, `to_goal_set/2`). JSON decode via the
existing `jason` dep. Suite 741 -> 785.

**The cardinality decision (ADR-0015).** One goal-file PER capability, not one
goal carrying a predicate matrix. A goal is the unit of convergence/budget/status;
a capability is the unit of "what the product does" and the status we want
computed. A predicate matrix would couple N capabilities into one convergence unit
(one failure => whole goal stuck; shared budget; per-capability status lost). The
goal set is what makes status loop-computed per capability — the point of the
feature.

**Boundaries enforced mechanically.** Prose `.md` is rejected before reading
("generated views, not registry inputs" — bakes JSON-is-truth into the tool).
Source-inferred bindings stay behind `--enrich` (off by default), filling only
gaps, never overriding a declared binding. Live predicates are commented TODO
scaffolds, never guessed.

**Independent verification (not the subagent's word).** Ran the fixture
`capabilities.json` (3 capabilities) through `Registry.parse` -> `to_goal_set` ->
`Kazi.Goal.Loader.from_map` myself: all 3 goals load; a multi-binding capability
yields multiple `test_runner` predicates; prose `.md` rejected with a clear
message. The convergence test (`adopt_registry_convergence_test.exs`) drives a
registry-derived goal through the REAL `Kazi.Runtime` with the same stub seams
`Kazi.RuntimeTest` uses and reaches `:converged` — proving a registry-derived goal
is runnable, not merely loadable.

**Plan note.** E7 listed T5.3/T5.5 as prereqs and also (accidentally) duplicated
their WBS lines; reconciled to single entries under E5, marked done. T6.2 (Burrito
wrap, PR #74) merged its config/wiring but is left UNCHECKED: the host binary
could not be linked locally (Zig 0.15.2 vs macOS-26 SDK); it completes on the T6.3
CI matrix (macOS-15/Ubuntu runners), not this machine.

## 2026-06-21 — Slice-2 creation dogfood (T2.5): kazi BUILDS a small real feature from failing acceptance criteria to green-and-live

**What was exercised.** The Slice-2 creation acceptance dogfood (UC-010, D2) —
the creation analog of the Slice-0 full-loop dogfood (T0.11/T0.12) and the
Slice-1 regression dogfood (T1.8). Where Slice 1 proves kazi catches a BAD fix,
this proves kazi makes a GOOD one: it does not just REPAIR regressed behavior, it
CREATES behavior that did not exist before. Driven end-to-end through the REAL
`Kazi.Runtime`/`Kazi.Loop` with the REAL providers (`Kazi.Providers.TestRunner`
over a real temp workspace; `Kazi.Providers.HttpProbe` over a REAL local server),
the REAL `Kazi.Harness.ClaudeAdapter` (pointed at a real local "build" binary via
its `:command` seam), the REAL `Kazi.Actions.Integrate` (a real local
rebase-merge into a bare `origin`, no GitHub) and `Kazi.Actions.Deploy` (a stub
emulating `gcloud run deploy`, no gcloud), and real SQLite read-model
persistence. Test: `test/kazi/slice2_dogfood_test.exs`. Hermetic: own Sandbox
connection, a real harness binary, a real temp git repo, a real local HTTP
server — no Go, no external network, no GitHub, no GCP, no real browser.

**The feature spec (as failing acceptance predicates).** A tiny real feature —
*GET /greeting returns 200 with a body containing `hello, kazi`* — authored as a
create-mode goal (`mode: :create`) whose three acceptance criteria are all
designed to FAIL at t0:

- `feature_built` (`tests`, acceptance): the feature source exists
  (`grep -q '^built$' greeting.feature`). RED at t0 (marker `absent`). This CODE
  criterion is what carries the loop past dispatch into integrate/deploy.
- `greeting_endpoint` (`http_probe`, acceptance): `GET /greeting` returns 200. A
  REAL request against a running stdlib `:inets`/`:httpd` server. RED at t0 — the
  route does not exist yet, so the server genuinely **404s** (the
  `create_feature.toml` "no such route yet" shape).
- `greeting_body` (`http_probe`, acceptance): `GET /greeting` body contains
  `hello, kazi`. The precise behavior kazi must CREATE. RED at t0 (no endpoint).

The "live" check is a REAL http_probe request against an actually-running local
server whose response the deploy step rewrites — "live" here means a genuinely
running service the probe hits over `127.0.0.1`, NOT Cloud Run. A pre-flight
assertion confirms all three criteria genuinely fail against the real world at t0
(so the vacuous-goal guard, T2.3, does not trip — there is real work to do).

**How the build happens (over the real seams, zero-stub in lib/).** The harness
binary is the coding agent: it performs the genuine build by writing the feature
source marker (`built`) into the workspace, flipping `feature_built` red → green.
The integrate action's `:integrator` seam really rebase-merges the built feature
onto origin's `main`. The deploy action's `:deploy_cmd` seam "ships" the feature
by creating the server's backing resource serving the greeting, so the route
comes into being live — the live http_probe criteria pass only against the
deployed feature.

**What kazi did (observed, not expected).** The recorded trajectory:

```
outcome=converged  iterations=4
actions=[:dispatch_agent, :integrate, :deploy]
  iter 0: feature_built=fail greeting_endpoint=fail greeting_body=fail  converged=false  # honest start: feature absent, route 404s
  iter 1: feature_built=pass greeting_endpoint=fail greeting_body=fail  converged=false  # agent BUILT the source; route still absent
  iter 2: feature_built=pass greeting_endpoint=fail greeting_body=fail  converged=false  # landed; still not deployed -> live still 404
  iter 3: feature_built=pass greeting_endpoint=pass greeting_body=pass  converged=true   # deployed -> route live -> whole acceptance vector holds
```

1. **Failed at t0, non-vacuously.** Every acceptance criterion was RED before
   kazi did anything (feature absent, endpoint 404). The goal was real work, not
   a vacuous "already done" — the t0 guard let it through and the first persisted
   observation is all-fail.
2. **Built the feature.** The agent dispatch made `feature_built` go green
   (`greeting.feature` = `built` in the real workspace); integrate landed it on
   origin's `main` (`git ls-tree main` shows `greeting.feature`); deploy created
   the live route serving the greeting. The full creation arc:
   dispatch (BUILD) → integrate (LAND) → deploy (SHIP).
3. **Did NOT converge before the feature existed.** The objective-termination
   guard (T0.8) held for CREATION exactly as for repair: there are observed
   states (iters 1–2) where the built CODE acceptance passed but the LIVE
   greeting had not yet flipped — and the loop did NOT converge in any of them.
   Convergence was gated on the live feature, not on code-green.
4. **Converged green-and-live, persisted in order.** Only the LAST iteration is
   marked converged; the terminal vector is objectively satisfied; a final REAL
   `:httpc` request confirms the running endpoint serves `hello, kazi`.

**Evidence.** `result.outcome == :converged`,
`result.actions == [:dispatch_agent, :integrate, :deploy]`; the workspace file
`greeting.feature` = `built`; `greeting.feature` present on origin's `main`; a
direct `:httpc` GET against the live server returning the greeting; the persisted
read-model history (4 iterations) showing the all-fail t0 start, the
code-green-but-live-red gate, and exactly one converged iteration at the end.

**Conclusion: D2 acceptance holds (hermetically).** kazi builds one small real
feature from failing acceptance predicates to green-and-live: the criteria fail
at t0, kazi dispatches a build, lands it, ships it, and converges only once the
live endpoint genuinely serves the new behavior — never declaring the feature
done before it is live.

**Honesty note — the Cloud-Run caveat.** This dogfood proves the creation arc
*hermetically*: the "live" surface is a real local `:inets` server, and the
deploy step is a stub emulating `gcloud run deploy`. Production-Cloud-Run-live
(an http_probe passing against a real Cloud Run URL after a real `gcloud`
deploy) remains **T0.12**, which is human/GCP-gated and out of scope here by
design (the task forbids Go/GCP/external network so CI stays self-contained).
So D2's "to live" is met in the local-running-service sense, not yet against
production Cloud Run; that final step is tracked by T0.12. Everything behaved as
designed on the first real run; no `lib/` change was needed.

## 2026-06-21 — Slice-1 dogfood (T1.8): naive fix regresses a coupled predicate; kazi detects + escalates

**What was exercised.** The Slice-1 acceptance dogfood (UC-007), the
trustworthiness analog of the Slice-0 full-loop dogfood (T0.11/T0.12). Driven
end-to-end through the REAL `Kazi.Loop` with the REAL `Kazi.Providers.TestRunner`
(shelling out to `grep` over a real temp workspace), the REAL
`Kazi.Harness.ClaudeAdapter` (pointed at a real local "naive fix" binary via its
`:command` seam), real SQLite read-model persistence, and Noop integrate/deploy
doubles. Hermetic: own Sandbox connection, a real harness binary, a real temp
workspace — no Go, no network, no GitHub, no cloud. Test:
`test/kazi/slice1_dogfood_test.exs`.

**The scenario (a genuine coupling, not a contrived flag).** Two CODE predicates
over the temp workspace:

- `pred_a` passes iff `a.txt` contains `ok`; starts RED (`a.txt` = `broken`).
- `pred_b` passes iff `b.txt` contains `ok`; starts GREEN (`b.txt` = `ok`).

The "naive fix" harness is a real executable run with `cd: workspace`. It fixes
`pred_a` (writes `ok` into `a.txt`) but, because the predicates are coupled,
BREAKS `pred_b` as a side effect (writes `broken` into `b.txt`). This is the
canonical "a fix for predicate A breaks predicate B" (concept §5, the case
ADR-0002 rejects a single exit code for) — observed through the real provider
over a real mutated workspace, not faked with a status script. The harness is
idempotent (same edit each dispatch), so once B is red it stays red.

**What kazi did (observed, not expected).** The recorded trajectory:

```
outcome=stopped  reason=:stuck  iterations=4
actions=[:dispatch_agent, :dispatch_agent, :dispatch_agent]
  iter 0: pred_a=fail pred_b=pass      # honest start: A is real work, B green
  iter 1: pred_a=pass pred_b=fail      # naive fix flipped A green AND B red
  iter 2: pred_a=pass pred_b=fail      # failing set settles on {pred_b}
  iter 3: pred_a=pass pred_b=fail      # 3rd identical observation -> stuck
REGRESSION pred_b green@0 -> red@1 status=fail attributed=[:pred_a]
stuck_failing=[:pred_b]
```

1. **Detected the regression.** The regression detector flagged `pred_b`
   green→red between observation 0 and 1, and ATTRIBUTED it to the
   `:dispatch_agent` whose failing work-list was `[:pred_a]` — i.e. the very fix
   sent to repair A is named as the cause of B breaking. Visible in `snapshot/1`
   and read back from the persisted read-model (`ReadModel.regressions/1`,
   string-keyed on-disk form).
2. **Did NOT falsely converge.** The objective-termination guard (T0.8) held:
   the whole vector was never all-pass, because the instant the naive fix made A
   pass it made B fail. `:converged` was never reached; no persisted iteration is
   marked converged. The workspace confirms the coupling really happened
   (`a.txt` = `ok`, `b.txt` = `broken`).
3. **Escalated rather than spinning forever.** The same non-empty failing set
   `{pred_b}` persisted across the stuck window (3), the human-escalation hook
   fired exactly once with `failing == {:pred_b}`, and the loop stopped
   `:stopped` / reason `:stuck`. The iteration-budget backstop (50) was never
   reached — escalation, not budget exhaustion, ended the run. Terminal outcome,
   reason, the regression flag, and `stuck_failing` are all visible in both
   `snapshot/1` and the persisted read-model.

**Evidence.** `snapshot/1` carried the regression flag, `stuck_failing =
[:pred_b]`, and terminal state `:stopped`. The read-model carried the same
regression (queryable via `ReadModel.regressions/1`), an in-order iteration
history with NO converged iteration, and an iteration showing `pred_a :pass`
while `pred_b :fail` — the coupled regression made durable.

**Conclusion: D1 acceptance holds.** kazi catches the naive fix that trades one
green predicate for another rather than declaring false success: it detects the
regression, attributes it to the causing dispatch, refuses to converge while the
regressed predicate is red, and escalates to a human via the stuck detector. The
Slice-1 trustworthy-loop acceptance is met.

**Honesty note.** Everything behaved as designed on the first real run; nothing
needed a lib/ fix. One thing worth recording: the regression is flagged once (at
the green→red edge, iter 1) and is NOT re-flagged on subsequent identical
observations — `pred_b` stays red (red→red is not a new green→red edge), so the
single persistent flag is correct, not a missed re-detection. The loop continues
to surface that flag every iteration via `snapshot/1`/the read-model until it
escalates.

## 2026-06-22 — E4 context-injection epic shipped; pool drained

**Session:** `/loop /apply --pool`. Executed E4 (ADR-0010) end-to-end across two
waves, 8 PRs, all rebase-merged with green CI and verified on integrated main.

- **Wave 13:** T4.1 (adapter `--output-format json`: real token/cost/touched →
  budget, PR #41), T4.2 (`Kazi.Context` orientation-pack builder, deterministic +
  hermetic, PR #43), T4.5 (`Kazi.Workspace` code-review-graph MCP wiring + graph
  freshness before dispatch, PR #42).
- **Wave 14:** T4.3 (stable cacheable orientation prefix in `build_prompt`, PR #44),
  T4.4 (target `.kazi/context.md` orientation file, PR #46), T4.6 (SHA-keyed
  orientation-pack cache in the read-model + migration `20260622060000`, PR #47),
  T4.8 (per-dispatch token/cost ceiling + `truncate_evidence/2` + least-privilege
  tool/permission set, PR #45), then T4.7 (`Kazi.Loop.Digest`: bounded working-set
  digest across iterations — map memory only, never the transcript, preserving
  ADR-0008 anti-anchoring, PR #48).
- **Tests:** 372 → 495 passing (+123) across the epic; format + warnings-as-errors
  clean at every merge. T4.9 (semantic-retrieval RAG) remains deferred per ADR-0005.

**Pool drained of ready work.** Remaining incomplete tasks are not pool-eligible:
- **T0.6h** (`kind: human`) — GCP project/billing/Cloud Run provisioning. Blocks
  **T0.12**, the headline Slice-0 dogfood (idea→live production probe), which is the
  project's success bar. This human task is the critical-path blocker.
- **T3.1 / T3.5 / T3.7** — unblocked by deps (T2.6 done) but coarse Slice-3
  placeholders (NATS leases, predicate-authoring front-end, Telegram) with
  `Est: TBD` and no acceptance criteria; need `/plan` granularization into hermetic
  subtasks before agents can execute against a checkable bar. T3.2/T3.6 sit behind
  T3.1.

**Next:** either (a) complete T0.6h (human GCP setup) to unblock the T0.12 dogfood,
or (b) `/plan` the Slice-3 epic (T3.1/T3.5/T3.7) into granular tasks for a new pool wave.

## 2026-06-22 — Slice-3 epic (E3) shipped via pool; all plannable agent work done

**Session:** continuation of `/loop /apply --pool`. After granularizing the coarse
Slice-3 backlog into 16 hermetic subtasks (see the plan Change Summary + ADR-0011),
executed them end-to-end across Waves 15-18, 16 PRs (#49-#64), all rebase-merged
with green CI and verified on integrated main.

- **Wave 15:** T3.1a (lease behaviour + in-memory backend + shared conformance suite),
  T3.5a (`Kazi.Authoring.propose`), T3.6a (Phoenix LiveView skeleton + Playwright).
- **Wave 16:** T3.1b (real NATS JetStream KV lease backend; integration test gated on
  `NATS_URL`, excluded by default so `mix test` stays hermetic — added `gnat`),
  T3.1c (presence/intent snapshot), T3.2a (`Kazi.Partition` blast-radius partitioning
  reusing the T4.2 graph seam), T3.5b (approve/reject/edit workflow), T3.6b (goal board
  LiveView), T3.7a (Telegram ingress via client seam).
- **Wave 17:** T3.1d (acquire lease before dispatch), T3.2b (partition->lease-key map),
  T3.5c (CLI propose/approve), T3.6c (presence + lease-map LiveView), T3.6d (history
  timeline LiveView), T3.7b (egress pings on terminal loop events). T3.6c/T3.6d shared
  `router.ex` — merged T3.6c first; T3.6d rebased with a manual one-line router conflict
  resolution (kept both routes), re-verified green before merge.
- **Wave 18:** T3.7c (end-to-end ingress->authoring->approval->run->egress test).
- **Tests:** 372 (session start) -> 650 passing (+278 across E4 + E3), 17 `:nats`
  integration tests excluded by default; format + warnings-as-errors clean at every merge.
- **ADR-0011** added: Slice-3 operator surfaces (LiveView dashboard + Telegram bridge)
  are READ projections over the read-model + NATS and never couple into the core loop;
  both sit behind injectable seams for hermetic tests.

**Pool drained — all plannable agent work in the plan is now complete (E0-E4 + E3).**
Remaining incomplete tasks are NOT pool-eligible:
- **T0.6h** (`kind: human`) — GCP project/billing/Cloud Run provisioning. Still the
  single critical-path blocker for **T0.12**, the headline Slice-0 dogfood (idea -> live
  production probe) that is the project's success bar.
- **T4.9** — deferred semantic-retrieval/RAG adapter (ADR-0005); off by default,
  un-deferring is a deliberate user decision (adds an embeddings dependency surface).

**Next:** complete T0.6h (human GCP setup) to unblock the T0.12 live dogfood; OR opt in
to building the deferred T4.9. No other autonomous pool work remains.

## 2026-06-22 — T4.9 retrieval adapter shipped; plan fully built (only human GCP remains)

**Session:** continuation of `/loop /apply --pool`. Per user direction, un-deferred
T4.9 (the ADR-0005 pluggable memory adapter), granularized it (ADR-0012), and built
it across Waves 19-20, PRs #65-#67, all rebase-merged green.

- **T4.9a** (PR #65): `Kazi.Retrieval` behaviour + no-op default + optional
  build_prompt section, OFF by default (default output byte-identical, tested).
- **T4.9b** (PR #66): graphify-embeddings backend behind the seam; integration test
  tagged `:graphify` and excluded by default so `mix test` stays hermetic.
- **T4.9c** (PR #67): per-goal opt-in wiring + SHA-keyed snippet cache (migration
  20260622080000) reusing the T4.6 pattern; off-by-default leaves the loop unchanged.
- **Tests:** 666 -> 698 passing (+32), 18 excluded (`:nats` + `:graphify` integration
  tests); format + warnings-as-errors clean at every merge. ADR-0012 records the design.

**Plan fully built. Every buildable agent task is complete: E0 (scaffold + Slice-0
loop), E1 (trustworthy loops), E2 (creation mode), E3 (Slice-3: NATS leases,
partitioning, authoring, LiveView dashboard, Telegram), E4 (context injection),
and T4.9 (retrieval).** Cumulative this session: 372 -> 698 tests (+326).

**The ONLY remaining work is human-gated:**
- **T0.6h** (`kind: human`) — provision the GCP project + Cloud Run service + deploy
  credentials. Irreducibly human (billing/credentials). This is the sole blocker for...
- **T0.12** — the headline Slice-0 dogfood (idea -> live, verified production
  deployment), which is the project's success metric (CLAUDE.md). It cannot run until
  T0.6h lands. T0.13 already built the deployable fixture + Cloud Run deploy workflow,
  so once GCP credentials exist the dogfood is unblocked.

**Next (human):** complete T0.6h, then run T0.12 to close the idea->production loop and
hit the project's success bar. No autonomous pool work remains.

## 2026-06-22 — T0.12 Slice-0 dogfood CONVERGED (idea → live production)

kazi drove the `fixtures/deploy-target` Go service from a deliberately failing test
to a live, verified Cloud Run deployment — autonomously, end-to-end. This is the
project's success bar (CLAUDE.md): idea → production, with objective convergence.

**Run (`Kazi.Runtime.run`, goal = test_runner + http_probe, budget 8 iters):**
- iter 1: both predicates FAIL (go test `not-ok`; live `/livez` body `not-ok`) → `:dispatch_agent` — a real `claude -p` edited `healthBody "not-ok"→"ok"`.
- iter 2: code green, live still FAIL (not deployed) → `:integrate` (branch → PR #69 → rebase-merge to main).
- iter 3: landed, not deployed → `:deploy` (`gcloud run deploy --source`).
- iter 4: both PASS — live `/livez` returns `ok` → **`:converged`** (release_ref `release-kazi-deploy-target-1782167118`).
- Independently verified live: `curl https://kazi-deploy-target-2r7ah2mlpa-wl.a.run.app/livez` → `200 "ok"`; `origin/main` fixture `healthBody = "ok"` (kazi's PR #69 merged).
- Crucially, kazi REFUSED success while either predicate failed (iters 1-3 stayed non-converged) — done is objective, not the agent's opinion.

**Real defects the dogfood surfaced (all now fixed or recorded):**
- L-0001/L-0002: first Cloud-Run `--source` deploy needs `artifactregistry.admin` on the deploy SA and `cloudbuild.builds.builder` on the default compute SA.
- L-0003: Cloud Run intercepts the exact path `/healthz`; the fixture's liveness route moved to `/livez`.
- L-0004: a TOML goal-file can only express `body_match` as the string `"exact"`; the http_probe matched only the `:exact` atom, so it silently fell back to substring-contains and `"ok"` falsely passed on `"not-ok"`. Fixed in `Kazi.Providers.HttpProbe` (PR #68) + regression test; example goal corrected.
- Open follow-up (non-fatal): running via `mix run` (not `mix kazi.run`) skips the read-model migration, so this run logged `no such table: iterations` and did NOT persist evidence to SQLite. Convergence is proven by the run log + the live service; persistence works under `mix kazi.run` (which migrates on startup). Worth a guard so any entrypoint ensures the read-model schema.

**Infra note:** the `kazi-deploy` project's Domain-Restricted-Sharing org policy was
relaxed (project-scoped allValues=ALLOW) to permit `allUsers` public invoker so the
live probe can reach `/livez`. Restore it (delete the project-level override) if the
fixture no longer needs to be public.
