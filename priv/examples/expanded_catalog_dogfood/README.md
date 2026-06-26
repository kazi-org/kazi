# Expanded predicate-catalog dogfood fixture (T32.11)

A self-contained, reproducible fixture that exercises the E32 predicate framework
end-to-end: a creation-mode goal whose new-kind predicates start **RED** at t0 and
converge to objective-true under active anti-gaming enforcement.

It drives four of the five new-kind predicates from a single coding-agent loop:

| Predicate | Provider | t0 (RED) | Converged | What the agent does |
|-----------|----------|----------|-----------|---------------------|
| `no-unsafe-eval` | `:static` (SARIF) | 1 finding | 0 findings | remove `eval(` from `src/stats.py` |
| `coverage` | `:coverage` ratchet | 20% | 100% | add `test_<fn>` for every function |
| `mutation-score` | `:mutation` | 0.2 | 1.0 (≥0.8) | add assertions (threshold is **not** 100%) |
| `no-vulnerable-deps` | `:cve` (manifest tier) | 1 vuln | 0 vulns | bump `requests` off 2.19.x |

The fifth kind, the **sustained-health** `http_probe` (T32.10), needs a running
service, so it is demonstrated separately (see `docs/devlog.md`, the T32.11 entry).

## The graders

The checks under `checks/` are deterministic stand-ins for the real tools
(Dialyzer/coverage/mutation-tester/trivy) so the fixture runs offline and
reproducibly. They observe **real workspace state**, so a real coding agent
converges them by editing `src/`, `tests/`, and `requirements.txt` — the framework
(provider gating, the envelope-v2 score gradient, the ratchets, enforcement) is
what is under test, and the providers are generic command-runners by design
(ADR-0040). Swap any `cmd` for the real tool to run it for real.

> **Grader invocation:** the graders are invoked as `cmd = "bash", args =
> ["checks/<x>.sh"]`, not as a bare relative `cmd`. A relative executable `cmd`
> is resolved against the launcher's cwd, not `--workspace`, and fails with
> `:enoent`; a PATH-resolvable `cmd` (`bash`) with the script in `args` runs in
> the workspace correctly.

## Enforcement (ADR-0042)

`mode = "create"` makes enforcement default-on. The `[enforcement]` block adds
`clean_tree` + `separate_process` isolation, `fail_on_skip`, a `read_only_paths`
lease over `checks/` (a write to a grader is a flagged event), and a test-count
ratchet guard (the suite may only grow).

## Run it

```sh
# from a git checkout of THIS directory (clean_tree needs a git workspace):
ws=$(mktemp -d) && cp -R . "$ws" && (cd "$ws" && git init -q && git add -A && git commit -qm seed)
kazi apply "$ws/kazi.goal.toml" --workspace "$ws" --harness claude --json
```
