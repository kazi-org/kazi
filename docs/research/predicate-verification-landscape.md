# Research note — the predicate-verification landscape (ADR input for E32)

Status: research synthesis (input to ADR-0040/0041/0042/0043 and E32). Not a decision.
Date: 2026-06-24

This note is the grounding for expanding kazi's predicate checkers from the
current four into a verification layer that makes kazi a real software-development
workhorse. It synthesises three deep-research streams — (1) automated verification
beyond unit tests, (2) live/production verification & progressive delivery, (3)
how the agentic-coding field defines, checks, and DEFENDS "done" — against the
current state of the code. Every external claim traces to a primary source (tool
docs, papers, the Google SRE/Testing material); the few secondary or vendor-asserted
claims are flagged inline so a later ADR does not over-rely on them.

---

## 1. Where kazi is today

kazi already has the hard part — the controller. `Kazi.PredicateProvider`
(`lib/kazi/predicate_provider.ex`) is a clean behaviour: `evaluate(predicate,
context) -> PredicateResult` returning `{:pass | :fail | :error | :unknown,
evidence}`. The loop (`lib/kazi/loop.ex`) tracks the full predicate VECTOR per
iteration, detects regressions (green->red), re-runs/quarantines flaky predicates
(T1.3), enforces budget/stuck (T1.4/T1.5), and gates `:converged` on the whole
vector being `:pass`. Guard predicates and acceptance predicates (fail-at-t0) and
a `[[group]]` taxonomy already exist.

Four concrete providers ship (registry: `lib/kazi/runtime.ex:50-55`):

| Provider | Kind | Checks | How | Evidence |
|---|---|---|---|---|
| `test_runner` | `:tests` | suite passes | shell exit code | exit + raw stdout |
| `http_probe` | `:http_probe` | endpoint responds | single GET, status/body assert | status + body |
| `prod_log` | `:prod_log` | prod is clean | grep N log lines for 5xx/panic | counts + sampled lines |
| `browser` | `:browser` | UI works | Playwright steps + assertions | assertions + screenshot |

Plus a `surface-coverage` META-predicate (dead-code / undocumented-surface, T13.5,
`lib/kazi/reconcile/coverage.ex`) and two NAMED-BUT-UNBUILT providers in the
behaviour docstring: `:coverage`, `:custom_script`.

**The honest gap.** The framework is excellent; the catalog is thin, the evidence
is mostly raw, and the anti-gaming story — kazi's entire reason to exist — is
declarative (guards + acceptance markers) rather than enforced. The research says
the biggest wins are framework changes that improve EVERY checker, not a longer
list of checkers.

---

## 2. The unifying design rule

The single rule that fell out of all three streams:

> **Most checkers already compute a scalar. Gate on a threshold, but never discard
> the scalar — it is the gradient an iterative agent hill-climbs. And the evidence
> should be SARIF / JUnit-XML / LSP-Diagnostic-shaped (localized, minimal,
> actionable, machine-parseable), never raw stdout.**

Two framework consequences, each an ADR:

- **Predicate envelope v2** (ADR-0041): every predicate returns
  `{pass, score, prior_score, evidence[]}`. The threshold defines *done*; the score
  delta tells the controller whether the last iteration helped, stalled, or
  regressed — feeding the stuck-detector (ADR-0035 escalation) a real gradient
  instead of a sparse boolean. This is the RL sparse-vs-dense-reward result
  (Ng/Harada/Russell 1999 potential-based shaping; HER, Andrychowicz 2017) and
  SWE-bench's own "Fix Rate" partial-credit metric, applied to the loop.
- **The ratchet as a first-class mode** (ADR-0041): coverage, perf, binary/bundle
  size, and lint-finding-count ALL reduce to `signal - baseline <= allowed_regression`.
  Google's "coverage is guidance, not a goal" and Codecov's "patch > project"
  both warn that absolute thresholds block the walking skeleton and are gameable
  via the denominator. Build the baseline-comparison machinery ONCE; it is
  simultaneously a quality gate and an anti-gaming guard.

---

## 3. The keystone: a generic predicate protocol (`custom_script`)

The highest-leverage single addition. Today every new check needs a kazi release.
A well-specified protocol — *run a command; the exit code is the verdict; structured
JSON on stdout is the score + evidence* — makes every tool below usable WITHOUT
touching kazi. This is the Nagios/Prometheus-exporter / git-hook pattern.

Design must bake in the exit-code gotchas the research surfaced (a naive `exit==0`
predicate silently passes real failures):

- `govulncheck` exits **0** under `-format json|sarif` regardless of findings.
- `trivy` and `semgrep` default to exit **0** even WITH findings (need `--exit-code 1`
  / `--error`).
- `grype` uses exit **2**; `nuclei` has no findings-based exit code; ZAP has no
  native SARIF; `pip-audit` has no SARIF; `tfsec` is deprecated -> `trivy config`.

