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
`clean_ref` (`Kazi.Enforcement.Isolation.with_clean_tree/3`, the same
`git worktree add --detach` pattern as `Kazi.Ratchet.resolve_git_ref/3`).
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
