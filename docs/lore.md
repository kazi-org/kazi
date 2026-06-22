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