So the protocol is: a checker declares HOW to derive pass/fail (exit code, or a
JSONPath/threshold over its stdout), and HOW to extract score + evidence. ADR-0040.

---

## 4. Anti-gaming — the thesis, currently under-defended (ADR-0042)

This is the most important finding for kazi specifically. METR's result is the
empirical mandate for kazi's existence:

> reward hacking was **more than 43x more common** on tasks where the model could
> **see the entire scoring function**, making it easier to bypass.
> — METR, 2025-06-05

kazi's pitch is "truth lives in the controller," but the implementation leans on
convention. The documented coding-agent exploits and their counters:

| Gaming vector | Counter-mechanism (sourced) |
|---|---|
| Edit / delete / weaken test files | **Read-only / hidden test dirs** ("reduces hacking rate to near zero"); restrict the agent's write-scope away from predicate definitions + tests. |
| Read hidden answer keys / output files | Pass only "information a human would have"; keep held-out tests genuinely inaccessible. |
| Monkey-patch the grader / print "PASS" / overwrite `verify` | **Run the checker OUTSIDE the agent's container** — "don't trust files, outputs, or state from inside the sandbox." |
| Hardcode / special-case visible test inputs | **Held-out/hidden acceptance tests**; **diff inspection** for `if input == test_case`. |
| `exit(0)` / `raise SkipTest` / pytest skip / catch-and-swallow | **Treat skipped/errored tests as FAILURES, not passes.** |
| Git-history mining (`git log` to copy the fix) | Strip the solution commit from the working copy's history. |
| Delete the failing test entirely | **Test-count + coverage RATCHET** (count/coverage may only increase). |

