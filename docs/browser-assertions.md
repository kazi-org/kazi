# Browser assertions: the `assertions[].type` reference

The `browser` predicate (`provider = "browser"`, T2.2) drives a **real Chromium**
via the shipped Playwright runner (`priv/browser/playwright_runner.js`), replays a
short interaction journey, and evaluates a list of **assertions** against the
rendered page. "Done" is what a real browser *observes* — an element is visible, a
heading carries the expected text, the console is clean, axe-core finds no
violation — not an agent's claim that the UI works (concept §2–3, ADR-0002,
UC-012).

This is the single reference for the assertion vocabulary. It matches
`kazi schema browser` exactly (the machine schema; run it to see the same set) and
the loader's allow-list (`Kazi.Goal.Loader.browser_assertion_types/0`). The
`browser` provider section of [live-providers.md](live-providers.md#browser--synthetic-journey)
frames the same provider in the "sustained health / synthetic monitor" family;
this doc is the full per-type how-to.

## Setup — the runner's optional deps

`mix test` and CI never launch a browser: every hermetic test injects a **stub**
runner that returns canned JSON, so no Playwright, no browser download. Driving a
real page requires the runner's own JavaScript deps, installed **once** in (or
alongside) the workspace the runner runs in:

```bash
npm i playwright                          # the browser driver (always)
npm i axe-core                            # only if you use `a11y`
npm i pixelmatch pngjs                    # only if you use `visual`
npx playwright install chromium           # the browser binary
```

