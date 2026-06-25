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
    * `:path` — for the `"json"` verdict: a JSONPath over the parsed stdout. A
      focused subset is supported: a leading `$`, `.key` segments, and `[index]`
      array subscripts (e.g. `"$.runs[0].results"`, `"$.summary.failures"`). The
      extracted value is coerced to a number for comparison: a number is used
      verbatim; a LIST uses its length (so `path` pointing at a findings array
      compares its COUNT).
    * `:pass_when` — for the `"json"` verdict: a comparison the extracted number
      must satisfy to `:pass`, written `"<op> <number>"` where `<op>` is one of
      `== != < <= > >=` (e.g. `"== 0"`, `">= 0.8"`, `"<= 5"`).
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
  `:pass_when`, and the `:observed` number. An `:evidence_format` of `"sarif"` /
  `"junit"` adds structured `:findings`. An `:error` result carries a `:reason`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}

  # Keep the retained raw output seed-sized: enough to orient a fixer, not a full
  # dump (ADR-0040 decision 3 — raw stdout is a truncated fallback).
  @output_limit 4_000

  # The declared verdict strings, mapped to their internal evaluators.
  @verdicts ~w(exit_zero exit_code json)

  # The recognised evidence envelopes for :evidence_format.
  @evidence_formats ~w(sarif junit json raw)

  # A pass_when comparison: an operator and a numeric operand.
  @pass_when_re ~r/^\s*(==|!=|<=|>=|<|>)\s*(-?\d+(?:\.\d+)?)\s*$/
  # One JSONPath segment: a `.key` or a `[index]`.
  @path_token_re ~r/\.([^.\[\]]+)|\[(\d+)\]/

  @doc "The verdict strings this provider accepts."
  @spec verdicts() :: [String.t()]
  def verdicts, do: @verdicts

  @doc "The `:evidence_format` envelopes this provider accepts."
  @spec evidence_formats() :: [String.t()]
  def evidence_formats, do: @evidence_formats

  @impl true
  def evaluate(%Predicate{kind: :custom_script, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()

    with {:ok, cmd, args} <- fetch_cmd(config),
         {:ok, verdict} <- fetch_verdict(config) do
      run(cmd, args, workspace, config, verdict)
    else
      {:error, reason} -> PredicateResult.error(%{reason: reason, workspace: workspace})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
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
    opts = [cd: workspace, stderr_to_stdout: false] ++ env_opt(config)

    case run_cmd(cmd, args, opts, Map.get(config, :timeout_ms)) do
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

  # Execute the command. With no :timeout_ms we run System.cmd/3 directly (the
  # same boundary the other providers use); with a timeout we run it in a task we
  # can brutally kill if it overruns, mapping the overrun to a :timeout the caller
  # turns into an :error. A raise inside the task (missing binary) is captured and
  # returned tagged rather than crashing the provider.
  defp run_cmd(cmd, args, opts, nil) do
    {output, exit_code} = System.cmd(cmd, args, opts)
    {:ran, output, exit_code}
  rescue
    error in [ErlangError, File.Error] -> {:raised, Exception.message(error)}
  end

  defp run_cmd(cmd, args, opts, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd(cmd, args, opts)}
        rescue
          error in [ErlangError, File.Error] -> {:raised, Exception.message(error)}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, exit_code}}} -> {:ran, output, exit_code}
      {:ok, {:raised, message}} -> {:raised, message}
      _ -> {:timeout, timeout_ms}
    end
  end

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
         {:ok, raw} <- json_get(data, path),
         {:ok, number} <- to_number(raw) do
      evidence =
        evidence
        |> Map.merge(%{path: path, pass_when: expr, observed: number})
        |> with_findings(config, data)

      decide(compare(number, op, operand), evidence)
    else
      {:error, reason} -> PredicateResult.error(Map.put(evidence, :reason, reason))
    end
  end

  defp decide(true, evidence), do: PredicateResult.pass(evidence)
  defp decide(false, evidence), do: PredicateResult.fail(evidence)

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

  # A number is used verbatim; a list uses its length (so a path pointing at a
  # findings array compares its COUNT). Anything else cannot be compared.
  defp to_number(n) when is_number(n), do: {:ok, n}
  defp to_number(list) when is_list(list), do: {:ok, length(list)}
  defp to_number(other), do: {:error, {:not_a_number, other}}

  # =============================================================================
  # JSONPath subset ($, .key, [index])
  # =============================================================================

  defp json_get(data, path) do
    with {:ok, tokens} <- parse_path(path) do
      fetch_path(data, tokens, path)
    end
  end

  defp parse_path("$" <> rest), do: tokenize(rest)
  defp parse_path(path), do: {:error, {:invalid_path, path}}

  defp tokenize(rest) do
    matches = Regex.scan(@path_token_re, rest)
    consumed = matches |> Enum.map(&hd/1) |> Enum.join()

    if consumed == rest do
      {:ok, Enum.map(matches, &token/1)}
    else
      {:error, {:invalid_path, "$" <> rest}}
    end
  end

  # Regex.scan yields the full match plus the two alternation groups; the one that
  # did not participate is the empty string.
  defp token([_full, key, ""]), do: {:key, key}
  defp token([_full, "", index]), do: {:index, String.to_integer(index)}
  defp token([_full, key]), do: {:key, key}

  defp fetch_path(value, [], _path), do: {:ok, value}

  defp fetch_path(map, [{:key, key} | rest], path) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest, path)
      :error -> {:error, {:path_missing, key, path}}
    end
  end

  defp fetch_path(list, [{:index, index} | rest], path) when is_list(list) do
    case Enum.fetch(list, index) do
      {:ok, value} -> fetch_path(value, rest, path)
      :error -> {:error, {:path_index_out_of_range, index, path}}
    end
  end

  defp fetch_path(_value, [token | _rest], path), do: {:error, {:path_type_mismatch, token, path}}

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
