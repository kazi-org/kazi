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

### Assertions

Each entry in `assertions` needs a `type`. The **runner** owns this vocabulary —
kazi passes `assertions` verbatim to `priv/browser/playwright_runner.js`, which
dispatches on `type` (ADR-0053 §1) — but the type must be one kazi knows, so a
typo fails at goal-load naming the valid set rather than looking like a broken UI
for the rest of the run.

| `type` | Keys | Holds when |
|--------|------|------------|
| `visible` | `selector` | the element is visible |
| `hidden` | `selector` | the element is absent or hidden |
| `text` | `selector` + `contains` \| `exact` | the element's text matches |
| `url` | `contains` \| `exact` | the current URL matches |
| `console_clean` | `network` (optional, bool) | the journey produced no `console.error` |

### `console_clean` — the site-smoke check

`console_clean` asserts the journey produced **zero** `console.error`. With
`network = true` it also fails on any 4xx/5xx response. This is higher-signal than
"the page loaded": a page that renders while throwing in the console is broken,
and nothing in a `visible`/`text` assertion sees it.

```toml
[[predicate]]
id = "app-console-clean"
provider = "browser"
url = "https://app.example.com"

[[predicate.steps]]
action = "click"
selector = "a[href='/cart']"

[[predicate.assertions]]
type = "console_clean"
network = true       # also fail on a failed 4xx/5xx response
```

Errors are captured across the **whole journey** — the initial load and every
step — not just the state at assert time. An error thrown during a step and then
cleared by a later one still trips the assertion: the journey produced it.
Evidence lists the offenders (`found`), each with the console text and its source
location, or the status and URL for a network failure.

**What `network = true` actually buys you.** Chromium logs its *own*
`console.error` for a failed subresource or navigation (`Failed to load resource:
the server responded with a status of 404`), so a 4xx/5xx usually trips
`console_clean` even without `network` — verified against a real Chromium, not
assumed. The flag is about **evidence**, not extra coverage: Chromium's message is
prose with no parseable status, while a network record is structured —
`{kind: "network", status: 404, url: "…"}` — so a fixer agent gets the status code
as data. Turn it on when you want the response detail; leave it off and console
errors alone still catch most broken loads.

`network` must be a real boolean. The runner is JavaScript, where the *string*
`"false"` is truthy, so `network = "false"` would silently turn network checking
on — the loader rejects a non-boolean at load instead.

Captured errors are a `:fail` (the page ran and misbehaved — real work for a fixer
agent). A runner that cannot produce a verdict at all (Playwright missing, launch
or navigation failure) is an `:error`, never a `:fail`.

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
