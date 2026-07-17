defmodule Kazi.Providers.CustomScript do
  @moduledoc """
  The `:custom_script` predicate provider (T32.1, ADR-0040): the GENERIC
  command-runner. It runs a user-declared command in the target workspace and
  maps the result to a `Kazi.PredicateResult` via a DECLARED verdict — the
  sanctioned extension point that turns any CLI checker (a mutation tester, a
  SARIF-emitting scanner, a contract checker) into a kazi predicate WITHOUT a
  kazi release (concept §3, ADR-0002, ADR-0040).

  The hazard ADR-0040 designs out is the naive "exit 0 == pass": common security
  and contract tools exit `0` *with* findings (`govulncheck`/`semgrep`/`trivy`
  under JSON/SARIF output). So the verdict is DECLARED, never assumed, and the
  provider distinguishes a genuine `:fail` from an `:error` (the checker could not
  run) so a broken evidence pipeline is never read as a pass.

  ## Config

  The predicate's `config` map carries the command and the verdict declaration:

    * `:cmd`  — the executable (string). Required. Like `Kazi.Providers.TestRunner`,
      this is ONE executable, not a command line (`cmd: "semgrep"`, not
      `cmd: "semgrep scan"`); use `:args` for the rest (docs/lore.md L-0012).
      Resolved with shell semantics: a `:cmd` that NAMES A PATH (contains a `/`)
      resolves against the workspace, so a checker committed in the tree it grades
      (`cmd: "scripts/chk.sh"`) just works; a bare name (`cmd: "semgrep"`) is
      looked up on `PATH`. A path that does not resolve to an executable file is
      left as written, so a typo surfaces as an `:error` naming what was tried,
      never a silent pass.
    * `:args` — argument list (list of strings). Optional, defaults to `[]`.
    * `:env`  — extra environment, a `{name, value}` list or a `{name => value}`
      map. Optional.
    * `:verdict` — how the result maps to a status. One of:
      * `"exit_zero"` (the default) — exit `0` is `:pass`; any other exit is
        `:fail`. The safe baseline for a tool whose exit code already means
        pass/fail (e.g. a test runner).
      * `"exit_code"` — map specific exit codes. `:pass_codes` (a non-empty list
        of integers) are `:pass`; `:fail_codes` (an optional list) are `:fail`;
        any code in neither list is `:fail` (a gate never passes an undeclared
        code). Use for a tool whose "findings" exit code is not `1`
        (e.g. `grype` exits `2`).
      * `"json"` — parse stdout as JSON, extract the value at `:path`, and compare
        it via `:pass_when`. This gates a tool on its PARSED output, not its exit
        code — so a SARIF scanner that always exits `0` is failed on its findings
        count. A JSON parse failure or a missing path is an `:error`, never a
        silent pass.
      * `"match_count"` — count the lines of the command's output that match
        `:match_regex` and compare that COUNT via `:pass_when`. This gates a tool
        on the textual signal in its output rather than its exit code (e.g. "no
        `panic` lines", "at most 2 deprecation warnings"). It is the verdict the
        `:prod_log` preset specialises (T32.1b, ADR-0040 decision 1). An invalid
        `:match_regex` or `:pass_when` is an `:error`, never a silent pass.
    * `:match_regex` — for the `"match_count"` verdict: a regex (string) marking a
      line to count. Required for that verdict.
    * `:path` — for the `"json"` verdict: a JSONPath over the parsed stdout. A
      focused subset is supported: a leading `$`, `.key` segments, and `[index]`
      array subscripts (e.g. `"$.runs[0].results"`, `"$.summary.failures"`). The
      extracted value is coerced to a number for comparison: a number is used
      verbatim; a LIST uses its length (so `path` pointing at a findings array
      compares its COUNT).
    * `:pass_when` — for the `"json"` and `"match_count"` verdicts: a comparison
      the extracted/observed number must satisfy to `:pass`, written
      `"<op> <number>"` where `<op>` is one of `== != < <= > >=` (e.g. `"== 0"`,
      `">= 0.8"`, `"<= 5"`).
    * `:merge_stderr` — when `true`, capture the command's stderr INTO its stdout
      (`stderr_to_stdout: true`), so the retained `:output` is the same combined
      stream a developer reads. Optional, defaults `false` (stdout and stderr are
      separate). The `:tests`/`:prod_log` presets set it `true` to preserve their
      historical combined-stream evidence.
    * `:error_codes` — a list of exit codes that mean the checker COULD NOT RUN
      (bad config, missing dependency), mapped to `:error` (infra, not failing
      work) BEFORE the verdict is applied. Optional.
    * `:evidence_format` — shape the evidence from a recognised envelope on stdout.
      One of `"sarif"`, `"junit"`, `"json"`, or `"raw"` (the default). `"sarif"`
      and `"junit"` extract structured `:findings`; `"json"`/`"raw"` keep only the
      (truncated) raw output. Evidence extraction NEVER changes the verdict.
    * `:timeout_ms` — kill the command after this many milliseconds and map it to
      `:error` (the checker did not complete in time). Optional; absent means no
      timeout.

  ## Context

  `context[:workspace]` is the directory the command runs in (`cd:`), so a
  relative-path checker resolves against the same tree the harness edits. Defaults
  to the current directory when absent (mirrors `Kazi.Providers.TestRunner`).

  ## Evidence

  Every result carries the proof a fixer agent needs (ADR-0002): the resolved
  `:cmd`, `:args`, `:workspace`, the `:verdict`, and on a completed run the `:exit`
  code and a truncated `:output`. A `"json"` verdict adds the resolved `:path`,
  `:pass_when`, and the `:observed` number. A `"match_count"` verdict adds the
  resolved `:match_regex`, `:pass_when`, the `:observed` count, and a bounded
  sample of the `:matched_lines`. An `:evidence_format` of `"sarif"` / `"junit"`
  adds structured `:findings`. An `:error` result carries a `:reason`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.CommandRunner

  # Keep the retained raw output seed-sized: enough to orient a fixer, not a full
  # dump (ADR-0040 decision 3 — raw stdout is a truncated fallback).
  @output_limit 4_000

  # The declared verdict strings, mapped to their internal evaluators.
  @verdicts ~w(exit_zero exit_code json match_count)

  # Keep the retained match sample seed-sized: enough lines to orient a fixer, not
  # a full dump (mirrors the prod_log preset's sample budget).
  @match_sample_limit 20

  # The recognised evidence envelopes for :evidence_format.
  @evidence_formats ~w(sarif junit json raw)

  # A pass_when comparison: an operator and a numeric operand.
  @pass_when_re ~r/^\s*(==|!=|<=|>=|<|>)\s*(-?\d+(?:\.\d+)?)\s*$/

  @doc "The verdict strings this provider accepts."
  @spec verdicts() :: [String.t()]
  def verdicts, do: @verdicts

  @doc "The `:evidence_format` envelopes this provider accepts."
  @spec evidence_formats() :: [String.t()]
  def evidence_formats, do: @evidence_formats

  @impl true
  def evaluate(%Predicate{kind: :custom_script, config: config}, context) do
    evaluate_config(config, context)
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  @doc """
  Evaluate a custom_script-shaped `config` against `context`, the shared engine the
  `:tests`/`:prod_log` presets delegate to (T32.1b, ADR-0040 decision 1).

  Exposed so a preset can build its config (e.g. `verdict: "exit_zero"`) and run it
  through the one engine without constructing a `:custom_script` `Kazi.Predicate`.
  """
  @spec evaluate_config(map(), map()) :: PredicateResult.t()
  def evaluate_config(config, context) when is_map(config) do
    workspace = context[:workspace] || File.cwd!()

    with {:ok, cmd, args} <- fetch_cmd(config),
         {:ok, verdict} <- fetch_verdict(config) do
      run(cmd, args, workspace, config, verdict)
    else
      {:error, reason} -> PredicateResult.error(%{reason: reason, workspace: workspace})
    end
  end

  # Resolve the command, rejecting a missing/blank :cmd before we ever shell out
  # so a malformed predicate is an :error, not a crash (mirrors TestRunner).
  defp fetch_cmd(config) do
    case config[:cmd] do
      cmd when is_binary(cmd) and cmd != "" ->
        {:ok, cmd, List.wrap(config[:args] || [])}

      nil ->
        {:error, :missing_cmd}

      other ->
        {:error, {:invalid_cmd, other}}
    end
  end

  # Resolve the declared verdict, defaulting to "exit_zero" (the safe baseline).
  # An unknown verdict is a config error surfaced before any work runs.
  defp fetch_verdict(config) do
    case Map.get(config, :verdict, "exit_zero") do
      v when v in @verdicts -> {:ok, v}
      other -> {:error, {:unknown_verdict, other}}
    end
  end

  # Run the command in the workspace, then map exit/output to a result. The
  # declared :error_codes are checked FIRST (the checker could not run), so a
  # broken evidence pipeline is never read as a pass; otherwise the verdict
  # decides. A missing binary / bad cwd is mapped to :error, never :fail.
  defp run(cmd, args, workspace, config, verdict) do
    cmd = resolve_cmd(cmd, workspace)
    opts = [cd: workspace, stderr_to_stdout: merge_stderr?(config)] ++ env_opt(config)

    case CommandRunner.run(cmd, args, opts, Map.get(config, :timeout_ms)) do
      {:ran, output, exit_code} ->
        evidence = base_evidence(cmd, args, workspace, verdict, exit_code, output)

        if error_code?(config, exit_code) do
          PredicateResult.error(Map.put(evidence, :reason, {:error_exit, exit_code}))
        else
          apply_verdict(verdict, exit_code, output, config, evidence)
        end

      {:raised, message} ->
        PredicateResult.error(%{
          reason: {:cmd_unrunnable, message},
          cmd: cmd,
          args: args,
          workspace: workspace
        })

      {:timeout, ms} ->
        PredicateResult.error(%{
          reason: {:timeout_ms, ms},
          cmd: cmd,
          args: args,
          workspace: workspace
        })
    end
  end

  # Resolve a workspace-relative `cmd` against the workspace (#1096).
  #
  # `System.cmd/3` resolves a relative `cmd` via PATH, NOT the `:cd` option, so a
  # checker committed in the tree it grades (`cmd = "scripts/chk.sh"`) raised
  # :enoent even though it sat right next to the code under test. Join it to the
  # workspace ONLY when it NAMES A PATH (contains a separator) and resolves there
  # to an executable file. A bare name (`semgrep`) stays a PATH lookup — shell
  # semantics, so a stray ./semgrep in the workspace never shadows the real tool.
  # Anything that does not resolve is left VERBATIM: the exec then fails as it
  # always did and surfaces as :error with a reason, rather than being silently
  # rewritten into a different missing path.
  defp resolve_cmd(cmd, workspace) do
    candidate = Path.expand(cmd, workspace)

    if Path.type(cmd) == :relative and path_shaped?(cmd) and executable_file?(candidate) do
      candidate
    else
      cmd
    end
  end

  defp path_shaped?(cmd), do: String.contains?(cmd, "/")

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  # Whether to fold stderr into stdout for the retained evidence. Off by default
  # (the generic runner keeps the two streams separate); the :tests/:prod_log
  # presets set it true to preserve their historical combined-stream evidence.
  defp merge_stderr?(config), do: Map.get(config, :merge_stderr, false) == true

  defp base_evidence(cmd, args, workspace, verdict, exit_code, output) do
    %{
      cmd: cmd,
      args: args,
      workspace: workspace,
      verdict: verdict,
      exit: exit_code,
      output: truncate(output)
    }
  end

  # An exit code the predicate DECLARED as "could not run" — mapped to :error
  # (infra), distinct from a genuine :fail (ADR-0040 decision 5).
  defp error_code?(config, exit_code) do
    case Map.get(config, :error_codes) do
      codes when is_list(codes) -> exit_code in codes
      _ -> false
    end
  end

  # =============================================================================
  # Verdicts
  # =============================================================================

  # "exit_zero": exit 0 -> :pass, anything else -> :fail.
  defp apply_verdict("exit_zero", exit_code, _output, config, evidence) do
    decide(exit_code == 0, with_findings(evidence, config))
  end

  # "exit_code": a declared pass/fail code map. A code in neither list is :fail —
  # a gate never passes an undeclared code.
  defp apply_verdict("exit_code", exit_code, _output, config, evidence) do
    pass_codes = List.wrap(Map.get(config, :pass_codes, []))
    fail_codes = List.wrap(Map.get(config, :fail_codes, []))

    evidence =
      evidence
      |> Map.put(:pass_codes, pass_codes)
      |> Map.put(:fail_codes, fail_codes)
      |> with_findings(config)

    cond do
      exit_code in pass_codes ->
        PredicateResult.pass(evidence)

      true ->
        PredicateResult.fail(Map.put(evidence, :unmatched_code, exit_code not in fail_codes))
    end
  end

  # "json": parse stdout, extract the value at :path, compare via :pass_when. A
  # parse/path failure is an :error (never a silent pass) — the SARIF/JSON gotcha
  # ADR-0040 designs out.
  defp apply_verdict("json", _exit_code, output, config, evidence) do
    with {:ok, path} <- require_string(config, :path),
         {:ok, expr} <- require_string(config, :pass_when),
         {:ok, {op, operand}} <- parse_pass_when(expr),
         {:ok, data} <- decode_json(output),
         {:ok, raw} <- Kazi.JSONPath.get(data, path),
         {:ok, number} <- Kazi.JSONPath.to_number(raw) do
      evidence =
        evidence
        |> Map.merge(%{path: path, pass_when: expr, observed: number})
        |> with_findings(config, data)

      decide(compare(number, op, operand), evidence)
    else
      {:error, reason} -> PredicateResult.error(Map.put(evidence, :reason, reason))
    end
  end

  # "match_count": count the output lines matching :match_regex, compare that
  # COUNT via :pass_when. Gates a tool on the textual signal in its output rather
  # than its exit code (the verdict the prod_log preset specialises). A bad/missing
  # regex or pass_when is an :error, never a silent pass.
  defp apply_verdict("match_count", _exit_code, output, config, evidence) do
    with {:ok, expr} <- require_string(config, :pass_when),
         {:ok, {op, operand}} <- parse_pass_when(expr),
         {:ok, source} <- require_string(config, :match_regex),
         {:ok, regex} <- compile_regex(source) do
      matched = matched_lines(output, regex)
      count = length(matched)

      evidence =
        Map.merge(evidence, %{
          match_regex: source,
          pass_when: expr,
          observed: count,
          matched_lines: Enum.take(matched, @match_sample_limit)
        })

      decide(compare(count, op, operand), evidence)
    else
      {:error, reason} -> PredicateResult.error(Map.put(evidence, :reason, reason))
    end
  end

  defp decide(true, evidence), do: PredicateResult.pass(evidence)
  defp decide(false, evidence), do: PredicateResult.fail(evidence)

  defp matched_lines(output, regex) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&Regex.match?(regex, &1))
  end

  defp matched_lines(_output, _regex), do: []

  defp compile_regex(source) do
    case Regex.compile(source) do
      {:ok, regex} -> {:ok, regex}
      {:error, reason} -> {:error, {:invalid_match_regex, reason}}
    end
  end

  # =============================================================================
  # pass_when comparison
  # =============================================================================

  defp parse_pass_when(expr) do
    case Regex.run(@pass_when_re, expr) do
      [_, op, num] -> {:ok, {op, parse_number(num)}}
      _ -> {:error, {:invalid_pass_when, expr}}
    end
  end

  defp parse_number(num) do
    if String.contains?(num, "."), do: String.to_float(num), else: String.to_integer(num)
  end

  defp compare(value, "==", operand), do: value == operand
  defp compare(value, "!=", operand), do: value != operand
  defp compare(value, "<", operand), do: value < operand
  defp compare(value, "<=", operand), do: value <= operand
  defp compare(value, ">", operand), do: value > operand
  defp compare(value, ">=", operand), do: value >= operand

  # JSONPath extraction + numeric coercion are shared with the `:ratchet` metric
  # via `Kazi.JSONPath` (one implementation of the `$`/`.key`/`[index]` subset).

  # =============================================================================
  # Evidence extraction (SARIF / JUnit), best-effort
  # =============================================================================

  # With an already-parsed JSON document (the "json" verdict path).
  defp with_findings(evidence, config, data) do
    case Map.get(config, :evidence_format) do
      "sarif" -> Map.put(evidence, :findings, sarif_findings(data))
      _ -> evidence
    end
  end

  # Without a parsed document: parse the raw output per the declared envelope. A
  # parse failure degrades to no findings (evidence extraction never changes the
  # verdict — ADR-0040 decision 3).
  defp with_findings(evidence, config) do
    case Map.get(config, :evidence_format) do
      "sarif" ->
        case decode_json(evidence.output) do
          {:ok, data} -> Map.put(evidence, :findings, sarif_findings(data))
          {:error, _} -> evidence
        end

      "junit" ->
        Map.put(evidence, :findings, junit_findings(evidence.output))

      _ ->
        evidence
    end
  end

  # SARIF: flatten runs[].results[] into {file, line, rule, level, message} items.
  defp sarif_findings(%{"runs" => runs}) when is_list(runs) do
    runs
    |> Enum.flat_map(fn
      %{"results" => results} when is_list(results) -> results
      _ -> []
    end)
    |> Enum.map(&sarif_result/1)
  end

  defp sarif_findings(_), do: []

  defp sarif_result(result) when is_map(result) do
    location =
      result
      |> Map.get("locations", [])
      |> List.first(%{})
      |> get_in_safe(["physicalLocation"])

    %{
      rule: Map.get(result, "ruleId"),
      level: Map.get(result, "level"),
      message: get_in_safe(result, ["message", "text"]),
      file: get_in_safe(location, ["artifactLocation", "uri"]),
      line: get_in_safe(location, ["region", "startLine"])
    }
  end

  defp sarif_result(_), do: %{}

  # JUnit XML: a lightweight, dependency-free scan of non-self-closing <testcase>
  # elements (those with a closing tag, hence a body) that carry a <failure> or
  # <error> child, capturing the case name + the failure message attribute. A
  # passing (self-closing or empty-body) testcase is skipped. Robust to attribute
  # order; not a full XML parse (the verdict for a JUnit recipe is the exit code,
  # not this — decision 1).
  # The `(?<!\/)>` lookbehind keeps a SELF-closing `<testcase .../>` (a passing
  # case) from being matched as an opening tag whose body then runs into the next
  # case's failure.
  @junit_case_re ~r/<testcase\b[^>]*?\bname="([^"]*)"[^>]*?(?<!\/)>(.*?)<\/testcase>/s
  @junit_fault_re ~r/<(failure|error)\b([^>]*?)\s*\/?>/s
  @junit_message_re ~r/\bmessage="([^"]*)"/

  defp junit_findings(output) when is_binary(output) do
    @junit_case_re
    |> Regex.scan(output)
    |> Enum.flat_map(fn [_full, name, body] ->
      case Regex.run(@junit_fault_re, body) do
        [_, kind, attrs] -> [%{case: name, kind: kind, message: fault_message(attrs)}]
        nil -> []
      end
    end)
  end

  defp junit_findings(_), do: []

  # Pull the `message="..."` attribute out of a <failure>/<error> tag's attribute
  # string, if present.
  defp fault_message(attrs) do
    case Regex.run(@junit_message_re, attrs) do
      [_, message] -> message
      nil -> nil
    end
  end

  defp get_in_safe(map, keys) when is_map(map), do: get_in(map, keys)
  defp get_in_safe(_other, _keys), do: nil

  # =============================================================================
  # Helpers
  # =============================================================================

  defp require_string(config, key) do
    case Map.get(config, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_config_key, key}}
    end
  end

  defp decode_json(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :invalid_json_output}
    end
  end

  defp env_opt(config) do
    case Map.get(config, :env) do
      list when is_list(list) -> [env: normalize_env(list)]
      map when is_map(map) -> [env: normalize_env(Map.to_list(map))]
      _ -> []
    end
  end

  defp normalize_env(pairs) do
    Enum.map(pairs, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp truncate(output) when is_binary(output) do
    if String.length(output) > @output_limit do
      String.slice(output, 0, @output_limit) <> "…[truncated]"
    else
      output
    end
  end

  defp truncate(output), do: output
end
