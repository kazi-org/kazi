# `custom_script` recipe catalog — security, contract, perf, a11y

These are **config, not code** (ADR-0040, ADR-0043 decision 2). Each recipe turns a
real off-the-shelf checker into a kazi predicate over the generic
[`custom_script`](custom-script-provider.md) command-runner or the
[`ratchet`](ratchet-predicate.md) mode — no kazi release required. They ship under
[`priv/examples/`](../priv/examples/); copy one, adapt the `cmd`/`args`/paths to your
tool, and point a goal-file at it.

The long tail of verification (contract/schema compat, perf/size, secret scanning,
a11y, IaC/container scan, visual regression) stays config so the catalog grows
without growing kazi's release surface — the ADR-0040 dividend. The five checks that
earned a turnkey provider (`:static`, `:coverage`, `:property`, `:mutation`, `:cve`)
live elsewhere; **dependency CVE scanning is the first-class
[`:cve` provider](../docs/plan.md), not a recipe here** (ADR-0043 decision 1).

## The two evidence tiers

ADR-0043 decision 4 splits findings into two tiers, and **the tier picks the verdict
shape**:

| Tier | What it is | How a recipe gates it |
|------|-----------|------------------------|
| **Demonstration** (fail directly) | A concrete, located, live- or wire-verified fact: a `buf breaking` rule hit between two committed schemas, a TruffleHog `Verified:true` secret (the credential was actively confirmed against its provider), a pixel diff against an approved reference. | Fail the loop **directly** — `exit_zero` / `exit_code` for tools whose exit code is the verdict, or a `match_count`/`json` verdict that gates on the parsed signal. |
| **Presence / claim** (ratchet against a baseline) | A probabilistic or rolled-up signal that should only move one way: a generic SAST/IaC finding count, a perf latency, a Lighthouse a11y score. Pre-existing debt must not wedge the loop. | Gate with the [`ratchet`](ratchet-predicate.md) mode (`allowed_regression`, `direction`) so the signal can **only improve** (or stay within budget) — a new finding fails, pre-existing debt does not block. |

The rule of thumb: **a demonstration is safe to fail on directly; a claim is only
safe to ratchet.** Failing a loop directly on a presence-based finding blocks all
forward progress on pre-existing debt the agent did not introduce.

## Exit-code gotchas (read before you trust an exit code)

A naive "exit 0 == pass" silently passes real failures, because many scanners report
findings in their **output**, not their exit code. Each recipe is built to dodge the
specific trap:

| Tool | Trap | What the recipe does |
|------|------|----------------------|
| **Trivy**, **Semgrep** | Exit 0 even WITH findings unless you pass `--exit-code 1`. | Gate on the **parsed** output (a `json` verdict or a ratchet metric reading the finding count), never the exit code. Trivy exiting 0 is in fact required for the ratchet metric. |
| **grype** | Exits **2** (not 1) on findings with `--fail-on`. | Use the `exit_code` verdict with `pass_codes = [0]`, `fail_codes = [2]` (a code in neither list is still a fail). |
| **TruffleHog** | Exits 0 with findings unless `--fail` (which then exits 183 for *any* result). | Count `"Verified":true` lines with the `match_count` verdict — the verdict comes from the parsed JSON, never the exit code. |
| **govulncheck** | Exits 0 under `-format json`. | Handled by the first-class `:cve` provider (not a recipe). |
| **nuclei**, **OWASP ZAP** | No dedicated "findings" exit code at all. | Must gate on the parsed report (a `json` verdict over the JSON/SARIF output), never the exit code. |

## The recipes

### Contract / schema compatibility — *demonstration*

- [`recipe_contract_buf.toml`](../priv/examples/recipe_contract_buf.toml) — `buf breaking`
  finds no wire/source-incompatible Protobuf change vs a baseline (`exit_zero`).
- [`recipe_contract_oasdiff.toml`](../priv/examples/recipe_contract_oasdiff.toml) —
  `oasdiff breaking --fail-on ERR` finds no breaking OpenAPI change (`exit_code`,
  `pass_codes = [0]`, `fail_codes = [1]`).
- [`recipe_contract_pact.toml`](../priv/examples/recipe_contract_pact.toml) —
  `pact-broker can-i-deploy` confirms the version is compatible with what is already
  in production (`exit_zero`).

### Perf / size ratchets — *presence/claim*

- [`recipe_perf_ratchet.toml`](../priv/examples/recipe_perf_ratchet.toml) — p95
  latency from a benchmark (Criterion / bencher.dev / hyperfine) may not regress
  beyond a small budget (`ratchet`, `lower_better`).
- [`ratchet_size.toml`](../priv/examples/ratchet_size.toml) — binary/bundle size
  (size-limit / bloaty) may not grow vs a git ref (`ratchet`, `lower_better`). The
  SAME ratchet mode as perf — only the config differs.

### Secret scanning — *demonstration*

- [`recipe_secret_trufflehog.toml`](../priv/examples/recipe_secret_trufflehog.toml) —
  TruffleHog finds zero **verified** secrets (`match_count` over `"Verified":true`,
  gated on parsed output not the exit code).

