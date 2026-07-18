defmodule Kazi.Providers.SwiftTest do
  @moduledoc """
  The `:swift_test` predicate provider (issue #1406): a Swift/XCTest suite's
  verdict, read from an Xcode `.xcresult` bundle rather than an exit code.

  `xcodebuild test` (and `xcrun xctest`) exit non-zero on ANY failing test, which
  the plain `custom_script`/`test_runner` exit-code verdict already covers. What
  it can NOT tell you is *why* — which test failed and with what message — or
  catch the false-pass shape where a broken scheme runs ZERO tests and still
  exits `0`. This provider reads the structured summary Xcode itself writes to
  the `.xcresult` bundle instead:

      xcrun xcresulttool get test-results summary --format json --path <bundle>

  and gates on the PARSED counts, never the exit code (the same exit-code
  gotcha `Kazi.Providers.Cve`/`Kazi.Providers.Mutation` design around).

  ## Config

    * `:xcresult_path` — path (workspace-relative or absolute) to the `.xcresult`
      bundle a prior test run produced. Required — this is the artifact the
      predicate reads.
    * `:cmd`  — the executable that emits the summary JSON. Optional, defaults to
      `"xcrun"`.
    * `:args` — argument list. Optional, defaults to
      `["xcresulttool", "get", "test-results", "summary", "--format", "json",
      "--path", xcresult_path]`. Supplying `:args` overrides the default
      entirely (including the `--path` flag), so a caller pinning an older
      `xcresulttool` invocation stays in control.
    * `:env`  — extra environment, a `{name, value}` list or a `{name => value}`
      map. Optional.
    * `:merge_stderr` — fold stderr into stdout. Optional, defaults `false` (the
      summary JSON must stay unpolluted by `xcresulttool`'s own diagnostics).
    * `:timeout_ms` — kill the run after this many ms and map it to `:error`.
      Optional; absent means no timeout.

  ## Verdict

    * The summary is missing `totalTestCount`/`passedTests`/`failedTests` (an
      `xcresulttool` schema this provider does not recognize — the summary
      sub-command is Xcode 16+ only) → `:unknown`. Never guessed as a pass.
    * `totalTestCount == 0` → `:fail` (`reason: :zero_tests`). A scheme that ran
      NO tests is broken configuration, not a green suite — the false-pass shape
      an exit-code-only check misses entirely.
    * `failedTests > 0` → `:fail`, with each entry in `testFailures` surfaced as a
      `Kazi.Evidence` diagnostic.
    * Otherwise → `:pass`.

  `score` is the passed-test count (`direction: :higher_better`) so the loop
  reads "are more tests passing?" as the gradient.

  ## Context

  `context[:workspace]` is the directory the command runs in (`cd:`). Defaults to
  the current directory when absent.

  ## Evidence

  Every result carries the resolved `:cmd`, `:args`, `:workspace`,
  `:xcresult_path`, the `:exit` code, and a truncated `:output`. A parsed summary
  adds `:total_tests`, `:passed_tests`, `:failed_tests`, `:skipped_tests`,
  `:expected_failures`, a bounded `:failures` list, and the raw `:result` string.
  An `:error` carries a `:reason`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.CommandRunner

  @output_limit 4_000
  @failure_sample_limit 25

  @default_cmd "xcrun"
  @default_args ~w(xcresulttool get test-results summary --format json)

  @impl true
  def evaluate(%Predicate{kind: :swift_test, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()

    with {:ok, xcresult_path} <- fetch_xcresult_path(config) do
      run(config, xcresult_path, workspace)
    else
      {:error, reason} -> PredicateResult.error(%{reason: reason, workspace: workspace})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  defp run(config, xcresult_path, workspace) do
    cmd = cmd(config)
    args = args(config, xcresult_path)
    opts = [cd: workspace, stderr_to_stdout: merge_stderr?(config)] ++ env_opt(config)

    case CommandRunner.run(cmd, args, opts, Map.get(config, :timeout_ms)) do
      {:ran, output, exit_code} ->
        decide(output, base_evidence(cmd, args, workspace, xcresult_path, exit_code, output))

      {:raised, message} ->
        PredicateResult.error(%{
          reason: {:cmd_unrunnable, message},
          cmd: cmd,
          workspace: workspace,
          xcresult_path: xcresult_path
        })

      {:timeout, ms} ->
        PredicateResult.error(%{
          reason: {:timeout_ms, ms},
          cmd: cmd,
          workspace: workspace,
          xcresult_path: xcresult_path
        })
    end
  end

  defp fetch_xcresult_path(config) do
    case config[:xcresult_path] do
      path when is_binary(path) and path != "" -> {:ok, path}
      nil -> {:error, :missing_xcresult_path}
      other -> {:error, {:invalid_xcresult_path, other}}
    end
  end

  # Gate on the PARSED summary, never the exit code — `xcresulttool` exits 0
  # whether the underlying suite passed or failed (it is reporting a summary,
  # not re-running the tests), and a broken invocation surfaces as unparseable
  # output regardless of exit code.
  defp decide(output, evidence) do
    case decode_json(output) do
      {:ok, data} -> decide_summary(data, evidence)
      {:error, reason} -> PredicateResult.error(Map.put(evidence, :reason, reason))
    end
  end

  defp decide_summary(data, evidence) do
    total = get_count(data, "totalTestCount")
    passed = get_count(data, "passedTests")
    failed = get_count(data, "failedTests")

    evidence =
      Map.merge(evidence, %{
        total_tests: total,
        passed_tests: passed,
        failed_tests: failed,
        skipped_tests: get_count(data, "skippedTests"),
        expected_failures: get_count(data, "expectedFailures"),
        failures: failures(data),
        result: Map.get(data, "result")
      })

    cond do
      is_nil(total) or is_nil(passed) or is_nil(failed) ->
        # `xcresulttool get test-results summary` (Xcode 16+) is the only
        # schema this provider reads; an older/unfamiliar shape without these
        # counts is honestly :unknown rather than a guessed pass or fail.
        PredicateResult.unknown(Map.put(evidence, :reason, :unrecognized_summary_schema))

      total == 0 ->
        # A scheme that ran ZERO tests is broken configuration, not a green
        # suite — the false-pass shape a bare exit-code check would miss
        # entirely (xcresulttool/xcodebuild both exit 0 here).
        PredicateResult.fail(Map.put(evidence, :reason, :zero_tests))

      failed > 0 ->
        PredicateResult.new(:fail, evidence,
          score: passed * 1.0,
          direction: :higher_better,
          diagnostics: Enum.map(evidence.failures, &diagnostic/1)
        )

      true ->
        PredicateResult.new(:pass, evidence, score: passed * 1.0, direction: :higher_better)
    end
  end

  defp failures(data) do
    case Map.get(data, "testFailures") do
      list when is_list(list) -> Enum.take(list, @failure_sample_limit)
      _ -> []
    end
  end

  defp diagnostic(failure) when is_map(failure) do
    Kazi.Evidence.new(
      rule: Map.get(failure, "testIdentifierString") || Map.get(failure, "testIdentifier"),
      level: :error,
      message: Map.get(failure, "failureText") || "swift test failed"
    )
  end

  defp diagnostic(_failure), do: Kazi.Evidence.new(level: :error, message: "swift test failed")

  defp get_count(data, key) do
    case Map.get(data, key) do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      _ -> nil
    end
  end

  # =============================================================================
  # Config + helpers
  # =============================================================================

  defp cmd(config) do
    case Map.get(config, :cmd) do
      cmd when is_binary(cmd) and cmd != "" -> cmd
      _ -> @default_cmd
    end
  end

  defp args(config, xcresult_path) do
    case Map.get(config, :args) do
      args when is_list(args) -> args
      _ -> @default_args ++ ["--path", xcresult_path]
    end
  end

  defp merge_stderr?(config), do: Map.get(config, :merge_stderr, false) == true

  defp base_evidence(cmd, args, workspace, xcresult_path, exit_code, output) do
    %{
      cmd: cmd,
      args: args,
      workspace: workspace,
      xcresult_path: xcresult_path,
      exit: exit_code,
      output: truncate(output)
    }
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