These are **runner-side** deps (plain `npm`), not Elixir/mix deps. When a required
one is absent the run is an `:error` ("a11y unavailable", "visual diff
unavailable", Playwright missing) — **never** a false `:pass` and never a `:fail`.
A missing checker is infra; kazi must not dispatch a fixer agent against "your UI
is broken" when the truth is "the checker was not installed."

## Anatomy of a browser predicate

```toml
[[predicate]]
id = "checkout-journey"
provider = "browser"
url = "https://app.example.com"        # REQUIRED — the page to open
timeout_ms = 30000                     # optional per-operation timeout (default 30000)

# optional interaction steps replayed BEFORE the assertions
[[predicate.steps]]
action = "click"                       # click | fill | press | wait_for | goto
selector = "a[href='/cart']"

# the checks the runner evaluates (this doc's subject)
[[predicate.assertions]]
type = "console_clean"
network = true
```

| Key | Type | Meaning |
|-----|------|---------|
| `url` | string (**required**) | the page to open |
| `steps` | array&lt;table&gt; | interaction steps replayed before asserting (runner vocabulary: `click`, `fill`, `press`, `wait_for`, `goto`) |
| `assertions` | array&lt;table&gt; | the checks below; each needs a `type` |
| `viewport` | string \| table \| array | run the WHOLE journey at each width — `"mobile"` (390×844), `"tablet"` (820×1180), `"desktop"` (1440×900), or `{width, height}`; a list runs each in turn. Any viewport failing fails the predicate and the evidence names which (T43.5, ADR-0053) |
| `samples` | integer | number of **consecutive** passing runs required (default 1). With `> 1` it is a post-deploy synthetic monitor — a one-off success among failures never passes (T32.10, ADR-0043); `score` is the passing-run count (`higher_better`) |
| `timeout_ms` | integer | per-operation timeout passed to the runner (default 30000) |
| `screenshot` | string | path the runner writes a screenshot to |
| `cmd` / `args` / `env` | string / array / pairs | override the runner executable (tests point this at a stub); `env` adds runner environment |

With **no** assertions, a page that merely loads passes (the probe only proves the
page renders). The **runner** owns the assertion vocabulary — kazi hands
`assertions` verbatim to the runner, which dispatches on `type` — but the type must
be one kazi knows, so a typo fails at **goal-load** (naming the valid set) rather
than looking like a broken UI for the rest of the run.

`:pass` = every assertion held. `:fail` = an assertion did not hold — real failing
work, with expected-vs-found evidence a fixer agent can act on. `:error` = the
runner could not produce a verdict at all (Playwright missing, launch/navigation
failure, a missing optional checker) — infra, never conflated with `:fail`.

## The assertion types

| `type` | Keys | Holds when |
|--------|------|------------|
| [`visible`](#visible) | `selector` | the element is visible |
| [`hidden`](#hidden) | `selector` | the element is absent or hidden |
| [`text`](#text) | `selector` + `contains` \| `exact` | the element's text matches |
| [`url`](#url) | `contains` \| `exact` | the current URL matches |
| [`console_clean`](#console_clean) | `network` (optional bool) | the journey produced no `console.error` (and, with `network`, no failed 4xx/5xx) |
| [`download`](#download) | `filename_pattern` + `trigger_selector`, `timeout_ms` (optional) | the journey produced a download whose filename matches |
| [`attr`](#attr) | `selector` + `name` + `expected` | the element's `name` attribute equals `expected` |
| [`count`](#count) | `selector` + `expected` (non-negative int) | exactly `expected` elements match the selector |
| [`enabled`](#enabled) | `selector` + `expected` (optional bool, default `true`) | the element's enabled state equals `expected` |
| [`field_value`](#field_value) | `selector` + `expected` | an input/select's current value equals `expected` |
| [`form_validation`](#form_validation) | see below | invalid input errors, submit is disabled-until-valid, and a valid submission persists |
| [`a11y`](#a11y) | `severity`, `max_violations` (both optional) | axe-core finds `<= max_violations` violations at/above `severity` |
| [`visual`](#visual) | `name` + `selector`, `threshold` (optional) | the screenshot matches a committed baseline within `threshold` |

Every assertion records the **actual** value as `found`, so a `:fail` is
expected-vs-found, not a bare boolean.

### `visible`

The element is present and visible.

```toml
[[predicate.assertions]]
type = "visible"
selector = "h1"
```

### `hidden`

The element is absent or hidden — the inverse of `visible`. Use it to assert a
spinner cleared, a modal closed, an error banner is gone.

```toml
[[predicate.assertions]]
type = "hidden"
selector = "#loading-spinner"
```

### `text`

The element's text matches. Give **one** of `contains` (substring) or `exact`
(whole trimmed text).

```toml
[[predicate.assertions]]
type = "text"
selector = "h1"
contains = "Dashboard"
```

### `url`

The current URL matches — the check after a navigation step. Give **one** of
`contains` or `exact`.

```toml
[[predicate.assertions]]
type = "url"
contains = "/dashboard"
```

### `console_clean`

The journey produced **zero** `console.error`. With `network = true` it also fails
on any failed 4xx/5xx response. Higher signal than "the page loaded": a page that
renders while throwing in the console is broken, and no `visible`/`text` assertion
sees it (T43.1, ADR-0053).

```toml
[[predicate.assertions]]
type = "console_clean"
network = true       # also fail on a failed 4xx/5xx response
```

Errors are captured across the **whole journey** — the initial load and every step
— not just the state at assert time. `found` lists the offenders, each with the
console text and source location, or the status and URL for a network failure.
`network` must be a real boolean: the runner is JavaScript, where the *string*
`"false"` is truthy, so a non-boolean is rejected at goal-load rather than
silently turning network checking on. What `network = true` buys you is
**evidence, not extra coverage** — Chromium already logs its own `console.error`
for a failed subresource, so a 4xx usually trips the check anyway; the flag makes
the failure a *structured* record (`{kind: "network", status: 404, url: …}`) a
fixer agent can read the status code from.

### `download`

The journey actually **produced a file**, not merely that a button looked
clickable. `filename_pattern` is a regex matched against the download's suggested
filename (T49.10, ADR-0064).

```toml
[[predicate.assertions]]
type = "download"
trigger_selector = "#export-csv"
filename_pattern = "^invoice-\\d{4}-\\d{2}\\.csv$"
```

`found` is `{filename, sha256, path}` — the **sha256** makes *"the right file"*
checkable, not just *"a file with the right name"*. With `trigger_selector` the
runner arms the download listener *before* clicking (clicking first races a fast
download); without one, a download triggered by an earlier `steps` entry counts
(captured across the whole journey, like `console_clean`). No download inside
`timeout_ms` is a real `:fail` — the page ran, it just did not deliver the file.

### `attr`

The element's `name` attribute equals `expected`.

```toml
[[predicate.assertions]]
type = "attr"
selector = "#email"
name = "aria-invalid"
expected = "true"
```

A **missing** attribute is `found: null` (distinct from `""`, an attribute present
but empty), so `expected = ""` does not spuriously match a missing one. `attr`
needs a non-empty `name`.

### `count`

Exactly `expected` elements match the selector. `expected` must be a **non-negative
integer** (a string `"3"` compares unequal to a JS number forever, so the loader
rejects it). Zero matches is a legitimate `found: 0`, not an error.

```toml
[[predicate.assertions]]
type = "count"
selector = "ul.results > li"
expected = 3
```

### `enabled`

The element's enabled state equals `expected` (optional, default `true`). A
disabled-until-valid submit asserts `expected = false`.

```toml
[[predicate.assertions]]
type = "enabled"
selector = "button[type=submit]"
expected = false
```

`expected` must be a **real boolean** — the string `"false"` is truthy in JS (the
inverse of intent), so a non-boolean is rejected at goal-load.

### `field_value`

An input/select's **current** value equals `expected` — read-back after a `fill`
step, or a default value on load.

```toml
[[predicate.assertions]]
type = "field_value"
selector = "#email"
expected = "a@b.com"
```

### `form_validation`

The three things a form must do, in order, and it names **which one broke** (T43.4,
UC-056):

1. **invalid input surfaces the expected error** — fill the `invalid` fields, then
   assert `error_text` appears at `error_selector`;
2. **submit is disabled-until-valid** — with the form still invalid,
   `submit_selector` is disabled;
3. **a valid submission persists** — fill the `valid` fields, click submit, and
   read back `success_selector` (or `success_url`).

```toml
[[predicate.assertions]]
type = "form_validation"
submit_selector = "button[type=submit]"
invalid = [{ selector = "#email", value = "not-an-email" }]
error_selector = "#email-error"
error_text = "valid email"
valid = [{ selector = "#email", value = "a@b.com" }]
success_selector = "#signup-complete"
```

`found` names each sub-check —
`{error_shown, submit_disabled_until_valid, submission_persisted}` — so a `:fail`
says WHICH broke. A sub-check whose inputs you omit is **skipped** (`null`), not a
silent pass; a `form_validation` that requests none of `error_selector` /
`submit_selector` / `success_selector` / `success_url` is a load error, because it
would check nothing. Use `success_url` when a valid submit navigates rather than
swapping in a success element.

### `a11y`

Runs [axe-core](https://github.com/dequelabs/axe-core) against the current view and
asserts **at most `max_violations`** (default `0`) violations at or above a
`severity` (`minor` | `moderate` | `serious` | `critical`, default `serious`). It
catches the accessibility regressions a `visible`/`text` assertion never sees — a
missing label, insufficient contrast, a broken ARIA role (T43.2, UC-056).

```toml
[[predicate.assertions]]
type = "a11y"
severity = "serious"   # gate on serious + critical (the default)
max_violations = 0     # zero tolerated (the default)
```

The violation **count** is surfaced as the envelope-v2 `score` with
`direction = "lower_better"` (ADR-0041), so the controller reads "5 violations → 2
violations" as progress even before the gate is met. `found` lists each violation's
rule `id`, `impact`, and offending `nodes` (CSS selectors), so a fixer can locate
every one. axe-core is a **runner-side optional dep**; absent, the run is `:error`
("a11y unavailable"), never `:fail`. `severity` must be one of the four impact
levels and `max_violations` a non-negative integer.

### `visual`

Screenshots a `selector` (or the whole page when `selector` is absent) and
perceptual-diffs it against a **committed baseline image** within a `threshold` —
the max fraction of pixels allowed to differ (default `0.01`, i.e. 1%) (T43.3,
UC-056).

```toml
[[predicate.assertions]]
type = "visual"
name = "home-hero"        # REQUIRED — identifies the baseline file
selector = "#hero"        # optional; omit to diff the whole page
threshold = 0.01          # optional; allowed differing-pixel fraction (default 0.01)
```

Baselines live under the workspace at `.kazi/visual-baselines/<name>.png` and are
**committed alongside the code they pin**; a failure writes the diff to
`.kazi/visual-diffs/<name>.png` and surfaces its path in `found.diff_path`. **A
missing baseline is not a pass** — the runner *writes* the current screenshot as
the new baseline and returns `:error` "baseline seeded", so a goal never silently
passes its first run; the next run does the real comparison. The pixel diff needs
`pixelmatch` + `pngjs` runner-side; absent, `:error` "visual diff unavailable" —
never a false pass. `name` is required and `threshold` must be a number in
`[0, 1]`.

## Worked example — a live dogfood

[`priv/examples/live_site_ui.toml`](../priv/examples/live_site_ui.toml) runs
`console_clean` + `a11y` against the deployed https://kazi.sire.run as a
**read-only, observational** check (it asserts against what is already live; it
deploys nothing):

```bash
kazi apply priv/examples/live_site_ui.toml --workspace .
```

See [docs/devlog.md](devlog.md) for the recorded live verdicts (both predicates
pass at `severity = "critical"`; the same page returns a real `:fail` at
`severity = "serious"`, proving the verdict is genuinely computed, not a
rubber-stamp).

## See also

- [`kazi schema browser`](../lib/kazi/predicate/schema.ex) — the machine schema this
  reference mirrors.
- [live-providers.md](live-providers.md) — the `browser` provider in the sustained
  health / synthetic-monitor family, alongside `http_probe`, `metrics`, and
  `prod_log`.
- [`priv/examples/browser_acceptance.toml`](../priv/examples/browser_acceptance.toml)
  — a Slice 2 browser-acceptance target with `steps` + `visible`/`text`.
