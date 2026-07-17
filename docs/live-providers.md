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

The full per-type how-to — every `assertions[].type` with keys, examples, and
pass/fail/error semantics — is [docs/browser-assertions.md](browser-assertions.md)
(the consolidated reference, matching `kazi schema browser`). The summary below
covers the same vocabulary in the sustained-health framing.

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
| `download` | `filename_pattern` + `trigger_selector`, `timeout_ms` (optional) | the journey produced a download whose filename matches |
| `attr` | `selector` + `name` + `expected` | the element's `name` attribute equals `expected` |
| `count` | `selector` + `expected` (non-negative int) | exactly `expected` elements match the selector |
| `enabled` | `selector` + `expected` (optional bool, default `true`) | the element's enabled state equals `expected` |
| `field_value` | `selector` + `expected` | an input/select's current value equals `expected` |
| `form_validation` | see below | invalid input errors, submit is disabled-until-valid, and a valid submission persists |
| `a11y` | `severity` (optional), `max_violations` (optional) | axe-core finds `<= max_violations` violations at/above `severity` |
| `visual` | `name` + `selector`, `threshold` (optional) | the screenshot matches a committed baseline within `threshold` |

### `download` — the file-effect check

`download` asserts the journey actually **produced a file**, not merely that a
button looked clickable. `filename_pattern` is a regex matched against the
download's suggested filename:

```toml
[[predicate]]
id = "invoice-export"
provider = "browser"
url = "https://app.example.com/reports"
assertions = [
  { type = "download", trigger_selector = "#export-csv", filename_pattern = "^invoice-\\d{4}-\\d{2}\\.csv$" },
]
```

`found` is `{filename, sha256, path}`. The **sha256** is the point: it makes *"the
right file"* checkable rather than just *"a file with the right name"* — pin it in
a follow-up check once you know the expected digest.

Two ways a download arrives, both supported:

- **With `trigger_selector`** — the runner arms the download listener *before*
  clicking it. (Clicking first and then waiting races the event: a fast download
  fires before the listener attaches.)
- **Without one** — a download triggered by an earlier `steps` entry counts.
  Downloads are captured across the whole journey, exactly like `console_clean`'s
  errors, because assertions run *after* every step: a bare wait at assert time
  would sit there expecting a *second* download and report a false negative.

No download inside `timeout_ms` (default: the predicate's timeout) is a real
**fail**, never an error — the page ran, it just did not deliver the file.

### DOM-state checks — `attr`, `count`, `enabled`, `field_value`

Four small checks the `visible`/`text` pair could not express. Each reports the
**actual** value as `found`, so a fixer reads expected-vs-found rather than a bare
boolean:

```toml
assertions = [
  { type = "attr",        selector = "#email", name = "aria-invalid", expected = "true" },
  { type = "count",       selector = "ul.results > li",               expected = 3 },
  { type = "enabled",     selector = "button[type=submit]",           expected = false },
  { type = "field_value", selector = "#email",                        expected = "a@b.com" },
]
```

A selector that matches nothing is a real **fail** (the thing under test is
absent), never an error — except `count`, where zero matches is a legitimate
`found: 0` compared against `expected` like any other number. A missing attribute
is `found: null` (distinct from `""`, an attribute present but empty), so
`expected = ""` does not spuriously match a missing one.

Load-time guards catch the footguns before they cost a dispatch: `count`'s
`expected` must be a non-negative integer (a string `"3"` compares unequal to a JS
number forever), `enabled`'s `expected` must be a real boolean (the string
`"false"` is truthy in JS — the inverse of intent), and `attr` needs a non-empty
`name`.

### `form_validation` — the whole form contract in one assertion

`form_validation` checks the three things a form must do, in order, and names
which one broke:

1. **invalid input surfaces the expected error** — fill the `invalid` fields, then
   assert `error_text` appears at `error_selector`;
2. **submit is disabled-until-valid** — with the form still invalid, `submit_selector`
   is disabled;
3. **a valid submission persists** — fill the `valid` fields, click submit, and read
   back `success_selector` (or `success_url`).

```toml
[[predicate]]
id = "signup-form-works"
provider = "browser"
url = "https://example.test/signup"
description = "the signup form validates, gates submit, and persists a valid signup"

assertions = [
  { type = "form_validation",
    submit_selector = "button[type=submit]",
    invalid         = [{ selector = "#email", value = "not-an-email" }],
    error_selector  = "#email-error",
    error_text      = "valid email",
    valid           = [{ selector = "#email", value = "a@b.com" }],
    success_selector = "#signup-complete" },
]
```

`found` names each sub-check —
`{ error_shown, submit_disabled_until_valid, submission_persisted }` — so a
**fail** says WHICH of the three broke, not just that the form is wrong. A
sub-check whose inputs you omit is **skipped** (`null`), not a silent pass: a
`form_validation` that requests none of `error_selector` / `submit_selector` /
`success_selector` / `success_url` is a load error, because it would check
nothing. Use `success_url` instead of `success_selector` when a valid submit
navigates rather than swapping in a success element.

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

### `a11y` — accessibility violations (axe-core)

