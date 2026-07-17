defmodule Kazi.Providers.Cli do
  @moduledoc """
  The `:cli` predicate provider (T43.7, UC-055): assert that a SHIPPED command-line
  binary actually runs the way a user invokes it.

  `mix test` proves the code compiles and the unit paths hold; it does NOT prove the
  packaged binary boots and answers `kazi version` on a real `$PATH`. Several real
  regressions passed the whole test suite while the released binary crashed on its
  first CLI call (a `:noproc` on the read-model, an OTP-28 stderr warning, the
  L-0022 `RELEASE_*` env leak). `:cli` closes that gap: it runs a declared binary
  with declared args and gates on the OBSERVABLE surface a user sees — the exit
  code, and the two output streams.

  ## Verdict boundary (ADR-0002)

    * `:pass`  — every configured assertion holds.
    * `:fail`  — the binary RAN but an assertion does not hold (real work: the CLI
      answered, just not correctly). Carries expected-vs-found evidence.
    * `:error` — the binary could not be launched at all (missing executable, bad
      workspace) or overran `timeout_ms`. Per ADR-0002 this is NOT failing work for
      a fixer agent — conflating it with `:fail` would dispatch an agent against an
      infra problem.

  envelope-v2 grading (ADR-0041): `score` is the count of assertions that passed
  and `direction` is `:higher_better`, so the controller reads "2 of 3 → 3 of 3" as
  progress without CLI-specific knowledge.

  ## Config

    * `:cmd`  — the executable (string). Required. ONE executable, not a command
      line (`cmd: "kazi"`, not `cmd: "kazi version"`); use `:args` for the rest. A
      name containing `/` resolves against the workspace (a binary committed in the
      tree it checks just works); a bare name is a `$PATH` lookup. A `:cmd` that
      resolves to no executable is an `:error` naming what was tried, never a silent
      pass.
    * `:args` — argument list (list of strings). Optional, defaults to `[]`.
    * `:env`  — extra environment, a `{name, value}` list or a `{name => value}`
      map. Optional.
    * `:timeout_ms` — kill the command after this many ms and map it to `:error`.
      Optional; absent means no timeout.
    * `:assertions` — a NON-EMPTY list of assertion tables (required UNLESS
      `:script` is set — the loader rejects a `:cli` predicate with neither). Each
      names a `target` and how to check it:
        * `target = "exit_code"` — `expected` is the integer the exit code must
          equal.
        * `target = "stdout"` / `"stderr"` — `match` selects the matcher over that
          stream: `"equals"` (whole-stream equality), `"contains"` (substring),
          `"regex"` (the stream matches the pattern), `"json_path"` (parse the
          stream as JSON, extract `path`, and compare to `expected`), or `"golden"`
          (the whole stream must equal a COMMITTED golden file at `golden`; a
          mismatch is a `:fail` carrying a unified `diff`). `expected` carries the
          operand; `json_path` also needs `path` (a `Kazi.JSONPath` subset);
          `golden` needs the `golden` file path (workspace-relative).
    * `:script` — an OPTIONAL ordered list of sub-invocations of the SAME `cmd`
      (T43.8). Each step is a table with its own `args` + non-empty `assertions`.
      The steps run in order and the predicate passes only when EVERY step passes;
      it STOPS at the first failing step and names it (`:failed_step`), since a
      later step usually depends on an earlier one's effect. Use INSTEAD OF a
      top-level `:assertions` list. Score is the count of passing steps.
    * `:samples` — an OPTIONAL positive integer (T43.8, mirrors the `:browser`
      provider): require N CONSECUTIVE passing runs before the predicate is
      considered stably green (flake detection). Defaults to `1`. A single non-pass
      breaks the streak; an `:error` run is infra (`:error`), never a broken streak.

  ## Context

  `context[:workspace]` is the directory the command runs in (`cd:`), so a
  workspace-relative binary resolves against the same tree the harness edits.
  Defaults to the current directory when absent (mirrors the other command-runner
  providers).

  ## Stream separation

  The shared `Kazi.Providers.CommandRunner` seam (a `System.cmd/3` wrapper) captures
  ONE output stream, so to keep `stdout` and `stderr` independently assertable the
  provider pre-resolves the executable (which is also what yields the
  `:error`-on-unrunnable verdict, since a resolved binary never raises `:enoent`)
  and then runs it through `CommandRunner` under `sh -c` with stderr redirected to a
  temp file — stdout is captured by the runner, stderr is read back from the file.
  Timeout and the L-0022 release-env scrub still apply because the run still goes
  through `CommandRunner`.

  ## Evidence

  Every result carries the proof a fixer needs: the resolved `:cmd`, `:args`,
  `:workspace`, the `:exit` code, and the truncated `:stdout` / `:stderr`. A pass or
  fail also carries the per-assertion `:results` matrix; a fail additionally carries
  an `:assertion_failures` list (each `{target, match, expected, found}`, a `golden`
  failure adding the unified `diff`). An `:error` carries a `:reason`.

  A `:script` result carries the per-step `:steps` matrix (each `{index, args,
  status, passed, total, assertion_failures}`), `:passing_steps`, and — on a
  non-pass — the `:failed_step`. A `:samples` result carries `:samples_required`,
  `:passing_count`, and the per-run `:runs` summary.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.CommandRunner

  # Keep retained output seed-sized: enough to orient a fixer, not a full dump.
  @output_limit 4_000

  # `:samples` default — one run, byte-identical to the pre-T43.8 provider.
  @default_samples 1

  @targets ~w(exit_code stdout stderr)
  @matchers ~w(equals contains regex json_path golden)

  @doc "The assertion targets this provider supports."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @doc "The stdout/stderr matchers this provider supports."
  @spec matchers() :: [String.t()]
  def matchers, do: @matchers

  @impl true
  def evaluate(%Predicate{kind: :cli, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()

    # `:samples > 1` wraps the WHOLE evaluation in a consecutive-pass loop (flake
    # detection), mirroring Kazi.Providers.Browser's synthetic-journey shape.
    case samples(config) do
      n when n <= 1 -> run_once(config, workspace)
      n -> sampled(config, workspace, n)
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  # One evaluation of the predicate: a `:script` of ordered sub-invocations, or a
  # single invocation. Both flow through the same run/decide path.
  defp run_once(config, workspace) do
    case Map.get(config, :script) do
      [_ | _] = steps -> run_script(config, workspace, steps)
      _ -> run_single(config, workspace)
    end
  end

  defp run_single(config, workspace) do
    cmd = config[:cmd]
    args = List.wrap(config[:args] || [])

    case resolve_executable(cmd, workspace) do
      {:ok, resolved} -> run(resolved, cmd, args, workspace, config)
      {:error, reason} -> PredicateResult.error(%{reason: reason, cmd: cmd, workspace: workspace})
    end
  end

  # ===========================================================================
  # Script — ordered sub-invocations (T43.8, UC-055)
  # ===========================================================================

  # Run each declared step (its own args + assertions) IN ORDER against the same
  # binary, stopping at the FIRST step that does not pass — a later step routinely
  # depends on an earlier one's effect (e.g. `init` then `status`), so fail-fast
  # both avoids cascade noise and names the first broken step. The predicate passes
  # only when EVERY step passes; the score is the count of passing steps
  # (higher_better), the same gradient the assertion count gives a single call.
  defp run_script(config, workspace, steps) do
    results = collect_steps(config, workspace, Enum.with_index(steps, 1), [])
    summarize_script(config[:cmd], workspace, length(steps), results)
  end

  defp collect_steps(_config, _workspace, [], acc), do: Enum.reverse(acc)

  defp collect_steps(config, workspace, [{step, index} | rest], acc) do
    result = run_single(step_config(config, step), workspace)
    entry = %{index: index, args: List.wrap(assertion_key(step, "args") || []), result: result}
    acc = [entry | acc]

    if result.status == :pass do
      collect_steps(config, workspace, rest, acc)
    else
      Enum.reverse(acc)
    end
  end

  # A step inherits cmd/env/timeout from the predicate and supplies its OWN args +
  # assertions — one invocation of the SAME binary.
  defp step_config(config, step) do
    %{
      cmd: config[:cmd],
      args: List.wrap(assertion_key(step, "args") || []),
      assertions: assertion_key(step, "assertions") || []
    }
    |> maybe_put(:env, config[:env])
    |> maybe_put(:timeout_ms, config[:timeout_ms])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp summarize_script(cmd, workspace, total, results) do
    passing = Enum.count(results, &(&1.result.status == :pass))
    steps = Enum.map(results, &step_summary/1)

    base = %{
      cmd: cmd,
      workspace: workspace,
      steps_required: total,
      passing_steps: passing,
      steps: steps
    }

    cond do
      errored = Enum.find(results, &(&1.result.status == :error)) ->
        base
        |> Map.put(:failed_step, step_summary(errored))
        |> Map.merge(Map.take(errored.result.evidence, [:reason]))
        |> PredicateResult.error()

      passing == total ->
        PredicateResult.new(:pass, base, score: passing * 1.0, direction: :higher_better)

      true ->
        failed = Enum.find(results, &(&1.result.status == :fail))

        base
        |> Map.put(:failed_step, step_summary(failed))
        |> then(&PredicateResult.new(:fail, &1, score: passing * 1.0, direction: :higher_better))
    end
  end

  # A seed-sized per-step record naming which step it was and how it fared.
  defp step_summary(%{index: index, args: args, result: result}) do
    %{
      index: index,
      args: args,
      status: result.status,
      passed: Map.get(result.evidence, :passed),
      total: Map.get(result.evidence, :total),
      assertion_failures: Map.get(result.evidence, :assertion_failures, [])
    }
  end

  # ===========================================================================
  # Samples — N consecutive passing runs (T43.8, mirrors Browser T32.10)
  # ===========================================================================

  # Re-run the whole evaluation up to N times; stop at the first non-:pass (a broken
  # streak can never reach N consecutive passes, an :error run is infra), then
  # summarize the runs actually taken. Score is the passing-run count (higher_better).
  defp sampled(config, workspace, n) do
    runs = collect_samples(config, workspace, n, [])
    summarize_samples(workspace, n, runs)
  end

  defp collect_samples(config, workspace, remaining, acc) do
    result = run_once(config, workspace)
    acc = [result | acc]

    cond do
      result.status != :pass -> Enum.reverse(acc)
      remaining <= 1 -> Enum.reverse(acc)
      true -> collect_samples(config, workspace, remaining - 1, acc)
    end
  end

  defp summarize_samples(workspace, samples, runs) do
    passing = Enum.count(runs, &(&1.status == :pass))

    evidence = %{
      workspace: workspace,
      samples_required: samples,
      passing_count: passing,
      runs: Enum.map(runs, &sample_summary/1)
    }

    cond do
      errored = Enum.find(runs, &(&1.status == :error)) ->
        PredicateResult.error(Map.merge(errored.evidence, evidence))

      passing == samples ->
        PredicateResult.new(:pass, evidence, score: passing * 1.0, direction: :higher_better)

      true ->
        failed = Enum.find(runs, &(&1.status == :fail))

        evidence
        |> Map.merge(Map.take(failed.evidence, [:assertion_failures, :failed_step]))
        |> then(&PredicateResult.new(:fail, &1, score: passing * 1.0, direction: :higher_better))
    end
  end

  defp sample_summary(%PredicateResult{status: status, evidence: evidence}) do
    %{
      status: status,
      passed: Map.get(evidence, :passed) || Map.get(evidence, :passing_steps),
      assertion_failures: Map.get(evidence, :assertion_failures, [])
    }
  end

  defp samples(config) do
    case Map.get(config, :samples, @default_samples) do
      n when is_integer(n) and n >= 1 -> n
      _ -> @default_samples
    end
  end

  # =============================================================================
  # Execution
  # =============================================================================

  # Run the resolved binary through the shared CommandRunner under `sh -c`, with the
  # inner command's stderr redirected to a temp file so the two streams stay
  # independently assertable. The inner command's exit status is `sh`'s exit status
  # (it is the last/only command), and its stdout flows up to CommandRunner's
  # capture unredirected.
  defp run(resolved, declared_cmd, args, workspace, config) do
    stderr_path = temp_path()
    command = shell_command([resolved | args], stderr_path)
    opts = [cd: workspace, stderr_to_stdout: false] ++ env_opt(config)

    try do
      case CommandRunner.run("sh", ["-c", command], opts, Map.get(config, :timeout_ms)) do
        {:ran, stdout, exit_code} ->
          stderr = read_stderr(stderr_path)
          decide(config, declared_cmd, args, workspace, stdout, stderr, exit_code)

        {:raised, message} ->
          PredicateResult.error(%{
            reason: {:cmd_unrunnable, message},
            cmd: declared_cmd,
            args: args,
            workspace: workspace
          })

        {:timeout, ms} ->
          PredicateResult.error(%{
            reason: {:timeout_ms, ms},
            cmd: declared_cmd,
            args: args,
            workspace: workspace
          })
      end
    after
      File.rm(stderr_path)
    end
  end

  # Resolve `cmd` to an executable BEFORE shelling out, so a missing binary is an
  # :error (never a silent pass, never a shell 127 that would look like a real exit
  # code). A path-shaped cmd (contains `/`) resolves against the workspace; a bare
  # name is a $PATH lookup. Mirrors Kazi.Providers.CustomScript.resolve_cmd/2.
  defp resolve_executable(cmd, _workspace) when not is_binary(cmd) or cmd == "",
    do: {:error, {:cmd_unrunnable, :missing_cmd}}

  defp resolve_executable(cmd, workspace) do
    if String.contains?(cmd, "/") do
      candidate = Path.expand(cmd, workspace)

      if executable_file?(candidate),
        do: {:ok, candidate},
        else: {:error, {:cmd_unrunnable, {:not_executable, cmd}}}
    else
      case System.find_executable(cmd) do
        path when is_binary(path) -> {:ok, path}
        nil -> {:error, {:cmd_unrunnable, {:not_found, cmd}}}
      end
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  # Build the `sh -c` command string: the resolved executable + args, each
  # single-quoted so a space/glob/metachar in an arg stays a literal argument, with
  # the inner command's stderr redirected to `stderr_path`.
  defp shell_command(tokens, stderr_path) do
    Enum.map_join(tokens, " ", &shell_quote/1) <> " 2>" <> shell_quote(stderr_path)
  end

  defp shell_quote(token) do
    "'" <> String.replace(to_string(token), "'", "'\\''") <> "'"
  end

  defp read_stderr(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end

  defp temp_path do
    name = "kazi_cli_stderr_#{System.unique_integer([:positive])}.txt"
    Path.join(System.tmp_dir!(), name)
  end

  # =============================================================================
  # Assertion evaluation
  # =============================================================================

  defp decide(config, cmd, args, workspace, stdout, stderr, exit_code) do
    streams = %{"stdout" => stdout, "stderr" => stderr}

    results =
      config
      |> Map.get(:assertions, [])
      |> Enum.map(&evaluate_assertion(&1, streams, exit_code, workspace))

    passed = Enum.count(results, & &1.passed)
    total = length(results)

    base = %{
      cmd: cmd,
      args: args,
      workspace: workspace,
      exit: exit_code,
      stdout: truncate(stdout),
      stderr: truncate(stderr),
      passed: passed,
      total: total,
      results: results
    }

    status = if passed == total, do: :pass, else: :fail

    evidence =
      case status do
        :pass -> base
        :fail -> Map.put(base, :assertion_failures, failures(results))
      end

    PredicateResult.new(status, evidence, score: passed * 1.0, direction: :higher_better)
  end

  defp failures(results) do
    results
    |> Enum.reject(& &1.passed)
    |> Enum.map(&Map.drop(&1, [:passed]))
  end

  # exit_code: the observed exit status must equal the expected integer.
  defp evaluate_assertion(assertion, streams, exit_code, workspace) when is_map(assertion) do
    case assertion_key(assertion, "target") do
      "exit_code" ->
        expected = assertion_key(assertion, "expected")

        %{
          target: "exit_code",
          match: "equals",
          expected: expected,
          found: exit_code,
          passed: exit_code == expected
        }

      target when target in ["stdout", "stderr"] ->
        evaluate_stream(target, assertion, Map.fetch!(streams, target), workspace)

      other ->
        %{target: other, match: nil, expected: nil, found: nil, passed: false}
    end
  end

  # stdout/stderr matchers. A matcher that cannot evaluate the stream (an invalid
  # regex, non-JSON output under json_path, a missing json_path path) is a FAIL —
  # the binary ran and produced output that does not satisfy the assertion — never
  # an :error, which is reserved for a binary that could not launch. The reason is
  # surfaced in the evidence so a fixer sees WHY.
  defp evaluate_stream(target, assertion, stream, workspace) do
    match = assertion_key(assertion, "match") || "equals"
    expected = assertion_key(assertion, "expected")

    {passed, extra} = apply_matcher(match, stream, expected, assertion, workspace)

    Map.merge(
      %{
        target: target,
        match: match,
        expected: expected,
        found: truncate(stream),
        passed: passed
      },
      extra
    )
  end

  defp apply_matcher("equals", stream, expected, _assertion, _workspace) do
    {stream == to_string_safe(expected), %{}}
  end

  defp apply_matcher("contains", stream, expected, _assertion, _workspace) do
    {String.contains?(stream, to_string_safe(expected)), %{}}
  end

  defp apply_matcher("regex", stream, expected, _assertion, _workspace) do
    case Regex.compile(to_string_safe(expected)) do
      {:ok, regex} -> {Regex.match?(regex, stream), %{}}
      {:error, reason} -> {false, %{reason: {:invalid_regex, inspect(reason)}}}
    end
  end

  defp apply_matcher("json_path", stream, expected, assertion, _workspace) do
    path = assertion_key(assertion, "path")

    with {:ok, data} <- decode_json(stream),
         {:ok, value} <- Kazi.JSONPath.get(data, to_string_safe(path)) do
      {values_equal?(value, expected), %{path: path, extracted: value}}
    else
      {:error, reason} -> {false, %{path: path, reason: reason}}
    end
  end

  # golden: the WHOLE stream must equal a COMMITTED golden file (workspace-relative).
  # A mismatch is a :fail carrying a line-oriented unified diff (golden vs actual) so
  # a fixer sees the exact drift — the discipline behind help/usage-text snapshots
  # (ADR-0034). A missing/unreadable golden is also a :fail naming the path: the
  # binary ran fine, the gate just cannot compare, which is drift the author fixes by
  # committing the golden (never an :error, which is reserved for an unlaunchable
  # binary).
  defp apply_matcher("golden", stream, _expected, assertion, workspace) do
    path = assertion_key(assertion, "golden")

    case read_golden(path, workspace) do
      {:ok, golden} ->
        if stream == golden do
          {true, %{golden: path}}
        else
          {false, %{golden: path, diff: unified_diff(golden, stream)}}
        end

      {:error, reason} ->
        {false, %{golden: path, reason: reason}}
    end
  end

  defp apply_matcher(other, _stream, _expected, _assertion, _workspace) do
    {false, %{reason: {:unknown_matcher, other}}}
  end

  defp read_golden(path, _workspace) when not is_binary(path) or path == "",
    do: {:error, {:missing_golden_path, path}}

  defp read_golden(path, workspace) do
    case File.read(Path.expand(path, workspace)) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:golden_unreadable, reason}}
    end
  end

  # A line-oriented unified diff over List.myers_difference/2 (stdlib — no new dep),
  # the same convention Kazi.Scenario.Demonstrator uses: context lines prefixed
  # "  ", deletions "- " (the golden), insertions "+ " (the actual output).
  defp unified_diff(golden, actual) do
    String.split(golden, "\n")
    |> List.myers_difference(String.split(actual, "\n"))
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &("  " <> &1))
      {:del, lines} -> Enum.map(lines, &("- " <> &1))
      {:ins, lines} -> Enum.map(lines, &("+ " <> &1))
    end)
    |> Enum.join("\n")
  end

  # A json_path value equals `expected` when it matches directly, or when both sides
  # agree once stringified (a TOML `expected = "5"` against an extracted number 5).
  defp values_equal?(value, expected) do
    value == expected or to_string_safe(value) == to_string_safe(expected)
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp to_string_safe(value), do: inspect(value)

  defp decode_json(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :invalid_json_output}
    end
  end

  # The assertion sub-tables arrive string-keyed from TOML (the loader only atomizes
  # top-level predicate keys) or atom-keyed from an inline/authored map. Read either
  # spelling; a present `false`/`0` is distinguished from an absent key.
  defp assertion_key(assertion, key) do
    with :error <- Map.fetch(assertion, key),
         :error <- atom_key_fetch(assertion, key) do
      nil
    else
      {:ok, value} -> value
    end
  end

  defp atom_key_fetch(assertion, key) do
    Map.fetch(assertion, String.to_existing_atom(key))
  rescue
    ArgumentError -> :error
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
