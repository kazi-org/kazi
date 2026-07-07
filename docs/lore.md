# kazi lore -- invariants, landmines, gotchas

Append-only, topic-ordered, greppable by tag. Grep before debugging.

## Deploy / Cloud Run

### L-0001 #deploy #gcp #cloudrun #iam -- `run deploy --source` needs artifactregistry.admin on first deploy
`gcloud run deploy --source .` (used by `.github/workflows/deploy-fixture.yml`)
auto-creates an Artifact Registry repo named `cloud-run-source-deploy` on the
FIRST deploy to a project/region. That create needs the permission
`artifactregistry.repositories.create`, which is in `roles/artifactregistry.admin`
but NOT in `roles/artifactregistry.writer`. Symptom in the deploy log:
`PERMISSION_DENIED: Permission 'artifactregistry.repositories.create' denied`.
Fix: grant the deploy service account `roles/artifactregistry.admin` (or pre-create
the repo once: `gcloud artifacts repositories create cloud-run-source-deploy
--repository-format=docker --location=$REGION`). The `--source` build also runs via
Cloud Build, so the SA needs `roles/cloudbuild.builds.editor` + `roles/storage.admin`
and the `cloudbuild.googleapis.com` API enabled. (T0.6h / T0.12, 2026-06-22.)

### L-0002 #deploy #gcp #cloudrun #iam #cloudbuild -- the BUILD runs as the default compute SA, which needs build roles
`gcloud run deploy --source .` builds via Cloud Build, and on a fresh project the
build runs as the project's DEFAULT COMPUTE ENGINE service account
(`PROJECT_NUMBER-compute@developer.gserviceaccount.com`), NOT the deploy SA that
authenticated. That compute SA has no permissions by default, so the build fails
reading the uploaded source. Symptom: `INVALID_ARGUMENT: Invalid build request.
could not resolve source: ... PROJECT_NUMBER-compute@developer.gserviceaccount.com
does not have storage.objects.get access to ... buckets/run-sources-...`. Fix:
grant the COMPUTE SA the Cloud Build builder bundle (covers source storage read,
Artifact Registry push, and log write):
`gcloud projects add-iam-policy-binding $PROJECT --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" --role="roles/cloudbuild.builds.builder"`.
The project number is in the error string. This is distinct from L-0001 (that one
is the DEPLOY SA needing AR admin; this one is the BUILD SA needing build roles).
(T0.6h / T0.12, 2026-06-22.)