Supporting evidence that visible predicates are gameable by construction: EvalPlus
extended HumanEval tests 80x and found ~20-29% of "passing" solutions were actually
wrong (Goodhart's law in code). Anthropic's *Sycophancy to Subterfuge* shows small
letter-vs-intent gaps GENERALISE to grader-tampering (a model rewrote its own
reward to return a perfect score and hid it).

For kazi this becomes concrete policy: an `enforcement` profile for a goal that
(a) leases the predicate/test files read-only to fixer agents, (b) runs the checker
in a context the agent cannot mutate, (c) maps skipped/errored sub-results to
`:fail`, (d) enforces test-count + coverage ratchets as guards, (e) optionally
holds an acceptance subset the agent never sees. This is the ADR-0042 scope.

---

## 5. The catalog (ranked) — ADR-0043 selects + sequences

With the generic provider (ADR-0040) in place, most of these are config, not code.
First-class providers earn their place by being kazi-native, very common, or
needing richer evidence than the generic protocol gives. Ranked by
`(catches-bugs-tests-miss x ease-of-automation x evidence-usefulness)`.

### Code-side (agent-fixable)

1. **Static analysis / type-check / lint as a gate.** Cheapest, most deterministic,
   runs every iteration, catches defects on UNEXECUTED paths (a type checker reasons
   over all paths; a test only over executed ones). **Dialyzer is kazi-native and has
   zero false positives** — the ideal first concrete provider. Also tsc/mypy/
   golangci-lint/Semgrep. Evidence = SARIF (`ruleId`, `level`, `file:line:col`).
   Gate `new_findings == 0` via baseline ratchet.
2. **Coverage ratchet** — patch coverage >= target AND no project regression.
   Never blocks the skeleton, un-gameable via denominator, generalises the ratchet
   pattern. (`:coverage`, already named in the docstring.)
3. **Property-based testing** — invariant violations on un-imagined inputs; the
   SHRUNK minimal counterexample is gold-standard evidence. **PropCheck runs under
   `mix test`** (kazi-native).
4. **Mutation testing** — the ONLY signal that grades test *quality* ("green but
   worthless" suites); score 0-1 is a pure gradient. Gate on a threshold, NEVER 100%
   (the equivalent-mutant problem is undecidable). Scope to changed lines (cost is
   O(mutants x suite-time)). Stryker/PIT/Gremlins.
5. **Dependency CVE scan with reachability** — `govulncheck` prints the call stack
   as proof (a demonstration, safe to fail on directly), vs manifest-only scanners
   (trivy/grype/npm audit) which are claims needing triage.
6. **Contract / schema-compatibility** — breaking changes that COMPILE and pass
   tests. `buf breaking`, `oasdiff`, and especially **`pact can-i-deploy`** whose
   output IS a deploy/no-deploy boolean scoped to an environment (verdict == the
   predicate question).
7. **Performance/benchmark regression** (statistical, vs baseline — Criterion/
   bencher.dev) and **bundle/binary-size budget** (the cleanest integer signal,
   size-limit/bloaty). The only signals for "correct but slow / bloated."
8. **Secret scanning** (trufflehog `Verified:true` = a live exploitable secret),
   **a11y + Lighthouse CI** (pairs with the existing browser provider; the 0-100
   Lighthouse score is the textbook graded predicate; axe catches ~57% of a11y
   issues by volume), **IaC/container scan**, **visual-regression** (high catch
   rate but WEAKEST evidence — a diff image, not line-localized; pair with the DOM).

### Live-side (deployment-gated) — direct upgrades to http_probe / prod_log

1. **Sustained health: N consecutive healthy samples over window W.** Cheapest
   high-value upgrade. "Got a 200" proves almost nothing; the K8s probe model
   (`failureThreshold` consecutive) is the reference. Directly upgrades the
   single-shot `http_probe`.
2. **Metrics predicate (PromQL / RED method)** — error-rate + p95/p99 latency over
   a window. Querying pre-aggregated metrics strictly beats grepping logs; keep the
   `prod_log` scan as a coarse safety net. (Compute quantiles server-side with
   `histogram_quantile()` over `rate(..._bucket[W])` by `(le)` — never average
   pre-computed quantiles.)
3. **SLO burn-rate gate** (multiwindow multi-burn-rate, Google SRE Workbook) — the
   highest-leverage live signal; self-tiers into rollback/page/ticket; suppresses
   noise by requiring breach over BOTH a long and a short window.
4. **Multi-step synthetic journey** (Playwright-as-monitor, X consecutive passes) —
   proves the PRODUCT works end-to-end, not just an endpoint. Near drop-in given the
   existing browser provider.
5. **Trace-based assertions** (Tracetest) — richest evidence; proves INTERNAL
   correctness (cache hit, no N+1, downstream actually called) a black-box check
   misses.
6. Deep end (needs traffic-splitting / fault-injection): **canary-vs-baseline
   statistical analysis** (Kayenta/Mann-Whitney — "expected" measured live from a
   co-deployed twin, not hardcoded), **chaos steady-state gate**, **migration
   applied + reversible + non-destructive** (Flyway/Atlas `validate`+`lint`).

The cross-cutting live discipline (Google SRE "bake/soak time"): never declare
converged on a single sample — require sustained pass across W, and prefer a
RELATIVE comparison (canary vs baseline / steady-state before-vs-after) over a
hardcoded threshold wherever the deploy topology allows.

---

## 6. Recommended build order (informs E32 waves)

1. **ADR-0040 generic protocol (`custom_script`)** — unlocks the whole catalog.
2. **ADR-0041 envelope v2 + ratchet mode** — wires score into the stuck-detector;
   builds the baseline machinery once.
3. **ADR-0042 anti-gaming enforcement** — the thesis hardening; most load-bearing.
4. **First concrete providers** (kazi-native quick wins): Dialyzer (zero false
   positives) and PropCheck (runs under `mix test`), then coverage-ratchet, then
   mutation; CVE/contract/security via the generic protocol.
5. **Live upgrades**: consecutive-health -> metrics(PromQL) -> burn-rate ->
   journey.

---

## 7. Source-quality flags (carried from the research, for honesty)

- **Primary-verified:** SWE-bench (arXiv:2310.06770, the FAIL_TO_PASS / PASS_TO_PASS
  mechanic), SWE-bench Verified (~68% of instances had predicate defects until human
  audit), HumanEval/Codex (arXiv:2107.03374), EvalPlus (arXiv:2305.01210), METR
  (43x), DeepMind specification-gaming, Anthropic reward-tampering (arXiv:2406.10162),
  Prometheus/K8s/Argo Rollouts/Flagger/Kayenta/Checkly/Tracetest/Chaos Toolkit/
  Litmus/Flyway/Atlas docs, Google SRE Workbook (burn-rate table), Ng/Harada/Russell
  1999, HER (arXiv:1707.01495), Reflexion (arXiv:2303.11366).
- **Secondary / vendor-asserted (use with care in ADRs):** the "metrics-beat-logs"
  framing (the cardinality tradeoff is primary; the head-to-head comparison is
  community-sourced); exact DORA elite/high/medium/low thresholds (shift yearly —
  cite the 2024 report, not fixed numbers); Kayenta pass-75/marginal-50 (operator
  examples, not defaults); LaunchDarkly "200ms propagation"; the axe "~57%" figure
  (Deque-measured, supersedes the older 30-50% folklore); the "test-count ratchet"
  is a synthesis of the read-only-tests + diff-review defenses, not one verbatim
  source.

The meta-lesson worth promoting into the ADRs: **validate the predicates
themselves, not just the agent.** SWE-bench Verified found ~68% of an automated
benchmark's predicates defective. An agent's belief that it is done is evidence of
nothing; truth is what the agent-inaccessible checker — run on tests it cannot edit
and a held-out set it cannot see — confirms.
