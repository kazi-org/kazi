# Deferred interactive-surface recipes (T43.10, ADR-0053 §3)

Worked `custom_script` recipes — each with a fixture — for the four interactive
surfaces ADR-0053 §3 deliberately keeps as **config, not code**: mobile, TUI, API
contract, and Lighthouse. They run real off-the-shelf tools through the generic
[`custom_script`](../../../docs/custom-script-provider.md) command-runner (ADR-0040),
so they are reachable **without a kazi release**. Copy a directory, adapt the
`cmd`/`args`/paths to your app, and point a goal-file at it.

## The recipes

| Surface | Tool | Recipe | Fixtures | Verdict | Tier (ADR-0043 §2) |
|---------|------|--------|----------|---------|--------------------|
| **Mobile** | Maestro | [`mobile/recipe.goal.toml`](mobile/recipe.goal.toml) | `login_flow.yaml` (pass), `login_flow.broken.yaml` (fail) | `exit_zero` | demonstration |
| **TUI** | expect (pty) | [`tui/recipe.goal.toml`](tui/recipe.goal.toml) | `tui_app.sh` + `check_tui.exp` (pass), `tui_app.broken.sh` (fail) | `exit_zero` | demonstration |
| **API contract** | oasdiff | [`api_contract/recipe.oasdiff.goal.toml`](api_contract/recipe.oasdiff.goal.toml) | `openapi.base.yaml` + `openapi.revision.yaml` (breaking → fail), `openapi.compatible.yaml` (pass) | `exit_code` | demonstration |
| **API contract** | schemathesis | [`api_contract/recipe.schemathesis.goal.toml`](api_contract/recipe.schemathesis.goal.toml) | reuses `openapi.base.yaml` against a local server | `exit_zero` | demonstration |
| **Lighthouse** | lighthouse | [`lighthouse/recipe.goal.toml`](lighthouse/recipe.goal.toml) | `report.lowscore.json` (0.42 → fail), `report.goodscore.json` (0.95 → pass) | `json` budget `>= 0.9` | budget gate |

Each fixture ships a **deliberately failing** variant so you can watch the recipe
report `:fail` before you point it at your own app.

## The exit-code discipline (ADR-0043 §2)

Every recipe's verdict is chosen from the tool's REAL contract, never a naive
"exit 0 == pass":

- **Maestro / expect / schemathesis** — the tool's exit code already means
  pass/fail, so `exit_zero` is correct. schemathesis additionally maps its
  internal-error codes (`2`, `3`) to `:error` so an unreachable fixture server is
  never read as failing API work.
- **oasdiff** — `--fail-on ERR` exits `1` on a breaking change, `0` otherwise; the
  `exit_code` verdict pins `pass_codes = [0]`, `fail_codes = [1]`, and any other
  code is still a fail (a gate never passes an undeclared code).
- **Lighthouse** — exits `0` on a successful run **regardless of the score**, so
  `exit_zero` would pass a slow page. The `json` verdict reads
  `$.categories.performance.score` and gates it (`>= 0.9`) from the PARSED report,
  not the exit code.

Demonstration vs budget/claim tiers (ADR-0043 §2): a Maestro/expect/oasdiff/
schemathesis failure is a concrete, reproduced fact — safe to fail on directly. A
Lighthouse score is a rolled-up signal; this recipe gates it against a fixed
**budget**, and its `ratchet`-against-baseline counterpart is
[`recipe_a11y_lighthouse.toml`](../recipe_a11y_lighthouse.toml).

## First-class promotion is DEFERRED (ADR-0053 §3, ADR-0007)

None of these four surfaces gets a dedicated first-class predicate provider yet.
Per ADR-0053 §3 and the walking-skeleton discipline of ADR-0007, kazi does **not**
build a provider speculatively; a surface earns promotion only when a concrete goal
proves it common enough (the earns-first-class test of ADR-0043). ADR-0053 §3 is
explicit that mobile in particular stays a recipe because a first-class `:mobile`
provider would drag in a device-farm / emulator dependency kazi does not own —
exactly the integration cost ADR-0043 §3 deferred for canary/chaos. Until then they
live here as documented `custom_script` config, which keeps the catalog growing
without growing kazi's release surface (the ADR-0040 dividend).

Contrast with what ADR-0053 DID promote: the `:cli` provider (decision 2) and the
`:browser` UI-assertion pack (decision 1), which each passed the earns-first-class
test. These four did not — so they are recipes, not code, **for now**.