`a11y` runs [axe-core](https://github.com/dequelabs/axe-core) against the current
view and asserts **at most `max_violations`** (default `0`) violations at or above
a `severity` (`minor` | `moderate` | `serious` | `critical`, default `serious`).
It catches the accessibility regressions a `visible`/`text` assertion never sees —
a missing label, insufficient contrast, a broken ARIA role.

```toml
[[predicate.assertions]]
type = "a11y"
severity = "serious"   # gate on serious + critical (the default)
max_violations = 0     # zero tolerated (the default)
```

The violation **count** is surfaced as the envelope-v2 `score` with
`direction = "lower_better"` (ADR-0041), so the controller reads "5 violations →
2 violations" as progress even before the gate is met — the ratchet-friendly
gradient. Evidence (`found`) lists each violation's rule `id`, `impact`, and the
offending `nodes` (CSS target selectors), so a fixer agent can locate every one.

axe-core is a **runner-side optional dependency** (installed alongside the runner,
`npm i axe-core`, not an Elixir/mix dep). When it is **absent** the assertion is
**unavailable** and the whole run is an `:error` ("a11y unavailable") — never a
`:fail`. A missing evidence tool is infra, exactly like a missing Playwright: kazi
must not dispatch a fixer agent against "your UI is inaccessible" when the truth is
"the checker was not installed."

`severity` must be one of the four axe-core impact levels and `max_violations` a
non-negative integer; the loader rejects anything else at goal-load.

### `visual` — pixel regression against a committed baseline

`visual` screenshots a `selector` (or the whole page when `selector` is absent)
and perceptual-diffs it against a **committed baseline image** within a
`threshold` — the maximum fraction of pixels allowed to differ (default `0.01`,
i.e. 1%).

```toml
[[predicate.assertions]]
type = "visual"
name = "home-hero"        # REQUIRED — identifies the baseline file
selector = "#hero"        # optional; omit to diff the whole page
threshold = 0.01          # optional; allowed differing-pixel fraction (default 0.01)
```

**Baseline path convention.** Baselines live under the workspace at
`.kazi/visual-baselines/<name>.png` and are **committed alongside the code they
pin**. On a failure, the diff image is written to `.kazi/visual-diffs/<name>.png`
and its path is surfaced in `found.diff_path` so a fixer agent can open it. (kazi
ignores `.kazi/` by default; the baselines subdirectory is un-ignored so it can be
committed — the same pattern kazi uses for `.kazi/goals/`. Add
`!.kazi/visual-baselines/` to your workspace's `.gitignore` if it blocks `.kazi/`.
The `.kazi/visual-diffs/` output stays ignored — it is a transient artifact.)

**The seed-on-first-run invariant.** A **missing baseline** is not a pass. The
runner **writes** the current screenshot as the new baseline and returns an
`:error` with reason `"baseline seeded"` — never `:pass`, never `:fail`. A goal
must never silently pass its first run just because there was nothing to compare
against; the seeded baseline is there for you to review and commit, and the next
run does the real comparison. A dimension change (the view resized) is a real
`:fail` with the diff artifact, not a seed.

The pixel diff needs `pixelmatch` + `pngjs` installed alongside the runner
(`npm i pixelmatch pngjs`, runner-side optional deps like axe-core). Absent, the
assertion is `:error` `"visual diff unavailable"` — never a false pass.

`name` is required (it is the baseline's identity) and `threshold` must be a number
in `[0, 1]`; the loader rejects anything else at goal-load.

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

### `correlate` — a trust-check on the green (opt-in)

A `prod_log` predicate can pass — no panic, 5xx within tolerance — while a route
you care about is quietly erroring. `correlate` cross-checks the fetched logs for
a named route and, when it finds a 5xx/panic there, flags the pass instead of
silently trusting the green (ADR-0051 decision 4):

```toml
[[predicate]]
id = "prod-behaving"
provider = "prod_log"
cmd = "gcloud"
args = ["logging", "read", "resource.type=cloud_run_revision", "--freshness=1h"]
max_5xx = 5
correlate = { route = "/checkout", window = 60 }
```

When configured, the evidence gains `correlated_prod_error` (a boolean),
`correlate` (the `{route, window}` it checked), and a bounded `correlated_lines`
sample. The **verdict is unchanged** — a `:pass` stays `:pass`; the flag downgrades
*trust* in the green, not the verdict, so a consumer can decide whether a
correlated error on that route warrants attention. `route` matches as a literal
substring of a log line; `window` is recorded (the span the correlation speaks
for) but not used for filtering — the query already bounds the window, exactly
like the informational `window_minutes`. Absent `correlate`, evidence is
byte-identical to a goal that never named it — a pure, opt-in add. A malformed
`correlate` (a bare string instead of a `{route, window}` table, an empty route, a
non-numeric window) is a **load error**, not a silent no-op.

---

## Why this matters

Convergence still requires the whole predicate vector to pass (ADR-0002); the
graded `score` on live results is a progress *signal*, never a second gate. The
point of the bake window is that a live predicate's `:pass` means *sustained*
health — so when kazi reports a goal converged, the deployed service has held up
across a window, not blinked green for one request.
