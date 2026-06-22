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
