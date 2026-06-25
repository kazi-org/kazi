# ADR 0043: Predicate catalog expansion — which checkers ship first-class, and in what order

## Status
Accepted

## Date
2026-06-24

## Refines / depends on
ADR-0040 (the `custom_script` generic protocol), ADR-0041 (envelope v2 + ratchet
mode), ADR-0042 (anti-gaming enforcement). This ADR decides which verification
techniques from the research note (`docs/research/predicate-verification-landscape.md`)
become FIRST-CLASS providers vs config over the generic protocol, and the order.

## Context

The research catalogued ~20 objective, machine-checkable verification signals beyond
unit tests (code-side and live-side), ranked by
`(catches-bugs-tests-miss x ease-of-automation x evidence-usefulness)`. With ADR-0040
in place most are reachable as `custom_script` config. The decision is therefore not
"build all of them" but "which earn a first-class provider, and what sequence proves
the framework."

A provider earns first-class status when it is (a) kazi-native (low friction, high
trust — e.g. Elixir tooling), (b) extremely common (worth a turnkey schema), or
(c) needs richer evidence/score handling than the generic JSON parse gives.

## Decision

1. **Ship these FIVE as FIRST-CLASS providers, in this order** (operator promoted the
   CVE provider from a recipe to first-class, 2026-06-24):
   - **`:static` (analysis / type-check / lint).** Cheapest, most deterministic, runs
     every iteration, catches defects on unexecuted paths. Lead with **Dialyzer**
     (kazi-native, zero false positives) AND ship the polyglot SARIF path
     (tsc/mypy/golangci-lint/Semgrep) in the SAME provider, not later. Baseline-ratchet
     on new findings (ADR-0041).
   - **`:coverage` (ratchet).** Already named in the behaviour docstring. Patch
     coverage >= target AND no project regression; an instance of the ADR-0041 ratchet
     mode + an ADR-0042 guard.
   - **`:property` (property-based testing).** **PropCheck under `mix test`**
     (kazi-native); shrunk counterexample as evidence. Score = cases passed / N.
   - **`:mutation` (mutation testing).** The only test-QUALITY signal; score 0-1, gate
     on a threshold never 100%, scope to changed lines. Surviving-mutant evidence.
   - **`:cve` (dependency vulnerability scan).** Common + high-stakes enough to warrant
     a turnkey provider rather than a recipe. Lead with **`govulncheck` reachability**
     (flags a vuln only if the vulnerable symbol is transitively called, printing the
     call stack as proof — a DEMONSTRATION, safe to fail on directly); trivy/grype/
     npm-audit are manifest-only tier-2 (CLAIMS — ratcheted against a baseline, decision
     4). Encodes the exit-code gotcha (govulncheck exits 0 under `-format json`).

2. **Ship these as DOCUMENTED `custom_script` recipes (config, not code), with shipped
   examples in `priv/examples`:** contract/schema compat (`buf breaking`, `oasdiff`,
   `pact can-i-deploy`), perf/size ratchets (Criterion/bencher.dev, size-limit/bloaty),
   secret scanning (trufflehog `Verified:true`), a11y + Lighthouse CI, IaC/container
   scan, visual-regression. The generic protocol + the SARIF/JUnit parser (ADR-0040)
   cover these; promotion to first-class is deferred until a recipe proves common
   enough to warrant a turnkey schema. (CVE was promoted OUT of this list to first-class
   — decision 1.)

3. **Upgrade the LIVE providers in this order (each an extension of `http_probe` /
   `prod_log`, not a new mechanism):**
   - **Sustained health** — `http_probe` gains "N consecutive healthy samples over
     window W" instead of a single 200 (the K8s `failureThreshold` model).
   - **`:metrics` (PromQL / RED).** Error-rate + p95/p99 over W; `histogram_quantile`
     over `rate(..._bucket[W])` by `(le)`. Querying metrics supersedes the `prod_log`
     grep, which stays a coarse safety net.
   - **SLO burn-rate gate** — multiwindow multi-burn-rate over `:metrics`.
   - **Synthetic journey** — the `browser` provider re-run N times as a post-deploy
     monitor requiring X consecutive passes.
   - Deferred to the deep end (needs traffic-splitting / fault-injection): trace-based
     assertions (Tracetest), canary-vs-baseline statistical analysis (Kayenta-style),
     chaos steady-state gate, migration validate+lint.

4. **Two evidence tiers are explicit** (from the research): reachability / live-verified
   findings (`govulncheck` call site, trufflehog `Verified:true`) are DEMONSTRATIONS —
   safe to fail a loop on directly; presence-based findings (manifest SCA, generic
   SAST) are CLAIMS — routed through an allowlist/triage so security debt can only
   shrink (a baseline ratchet), not block on pre-existing debt.

5. **Each first-class provider lands with its docs** (ADR-0034 docs-with-code): a
   `kazi schema <kind>` entry, a goal-file example, and a `docs/` how-to. The bake-in
   discipline for live providers (never converge on a single sample; prefer a relative
   comparison) is documented, not just coded.

## Consequences

- The framework ADRs (0040/0041/0042) are PROVEN by concrete providers that exercise
  every new capability: `:static` exercises SARIF evidence + ratchet; `:mutation`
  exercises a 0-1 score gradient; `:coverage` exercises the ratchet-as-guard;
  sustained-health/`:metrics` exercise the windowed live shape.
- Most of the long tail stays config, so the catalog grows without growing kazi's
  release surface — the ADR-0040 dividend.
- Risk: provider sprawl (too many first-class kinds to maintain). Mitigated by the
  earns-first-class test (§context) — five code-side + the live upgrades, everything
  else config.
- Risk: live providers (metrics/burn-rate) assume an observability stack (Prometheus)
  kazi cannot provision. Acceptable — they degrade to "not applicable" when no metrics
  endpoint is configured; the sustained-health upgrade needs only an HTTP endpoint and
  is the universal baseline.

## Alternatives rejected

- **Build every catalogued technique as a first-class provider.** Sprawl; most are
  one-line `custom_script` configs once ADR-0040 lands. Rejected.
- **Generic-protocol-only, no new first-class providers.** Loses the kazi-native trust
  + turnkey ergonomics for the highest-value checks (Dialyzer/PropCheck/coverage/
  mutation) and fails to dogfood the framework ADRs. Rejected.
- **Lead with the live/prod deep end (canary, chaos).** Highest integration cost,
  needs infra kazi doesn't own; the code-side quick wins + sustained-health/metrics
  deliver more per unit effort first. Deferred, not dropped.
