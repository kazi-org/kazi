# The `swift_test` predicate

`swift_test` (issue #1406) is kazi's Swift/XCTest gate — it reads a suite's
verdict from the structured summary Xcode writes to an `.xcresult` bundle
instead of trusting the test runner's exit code.

`xcodebuild test` exits non-zero on any failing test, which a plain
`custom_script`/`test_runner` exit-code check already covers. What it can't tell
you is *which* test failed and why, and it can't catch the false-pass shape
where a broken scheme runs **zero tests** and still exits `0`. `swift_test`
parses the bundle instead:

```
xcrun xcresulttool get test-results summary --format json --path <bundle>
```

Introspect every key at runtime with:

```
kazi schema swift_test
```

## Gated on the parsed summary, not the exit code

`xcresulttool` exits `0` whether the underlying suite passed or failed — it is
reporting a summary, not re-running the tests. kazi reads the **parsed**
`totalTestCount` / `passedTests` / `failedTests` counts instead (the same
exit-code gotcha `cve`/`mutation` design around, see `docs/mutation-predicate.md`).

## Zero tests run is a failure, not a pass

A scheme that ran **no tests** is broken configuration (a bad target, an unbuilt
test bundle) — not a green suite. `totalTestCount == 0` is `:fail` with
`reason: zero_tests`, never a silent pass.

## An unrecognized summary schema is `:unknown`

`xcresulttool get test-results summary` is Xcode 16+ only. When the parsed JSON
is missing `totalTestCount`/`passedTests`/`failedTests` — an older or unfamiliar
schema — the result is honestly `:unknown` rather than a guessed pass or fail.

## Config keys

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `xcresult_path` | string | yes | Path to the `.xcresult` bundle a prior test run produced. |
| `cmd` | string | no | The executable that emits the summary JSON. Default `xcrun`. |
| `args` | array of strings | no | Argument list. Default `["xcresulttool", "get", "test-results", "summary", "--format", "json", "--path", xcresult_path]`. Overrides the default entirely. |
| `env` | table / pairs | no | Extra environment. |
| `merge_stderr` | boolean | no | Fold stderr into stdout. Default `false` (keeps the summary JSON clean). |
| `timeout_ms` | integer | no | Kill the run after this many ms → `:error`. |

## Example

```toml
[[predicate]]
id = "swift-suite-green"
provider = "swift_test"
acceptance = true
xcresult_path = "TestResults.xcresult"
```

Run the suite into that bundle path before evaluating the goal, e.g. via a
`custom_script` step or the harness's own build command:

```sh
xcodebuild test -scheme MyApp -resultBundlePath TestResults.xcresult
```

## Evidence

Every result carries the resolved `cmd`, `args`, `workspace`, `xcresult_path`,
the `exit` code, and a truncated `output`. A parsed summary adds `total_tests`,
`passed_tests`, `failed_tests`, `skipped_tests`, `expected_failures`, a bounded
`failures` list, and the raw `result` string. Each entry in `failures` is also
surfaced as a `Kazi.Evidence` diagnostic. An `:error` carries a `reason`.
