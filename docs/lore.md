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
