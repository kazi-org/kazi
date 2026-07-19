# ADR 0053: Higher-level interactive-surface predicates — a `:browser` assertion pack + a first-class `:cli` provider

## Status
Accepted

## Date
2026-07-01

## Refines / depends on
ADR-0002 (goals are predicate sets; a new goal type is a new PROVIDER, not a core
change), ADR-0040 (the `custom_script` generic protocol), ADR-0041 (envelope v2 —
`{pass, score, prior_score, direction, evidence[]}`), ADR-0043 (predicate catalog
expansion — the "earns first-class vs stays a recipe" test, and the browser-as-
template pattern). This ADR extends ADR-0043 along the axis it under-served: the
**interactive surfaces a real user actually touches** — the shipped CLI, the UI, a
form, a component.

## Context

ADR-0043 expanded the catalog along the code-side axis (`:static`, `:coverage`,
`:property`, `:mutation`, `:cve`) and the live-observability axis (sustained-health,
`:metrics`, burn-rate, synthetic journey). It deliberately left the long tail as
`custom_script` recipes. Two gaps remain, both on the **"does the thing a user
operates actually behave"** axis:

1. **The UI surface is shallow.** The `:browser` provider (T2.2, extended for
   synthetic journeys in T32.10) drives a real page, but its runner only knows two
   assertion types — `visible` and `text`. The checks users ask for first — "no
   console errors", "the form rejects a bad input and accepts a good one", "this
   component still looks right", "it's accessible", "it works on a phone-width
   viewport" — are all expressible against the SAME Playwright session but are not in
   the runner's vocabulary. A goal author reaches them today only by hand-authoring a
   long `steps` + raw-DOM `text`/`visible` sequence, which is brittle and re-derives
   the same journey every time.

2. **There is no check that a shipped BINARY actually runs.** kazi is itself a CLI
   distributed as a burrito/escript binary, yet its only executable-behavior
   predicate is `:tests` — which proves the code COMPILES and the unit suite passes,
   not that the produced artifact serves when invoked. This exact gap has bitten kazi
   repeatedly and expensively at the release boundary, each time GREEN in `mix test`:
   the `:noproc` crash on the CLI path (PartitionSupervisor not started off the test
   path), the OTP-28.0 "regexes re-compiled" stderr warning on every run, the burrito
   binary leaking host `RELEASE_*`/ERTS env into `custom_script` children so a
   `mix test` predicate died exit-2 (lore L-0022), and the brew-installed binary
   crashing on `status`/`approve` because `Kazi.Repo` was not started on the burrito
   path. `:tests` is structurally blind to all four. There is no first-class,
   turnkey way to declare "the built binary, invoked as a user invokes it, exits 0
   and prints what it should, with a clean stderr."

The organizing principle from ADR-0043 still holds: the runner owns the assertion
vocabulary (kazi core does not), and a surface earns a first-class provider only when
it is (a) kazi-native / high-trust, (b) extremely common, or (c) needs richer
evidence/score handling than a raw `custom_script` parse. That test decides what
follows.

## Decision

### 1. Extend the `:browser` runner with a UI-assertion pack (runner-only, NO new kind)

