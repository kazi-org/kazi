# Live providers: sustained health, metrics, burn-rate, and journeys

kazi's *live* providers verify a **deployed** service, not just code that
compiles. They are the difference between "the build is green" and "the change is
behaving in production". This guide covers the four live providers and the one
discipline they all enforce.

> **The bake-window discipline — never converge on a single sample.**
> A service can answer one probe and then fall over. A single `200`, a single
> green journey, or a single clean metric scrape is a *weak* signal. Every live
> provider here is built to require *sustained* evidence over a window, and to
> prefer a **relative** comparison (an error-rate ratio, a burn-rate factor) over a
> single absolute reading. This is the Kubernetes `failureThreshold` model and the
> Google SRE multiwindow burn-rate model, encoded as predicates (ADR-0043).

All four are **deploy-gated**: the convergence loop only expects them to pass
*after* the change is landed and deployed, so a red live predicate never
dispatches a fixer agent against code that has not shipped yet.

---

## `http_probe` — sustained health

A single `200` proves reachability, not health. With `samples > 1` the probe
takes **N consecutive samples** and passes only when *all* of them are healthy —
the first sample that fails an assertion breaks the run, so a lone transient `200`
among failures never passes.

```toml
[[predicate]]
id = "healthz-sustained"
provider = "http_probe"
url = "https://service.example.com/healthz"
expect_status = 200
expect_body = "ok"
samples = 5          # require 5 consecutive healthy samples
interval_ms = 2000   # 2s between samples → a ~10s bake window
```

| Key | Meaning |
|-----|---------|
| `samples` | Number of **consecutive** healthy samples required (default `1`). |
| `interval_ms` | Delay between samples in ms (default `0`). |

A sustained result carries envelope-v2 grading (ADR-0041): `score` is the count of
healthy samples and `direction` is `higher_better`, so the controller reads "3 of
5 → 4 of 5" as progress. `samples = 1` (the default) is byte-identical to the
original single-probe behaviour. Run `kazi schema http_probe` for every key.

---

## `browser` — synthetic journey

The same discipline for a real browser flow: with `samples > 1` the `browser`
provider re-runs the journey **N times** as a post-deploy synthetic monitor and
passes only when *all* N runs pass. A one-off success among failures is rejected.

```toml
[[predicate]]
id = "checkout-journey"
provider = "browser"
url = "https://app.example.com"
assertions = [ { type = "visible", selector = "h1" } ]
samples = 3          # require 3 consecutive passing runs
```

`score` is the count of passing runs (`higher_better`). `samples = 1` is
byte-identical to the original single-run behaviour. Run `kazi schema browser`.

---

## `metrics` — RED/SLO over PromQL

`metrics` queries a Prometheus-compatible endpoint and gates on a windowed signal.
It supersedes the `prod_log` grep for behavioural verification; `prod_log` stays a
coarse safety net. It has three modes.

### Scalar — error-rate, or a quantile Prometheus computes

`:query` is any PromQL that evaluates to one number; `:pass_when` gates it.

```toml
[[predicate]]
id = "error-rate-under-1pct"
provider = "metrics"
query_url = "https://metrics.example.com"
query = "sum(rate(http_requests_total{code=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m]))"
pass_when = "< 0.01"     # <op> <number>, op ∈ == != < <= > >=
window = "5m"            # informational; kazi does not rewrite the query's [W]
```

### Quantile — kazi computes `histogram_quantile`

Set `:quantile` (a float in `0..1`) and let `:query` return the windowed bucket
*vector* (`sum(rate(..._bucket[W])) by (le)`). kazi computes the quantile itself
(the Prometheus algorithm — linear interpolation within the rank bucket) and gates
the result.

```toml
[[predicate]]
id = "p95-latency-under-slo"
provider = "metrics"
query_url = "https://metrics.example.com"
query = "sum(rate(http_request_duration_seconds_bucket[5m])) by (le)"
quantile = 0.95
pass_when = "<= 0.5"     # p95 must be ≤ 500ms
```

### Burn-rate — a multiwindow multi-burn-rate SLO gate

The Google SRE workbook alert: page only when **both** a long-window and a
short-window burn rate breach the threshold. A single window breaching is noise;
two agreeing is signal. The predicate **fails** (the gate fires) iff both windows
breach, and passes otherwise.

```toml
[[predicate]]
id = "slo-burn-rate"
provider = "metrics"
query_url = "https://metrics.example.com"
[predicate.burn_rate]
long = "error_budget_burn_rate_1h"
short = "error_budget_burn_rate_5m"
threshold = 14.4         # e.g. the 1h/5m fast-burn factor
```

| Key | Meaning |
|-----|---------|
| `query_url` | Prometheus HTTP API base. **Absent → `:unknown` (not applicable).** |
| `query` / `pass_when` | The scalar/quantile expression and its gate. |
| `quantile` | Selects quantile mode; kazi computes `histogram_quantile`. |
| `burn_rate` | `{ long, short, threshold }` — the multiwindow burn-rate gate. |
| `direction` | `higher_better` / `lower_better` (default `lower_better`). |
| `window`, `timeout_ms` | Informational span; HTTP timeout (default 5000ms). |

### Not applicable without an endpoint

Live metrics assume an observability stack kazi cannot provision. Absent a
`query_url`, a `metrics` predicate reports `:unknown` with
`reason: :no_metrics_endpoint` — it **never falsely passes**, and it does not
dispatch a fixer. An `:unknown` carries no claim; it simply records that the
signal is not applicable in this environment. (The sustained-health upgrade needs
only an HTTP endpoint and is the universal live baseline.)

Run `kazi schema metrics` for every key.

---

## `prod_log` — the coarse safety net

`prod_log` queries production logs for panics / 5xx over a window. Since `metrics`
gives a precise RED/SLO signal, `prod_log` is now the *coarse* backstop — cheap,
always-available evidence that nothing is on fire — rather than the primary
behavioural gate. See the provider docs for its config.

---

## Why this matters

Convergence still requires the whole predicate vector to pass (ADR-0002); the
graded `score` on live results is a progress *signal*, never a second gate. The
point of the bake window is that a live predicate's `:pass` means *sustained*
health — so when kazi reports a goal converged, the deployed service has held up
across a window, not blinked green for one request.
