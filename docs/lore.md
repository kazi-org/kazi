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
