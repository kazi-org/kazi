defmodule Kazi.Predicate.Schema do
  @moduledoc """
  Self-describing config schemas for predicate-provider kinds (T32.1, ADR-0040
  decision 6) — and, additively, goal-file config BLOCKS.

  `kazi schema <name>` emits one of these so any agent can introspect the config
  keys accepted — no external docs. This covers the predicate providers
  `custom_script` (the generic command-runner whose verdict/evidence keys are
  config, not code), the `ratchet` mode (ADR-0041), the `static` analysis
  provider (T32.7, ADR-0043), the live providers `http_probe`, `browser`, and
  `metrics` (T32.10, ADR-0043), and the `cli` binary-invocation provider (T43.7,
  UC-055); plus the goal-file `integration` landing block (T44.1, ADR-0055). Other
  kinds/blocks can be added the same way.

  The descriptor is intentionally flat — a `keys` list of
  `{name, type, required, description}` rows plus an `example` object — the same
  field-table shape the result schemas (`Kazi.CLI.Schema`) and the goal-file docs
  use, so the doc and the emitted schema stay legible side by side.
  """

  @custom_script %{
    kind: "custom_script",
    title: "custom_script predicate config",
    description:
      "The generic command-runner (ADR-0040): run a declared command in the workspace and " <>
        "map its result to a verdict. The sanctioned extension point — a new verification " <>
        "kind is config, not a kazi release.",
    keys: [
      %{
        name: "cmd",
        type: "string",
        required: true,
        description: "The executable to run (ONE executable, not a command line; use args)."
      },
      %{
        name: "args",
        type: "array<string>",
        required: false,
        description: "Argument list passed to cmd. Default []."
      },
      %{
        name: "env",
        type: "table | array<pair>",
        required: false,
        description: "Extra environment as a {name = value} table or {name, value} pairs."
      },
      %{
        name: "verdict",
        type: "string",
        required: false,
        description:
          "How the result maps to a status: \"exit_zero\" (default; exit 0 -> pass), " <>
            "\"exit_code\" (map specific codes), \"json\" (gate on parsed stdout), or " <>
            "\"match_count\" (gate on a count of output lines matching a regex)."
      },
      %{
        name: "pass_codes",
        type: "array<integer>",
        required: false,
        description:
          "verdict=exit_code: exit codes that count as pass. Required for that verdict."
      },
      %{
        name: "fail_codes",
        type: "array<integer>",
        required: false,
        description:
          "verdict=exit_code: exit codes that count as fail. A code in neither list is fail."
      },
      %{
        name: "path",
        type: "string",
        required: false,
        description:
          "verdict=json: a JSONPath subset over stdout ($, .key, [index]) to the value to " <>
            "compare. A list value compares its length. Required for that verdict."
      },
      %{
        name: "match_regex",
        type: "string",
        required: false,
        description:
          "verdict=match_count: a regex marking an output line to count. Required for that " <>
            "verdict."
      },
      %{
        name: "pass_when",
        type: "string",
        required: false,
        description:
          "verdict=json or match_count: the comparison the extracted/observed number must " <>
            "satisfy to pass, \"<op> <number>\" with op one of == != < <= > >=. Required for " <>
            "those verdicts."
      },
      %{
        name: "merge_stderr",
        type: "boolean",
        required: false,
        description:
          "Fold the command's stderr into stdout so the retained output is the combined " <>
            "stream. Default false. (The test_runner/prod_log presets set it true.)"
      },
      %{
        name: "error_codes",
        type: "array<integer>",
        required: false,
        description:
          "Exit codes that mean the checker could not run -> :error (infra, not failing work), " <>
            "checked before the verdict."
      },
      %{
        name: "evidence_format",
        type: "string",
        required: false,
        description:
          "Shape evidence from a recognised envelope on stdout: \"sarif\", \"junit\", " <>
            "\"json\", or \"raw\" (default). Never changes the verdict."
      },
      %{
        name: "timeout_ms",
        type: "integer",
        required: false,
        description:
          "Kill the command after this many ms and map it to :error. Default: no timeout."
      }
    ],
    example: %{
      "id" => "no-high-severity-findings",
      "provider" => "custom_script",
      "cmd" => "semgrep",
      "args" => ["--sarif", "--config", "auto", "."],
      "verdict" => "json",
      "evidence_format" => "sarif",
      "path" => "$.runs[0].results",
      "pass_when" => "== 0"
    }
  }

  @ratchet %{
    kind: "ratchet",
    title: "ratchet predicate config",
    description:
      "The first-class ratchet mode (ADR-0041): a metric passes iff it stays within " <>
        "allowed_regression of a baseline, interpreted through direction. Coverage, perf, and " <>
        "size are configs of this one mode. Reports score = signal.",
    keys: [
      %{
        name: "metric",
        type: "table",
        required: true,
        description:
          "How to produce the signal: a table with cmd (required), args, env, path (a JSONPath " <>
            "subset over JSON stdout; absent means stdout is the number), timeout_ms."
      },
      %{
        name: "baseline",
        type: "number | string",
        required: true,
        description:
          "The bar: a number (fixed threshold), \"stored\"/\"prior\" (the metric's own last " <>
            "passing value, persisted and tightened on a pass; first run seeds it), or a git " <>
            "ref (\"HEAD~1\", \"main\": the metric recomputed at that ref)."
      },
      %{
        name: "direction",
        type: "string",
        required: true,
        description:
          "\"higher_better\" (coverage, mutation score: down is worse) or \"lower_better\" " <>
            "(size, latency, lint count: up is worse)."
      },
      %{
        name: "allowed_regression",
        type: "number",
        required: false,
        description:
          "The tolerated worsening. Default 0 — \"may only improve\" (the anti-gaming guard " <>
            "substrate, ADR-0042)."
      }
    ],
    example: %{
      "id" => "coverage-no-regression",
      "provider" => "ratchet",
      "baseline" => "stored",
      "direction" => "higher_better",
      "allowed_regression" => 0.0,
      "metric" => %{
        "cmd" => "scripts/coverage",
        "args" => ["--json"],
        "path" => "$.totals.percent"
      }
    }
  }

  @static %{
    kind: "static",
    title: "static predicate config",
    description:
      "Static analysis / type-check / lint (ADR-0043), Dialyzer-led and generalized to the " <>
        "polyglot SARIF tools. Gated on PARSED findings (not the exit code); a baseline ratchet " <>
        "fails only on NEW findings. Reports score = finding count (lower_better).",
    keys: [
      %{
        name: "cmd",
        type: "string",
        required: true,
        description: "The analyzer executable (ONE executable, not a command line; use args)."
      },
      %{
        name: "args",
        type: "array<string>",
        required: false,
        description: "Argument list passed to cmd. Default []."
      },
      %{
        name: "env",
        type: "table | array<pair>",
        required: false,
        description: "Extra environment as a {name = value} table or {name, value} pairs."
      },
      %{
        name: "format",
        type: "string",
        required: false,
        description:
          "How findings are read from stdout: \"dialyzer\" (default; Dialyzer short-format " <>
            "lines) or \"sarif\" (a SARIF log via the shared parser). A SARIF parse failure " <>
            "is :error, never a silent pass."
      },
      %{
        name: "baseline",
        type: "number | string",
        required: false,
        description:
          "Absent = the zero-findings gate (any finding fails). A number (a fixed finding " <>
            "budget), \"stored\"/\"prior\" (the finding count's own last passing value, seeded " <>
            "on the first run and tightened on a pass), or a git ref (\"HEAD~1\", \"main\": the " <>
            "analyzer re-run at that ref) selects the ratchet gate — fails only on NEW findings."
      },
      %{
        name: "allowed_regression",
        type: "number",
        required: false,
        description: "Ratchet mode: how many NEW findings are tolerated. Default 0."
      },
      %{
        name: "merge_stderr",
        type: "boolean",
        required: false,
        description: "Fold the analyzer's stderr into stdout for parsing/evidence. Default false."
      },
      %{
        name: "error_codes",
        type: "array<integer>",
        required: false,
        description:
          "Exit codes that mean the analyzer could not run -> :error (infra, not failing work), " <>
            "checked before findings are read."
      },
      %{
        name: "timeout_ms",
        type: "integer",
        required: false,
        description:
          "Kill the analyzer after this many ms and map it to :error. Default: no timeout."
      }
    ],
    example: %{
      "id" => "no-new-dialyzer-warnings",
      "provider" => "static",
      "cmd" => "mix",
      "args" => ["dialyzer", "--format", "short"],
      "format" => "dialyzer",
      "baseline" => "stored",
      "allowed_regression" => 0
    }
  }

  @http_probe %{
    kind: "http_probe",
    title: "http_probe predicate config",
    description:
      "The live HTTP probe (T0.5b, sustained-health T32.10/ADR-0043): request a URL and " <>
        "assert on the response. With samples > 1 it requires N CONSECUTIVE healthy samples " <>
        "(the K8s failureThreshold model) — never converge on a single 200.",
    keys: [
      %{name: "url", type: "string", required: true, description: "The URL to request."},
      %{
        name: "method",
        type: "string",
        required: false,
        description: "HTTP method (default \"get\")."
      },
      %{
        name: "expect_status",
        type: "integer",
        required: false,
        description: "The status the response must equal."
      },
      %{
        name: "expect_body",
        type: "string",
        required: false,
        description: "Substring (default) or exact value the body must match."
      },
      %{
        name: "body_match",
        type: "string",
        required: false,
        description: "\"contains\" (default) or \"exact\"."
      },
      %{
        name: "headers",
        type: "array<pair>",
        required: false,
        description: "Request headers as {name, value} pairs."
      },
      %{
        name: "timeout_ms",
        type: "integer",
        required: false,
        description: "Per-request timeout in ms (default 5000)."
      },
      %{
        name: "samples",
        type: "integer",
        required: false,
        description:
          "Number of CONSECUTIVE healthy samples required (default 1). With > 1, a lone " <>
            "transient 200 among failures never passes (sustained health)."
      },
      %{
        name: "interval_ms",
        type: "integer",
        required: false,
        description: "Delay between samples in ms (default 0). Only meaningful with samples > 1."
      }
    ],
    example: %{
      "id" => "healthz-sustained",
      "provider" => "http_probe",
      "url" => "https://service.example.com/healthz",
      "expect_status" => 200,
      "expect_body" => "ok",
      "samples" => 5,
      "interval_ms" => 2000
    }
  }

  @browser %{
    kind: "browser",
    title: "browser predicate config",
    description:
      "The live browser/Playwright UI check (T2.2). With samples > 1 it re-runs the journey " <>
        "as a post-deploy synthetic monitor requiring X CONSECUTIVE passes (T32.10/ADR-0043) — " <>
        "a one-off success among failures never passes.",
    keys: [
      %{name: "url", type: "string", required: true, description: "The page to open."},
      %{
        name: "viewport",
        type: "string | table | array",
        required: false,
        description:
          "Run the WHOLE journey at each width — \"mobile\" (390x844), \"tablet\" (820x1180), " <>
            "\"desktop\" (1440x900), or {width, height}; a list runs each in turn (T43.5, " <>
            "ADR-0053). Every assertion is replayed per viewport and its record names the " <>
            "width, so ANY viewport failing fails the predicate and the evidence says which. " <>
            "The whole journey (not just the assertions) reruns because layout drives " <>
            "behaviour: a nav that collapses to a burger on mobile makes a desktop click step " <>
            "miss. Absent = one journey at the browser default, unchanged."
      },
      %{
        name: "steps",
        type: "array<table>",
        required: false,
        description: "Interaction steps replayed before asserting (runner vocabulary)."
      },
      %{
        name: "assertions",
        type: "array<table>",
        required: false,
        description:
          "Checks the runner evaluates. Each table needs a \"type\"; an unknown type is a " <>
            "load error. Types: " <>
            "\"visible\" (selector) — the element is visible; " <>
            "\"hidden\" (selector) — the element is absent/hidden; " <>
            "\"text\" (selector + contains | exact) — the element's text matches; " <>
            "\"url\" (contains | exact) — the current URL matches; " <>
            "\"console_clean\" (optional network = true) — the journey produced ZERO " <>
            "console.error, and with network = true no failed 4xx/5xx response either " <>
            "(T43.1, ADR-0053). Errors are captured across the WHOLE journey (initial load " <>
            "+ every step), and `found` lists the offenders as evidence; " <>
            "\"download\" (filename_pattern + optional trigger_selector, timeout_ms) — the " <>
            "journey produced a download whose suggested filename matches the " <>
            "filename_pattern regex. With trigger_selector the runner clicks it and waits; " <>
            "without one, a download triggered by an earlier step counts (captured across " <>
            "the whole journey, like console_clean). `found` is {filename, sha256, path} — " <>
            "the sha256 makes \"the RIGHT file\" checkable, not just \"a file with the right " <>
            "name\". No download within the timeout is a real fail, not an error (T49.10, " <>
            "ADR-0064); " <>
            "\"a11y\" (optional severity, max_violations) — runs axe-core against the view " <>
            "and asserts <= max_violations (default 0) violations at or above severity " <>
            "(minor|moderate|serious|critical, default serious). `found` lists each " <>
            "violation's rule id + node; the violation COUNT is the envelope-v2 score " <>
            "(lower_better). axe-core is a runner-side optional dep — absent, the run is " <>
            ":error (\"a11y unavailable\"), never :fail (T43.2, UC-056)."
      },
      %{
        name: "samples",
        type: "integer",
        required: false,
        description:
          "Number of CONSECUTIVE passing runs required (default 1). With > 1, a synthetic " <>
            "journey monitor — a one-off success never passes."
      },
      %{
        name: "timeout_ms",
        type: "integer",
        required: false,
        description: "Per-operation timeout passed to the runner (default 30000)."
      },
      %{
        name: "screenshot",
        type: "string",
        required: false,
        description: "Path the runner writes a screenshot to."
      },
      %{
        name: "cmd",
        type: "string",
        required: false,
        description: "The runner executable (default the shipped node runner)."
      },
      %{
        name: "env",
        type: "table | array<pair>",
        required: false,
        description: "Extra environment for the runner."
      }
    ],
    example: %{
      "id" => "checkout-journey",
      "provider" => "browser",
      "url" => "https://app.example.com",
      "assertions" => [
        %{"type" => "visible", "selector" => "h1"},
        %{"type" => "console_clean", "network" => true}
      ],
      "samples" => 3
    }
  }

  @metrics %{
    kind: "metrics",
    title: "metrics predicate config",
    description:
      "The live RED/SLO metrics provider (T32.10, ADR-0043): query a Prometheus-compatible " <>
        "endpoint and gate on a windowed signal. Modes: scalar (Prometheus computes the " <>
        "number), quantile (kazi computes histogram_quantile over the bucket vector), and " <>
        "burn_rate (a multiwindow multi-burn-rate SLO gate that fires only when BOTH windows " <>
        "breach). Absent an endpoint it degrades to :unknown (not applicable), never a pass.",
    keys: [
      %{
        name: "query_url",
        type: "string",
        required: false,
        description:
          "Prometheus HTTP API base (e.g. \"https://metrics.example.com\"). Absent -> :unknown " <>
            "(not applicable)."
      },
      %{
        name: "query",
        type: "string",
        required: false,
        description: "The PromQL expression. Required for the scalar and quantile modes."
      },
      %{
        name: "pass_when",
        type: "string",
        required: false,
        description:
          "The comparison the observed number must satisfy, \"<op> <number>\" with op one of " <>
            "== != < <= > >=. Required for the scalar and quantile modes."
      },
      %{
        name: "quantile",
        type: "float",
        required: false,
        description:
          "A float in 0..1 selecting quantile mode; kazi computes histogram_quantile over the " <>
            "query's bucket vector."
      },
      %{
        name: "burn_rate",
        type: "table",
        required: false,
        description:
          "{long = promql, short = promql, threshold = number} selecting the SLO burn-rate " <>
            "gate (fails only when both windows breach)."
      },
      %{
        name: "direction",
        type: "string",
        required: false,
        description: "\"higher_better\" or \"lower_better\" (default lower_better)."
      },
      %{
        name: "window",
        type: "string",
        required: false,
        description: "Informational: the span the query speaks for (kazi does not rewrite [W])."
      },
      %{
        name: "timeout_ms",
        type: "integer",
        required: false,
        description: "HTTP request timeout in ms (default 5000)."
      }
    ],
    example: %{
      "id" => "p95-latency-under-slo",
      "provider" => "metrics",
      "query_url" => "https://metrics.example.com",
      "query" => "sum(rate(http_request_duration_seconds_bucket[5m])) by (le)",
      "quantile" => 0.95,
      "pass_when" => "<= 0.5",
      "window" => "5m"
    }
  }

  @coverage %{
    kind: "coverage",
    title: "coverage predicate config",
    description:
      "Patch coverage meets a target AND project coverage does not regress (ADR-0043): two " <>
        "Kazi.Ratchet comparisons. New code must be covered (patch vs a fixed target); the " <>
        "whole codebase's coverage may only improve (project vs a baseline). Reports score = " <>
        "patch coverage.",
    keys: [
      %{
        name: "patch",
        type: "table",
        required: true,
        description:
          "A metric table emitting the PATCH coverage % (cmd required, args, env, path, " <>
            "timeout_ms — same shape as ratchet's metric)."
      },
      %{
        name: "target",
        type: "number",
        required: true,
        description: "The patch-coverage floor (e.g. 80.0). Patch coverage below it fails."
      },
      %{
        name: "project",
        type: "table",
        required: false,
        description:
          "An optional metric table emitting TOTAL project coverage %. Present -> the project " <>
            "no-regression dimension gates too."
      },
      %{
        name: "project_baseline",
        type: "number | string",
        required: false,
        description:
          "The project bar: \"stored\"/\"prior\" (default — tightened on a pass), a git ref, " <>
            "or a number."
      },
      %{
        name: "project_allowed_regression",
        type: "number",
        required: false,
        description: "The tolerated project-coverage drop. Default 0 — \"may only improve\"."
      }
    ],
    example: %{
      "id" => "coverage",
      "provider" => "coverage",
      "target" => 80.0,
      "patch" => %{
        "cmd" => "scripts/patch-coverage",
        "args" => ["--json"],
        "path" => "$.patch.percent"
      },
      "project" => %{
        "cmd" => "scripts/coverage",
        "args" => ["--json"],
        "path" => "$.totals.percent"
      },
      "project_baseline" => "stored"
    }
  }

  @property %{
    kind: "property",
    title: "property predicate config",
    description:
      "Property-based testing, PropCheck under `mix test` (ADR-0043). Score = cases-passed / " <>
        "N (higher_better); the SHRUNK counterexample is the evidence on a failure. The " <>
        "verdict is read from the parsed PropEr summary, not the exit code alone.",
    keys: [
      %{
        name: "cmd",
        type: "string",
        required: false,
        description: "The executable. Default \"mix\"."
      },
      %{
        name: "args",
        type: "array<string>",
        required: false,
        description: "Argument list. Default [\"test\"]."
      },
      %{
        name: "env",
        type: "table | array<pair>",
        required: false,
        description: "Extra environment as a {name = value} table or {name, value} pairs."
      },
      %{
        name: "num_tests",
        type: "integer",
        required: false,
        description:
          "N — the generated cases per property, the score DENOMINATOR. Default 100 " <>
            "(PropCheck's own default). Must be a positive integer."
      },
      %{
        name: "merge_stderr",
        type: "boolean",
        required: false,
        description:
          "Fold stderr into stdout for the parsed output. Default true (the combined stream " <>
            "is what a developer reads)."
      },
      %{
        name: "timeout_ms",
        type: "integer",
        required: false,
        description: "Kill the run after this many ms and map it to :error. Default: no timeout."
      }
    ],
    example: %{
      "id" => "encode-decode-roundtrips",
      "provider" => "property",
      "cmd" => "mix",
      "args" => ["test", "--only", "property"],
      "num_tests" => 100
    }
  }

  @mutation %{
    kind: "mutation",
    title: "mutation predicate config",
    description:
      "Mutation testing — the test-QUALITY signal (ADR-0043). A 0-1 score (killed / total) " <>
        "gated on a threshold that is NEVER 100% (rejected at load). Surviving mutants are " <>
        "the evidence. Gated on the parsed score, not the exit code. Scope to changed lines " <>
        "via the tool's own flags in args.",
    keys: [
      %{
        name: "cmd",
        type: "string",
        required: true,
        description: "The executable (ONE executable, not a command line; use args)."
      },
      %{
        name: "args",
        type: "array<string>",
        required: false,
        description:
          "Argument list. Default []. Put the diff-scoping flag (e.g. --diff/--since) here."
      },
      %{
        name: "env",
        type: "table | array<pair>",
        required: false,
        description: "Extra environment as a {name = value} table or {name, value} pairs."
      },
      %{
        name: "threshold",
        type: "number",
        required: true,
        description: "The 0-1 score floor the run must meet. Must be >= 0 AND < 1.0 (never 100%)."
      },
      %{
        name: "score_path",
        type: "string",
        required: false,
        description:
          "A JSONPath over stdout to a PRECOMPUTED 0-1 score. Use when the tool reports a ratio."
      },
      %{
        name: "killed_path",
        type: "string",
        required: false,
        description:
          "A JSONPath to the killed COUNT. With survived_path the score is " <>
            "killed / (killed + survived). Use instead of score_path."
      },
      %{
        name: "survived_path",
        type: "string",
        required: false,
        description: "A JSONPath to the survived COUNT (pairs with killed_path)."
      },
      %{
        name: "survivors_path",
        type: "string",
        required: false,
        description: "A JSONPath to the surviving-mutant list, surfaced (bounded) as evidence."
      },
      %{
        name: "merge_stderr",
        type: "boolean",
        required: false,
        description: "Fold stderr into stdout for the parsed output. Default false."
      },
      %{
        name: "timeout_ms",
        type: "integer",
        required: false,
        description: "Kill the command after this many ms and map it to :error. Default: none."
      }
    ],
    example: %{
      "id" => "mutation-score",
      "provider" => "mutation",
      "cmd" => "mix",
      "args" => ["muzak", "--diff", "--format", "json"],
      "threshold" => 0.8,
      "killed_path" => "$.summary.killed",
      "survived_path" => "$.summary.survived",
      "survivors_path" => "$.survivors"
    }
  }

  @cve %{
    kind: "cve",
    title: "cve predicate config",
    description:
      "Dependency vulnerability scanning (ADR-0043), led by govulncheck REACHABILITY: fail on " <>
        "a transitively-called vuln with the call stack as proof (tier 1). trivy/grype/npm_audit " <>
        "are manifest-only (tier 2), ratcheted vs a baseline. Gated on the PARSED output, NEVER " <>
        "the exit code (govulncheck -json exits 0 even with vulns).",
    keys: [
      %{
        name: "tool",
        type: "string",
        required: false,
        description:
          "\"govulncheck\" (default, tier-1 reachability), \"trivy\", \"grype\", or " <>
            "\"npm_audit\" (tier-2 manifest, ratcheted)."
      },
      %{
        name: "cmd",
        type: "string",
        required: false,
        description: "The executable. Default: the tool's binary (npm for npm_audit)."
      },
      %{
        name: "args",
        type: "array<string>",
        required: false,
        description: "Argument list. Default: the tool's JSON-output invocation."
      },
      %{
        name: "env",
        type: "table | array<pair>",
        required: false,
        description: "Extra environment as a {name = value} table or {name, value} pairs."
      },
      %{
        name: "count_path",
        type: "string",
        required: false,
        description:
          "tier 2 (trivy/grype/npm_audit): a JSONPath to the vulnerability COUNT to ratchet. " <>
            "Required for the manifest tools."
      },
      %{
        name: "baseline",
        type: "number | string",
        required: false,
        description:
          "tier 2: the bar — a number (allowed max count) or \"stored\"/\"prior\" (the last " <>
            "passing count, tightened on a pass; first run seeds it). Default 0."
      },
      %{
        name: "allowed_regression",
        type: "number",
        required: false,
        description: "tier 2: the tolerated increase over baseline. Default 0."
      },
      %{
        name: "timeout_ms",
        type: "integer",
        required: false,
        description: "Kill the command after this many ms and map it to :error. Default: none."
      }
    ],
    example: %{
      "id" => "no-reachable-cves",
      "provider" => "cve",
      "tool" => "govulncheck",
      "args" => ["-json", "./..."]
    }
  }

  @no_stubs %{
    kind: "no_stubs",
    title: "no_stubs predicate config",
    description:
      "A deterministic diff scanner (T44.6): FAIL when the goal's diff-vs-base introduces a " <>
        "stub/placeholder/hardcoded-return marker (stub, mock, fake, dummy, placeholder, todo, " <>
        "fixme, notimplemented) on an ADDED line in a NON-TEST file. Productizes the zero-stub " <>
        "policy as a real predicate. Only added lines and only production files count (test " <>
        "files are exempt); a clean diff passes, a hit fails with file:line evidence.",
    keys: [
      %{
        name: "patterns",
        type: "array<string>",
        required: false,
        description:
          "The stub markers to scan for (case-insensitive). Default: stub, mock, fake, dummy, " <>
            "placeholder, todo, fixme, notimplemented."
      },
      %{
        name: "base",
        type: "string",
        required: false,
        description:
          "The base ref to diff against. Default: the merge-base with origin/main, else the " <>
            "repo root commit, else the empty tree."
      },
      %{
        name: "exclude",
        type: "array<string>",
        required: false,
        description:
          "Extra path PREFIXES to exempt beyond the built-in test-file rule (a path under a " <>
            "test/ directory or a _test.ex(s) file is always exempt). Default: none."
      }
    ],
    example: %{
      "id" => "no-stubs",
      "provider" => "no_stubs"
    }
  }

  @integration %{
    kind: "integration",
    title: "[integration] goal-file block",
    description:
      "How converged work LANDS (T44.1, ADR-0055): a goal-file `[integration]` table (NOT a " <>
        "predicate provider). Absent, or mode = \"none\", is converge-and-stop with no landing " <>
        "— byte-identical to a goal-file with no block. mode commit/branch/pr/merge land " <>
        "progressively further. This block is parsed/validated/exposed here; the synthesized " <>
        "`landed` predicate and the landing actions that consume it are later tasks.",
    keys: [
      %{
        name: "mode",
        type: "string",
        required: false,
        description:
          "How far work lands: \"none\" (default; converge-and-stop, no landing), \"commit\" " <>
            "(committed on a non-base branch), \"branch\" (pushed), \"pr\" (pushed AND a PR is " <>
            "open against base), or \"merge\" (PR rebase-merged — never squash, never a merge " <>
            "commit). An unknown mode is a load error."
      },
      %{
        name: "branch",
        type: "string",
        required: false,
        description:
          "The goal's REAL target branch the run's worktree checks out onto (T54.1, #1079/#1080). " <>
            "Stored verbatim; absent → derived \"task/<sanitized id>\", so a `landed` predicate " <>
            "naming that branch can converge."
      },
      %{
        name: "branch_prefix",
        type: "string",
        required: false,
        description:
          "Prefix for the landing branch name. Stored verbatim; the landing machinery applies " <>
            "its own default (\"kazi/\") when absent."
      },
      %{
        name: "base",
        type: "string",
        required: false,
        description:
          "The base branch a pr/merge targets. Stored verbatim; absent → detected from origin " <>
            "at landing time."
      },
      %{
        name: "commit_style",
        type: "string",
        required: false,
        description: "Informational commit-style hint (e.g. \"conventional\"). Stored verbatim."
      }
    ],
    example: %{
      "mode" => "pr",
      "branch" => "task/ship-widgets",
      "branch_prefix" => "kazi/",
      "base" => "main",
      "commit_style" => "conventional"
    }
  }

  @cli %{
    kind: "cli",
    title: "cli predicate config",
    description:
      "A golden invocation of a SHIPPED binary (T43.7, UC-055): run a declared command and " <>
        "assert on the exit code + stdout/stderr — the observable surface `mix test` never " <>
        "exercises (a packaged binary that crashes on its first CLI call). A binary that cannot " <>
        "launch is :error; a violated assertion is :fail. Score = assertions passed " <>
        "(higher_better).",
    keys: [
      %{
        name: "cmd",
        type: "string",
        required: true,
        description:
          "The executable (ONE executable, not a command line; use args). A name with a \"/\" " <>
            "resolves against the workspace; a bare name is a PATH lookup. Unresolvable -> :error."
      },
      %{
        name: "args",
        type: "array<string>",
        required: false,
        description: "Argument list passed to cmd. Default []."
      },
      %{
        name: "env",
        type: "table | array<pair>",
        required: false,
        description: "Extra environment as a {name = value} table or {name, value} pairs."
      },
      %{
        name: "timeout_ms",
        type: "integer",
        required: false,
        description:
          "Kill the command after this many ms and map it to :error. Default: no timeout."
      },
      %{
        name: "assertions",
        type: "array<table>",
        required: true,
        description:
          "A NON-EMPTY list of checks (an empty list is a load error). Each needs a \"target\": " <>
            "\"exit_code\" (\"expected\" = the integer the exit code must equal); or \"stdout\" / " <>
            "\"stderr\" with a \"match\" over that stream — \"equals\" (whole-stream equality), " <>
            "\"contains\" (substring), \"regex\" (the stream matches \"expected\"), or " <>
            "\"json_path\" (parse the stream as JSON, extract \"path\", compare to \"expected\"). " <>
            "\"expected\" carries the operand; \"json_path\" also needs \"path\" (a $/.key/[i] " <>
            "subset). A violated assertion is :fail with expected-vs-found evidence."
      }
    ],
    example: %{
      "id" => "kazi-version-runs",
      "provider" => "cli",
      "cmd" => "kazi",
      "args" => ["version"],
      "assertions" => [
        %{"target" => "exit_code", "expected" => 0},
        %{"target" => "stdout", "match" => "contains", "expected" => "kazi"},
        %{"target" => "stderr", "match" => "equals", "expected" => ""}
      ]
    }
  }

  @scenario %{
    kind: "scenario",
    title: "scenario predicate config",
    description:
      "Replay a pinned Gherkin Scenario by DELEGATING to a surface provider (T49.3, ADR-0064). " <>
        "Binds one Scenario in a .feature spec to a committed pin; passes only when the pin " <>
        "validates AND replays green through the surface provider. An unpinned/stale/invalid " <>
        "pin is failing work (:fail), never an error. Keys beyond those below pass through " <>
        "unchanged to the delegate (so its url/cmd/samples config works as authored directly).",
    keys: [
      %{
        name: "spec",
        type: "string",
        required: true,
        description: "Path to the .feature file holding the Scenario."
      },
      %{
        name: "scenario",
        type: "string",
        required: true,
        description: "The Scenario name to bind and replay."
      },
      %{
        name: "surface",
        type: "string",
        required: false,
        description:
          "Which surface provider replays the pin's trace: \"browser\" (default) or \"cli\"."
      },
      %{
        name: "pin",
        type: "string",
        required: false,
        description:
          "Path to the pin artifact. Defaults to docs/specs/pins/<derived-id>.pin.json."
      },
      %{
        name: "repin",
        type: "string",
        required: false,
        description: "Re-mint policy: \"auto\" (default) or \"manual\" (consumed by minting)."
      }
    ],
    example: %{
      "id" => "pat-create-download",
      "provider" => "scenario",
      "spec" => "docs/specs/pat.feature",
      "scenario" => "User can create and download a PAT",
      "surface" => "browser"
    }
  }

  @schemas %{
    "cli" => @cli,
    "custom_script" => @custom_script,
    "ratchet" => @ratchet,
    "static" => @static,
    "http_probe" => @http_probe,
    "browser" => @browser,
    "metrics" => @metrics,
    "coverage" => @coverage,
    "property" => @property,
    "mutation" => @mutation,
    "cve" => @cve,
    "no_stubs" => @no_stubs,
    "integration" => @integration,
    "scenario" => @scenario
  }

  @doc "The provider kinds with a documented config schema, sorted."
  @spec kinds() :: [String.t()]
  def kinds, do: @schemas |> Map.keys() |> Enum.sort()

  @doc """
  Fetch one provider kind's config schema. Returns `{:ok, schema}` or `:error`
  for a kind with no documented schema.
  """
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(kind), do: Map.fetch(@schemas, kind)
end