### L-0003 #deploy #cloudrun #fixture #livecheck -- Cloud Run intercepts the exact path `/healthz`
Cloud Run's front end swallows the EXACT request path `/healthz`: it returns a
Google-branded 404 and the request never reaches the container (no entry in
`gcloud run services logs read`). Every other path -- `/`, `/health`, `/healthzz`,
`/HEALTHZ` -- reaches the app normally. So a service that exposes its liveness
endpoint at `/healthz` is unprobeable through its Cloud Run URL. Fix: use a
non-reserved path (we moved the fixture's health route to `/livez`). This bit the
T0.12 dogfood: the deploy + public-access were fine, but the live `http_probe`
against `/healthz` always 404'd from the edge. (T0.12, 2026-06-22.)

### L-0004 #provider #http_probe #goalfile #livecheck -- body_match="exact" string + "ok"⊂"not-ok" false-pass
A TOML goal-file can only supply `body_match = "exact"` as a STRING (TOML has no
atoms; `Kazi.Goal.Loader` passes config values verbatim). The http_probe provider
originally matched only the `:exact` ATOM, so a goal-file's `"exact"` silently
degraded to the default substring-contains. Combined with the fixture body, that
caused a FALSE PASS: expecting `"ok"` matched `"not-ok"` because "not-ok" CONTAINS
"ok". Two lessons: (1) providers must accept string config values from goal-files,
not only atoms (fixed: `body_matches?` accepts `:exact` and `"exact"`); (2) never
pick a liveness sentinel that is a substring of the success value — use exact match
or a non-overlapping token. Surfaced by the T0.12 dogfood. (2026-06-22.)

## Release / CI / Burrito

### L-0005 #release #ci #burrito #cache -- cache a release `_build` and `mix release` skips the Burrito wrap
The release workflow (`.github/workflows/release.yml`) caches `deps` + `_build`
across runs. The FIRST run (cold cache) built fine; a LATER run with the warm
cache failed at the checksum step with `cd: burrito_out: No such file or
directory`. Root cause: `mix release` saw the already-assembled
`_build/prod/rel/kazi` from the restored cache and -- non-interactive, no
overwrite -- SKIPPED re-assembly and the Burrito wrap step, so `burrito_out/` was
never produced. The failure surfaces one step LATER (checksum), masking the real
cause. Fix: `mix release --overwrite` forces a fresh assemble + wrap every run
while keeping the cache for compile speed. The container arm64 job never hit this
because it has no cache step. Landmine: ALSO mind that deleting a GitHub Release
before its replacement has built leaves the Homebrew formula pointing at missing
assets -- build the new release FIRST, then swap. (E6 / T6.3, 2026-06-22.)

### L-0019 #release #homebrew #tap #onramp -- the Homebrew tap lags the latest release, so `brew install` ships a STALE binary
`brew install kazi-org/tap/kazi` does NOT track the newest GitHub release
automatically -- the tap formula is bumped separately, and it drifts behind. As
of the T16.6 dogfood (2026-06-25) the tap still served **1.41.1** while the
latest release was **v1.46.2+**. That matters because behavioral fixes ride the
binary: 1.41.1 carries the BROKEN prose on-ramp (the `kazi plan` "proposal is not
valid JSON" / "proposal has no predicates" bug fixed in T26.8 and shipped in
v1.46.x). Consequence: a user who `brew install`s kazi, runs `kazi install-skill`
(the skill content is correct and version-agnostic), and follows the skill's
`plan -> approve -> apply` flow FAILS at the very first step (`plan`) on the stale
binary -- even though the released binary converges the same goal end to end. The
skill is not the gate; the packaged binary is. Fix: auto-bump the tap on every
release so `brew install` is never more than one version behind. Until then,
verify on-ramp behavior against the DOWNLOADED release binary
(`gh release download <tag> -R kazi-org/kazi`), never the `brew`-installed one,
and tell brew users to upgrade. (E16 / T16.6, 2026-06-25.)

## Reconcile / surface scanner

### L-0006 #reconcile #surface #scanner #deadcode -- the surface scan is APPROXIMATE: reflection and string-dispatch are invisible
`Kazi.Reconcile.SurfaceScanner` (ADR-0021, decision 3) inventories a project's
public surface (exported `def`s, Mix tasks) by parsing source ASTs statically. A
static scan, by construction, CANNOT see surface that is reached dynamically:
`apply(mod, fun, args)` with a runtime-computed function, a route/command table
keyed by strings, a `Module.concat/1` or `String.to_existing_atom/1` lookup, a
behaviour invoked through a registry. Those entry points are real surface but are
INVISIBLE to the scan -- exactly the same blind spot the code-review-graph has
(it never sees reflection or string dispatch). Consequence for the
surface-coverage meta-predicate (T13.5): a dynamically-dispatched entry point will
look UNOWNED ("dead") even when it is live, and a genuinely-dead `def` is only
flagged if it is statically defined. This is why ADR-0021 mandates a "warn, don't
auto-delete" posture and an explicit allow-list for intentional un-predicated /
dynamic surface -- never let the scanner drive a destructive delete on its own. A
file that does not parse is silently skipped (its surface is simply unreported),
so a syntax error degrades coverage rather than crashing the scan. Always grep for
a symbol as a literal string before trusting "this surface is dead." (T13.4,
2026-06-23.)

## Harness / CLI profiles

### L-0007 #harness #antigravity #non-tty #stdout #landmine -- `antigravity -p` SILENTLY DROPS stdout under a non-TTY subprocess (#76); use `--prompt-file`
kazi drives every harness as a NON-INTERACTIVE SUBPROCESS (no TTY) and parses its
stdout (ADR-0001/ADR-0022). Google's Antigravity CLI (`antigravity`, also `agy`)
has a load-bearing bug for exactly this mode: invoked with the bare `-p` /
`--prompt` flag, it SILENTLY DROPS its stdout when stdout is not a TTY (a
pipe/redirect/subprocess) -- issue `google-antigravity/antigravity-cli#76`. The
process exits 0 with EMPTY stdout, so a naive `-p` profile parses nothing and the
loop concludes the agent "said nothing" -- a fake non-result, not an error. The
WORKAROUND (the only conformant path, ADR-0022 decision 3): write the prompt to a
TEMP FILE and invoke `antigravity run --prompt-file <tmp> --output json --yes`
(`--yes` auto-approves so it stays non-interactive); read the `--output json`
envelope back. Because `Kazi.Harness.Profile.build_args` is PURE it cannot create
the temp file mid-call, so the `:antigravity` profile declares `prompt_via: :file`
and the `Kazi.Harness.CliAdapter` owns the temp-file IO: it writes the prompt to a
`.kazi-prompt-*.txt` under the workspace, threads the path to `build_args` as
`opts[:prompt_file]`, and DELETES it after dispatch (in an `after`, so it cleans up
even on a missing-binary error or a raise). NEVER add a bare-`-p` Antigravity
profile -- it will pass a TTY smoke run by hand and then silently no-op under kazi.
The `:antigravity_live` smoke is the catch if a future release regresses the
workaround (a dropped stdout -> no `:result` -> no convergence, reported honestly);
Antigravity may need version pinning. (T14.3, 2026-06-23.)

### L-0029 #harness #childsupervisor #processgroup #shell #landmine -- a `kill <pid>` on a background watchdog leaves its OWN `sleep` grandchild running, delaying `System.cmd/3` by a whole poll interval
`Kazi.Harness.ChildSupervisor.wrap/3` (issue #857) wraps every harness dispatch
in a small `sh` script: a background watchdog subshell polls whether the
controller is alive, sleeping `poll_interval` between checks. The FIRST version
reaped that watchdog with a plain `kill "$watchdog_pid"` once the real dispatch
finished. `kill <pid>` (no leading `-`) targets only that ONE process -- the
watchdog SUBSHELL -- not its current `sleep N` invocation, which is a SEPARATE
exec'd process (a child of the subshell). Killing the subshell does not kill
that lingering `sleep`; it keeps running for up to one whole `poll_interval`,
holding the SAME inherited stdout/stderr pipe `System.cmd/3` is reading from
open the entire time. Since `System.cmd/3` waits for that pipe to reach EOF (all
writers to close) before returning, EVERY dispatch was silently ~1 second
slower than it needed to be (`poll_interval`'s default) -- invisible in an
isolated shell-script prototype (which doesn't share a pipe with anything), only
showing up as the WHOLE ExUnit suite mysteriously taking 100x longer once wired
into `CliAdapter`. FIX: group-kill with the leading `-` (`kill -TERM
-"$watchdog_pid"`), which (under `set -m` job control, where each backgrounded
job gets its own process group) kills the subshell AND its `sleep` child
together. Lesson: reaping a shell background job by pid alone is not enough
when that job itself forks further children sharing your process's file
descriptors -- always target the GROUP. (2026-07-06.)

## Context / token efficiency

### L-0008 #context #prompt #orientation #landmine -- T4.3 orientation-prefix is built but UNWIRED on the live loop
The live dispatch path `Kazi.Loop.dispatch_prompt/2` (`lib/kazi/loop.ex:1208`) builds
its OWN lean prompt -- working-set digest + `inspect(evidence)` + optional retrieval
-- and does NOT call `Kazi.Harness.Prompt.build_prompt/3`. So the ranked orientation
pack reaches the agent ONLY as the `.kazi/context.md` workspace file (which the agent
must READ: tool calls + tokens, no prompt-cache discount), never as a stable prompt
PREFIX. Do not assume "T4.3 done" (it has unit tests on `build_prompt/3`) means the
live prompt carries the pack -- it does not. E19/T19.1 wires it. (Verified 2026-06-24
by reading `dispatch_prompt/2`.)

### L-0009 #context #cache #harness #invariant -- kazi drives a SUBPROCESS, so it cannot set Anthropic cache_control
kazi shells out to `claude -p` (and opencode/codex) as a subprocess; it makes NO raw
Anthropic API calls. Therefore kazi cannot attach `cache_control` to the prompt --
the inner CLI manages its own caching. The ONLY prompt-cache lever kazi has is making
its injected prefix BYTE-STABLE across iterations so the inner harness's own cache
(5-min TTL) hits across kazi's separate stateless dispatches. Any claim that "kazi
enables prompt caching" must mean prefix stability, not headers (ADR-0010 frames it
this way). (2026-06-24.)

## Read-model / persistence

### L-0010 #readmodel #persistence #predicate #landmine -- errored-predicate evidence (tuples) crashes iteration persistence
`Kazi.ReadModel.serialize_vector/1` (`read_model.ex:550`) stores a PredicateResult's
`evidence` VERBATIM under the Ecto `:map` field. An `:error` result's evidence holds
non-JSON terms -- e.g. `reason: {:cmd_unrunnable, "..."}` (a tuple) and atom keys --
which fail the `:map` cast, so `record_iteration/1` RAISES and the iteration is never
recorded (the on_iteration callback log fills with the raise). Evidence must be
deep-sanitized to JSON-safe before insert. E18/T18.2 fixes it. (Observed in the token
benchmark, 2026-06-24.)

### L-0011 #readmodel #persistence #loop #landmine -- terminal/budget-stop re-persists the same iteration_index
The loop's per-iteration callback AND the terminal/budget-stop callback both persist
the SAME `(goal_ref, iteration_index)`, so the second insert hits the unique index
`iterations_goal_ref_iteration_index_index` ("has already been taken") and is logged
as a failure. Terminal persistence must be idempotent (skip-if-recorded or an
`on_conflict` upsert). E18/T18.3 fixes it. (2026-06-24.)

## Goal-file / providers

### L-0012 #provider #test_runner #goalfile #landmine -- `cmd` is ONE executable, NOT a command line
A `test_runner` predicate's `cmd` is passed straight to `System.cmd/3` as the
executable; `args` is the (separate) argument list. `cmd = "go test ./..."` is parsed
as a single binary named "go test ./..." -> `{:cmd_unrunnable, :enoent}` and the
predicate ERRORS (not fails). Use `cmd = "go"`, `args = ["test", "./..."]`. The
shipped `priv/examples/deploy_target.toml` had the wrong single-string form; E18/T18.1
fixes it + adds a runnability guard over all shipped examples. (README quickstart 2
already uses the correct split form.) (2026-06-24.)

### L-0015 #provider #cve #govulncheck #landmine -- `govulncheck -json` exits 0 EVEN WITH vulns; gate on parsed output
`govulncheck` returns a non-zero exit (3) when it finds vulns ONLY in its default
text mode. Under `-json` / `-format json` it ALWAYS exits 0 regardless of findings
(the structured-output mode suppresses the failure code). So a `:cve` (or any
`custom_script`) check that trusts the exit code under JSON output reads "exit 0" as
"no vulns" and FALSE-PASSES. The `:cve` provider (T32.8, ADR-0043) gates on the
PARSED finding stream, never the exit code: a non-zero exit with NO parseable JSON is
the only `:error` path; a parsed stream decides pass/fail. The same gotcha bites
manifest-tier tools the other way -- `npm audit`/`grype` exit NON-zero WITH findings
(`grype` exits 2, `npm audit` exits 1), so tier-2 also parses the count exit-code-
agnostically. Reachability matters too: govulncheck emits a finding per OSV at
increasing trace depth; a vuln is REACHABLE (safe to fail on) iff a finding's
`trace` leaf frame carries a `function` (the vulnerable symbol is actually called),
not merely imported. (2026-06-24.)

## Benchmarking

### L-0013 #benchmark #tokens #harness #method -- measure kazi tokens with a harness shim, in a REAL git repo
kazi captures per-dispatch tokens internally (claude `--output-format json` -> result
map) but PERSISTS/PRINTS no total, so the measurement seam is a SHIM: a wrapper named
`claude`/`opencode` on PATH that tees the JSON envelope to a log, then sum
input/output/cache tokens across `===CALL===` markers. Run each arm in a REAL git repo
with workspace permissions granted (`.claude/settings.local.json` accept-edits +
`Bash`; `opencode.json` edit/bash allow) -- NOT a `/tmp` scratch dir (opencode
auto-rejects edits in external/scratch dirs, T8.11). macOS has no `timeout`; background
the run and poll. Single-dispatch result (2026-06-24): kazi adds ~0% tokens vs vanilla
claude; the multi-dispatch case is the open question (E19/T19.4). (2026-06-24.)

## Concurrency / shared working tree

### L-0014 #concurrency #git #worktree #landmine -- the operator runs many sessions in ONE shared working dir; uncommitted edits get wiped
The operator runs several Claude Code sessions via `/loop /apply --pool` in the SAME
working directory on `main`. Those sessions `git checkout` / `git pull --ff-only` /
`git reset` the SHARED tree. So any UNCOMMITTED edits you hold -- and any UNTRACKED
new file (a new ADR, a new test) -- can be discarded at any moment by a sibling
process (observed 2026-06-24: a sibling reset wiped an in-progress ADR-0030 + plan +
devlog draft; reflog showed `reset: moving to HEAD`). Branch checkouts do NOT protect
you, because all branches share the one working tree in this dir.
Fix: for any multi-file edit (a plan/ADR/docs change), work in an ISOLATED
`git worktree add -b <branch> <path> origin/main`, edit + commit + push THERE, then
PR. Within the worktree your tree is private to that path. If you must edit in the
shared dir, commit immediately after each file (smallest possible uncommitted
window); never hold uncommitted work across tool calls. This is the textual companion
to the PreToolUse worktree hook + the CLAUDE.md Worktree Guardrail.

## Enforcement / anti-gaming

### L-0015 #enforcement #loop #worktree #invariant -- the checker-isolation seam is `run_provider/3`; scope clean-tree to graders only
The ONLY place `Kazi.Loop` invokes a predicate provider is `run_provider/3`
(`lib/kazi/loop.ex`), reached from `observe/2` -> `evaluate/4`; the checker cwd is
`context.workspace` built by `provider_context/2` from `data.workspace` (the agent's
working copy). That single seam is where T32.4 anti-gaming isolation sits. Two rungs
(ADR-0042 §1; container isolation deferred): SEPARATE-PROCESS is ALREADY held -- the
command-runner providers (`CustomScript`/`TestRunner`/`Ratchet` via `CommandRunner`)
use `System.cmd`, a fresh OS subprocess distinct from the agent's `claude -p`
dispatch -- so no change was needed for it. CLEAN-TREE is added by
`observe_with_isolation/1` wrapping the tick in a throwaway detached worktree at
`clean_ref` (`Kazi.Enforcement.Isolation.with_clean_tree/4` as of L-0024 -- see
that entry, candidate-overlaid + `read_only_paths`-pinned, arity was `/3` at
T32.4 -- the same `git worktree add --detach` pattern as
`Kazi.Ratchet.resolve_git_ref/3`).
LANDMINE: clean-tree MUST be scoped to the tamper-prone GRADERS (guard + held-out
predicates), NOT all checkers -- running a visible iterating predicate from a clean
ref would never see the agent's UNCOMMITTED work, so the loop could never converge
(a deadlock). The visible predicates run against the working copy; only the graders
are isolated. When the workspace is not a git repo the worktree-add fails, isolation
DEGRADES to the working copy, and `:clean_tree` is dropped from the reported
guarantees (`enforcement_status/1`) -- report the ACTUAL level, never a fabricated
one. The clean worktree is a temp dir, always removed in an `after` (L-0014: a
sibling can reset the shared tree). (2026-06-25, T32.4.)

### L-0016 #enforcement #loop #gaming #diff #invariant -- the diff guard is ADVISORY: downgrade progress, never block convergence
T32.5's `Kazi.Enforcement.DiffGuard` (ADR-0042 §5) scans the agent's `git diff HEAD`
for gaming signatures (skip/xfail markers, `if <input> == <literal>` special-casing,
grader-path edits) and is wired into `Kazi.Loop.flag_diff_gaming/1` AFTER the
dispatch, next to the §2 read-only-lease flagging. LANDMINE: it is ADVISORY -- a hit
must NOT fail the goal or touch the `:converged` gate. The "downgrade" is narrow: the
flagged observation's index is recorded in `gaming_flagged_iterations`, and ONLY
`code_history/1` (the history fed to the stuck detector) strips that observation's
graded SCORE, so a GAMED apparent score improvement can't fire the ADR-0041
graded-progress escape and rescue the loop from a stuck verdict. The STORED vector
keeps its real score and the boolean failing-set logic is untouched -- if predicates
genuinely pass, the loop still converges. Do NOT "harden" this into a hard block: the
ratchets (§4) + read-only lease (§2) are the hard guard; this is the cheap
early-warning layer with a low-false-positive bar (an `if mode == "create"` branch or
a whitespace refactor must NOT flag). The diff source is an injectable `diff_fn`
(default `git diff HEAD`); a crashing/non-git source degrades to "" -> no events, so
the guard can never break the tick. New untracked files don't appear in
`git diff HEAD` -- the guard sees edits to existing files only. (2026-06-25, T32.5.)

### L-0017 #harness #claude #stderr #parse #landmine -- claude's stderr warnings get merged into stdout and break the JSON-envelope parse
`Kazi.Harness.CliAdapter` runs the harness with `cmd_opts`'s `stderr_to_stdout: true`,
so ANYTHING the CLI prints to stderr is prepended/interleaved into the `output` the
profile parser reads. The `claude` CLI prints `Warning: no stdin data received in 3s,
proceeding without it. ...` to stderr (it waits for stdin under `System.cmd`, which
provides none), so on essentially EVERY dispatch the stdout the parser sees is
`"<warning line>\n{<envelope>}"`. LANDMINE: a naive `Jason.decode(output)` then FAILS
on the prefix and SILENTLY drops every structured field (`:result`, `:tokens`,
`:cost_usd`, `:usage`) -- it does not crash, it just returns `%{}`, so token/cost
accounting degrades to an estimate and the authoring on-ramp (which needs `:result`)
reports "proposal has no predicates". `Kazi.Harness.Profiles.Claude.parse/1` therefore
NARROWS to the JSON object span (first `{` .. last `}`) before decoding. INVARIANT: any
profile parsing a `--output-format json` style envelope must tolerate leading/trailing
stderr noise the same way -- never feed raw merged stdout straight to `Jason.decode`.
`kazi apply` masked this for a long time because it re-runs predicates to judge done
and the budget falls back to a token estimate (ADR-0008), so the dropped fields are
invisible there; only authoring surfaced it. (2026-06-25, T26.8.)

### L-0018 #authoring #harness #custom_script #schema #landmine -- a drafting harness GUESSES predicate config; `custom_script` is `cmd`, NOT `script`
A drafting harness (claude) told only the provider NAMES will INVENT each predicate's
`config` shape, and the guess does not match kazi's loader. Live on v1.46.1: claude
drafted a `custom_script` predicate with `{"script": "<bash>", "interpreter": "bash",
"working_dir": ".", "expected_exit_code": 0}`. The REAL `custom_script` schema (what
`kazi schema custom_script` prints, sourced from `Kazi.Predicate.Schema`) requires
`cmd` (ONE executable, not a command line) plus optional `args`/`verdict`/`env`/… and
has NO `script`/`interpreter`/`working_dir`/`expected_exit_code`. LANDMINE: the bad
config PARSES fine (authoring carries config through verbatim) and only EXPLODES one
layer later, at `approve` → `Kazi.Goal.Loader.from_map/1`, with `custom_script
predicate "…" requires a non-empty string "cmd"` — so the on-ramp dies at approve,
not at draft, making it look like an approval bug rather than a drafting one. FIX:
`Kazi.Authoring.build_prompt/2` EMBEDS the per-provider config contract rendered from
`Kazi.Predicate.Schema` (the single source of truth — never hand-duplicate the field
list, it WILL drift) and explicitly pins `custom_script` to `cmd` (a shell line goes
in `cmd:"sh", args:["-c","<line>"]`, never a `script` key). INVARIANT: when you teach
a harness to emit a kazi goal-file, embed the AUTHORITATIVE config schema, do not let
it guess — and source that schema from `Kazi.Predicate.Schema`, the same place the CLI
reads. (2026-06-25, T26.8.)

### L-0019 #scheduler #cli #burrito #release #parallel #landmine -- the released binary's `--parallel` crashes `:noproc`; `PartitionSupervisor` is never started in the standalone path
`kazi apply <goal> --parallel` on a RELEASED (Burrito standalone) binary crashes
immediately and deterministically with `{:noproc, {GenServer, :call,
[Kazi.Scheduler.PartitionSupervisor, {:start_child, ...DepScheduler.start_group...}]}}`.
Cause: `Kazi.Application.start/2` detects a Burrito standalone run and hands straight
to `Kazi.Release.burrito_main()`, so the supervision tree below it -- including
`{Kazi.Scheduler.PartitionSupervisor, name: ...}` (application.ex) -- is NEVER stood
up. The CLI then manually `start_link`s ONLY `Kazi.Repo` (in `migrate_read_model/0`,
the same retrofit the homebrew read-model crash needed, [[homebrew-tap-stale-readmodel-crash]]);
nothing starts `PartitionSupervisor`. So `run_goal_parallel/4` -> `Kazi.Scheduler.run_goals/2`
-> `DepScheduler` -> `PartitionSupervisor.start_child(PartitionSupervisor, …)` targets
a named process that does not exist -> `:noproc`. This breaks the ENTIRE E21/E23
parallel-execution surface on every released binary. LANDMINE: `--explain`
(pure planning, no supervisor) and serial `--apply` BOTH work, so the break is
invisible unless you actually run `--parallel` live -- exactly the gap the T23.9
dogfood hit. INVARIANT: any process the supervision tree starts that a CLI command
needs must ALSO be started in the Burrito standalone path (mirror `ensure_read_model`
/ `migrate_read_model`); declaring it in `Kazi.Application` children is NOT enough,
because that tree never boots under a standalone binary. FIXED (2026-06-26, T21.12):
`Kazi.Scheduler.PartitionSupervisor.ensure_started/1` (idempotent under the app
tree, process-linked-start under the standalone binary) is called by
`run_goal_parallel/4` BEFORE `Kazi.Scheduler.run_goals/2`, so BOTH start_child
sites (`scheduler.ex` flat path + `dep_scheduler.ex` DAG path, both targeting the
named `PartitionSupervisor`) have a running supervisor. The two coordinator
`GenServer.start_link`s (scheduler/dep_scheduler) do NOT need a supervisor, so they
were never affected. Regression: `test/kazi/scheduler/partition_supervisor_test.exs`
proves `start_child/2` works after `ensure_started/1` on a fresh (absent) name.
GENERAL RULE for the future: when adding any new CLI command that reaches a
supervised process (a `start_child`/`GenServer.call` to a named child of
`Kazi.Application`), ensure-start it on the CLI path or it will `:noproc` only on
the released binary. (Found on v1.64.1, T23.9; fixed T21.12, PR #740.) VERIFIED LIVE
on the FIXED released binary v1.64.2: `kazi apply
priv/examples/predicate_graph_waves.toml --parallel --json` ran end-to-end (no
`:noproc`), dispatched two disjoint partitions concurrently, gated the dependent
group, and converged collectively (exit 0) -- see docs/devlog.md (2026-06-26
re-verify entry).

### L-0020 #scheduler #partition #groups #parallel #landmine -- a single goal's disjoint GROUPS collapse into ONE serial partition unless they declare `needs`
The CLI `--parallel` path ALWAYS hands `Kazi.Scheduler.run_goals/2` exactly ONE goal
(the loaded goal-file). The flat partition unit is the WHOLE goal, so a single bare
goal always partitions to exactly ONE partition (`Kazi.Partition.partition([goal])`
=> 1 entry; proven by the long-standing "single goal degenerates to one partition"
test). The GROUP axis (parallelising a goal's predicate groups) only kicked in when
`Kazi.Scheduler.DepScheduler.dag?/1` was true -- i.e. some group declared a `needs`
edge. So a goal with 2+ INDEPENDENT groups and NO `needs` (the "fully parallel,
ADR-0027 default" case the `Group.needs` doc promises) silently ran as ONE serial
loop over all predicates -- disjoint groups did NOT parallelise. LANDMINE: `--explain`
computed the frontiers and partitioned the groups WITHIN a frontier, so the dry-run
schedule SHOWED N parallel partitions while the real run collapsed to 1 -- explain
and execution disagreed. FIXED (2026-06-26): `run_goals/2` now routes a single goal
through the group scheduler when `dag?` OR `group_parallel?/1` (2+ groups AND every
acceptance predicate carries a declared group). With no `needs`, `DepScheduler`
dispatches every group in ONE frontier (concurrent), matching explain. GUARD: a goal
with any UNGROUPED acceptance predicate stays FLAT -- the per-group sub-goal split
keeps only each group's predicates, so an ungrouped predicate would be DROPPED;
guards (which may be ungrouped) are replicated into every sub-goal, so they are safe.
Regression: `test/kazi/scheduler/run_goals_group_parallel_test.exs`.

### L-0021 #dashboard #leases #coordination #nats #native #landmine -- `/leases` 500s on a NATS-free run; the default Transport source RAISES with no `:bus`
The operator lease-map dashboard (`/leases`, `KaziWeb.LeaseMapLive`) defaulted to
`KaziWeb.CoordinationSource.Transport`, whose `snapshot/0` calls
`Kazi.Coordination.Presence.snapshot/1` -> `Kazi.Coordination.Transport.Memory.fetch/2`
-> `bus_pid/1`, which RAISES `ArgumentError "requires a :bus handle"` when no
`:coordination_opts` (`:bus`) is configured -- the native, NATS-free default. So
opening `/leases` on a single-node run 500'd. Root cause beyond the raise: native
parallel coordinates on PER-RUN `Kazi.Coordination.Lease.Memory` stores passed by
handle, deliberately NOT global, so there was NO readable singleton the dashboard
could project. FIXED (2026-06-26): added `Kazi.Coordination.LeaseTable` -- a
globally-readable, best-effort `Agent` registry of held native leases (every write a
no-op when it is not running, so it never couples the scheduler to the web tree or
crashes a headless run) -- started in the web subtree; `Kazi.Scheduler.LeasedReconciler`
records on acquire / forgets on terminal. A new non-NATS source
`KaziWeb.CoordinationSource.Native` projects that table and is now the DEFAULT, so
`/leases` renders the live native lease map (empty state when nothing is held)
without touching NATS. INVARIANT: a web read seam over coordination MUST NOT require
the NATS transport on a single-node run; default to the native source and opt into
Transport only when NATS is wired. UPDATE (2026-06-28, T21.9): the CLI
`--parallel` path now INJECTS a default `:lease` -- `Kazi.CLI.run_goal_parallel/4`
starts a per-run `Kazi.Coordination.Lease.Memory` store, calls
`Kazi.Coordination.LeaseTable.ensure_started/0` (the Burrito CLI bypasses the app
tree, same class as the `PartitionSupervisor`/`Repo` ensure-started fixes), and
points the lease layer at the global `LeaseTable`, so native partition leases
publish and a SAME-NODE dashboard renders the live lease map. Skipped when a
caller injects its own `:reconciler` or `:lease` (hermetic boundary tests).
LANDMINE that remains: the published table is per-BEAM-node -- a one-shot released
CLI and a separately-deployed dashboard are different nodes and share no in-memory
table, so cross-node lease visibility still needs the NATS Transport source
(Slice 3). Regression:
`test/kazi_web/live/lease_map_live_native_test.exs`,
`test/kazi_web/coordination_source/native_test.exs`,
`test/kazi/coordination/lease_table_test.exs`,
`test/kazi/cli_run_parallel_lease_test.exs`.

### L-0022 #burrito #release #custom_script #mix #env #landmine -- the released binary leaks its OWN release env into `custom_script` subprocesses, crashing a nested `mix test`
The Burrito-packaged `kazi` binary leaks its release environment (`RELEASE_*`,
`ELIXIR_ERL_OPTIONS`, etc.) into the subprocesses spawned by a `custom_script`
predicate. A `custom_script` of `cmd = "mix", args = ["test", ...]` then boots the
target app under the leaked release env and dies with **exit 2 and EMPTY output** --
the same "kazi can't SEE the green" failure class as the opencode `--workspace`
landmine: the inner harness makes the correct edit, but the grader can never read it
as passing, so the goal never converges (it loops to `max_iterations`). `mix format
--check-formatted` SURVIVES the leak (it does not boot the app), which makes the
failure look model-specific rather than env-specific. Sibling of L-0019's "Burrito
bypasses the app tree" class -- here the leak is OUTWARD into children, not a missing
supervisor inward. Workaround for a goal-file author: wrap the predicate so it starts
from a clean environment, e.g. `env -i HOME="$HOME" PATH="$PATH" LANG="$LANG"
MIX_ENV=test mix test ...` (keep only PATH/HOME/LANG so mix still resolves its
toolchain). Found 2026-06-30 dogfooding the `support-claude-sonnet-5` goal (driving
claude-sonnet-5): the price-map/suite predicates read `exit 2` until the clean-env
wrapper was added, after which the goal converged in 2 iterations. Real fix lives in
kazi core: scrub `RELEASE_*` / `ELIXIR_ERL_OPTIONS` from the `custom_script`
provider's spawn env so `mix test` (and any app-booting child) is hermetic without an
author workaround.

### L-0023 #claude #harness #permission #trust-dialog #stuck #landmine -- a headless `claude -p` dispatch against an untrusted workspace silently denies EVERY tool call, burning cost with zero progress
`kazi apply --harness claude` against a workspace that has never been through
Claude Code's interactive trust dialog (the common case for CI, fresh clones, or any
automated first-run) gets **every tool call (Write, Bash, ...) silently denied** --
`-p`/headless mode has no human to accept the dialog. The model tries, is refused,
and nothing changes on disk; the goal burns real tokens/`usage.cost_usd` each
iteration and eventually reports `stuck` with `stuck_bundle.changed_files == []`.
This is the same "kazi can't SEE the green" failure SHAPE as L-0021 (opencode
`--workspace`) but a DIFFERENT cause: here the inner harness never even makes the
edit, because Claude Code itself refused the write. The raw
`claude --output-format json` envelope's `permission_denials` array names exactly
which tool calls were refused (`tool_name`/`tool_input`); before this fix nothing in
kazi's own output surfaced it, so diagnosing it required manually re-deriving kazi's
argv from source and replaying `claude -p ...` by hand outside kazi (github.com/
kazi-org/kazi/issues/769). Fixed: `--permission-mode <mode>` / `--allowed-tools
<t> ...` are now real `kazi apply` CLI flags and goal-file `[harness]
permission_mode`/`allowed_tools` fields (CLI wins, mirroring `effort`'s precedence,
ADR-0047), wired to the `Kazi.Harness.Profiles.Claude.build_args/2` opts that
already knew how to render them but were never set anywhere in kazi. The parsed
envelope also now surfaces `:permission_denials` (`Kazi.Harness.Profiles.Claude.
parse/1`) so a `stuck` run with zero changed files and non-zero cost is diagnosable
from kazi's OWN result, not a manual argv replay. Regression:
`test/kazi/cli_harness_test.exs`, `test/kazi/harness/usage_test.exs`,
`test/kazi/goal/loader_test.exs`. NOT YET DONE: the denial isn't threaded into
`stuck_bundle`/the `--stream` per-iteration event (would need a new `Data` field +
carry-forward, mirroring `working_set_digest`) -- today it is on the raw harness
dispatch result, not yet distilled into the loop's terminal/streamed output.

### L-0024 #enforcement #isolation #held-out #worktree #landmine -- clean-tree isolation grading the WHOLE cwd from frozen `ref` makes a held-out predicate structurally unable to converge
Deep-review 001 H1: L-0015 scoped clean-tree isolation to the tamper-prone graders
(guard + held-out predicates) correctly, but the ORIGINAL realization then swapped
the checker's ENTIRE cwd to a worktree at frozen `clean_ref` -- so a held-out
`:custom_script`/`:tests` acceptance predicate graded committed `HEAD`, never the
agent's uncommitted working-copy fix. Because `dispatch_action/2` also filters
held-out ids out of the agent's work-list (T32.6, ADR-0042 §6 -- the agent must not
see what it's graded on), and `integrate` (the only commit path) never runs while
`decide/2` clause 2 (code still "failing") keeps firing, a goal with a held-out
acceptance predicate under default enforcement could loop FOREVER without ever
reaching either `:converged` or `integrate` -- a documented, default-on integrity
feature silently defeating itself. Fixed: `Kazi.Enforcement.Isolation.prepare/3`
(now arity 3, `with_clean_tree/4`) OVERLAYS the agent's candidate working-tree state
(tracked edits via a `git diff ref` patch + untracked new files copied
individually, respecting `.gitignore`) onto the clean worktree BEFORE the checker
runs, then re-checks-out ONLY the configured `read_only_paths` from `ref` -- so the
grader's OWN definition stays pinned (an in-iteration edit to IT still cannot flip
the verdict) while the candidate fix under test is graded live. LANDMINE for
operators: a grader/checker file is protected from overlay ONLY if it is listed in
`read_only_paths` -- before this fix EVERY file was implicitly pinned (too strong,
the root cause); a held-out `:custom_script` predicate's own script/config path
must now be added to `read_only_paths` to keep it tamper-proof. Regression:
`test/kazi/enforcement/isolation_working_tree_test.exs` (candidate overlay, deletion
overlay, grader-path pinning, absent-at-ref pinning, graceful degradation, and an
end-to-end `Kazi.Loop` convergence proof). (2026-07-03, deep-review 001
remediation.)

### L-0025 #scheduler #parallel #vacuous-goal #landmine -- a killed `--parallel` run's leftover partial progress permanently poisons LATER applies as an instant, zero-evaluation `:stuck`
Issue #786: `kazi apply <goal> --parallel` externally killed mid-collective (a
`kill -9` of the CLI process while a wave was in progress) made every SUBSEQUENT
`apply` for that goal terminate in ~1 second with a persisted-LOOKING `"collective":
"stuck"` verdict and ZERO evaluations (no `kazi.loop` iterations, no `iterations`
rows) -- and the poison SURVIVED a new goal id, renamed groups (new partition
content-hashes), and a fresh git worktree passed via `--workspace`, which looked
exactly like leaked scheduler/lease/partition state. It was not: `Kazi.Scheduler`
has NO cross-process persistence at that layer (`Kazi.Coordination.LeaseTable`,
`Kazi.Scheduler.WorktreeTable`, `Kazi.Coordination.Lease.Memory` are all per-BEAM-
process `Agent`s that die with the killed VM). The real cause: `Kazi.Runtime.run/2`'s
t0 vacuous-goal guard (T2.3, R3) rejects a goal whose WHOLE predicate vector already
passes with `{:error, :vacuous_goal}` -- correct for a human-authored goal, but a
scheduler PARTITION's or `needs`-DAG GROUP's sub-goal is authored by kazi itself and
can legitimately already be satisfied (a killed run's fix landed in the workspace
before the run recorded convergence, or a sibling partition's edit touched the same
files). `Kazi.Scheduler.reconcile_partition/2` (and `reconcile_partition_with_spend/2`,
`default_group_reconciler/2`) folded EVERY `{:error, _}` -- including `:vacuous_goal`
-- into `:stuck`, with NO iteration recorded (the t0 observation is real, per
`guard_not_vacuous/3`, but is never projected to the read-model). So a later apply
re-observing the SAME already-fixed files (a new goal id / renamed groups / a fresh
worktree checked out from the same branch all still see the same fixed files)
DETERMINISTICALLY re-derives the identical `:stuck` verdict -- indistinguishable from
poisoned state, because it is RECOMPUTED FRESH from the world every time, never
replayed from anything persisted. FIX: `reconcile_partition/2` and
`reconcile_partition_with_spend/2` now map `{:error, :vacuous_goal}` to `:converged`
(an already-satisfied sub-goal spent nothing to get there) instead of `:stuck`.
INVARIANT: convergence is recomputed from the world (concept §1) -- a sub-goal the
world already satisfies IS converged, never an error, at every scheduler layer that
folds a reconciler's terminal status. Regression: `test/kazi/scheduler/killed_run_
recovery_test.exs` (both `reconcile_partition/2` directly and an end-to-end
`needs`-DAG recovery through `Kazi.Scheduler.run_goals/2`, with NO injected
reconciler -- the real production path). (2026-07-05.)

### L-0026 #loop #budget #terminal-vector #landmine -- an `:over_budget` stop reported the PRE-dispatch vector, hiding work the budget-blowing dispatch actually finished
Issue #790: `Kazi.Loop`'s hard budget guard (T1.4) checks the ceiling ONCE at the
START of every tick, BEFORE observing again (`handle_event(:internal, :observe,
...)` calls `budget_check/1` first and only falls through to `observe_tick/1` on
`:ok`) -- by design, so a dispatch that would blow the budget is never even
started. But this meant a dispatch that FINISHED all the remaining work while
itself consuming the last of the budget (a completed fix, reported over-budget
purely on cost/iterations/wall-clock) terminated on the STALE vector from the
observation before that dispatch ran -- `result.vector` reported the predicates
as still failing even though the workspace was, at that moment, fully converged.
This is more than cosmetic: `budget_spent.tokens` is cache-inclusive (ADR-0046),
so a modest cap can be a small fraction of one dispatch's cost, and the ADR-0035
model-ladder escalation reads the terminal vector to decide whether to re-dispatch
a higher-rung model -- a stale all-failing vector drove it to re-spend a frontier
model's budget re-doing work that was already done. FIX: `terminate_over_budget/2`
now runs `reeval_terminal_vector/1` (a one-shot re-observation mirroring the
relevant slice of `observe_tick/1` -- fresh vector, prior-score threading,
quarantine -- WITHOUT bumping `iterations`/history/regressions, since this is a
terminal re-check, not another tick) before building the result. INVARIANT: any
terminal outcome's `result.vector` must reflect the workspace as the loop actually
leaves it, not as of the last full tick -- `:stuck` already satisfied this (its
stuck-check runs AFTER that tick's fresh observation), only `:over_budget`'s early
short-circuit needed the extra re-check. Regression:
`test/kazi/loop/terminal_vector_fresh_test.exs` (a provider that flips from
`:fail` to `:pass` the moment the harness dispatches, budget capped at
`max_iterations: 1`, asserting the terminal `result.vector` reports `:pass`, not
the stale `:fail`). (2026-07-06.)

### L-0027 #loop #flake #quarantine #stuck #landmine -- a quarantined-but-passing predicate had no way back onto the convergence bar, and no honest terminal either -- it spun the loop at full tick rate to `max_iterations`
Issue #820 (live occurrence on kazi 1.74.0): `suite_green` flapped once, got
quarantined (`:unknown`, per #795 correctly blocking `:converged`), then passed
every subsequent real evaluation while the loop had nothing left to dispatch --
`decide/2`'s clause 5 (`landed?`/`deployed?` both true, vector still unsatisfied)
re-observed on the fixed `reobserve_interval_ms` (default 1s) with no exit
condition of its own, so it ticked ~1/s to `max_iterations` (40) and stopped
`:over_budget` reporting a passing-evidence `unknown` predicate as the reason --
even though the code was demonstrably green. Root cause was two compounding gaps:
(1) an already-quarantined predicate was NEVER re-evaluated by the real provider
(`evaluate/4`'s quarantined branch returned `:unknown` unconditionally) -- so
there was no mechanism to ever leave quarantine, and (2) the `code_history/1`
window the ordinary T1.5 stuck detector reads DROPS quarantined ids entirely, so
a goal blocked SOLELY by quarantine has an empty failing set forever and that
detector can never fire on it either. FIX: `Kazi.Loop.Flake` gained
`record_pass_streak/3` (a quarantined predicate is now polled through the real
provider every tick; `rehab_streak/0`, 3, consecutive REAL passes un-quarantines
it and the vector converges the same tick) and `quarantine_blocks_only?/2` (true
iff every non-passing id in the vector is quarantined); `Kazi.Loop.decide/2`'s
clause 5 (`handle_no_work/2`) now stops honestly `:stuck` -- naming the
quarantined ids -- after `quarantine_only_stuck_ticks/0` (3) consecutive no-work
observations of that condition, and otherwise backs off the reobserve interval
(capped, doubling per consecutive no-work tick) instead of a fixed sub-second
poll forever. INVARIANT: quarantine excludes a predicate from WORK and from the
convergence bar, but never from OBSERVATION -- a quarantined id must keep being
checked for real, both so it can be rehabilitated and so "blocked only by
quarantine, nothing to do" is a distinguishable, honestly-terminable state rather
than an indefinite idle. This is independent of `stuck_iterations` (which gates
only the ordinary same-failing-set detector) by design -- disabling that detector
must not resurrect the burn-to-budget bug. Regression:
`test/kazi/loop/quarantine_exit_test.exs` (rehabilitation converging, honest
`:stuck` bounded well under a 40-iteration budget naming the quarantined id, and
the no-work backoff bounding tick count over a wall-clock window); four
pre-existing tests that asserted the OLD idle-forever symptom
(`test/kazi/loop_test.exs`, `test/kazi/loop/verdict_bar_test.exs`,
`test/kazi/deep_review_lows_test.exs`, `test/kazi/slice1_test.exs`) were updated
to the new, honestly-terminating expectation. (2026-07-06.)

### L-0028 #dashboard #liveview #phx-click #landmine -- the dashboard shipped ZERO JavaScript, so every `phx-click`/live-patch silently did nothing in a real browser

Until the starmap slide-over panel (2026-07-06), no dashboard page loaded any
JS: the root layout was deliberately asset-free, so LiveViews rendered as dead
server-side snapshots. LiveView tests (`render_click/1`) still pass against
such a page -- they drive the server directly and never notice the browser
gap -- so an interactive feature can be fully "test-green" yet do nothing when
clicked in Chrome. Symptom in the wild: `window.liveSocket` is `undefined`,
`[data-phx-main]` never gains `phx-connected`, clicks are inert, and pages
only update on manual refresh. Fix (no-build, release-safe): serve
`phoenix.min.js` + `phoenix_live_view.min.js` straight from the hex packages
via `Plug.Static` (`from: {:phoenix, "priv/static"}` resolves via
`:code.priv_dir/1` inside a release too), add the csrf meta + connect script
to the root layout, and `protect_from_forgery` in the browser pipeline so the
socket's csrf check has a session token. INVARIANT: any new `phx-*` binding
on a dashboard page must be verified in a REAL browser (agent-browser),
not only via `Phoenix.LiveViewTest` -- the test harness cannot see a missing
client. Regression: `test/kazi_web/live_client_test.exs`. (2026-07-06.)

### L-0029 #harness #shell #portability #dash #landmine -- "works on macOS sh" means bash: dash ignores `set -m`, its builtin `kill` cannot group-kill, and bash prints job notices into merged output

The #857 child-supervision wrapper converged green on macOS (2,556 tests) and
hard-failed CI on Ubuntu, three distinct ways. (1) Non-interactive dash
(Ubuntu /bin/sh) accepts `set -m` but creates NO process groups for
background jobs, so any `kill -- -$pid` group signal has nothing to hit —
make children real group leaders with `setsid` where it exists (Linux; macOS
ships none but its /bin/sh is bash, whose non-interactive `set -m` works).
(2) dash's BUILTIN `kill` rejects negative-pid group syntax outright
("Illegal number: -"), even with `--`; route group kills through `env kill`
so the external binary handles them, with a single-pid fallback. (3) On the
bash side, a background helper killed by the script becomes an asynchronous
"Terminated" job notice in the shell's output — which `stderr_to_stdout`
merges into the harness envelope; double-fork helpers (`( (...) & )`) so
they are never jobs, detach all three fds to /dev/null so a surviving helper
can never hold the port's stdout-EOF hostage (the exact Linux hang: an
orphaned grandchild `sleep` kept the pipe open and every dispatch timed
out). INVARIANT: any /bin/sh script kazi ships must be proven under dash,
not just macOS sh — locally: `dash script.sh` plus a `setsid` shim
(python3 os.setsid+exec) to simulate the Ubuntu group semantics.
Regression: the wrapper itself in `Kazi.Harness.ChildSupervisor` (moduledoc
documents all three); test/kazi/harness/child_lifetime_test.exs. (2026-07-06.)
