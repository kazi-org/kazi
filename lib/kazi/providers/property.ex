defmodule Kazi.Providers.Property do
  @moduledoc """
  The `:property` predicate provider (T32.8, ADR-0043): property-based testing,
  PropCheck under `mix test` (kazi-native).

  A unit test asserts one example; a property asserts an INVARIANT over hundreds
  of generated inputs, and on a counterexample PropCheck/PropEr SHRINKS it to the
  minimal failing case — the single most useful piece of fix-context a generator
  can hand a fixer. This provider runs the property command, reads PropEr's
  console output, and maps it to an envelope-v2 result:

    * `score = cases-passed / N` (`direction: :higher_better`) — the dense
      gradient. A property that gets further before failing (more cases passed)
      registers as progress even before it is green, exactly the signal the
      stuck-detector consumes (ADR-0041).
    * the SHRUNK counterexample rides in the evidence on a failure, so the fixer
      sees the minimal input that breaks the invariant, not a 100-line log.

  The convergence gate is unchanged: a property predicate contributes only its
  `:pass`.

  ## Verdict

  PropEr (which PropCheck surfaces) prints a recognizable console summary:

    * success — `OK: Passed 100 test(s).`
    * failure — `Failed: After 3 test(s).` followed by the failing input, then
      `Shrinking ...(N time(s))` and the SHRUNK counterexample.

  So the verdict is read from the PARSED output, not the exit code alone:

    * a failure summary present → `:fail` (score = cases-passed / N, the shrunk
      counterexample as evidence);
    * else exit `0` → `:pass` (score = 1.0 — every case passed);
    * else (a non-zero exit with NO property failure — a compile error, a crashed
      suite) → `:error`, never `:fail`. A broken suite is infra, not failing work.

  ## Config

    * `:cmd`  — the executable. Optional, defaults to `"mix"`.
    * `:args` — argument list. Optional, defaults to `["test"]`.
    * `:env`  — extra environment, a `{name, value}` list or a `{name => value}`
      map. Optional.
    * `:num_tests` — `N`, the number of generated cases per property, the score
      DENOMINATOR. Optional, defaults to `100` (PropCheck's own default).
    * `:merge_stderr` — fold stderr into stdout for the parsed output. Optional,
      defaults `true` (PropEr/ExUnit write the summary to different streams across
      versions; the combined stream is what a developer reads).
    * `:timeout_ms` — kill the command after this many ms and map it to `:error`
      (the property run did not complete). Optional; absent means no timeout.

  ## Context

  `context[:workspace]` is the directory the command runs in (`cd:`). Defaults to
  the current directory when absent.

  ## Evidence

  Every result carries the resolved `:cmd`, `:args`, `:workspace`, the `:exit`
  code, the `:num_tests`, the parsed `:cases_passed`, and a truncated `:output`. A
  failure adds the `:counterexample` (the shrunk minimal input). An `:error`
  carries a `:reason`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.CommandRunner

  @output_limit 4_000
  @default_cmd "mix"
  @default_args ["test"]
  @default_num_tests 100

  # PropEr's console summary markers. `Failed: After N test(s).` is the failure
  # signal; `Passed N test(s)` (with or without the `OK:` prefix) is success.
  @failed_re ~r/Failed:\s*After\s+(\d+)\s+test/i
  @passed_re ~r/(?:OK:\s*)?Passed\s+(\d+)\s+test/i

  # The shrunk counterexample sits on the line(s) AFTER the `Shrinking …(N time(s))`
  # line; PropCheck's ExUnit integration prints it after `Counter-Example is:`.
  @shrinking_re ~r/Shrinking[^\n]*\n/
  @counterexample_re ~r/Counter-?Example is:[^\n]*\n/i

  @impl true
  def evaluate(%Predicate{kind: :property, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()
    cmd = cmd(config)
    args = args(config)
    num_tests = num_tests(config)

    opts = [cd: workspace, stderr_to_stdout: merge_stderr?(config)] ++ env_opt(config)

    case CommandRunner.run(cmd, args, opts, Map.get(config, :timeout_ms)) do
      {:ran, output, exit_code} ->
        decide(output, exit_code, num_tests, base_evidence(cmd, args, workspace, num_tests))

      {:raised, message} ->
        PredicateResult.error(%{
          reason: {:cmd_unrunnable, message},
          cmd: cmd,
          workspace: workspace
        })

      {:timeout, ms} ->
        PredicateResult.error(%{reason: {:timeout_ms, ms}, cmd: cmd, workspace: workspace})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  # The verdict is read from the PARSED PropEr summary, not the exit code alone: a
  # failure summary is a genuine :fail (with the shrunk counterexample as
  # evidence); an exit-0 run with no failure is a :pass (every case passed); a
  # non-zero exit with NO failure summary is an :error (a crashed/uncompilable
  # suite is infra, never failing property work).
  defp decide(output, exit_code, num_tests, evidence) do
    evidence = Map.merge(evidence, %{exit: exit_code, output: truncate(output)})

    case Regex.run(@failed_re, output) do
      [_, n] ->
        failed_at = String.to_integer(n)
        cases_passed = max(failed_at - 1, 0)

        evidence
        |> Map.merge(%{cases_passed: cases_passed, counterexample: counterexample(output)})
        |> fail_with_score(cases_passed, num_tests)

      nil ->
        pass_or_error(output, exit_code, num_tests, evidence)
    end
  end

  defp pass_or_error(output, 0, num_tests, evidence) do
    cases_passed = passed_count(output, num_tests)

    PredicateResult.new(
      :pass,
      Map.put(evidence, :cases_passed, cases_passed),
      score: score(cases_passed, num_tests),
      direction: :higher_better
    )
  end

  defp pass_or_error(_output, exit_code, _num_tests, evidence) do
    # A non-zero exit with no property-failure summary: the suite did not run a
    # property to a verdict (compile error, crash). Infra, not failing work.
    PredicateResult.error(Map.put(evidence, :reason, {:no_property_verdict, exit_code}))
  end

  defp fail_with_score(evidence, cases_passed, num_tests) do
    PredicateResult.new(:fail, evidence,
      score: score(cases_passed, num_tests),
      direction: :higher_better
    )
  end

  # The number of cases the property passed before either finishing (the parsed
  # `Passed N`) or, absent that, the configured N (an exit-0 run with no explicit
  # count still passed every case).
  defp passed_count(output, num_tests) do
    case Regex.run(@passed_re, output) do
      [_, n] -> String.to_integer(n)
      nil -> num_tests
    end
  end

  defp score(_cases_passed, num_tests) when num_tests <= 0, do: nil

  defp score(cases_passed, num_tests) do
    Float.round(min(cases_passed / num_tests, 1.0), 4)
  end

  # The shrunk counterexample: the text on the line(s) following the LAST
  # `Shrinking …` line, or PropCheck's `Counter-Example is:` line, trimmed to the
  # next blank line. nil when neither marker is present.
  defp counterexample(output) do
    extract_after(output, @shrinking_re) || extract_after(output, @counterexample_re)
  end

  defp extract_after(output, marker_re) do
    case Regex.split(marker_re, output, parts: :infinity) do
      [_ | _] = parts when length(parts) > 1 ->
        parts
        |> List.last()
        |> String.split(~r/\n\s*\n/, parts: 2)
        |> List.first()
        |> String.trim()
        |> presence()

      _ ->
        nil
    end
  end

  defp presence(""), do: nil
  defp presence(str), do: str

  # =============================================================================
  # Config
  # =============================================================================

  defp cmd(config) do
    case Map.get(config, :cmd) do
      cmd when is_binary(cmd) and cmd != "" -> cmd
      _ -> @default_cmd
    end
  end

  defp args(config) do
    case Map.get(config, :args) do
      args when is_list(args) -> args
      _ -> @default_args
    end
  end

  defp num_tests(config) do
    case Map.get(config, :num_tests) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_num_tests
    end
  end

  defp merge_stderr?(config), do: Map.get(config, :merge_stderr, true) == true

  defp base_evidence(cmd, args, workspace, num_tests) do
    %{cmd: cmd, args: args, workspace: workspace, num_tests: num_tests}
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