Because the assertion vocabulary lives in `priv/browser/playwright_runner.js` and is
passed VERBATIM from config (ADR-0043's dividend), these are runner + schema changes,
not kazi-core changes. Add these `assertions[].type` values, each returning the same
per-assertion `{type, ok, expected, found}` record the runner already emits:

- **`console_clean`** — the journey produced zero `console.error` (and, opt-in, no
  failed 4xx/5xx network responses). Higher-signal than "the page loaded"; this is
  the recurring site-smoke check made first-class in the vocabulary.
- **`a11y`** — run axe-core against the current view; assert ≤ N violations at or
  above a configured severity. Ratchet-friendly (score = violation count,
  `lower_better`), promoting the ADR-0043 §2 a11y recipe into a turnkey assertion.
- **`visual`** — compare a screenshot of a `selector` (or the page) against a
  committed baseline within a perceptual threshold; a diff trips it. Baseline lives
  in the workspace; the diff image is evidence.
- **`form_validation`** — a bundled higher-level check for the "forms" surface:
  assert a required/invalid input surfaces the expected error message, that submit is
  disabled-until-valid, and that a valid submission persists (read-back assertion).
  One declarative predicate replaces the 6–8 raw click/type/assert steps a form
  otherwise costs.
- **Richer DOM assertions** — `attr`, `count`, `enabled`, `field_value` — the
  obvious gaps beyond `visible`/`text` that components and forms need.
- **Viewport matrix** — a `viewport` field (`mobile` | `tablet` | `desktop` | an
  explicit `{width,height}`) so one predicate asserts a journey at several widths;
  covers responsive / mobile-web layout without a device. A component (Storybook /
  Ladle / Histoire iframe URL) is just a `:browser` predicate targeting the story URL
  with these assertions — no new kind needed.

The strict pass/**fail**/**error** contract is unchanged: an assertion that does not
hold is `:fail` (real failing UI work); an inability to drive the browser or run axe
is `:error` (infra), never `:fail`.

### 2. Promote `:cli` to a FIRST-CLASS provider (the `:cve` precedent)

A turnkey provider that drives the **built binary** exactly as a user invokes it and
maps the result to a `PredicateResult`, following the `:browser` template (injectable
`cmd` seam so `mix test` stays hermetic; the executable and argv are config):

- **Config:** `cmd` (the binary under test) + `args` (argv); `assertions` over the
  invocation — `exit_code`, and `stdout`/`stderr` matchers (`equals` | `contains` |
  `regex` | `json_path`); an optional `script` of ordered sub-invocations (e.g.
  `version` → `status` → `apply <fixture>`); an optional `golden` mode comparing
  `--help`/usage output to a committed golden file; `samples` for flake, reusing the
  `:browser` consecutive-pass shape. `env`/`cd`/`timeout_ms` as the other command
  providers expose.
- **Discipline:** exit-code + output that VIOLATE the assertions are `:fail` (the
  binary ran and misbehaved — real work for a fixer). A binary that cannot even
  launch (missing executable, bad cwd) is `:error` (infra). Envelope-v2 score =
  assertions-passed, `direction: :higher_better`. A non-empty stderr can be asserted
  clean (`stderr equals ""`) — the L-0022 / OTP-warning class.
- **Why first-class, not a recipe:** it passes all three ADR-0043 tests. (a)
  kazi-native and dogfood-critical — kazi is a CLI whose release artifacts keep
  breaking in ways `:tests` cannot see; (b) extremely common — every CLI tool wants
  "does the binary run and say the right thing"; (c) richer evidence than a raw
  `custom_script` — a golden-diff and a per-sub-invocation matrix, not one exit code.
  It closes the "CI proves the code compiles, not that it serves traffic" gap for
  binaries (the global Definition-of-Done's live-verify requirement).
- **Docs land with it** (ADR-0034): a `kazi schema cli` entry, a `priv/examples`
  goal-file, and a `docs/` how-to. The dogfood is a shipped goal-file whose `:cli`
  predicates over kazi's OWN released binary would have caught the four regressions
  above.

### 3. Keep the remaining surfaces as DOCUMENTED recipes (config, not code) — for now

Per ADR-0043 §2 and the walking-skeleton discipline (ADR-0007), do NOT build these
speculatively; ship them as `custom_script` recipes in `priv/examples` with a fixture
so they are reachable without a kazi release, and promote only when a concrete goal
proves one common enough:

- **Mobile app** (`:mobile`) — a **Maestro** YAML flow (its navigate/assert vocab
  maps almost 1:1 onto the `:browser` step/assertion contract) or Appium, on an
  emulator/simulator. First-class promotion is deferred because it drags in a
  device-farm / emulator dependency kazi does not own — exactly the integration cost
  ADR-0043 §3 deferred for canary/chaos.
- **TUI** (`:tui`) — an expect/pty-driven interactive terminal check.
- **API contract** (`:api_flow` / `:openapi`) — multi-step API journey +
  schema-conformance (schemathesis / `oasdiff`); richer than the single-shot
  `:http_probe`.
- **Lighthouse / web-vitals** — perf/SEO/best-practices/a11y scores + LCP/CLS/TBT
  budgets, as the ADR-0043 §2 recipe (kazi's own site already runs this ad-hoc in
  T9.6).

### 4. No new mechanism

Everything above reuses `CommandRunner` (the single command seam), the envelope-v2
score/evidence shape (ADR-0041), the injectable-`cmd` test seam, and the pass/fail/
error contract (ADR-0002). The UI pack adds zero kazi-core surface; `:cli` adds one
provider + one loader validation clause + one runtime registry entry, mirroring
`:cve` byte-for-byte in structure.

## Consequences

- The catalog finally covers the surfaces a user OPERATES, not just the code and the
  telemetry: a goal can assert "the CLI a user runs works", "the form validates",
  "the page has no console errors / is accessible / renders on mobile" — objectively,
  from what a real invocation observes.
- kazi can DOGFOOD `:cli` against its own release binary, converting a recurring,
  expensive, post-release class of bugs (four documented instances) into a
  pre-merge predicate. This is the highest-leverage item in the ADR.
- The UI pack costs almost nothing in kazi core (runner + schema only), so the UI
  catalog grows without growing kazi's release surface — the ADR-0040 dividend again.
- Risk: runner dependency creep — axe-core, a screenshot-diff lib, Maestro. Mitigated
  by keeping them runner-side and OPTIONAL (an assertion type that needs an absent dep
  returns `:error` "not available", never `:fail`), exactly as Playwright itself is
  today.
- Risk: `:cli` overlaps `:tests`/`:custom_script`. Delineated: `:tests` runs the
  suite (compilation + unit truth); `:custom_script` runs an arbitrary tool with a
  declared parse; `:cli` is the turnkey golden-invocation of a SHIPPED binary with an
  exit/stdout/stderr assertion matrix and a help-golden mode — the artifact-serves
  check neither of the others gives ergonomically.
- Risk: provider sprawl. Bounded by decision 3 — only `:cli` is promoted now;
  mobile/TUI/api/lighthouse stay recipes until a goal earns their promotion.

## Alternatives rejected

- **Build `:mobile`, `:tui`, `:api_flow`, `:lighthouse` as first-class now.** Sprawl
  and speculative infra dependencies (emulators, device farms) with no concrete goal
  demanding them; violates ADR-0007 and ADR-0043's earns-first-class test. Deferred
  to recipes, not dropped.
- **Add the UI checks as new provider KINDS (`:a11y`, `:visual`, `:form`).** They
  share one Playwright session with `:browser`; splitting them into separate kinds
  would re-launch the browser per check and fragment the journey. They are assertion
  TYPES on `:browser`, not new providers. Rejected.
- **Leave `:cli` as a `custom_script` recipe.** Loses the turnkey exit/stdout/stderr
  matrix, the help-golden drift check, and the kazi-native trust for the single most
  dogfood-critical surface — the one whose absence has cost the most at the release
  boundary. Rejected; it earns first-class by every ADR-0043 test, as `:cve` did.
- **Rely on the global Definition-of-Done "verify live in a browser" step instead of
  a predicate.** That is a human/agent checklist item, not machine-checkable; the
  whole point of kazi is to turn "should work" into an objective predicate the loop
  cannot declare done without. Rejected.
