# ADR 0040: A generic predicate protocol (`custom_script`) — the extensibility keystone

## Status
Accepted

## Date
2026-06-24

## Refines
ADR-0002 (the goal contract: a predicate is provided by a pluggable provider that
returns `{pass|fail, evidence}`). This ADR makes "pluggable" real for USERS, not
just for kazi maintainers: it adds a provider that runs an arbitrary external
checker, so a new kind of verification no longer requires a kazi release. It also
UNIFIES the existing command-runner providers (`test_runner`, `prod_log`) onto this
one engine and deprecates their bespoke names (operator decision, 2026-06-24).

## Context

kazi ships four hard-coded providers (`test_runner`, `http_probe`, `prod_log`,
`browser`) and names two more in the behaviour docstring (`:coverage`,
`:custom_script`). Every new check today is an Elixir module + a release. The
research note (`docs/research/predicate-verification-landscape.md`) finds the
single highest-leverage addition is the escape hatch: a generic provider that
turns any CLI tool — mutation testers, fuzzers, `buf breaking`, `govulncheck`,
`checkov`, Lighthouse CI, `pact can-i-deploy` — into a kazi predicate WITHOUT
touching kazi. This is the Nagios/Prometheus-exporter / git-hook pattern.

The hazard the research surfaced is that a naive "exit code 0 == pass" is wrong for
common tools, and silently passes real failures:

- `govulncheck` exits **0** under `-format json|sarif` regardless of findings.
- `trivy` / `semgrep` default to exit **0** even WITH findings (need `--exit-code 1`
  / `--error`).
- `grype` uses exit **2**; `nuclei` has no findings-based exit code; `pip-audit`
  emits no SARIF; `tfsec` is deprecated (`trivy config`).

So the protocol must let a checker declare HOW its verdict and evidence are derived,
and must default safely.

## Decision

1. **`custom_script` is THE command-runner; the bespoke runners fold into it.**
   Add a `custom_script` provider (`:custom_script`) that runs a user-declared command
   in the workspace and maps its result to a `PredicateResult` — the sanctioned
   extension point (new verification kinds are CONFIG, not code). The two existing
   command-runner providers become thin PRESETS over this one engine: `test_runner` ==
   `custom_script` with `verdict = "exit_zero"` + JUnit evidence; `prod_log` ==
   `custom_script` with a regex-match-count verdict over the command's output. One
   engine, shared verdict/evidence logic. (`http_probe` and `browser` are NOT
   command-runners — they keep their own contracts and are out of scope.)

2. **Verdict is explicitly declared, not assumed.** A predicate declares one of:
   `verdict = "exit_zero"` (default: exit 0 -> pass), `verdict = "exit_code"` with
   an explicit pass/fail code map, or `verdict = "json"` with a JSONPath + comparison
   over the checker's stdout (e.g. `path = "$.summary.failures"`, `pass_when = "== 0"`).
   This defuses the exit-code gotchas above — a SARIF-emitting tool that always
   exits 0 is gated on its parsed findings, not its exit code.

3. **Evidence is extracted, not dumped.** The provider parses recognised envelopes —
   **SARIF**, **JUnit XML**, or a kazi-native JSON shape — into structured evidence
   items (`{file, line, col, rule, level, message}`). Raw stdout is retained only as
   a truncated fallback when no envelope is declared. (Envelope shaping is shared with
   ADR-0041.)

4. **Score is optional and forwarded.** If the checker emits a scalar (a JSONPath to
   a number, e.g. mutation score), the provider populates `score`/`prior_score`
   (ADR-0041). Absent a scalar, the predicate is boolean — `score` is `nil`.

5. **`:error` vs `:fail` is preserved.** A non-zero exit that means "the checker
   could not run" (missing binary, bad config) maps to `:error` (infra, not work),
   distinct from a genuine `:fail`. The predicate declares which exit codes / parse
   failures are `:error` so a broken evidence pipeline is never read as a pass — the
   same lesson Argo Rollouts encodes by separating `failureLimit` from
   `consecutiveErrorLimit`.

6. **The contract is documented + self-described.** `kazi schema custom_script` and
   the goal-file docs specify the keys (`cmd`, `args`, `verdict`, `path`, `pass_when`,
   `evidence_format`, `error_codes`, `timeout_ms`). A worked example per envelope
   (SARIF via Semgrep, JUnit via a test runner, JSON via a mutation tester) ships in
   `priv/examples`.

7. **`test_runner` / `prod_log` are DEPRECATED with a migration window, removed in
   v2.0.0.** During the window both names keep working (as the presets in decision 1)
   and emit a one-line deprecation hint to STDERR (never into `--json` stdout); the
   loader rewrites them to the unified provider. `docs/deprecations.md` + the CHANGELOG
   record the aliases, the migration (a near-mechanical goal-file edit), and the
   removal target. The unification + deprecation ships NON-BREAKING (a minor bump — the
   aliases still resolve); the actual REMOVAL of the names is the breaking change,
   scheduled for the next major (v2.0.0), mirroring the run/propose -> v1.0.0 pattern.
   This avoids forcing a v2.0.0 now (the 0.x/1.x landmine: the next breaking commit
   auto-bumps the major).

## Consequences

- The catalog in the research note (ADR-0043) becomes mostly reachable as config:
  security, contract, coverage, mutation, perf, a11y all slot in without a kazi
  release. First-class providers are then reserved for kazi-native or
  richer-evidence cases (ADR-0043 decides which).
- The exit-code gotchas are encoded as checker config, not assumptions — the class
  of "the gate silently passed" bug is designed out.
- Risk: a too-generic provider becomes a footgun (users mis-declare a verdict and
  pass a real failure). Mitigated by safe defaults, the `:error` distinction, and
  shipped examples; the verdict declaration is explicit precisely so the failure
  mode is visible.
- Risk: arbitrary command execution widens the trust surface. Acceptable — kazi
  already runs `test_runner`/`prod_log` commands from the goal file; the goal file
  is already trusted input. The anti-gaming context (ADR-0042) governs WHERE the
  checker runs relative to the fixer agent.

## Alternatives rejected

- **Keep adding hard-coded providers per tool.** Couples every check to the release
  cycle; never catches up with the long tail. The generic provider is the point.
- **Add `custom_script` alongside, keep `test_runner`/`prod_log` first-class forever.**
  Least churn, but leaves two ways to "run a command" and duplicated verdict/evidence
  logic. Rejected in favour of one engine (operator decision 2026-06-24).
- **Refactor onto a shared core but keep the bespoke names permanently as presets.**
  The middle option; rejected because the operator chose full unification — the names
  are deprecated, not kept indefinitely. (The presets exist only for the migration
  window, decision 7.)
- **Exit-code-only contract (`exit==0`).** Simpler but wrong for the most common
  security/contract tools (they exit 0 with findings). Rejected as the default; kept
  as the opt-in `verdict = "exit_zero"` mode.
- **A plugin system loading user Elixir/BEAM code.** Heavier, language-locked, and a
  bigger trust surface than a subprocess boundary — and contradicts ADR-0008's thin
  stateless subprocess philosophy. The subprocess + structured-stdout contract is
  the lighter, language-agnostic equivalent.
