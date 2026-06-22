# kazi deploy-target fixture

A tiny Go (`net/http`) web service used as the **sample target** for the kazi
Slice 0 walking skeleton. kazi drives this fixture from a **failing test → live
Cloud Run deployment** in the Slice 0 dogfood (plan task **T0.12**).

> This fixture is **not** part of the kazi application. It is deliberately
> isolated: it is a standalone Go module under `fixtures/deploy-target/`, so the
> root Elixir `mix compile` / `mix test` never sees it, and the kazi CI workflow
> (`mix test`) never runs it. That isolation matters because the fixture ships a
> **deliberately failing** test — if it ran in kazi CI it would turn `main` red.

## Endpoints

| Method & path | Behaviour |
|---------------|-----------|
| `GET /healthz` | Returns `200` with a plain-text body. **The live probe checks this.** |
| `GET /` | Returns `200` with `kazi deploy-target fixture` (sanity route). |

## The deliberate failure (the convergence target)

`GET /healthz` is supposed to return the body **`ok`**. It currently returns
**`not-ok`** (see the `healthBody` constant in `main.go`).

- The unit test `TestHealthzReturnsOK` (in `main_test.go`) asserts the body is
  `ok` → it **FAILS** today, on purpose.
- The live `http_probe` predicate (plan task T0.5b) asserts the deployed
  `/healthz` returns `ok` → a deployed instance would **FAIL** the live probe.

**Converged** means a single edit lands: change `healthBody` in `main.go` from
`"not-ok"` to `"ok"`. Once that happens:

- `go test ./...` passes (both tests green), AND
- the live probe against the deployed service passes.

Do **not** fix this by hand — converging it is kazi's job in T0.12.

## Build, run, test

All commands run from this directory (`fixtures/deploy-target/`).

```sh
# Run the unit tests (expect TestHealthzReturnsOK to FAIL until converged):
go test ./...

# Run the service locally:
PORT=8080 go run .
curl -s localhost:8080/healthz   # -> "not-ok" (pre-convergence), "ok" once converged
curl -s localhost:8080/          # -> "kazi deploy-target fixture"
```

### Container (Podman or Docker)

```sh
# Build:
podman build -t kazi-deploy-target .        # or: docker build -t kazi-deploy-target .

# Run (Cloud Run-style, honouring $PORT):
podman run --rm -e PORT=8080 -p 8080:8080 kazi-deploy-target
curl -s localhost:8080/healthz
```

The image is a distroless static binary listening on `$PORT` (default `8080`),
which is exactly what Cloud Run expects.

## Deploy to Cloud Run

The deploy workflow lives at `.github/workflows/deploy-fixture.yml`. It is
triggered **manually** (`workflow_dispatch`) or on **release publish** — never on
`push` / `pull_request`, so it cannot fail PRs and never runs before the GCP
credentials exist.

### Required repository secrets

| Secret | Purpose |
|--------|---------|
| `GCP_PROJECT` | GCP project id hosting the Cloud Run service |
| `GCP_REGION` | Cloud Run region (e.g. `us-central1`) |
| `GCP_SA_KEY` | JSON key for a service account with `run.admin`, `artifactregistry.admin`, `iam.serviceAccountUser`, `cloudbuild.builds.editor`, and `storage.admin` |

> **First-deploy gotcha.** `gcloud run deploy --source .` auto-creates an Artifact
> Registry repo (`cloud-run-source-deploy`) on the first run, which needs
> `artifactregistry.repositories.create` — present in `roles/artifactregistry.admin`
> but NOT in `roles/artifactregistry.writer`. Use `admin` (or pre-create the repo:
> `gcloud artifacts repositories create cloud-run-source-deploy --repository-format=docker --location=$REGION`).

These are provisioned by the human task **T0.6h** (GCP project + Cloud Run
service + deploy credentials). The workflow builds the container from source
(`gcloud run deploy --source .`) and prints the resulting service URL — which is
the URL the live probe (T0.5b/T0.12) then checks.