### Accessibility — *presence/claim*

- [`recipe_a11y_lighthouse.toml`](../priv/examples/recipe_a11y_lighthouse.toml) — the
  Lighthouse accessibility score may not regress (`ratchet`, `higher_better`,
  `allowed_regression = 0`).

### IaC / container scan — *presence/claim*

- [`recipe_iac_scan.toml`](../priv/examples/recipe_iac_scan.toml) — Trivy
  misconfiguration count may only shrink (`ratchet`, `lower_better`, gated on the
  parsed count not the exit code).

### Visual regression — *demonstration*

- [`recipe_visual_regression.toml`](../priv/examples/recipe_visual_regression.toml) —
  a visual-regression runner (BackstopJS / reg-cli / Playwright screenshots) matches
  every approved reference (`exit_zero`).

### Deferred interactive surfaces — mobile / TUI / API contract / Lighthouse

Four surfaces a user directly *operates* stay `custom_script` recipes rather than
first-class providers (ADR-0053 §3). Each ships as a self-contained, **fixture-bearing**
worked example under
[`priv/examples/deferred_surface_recipes/`](../priv/examples/deferred_surface_recipes/),
with a deliberately failing variant so you can watch it report `:fail`:

- [`mobile/recipe.goal.toml`](../priv/examples/deferred_surface_recipes/mobile/recipe.goal.toml)
  — **Maestro** replays a mobile flow on an emulator/simulator; `maestro test`
  exits non-zero on a failed step (`exit_zero`, *demonstration*). Fixtures:
  `login_flow.yaml` (pass), `login_flow.broken.yaml` (fail).
- [`tui/recipe.goal.toml`](../priv/examples/deferred_surface_recipes/tui/recipe.goal.toml)
  — an **expect** pty script drives an interactive terminal program and asserts on
  its output (`exit_zero`, *demonstration*). Fixtures: `tui_app.sh` + `check_tui.exp`
  (pass), `tui_app.broken.sh` (fail).
- [`api_contract/recipe.oasdiff.goal.toml`](../priv/examples/deferred_surface_recipes/api_contract/recipe.oasdiff.goal.toml)
  — **oasdiff** `breaking --fail-on ERR` finds no breaking OpenAPI change
  (`exit_code`, `pass_codes = [0]`, `fail_codes = [1]`, *demonstration*). Fixtures:
  `openapi.base.yaml` + `openapi.revision.yaml` (breaking → fail),
  `openapi.compatible.yaml` (pass). Its live complement,
  [`recipe.schemathesis.goal.toml`](../priv/examples/deferred_surface_recipes/api_contract/recipe.schemathesis.goal.toml),
  fuzzes a running server against the spec (`exit_zero`, infra codes → `:error`).
- [`lighthouse/recipe.goal.toml`](../priv/examples/deferred_surface_recipes/lighthouse/recipe.goal.toml)
  — **Lighthouse** performance score meets a **budget**; because Lighthouse exits 0
  regardless of score, the verdict is `json` over `$.categories.performance.score`
  (`pass_when = ">= 0.9"`), not the exit code. Fixtures: `report.lowscore.json`
  (0.42 → fail), `report.goodscore.json` (0.95 → pass). The ratchet-against-baseline
  counterpart is [`recipe_a11y_lighthouse.toml`](../priv/examples/recipe_a11y_lighthouse.toml).

**First-class promotion is DEFERRED (ADR-0053 §3, ADR-0007).** None of these four
earns a dedicated predicate provider yet. Per ADR-0053 §3 and the walking-skeleton
discipline of ADR-0007, kazi does not build a provider speculatively — a surface is
promoted only when a concrete goal proves it common enough (the earns-first-class
test of ADR-0043). ADR-0053 §3 calls out mobile specifically: a first-class
`:mobile` provider would drag in a device-farm / emulator dependency kazi does not
own, the same integration cost ADR-0043 §3 deferred for canary/chaos. Until a goal
earns it, they stay config, so the catalog grows without growing kazi's release
surface (the ADR-0040 dividend). ADR-0053 DID promote the `:cli` provider and the
`:browser` UI-assertion pack, which each passed the earns-first-class test; these
four did not — **for now**.

## See also

- [`docs/custom-script-provider.md`](custom-script-provider.md) — the generic
  command-runner the demonstration recipes use, and the full verdict/key reference.
- [`docs/ratchet-predicate.md`](ratchet-predicate.md) — the ratchet mode the
  presence/claim recipes use.
- ADR-0043 (`docs/adr/0043-predicate-catalog-expansion.md`) — which checkers ship
  first-class vs as config, the two evidence tiers (decision 4), and the order.
- ADR-0040 (`docs/adr/0040-generic-predicate-protocol-custom-script.md`) — the
  generic protocol that makes a new checker config, not a release.
- ADR-0053 (`docs/adr/0053-higher-level-interactive-surface-predicates.md`) — §3
  keeps mobile / TUI / API-contract / Lighthouse as recipes (promotion deferred),
  and ADR-0007 the walking-skeleton discipline behind that call.
