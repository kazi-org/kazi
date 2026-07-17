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
    * `:assertions` — a NON-EMPTY list of assertion tables (the loader rejects a
      `:cli` predicate with none). Each names a `target` and how to check it:
        * `target = "exit_code"` — `expected` is the integer the exit code must
          equal.
        * `target = "stdout"` / `"stderr"` — `match` selects the matcher over that
          stream: `"equals"` (whole-stream equality), `"contains"` (substring),
          `"regex"` (the stream matches the pattern), or `"json_path"` (parse the
          stream as JSON, extract `path`, and compare to `expected`). `expected`
          carries the operand; `json_path` also needs `path` (a `Kazi.JSONPath`
          subset).

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
  an `:assertion_failures` list (each `{target, match, expected, found}`). An
  `:error` carries a `:reason`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.CommandRunner

  # Keep retained output seed-sized: enough to orient a fixer, not a full dump.
  @output_limit 4_000

  @targets ~w(exit_code stdout stderr)
  @matchers ~w(equals contains regex json_path)

  @doc "The assertion targets this provider supports."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @doc "The stdout/stderr matchers this provider supports."
  @spec matchers() :: [String.t()]
  def matchers, do: @matchers

  @impl true
  def evaluate(%Predicate{kind: :cli, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()
    cmd = config[:cmd]
    args = List.wrap(config[:args] || [])

    case resolve_executable(cmd, workspace) do
      {:ok, resolved} -> run(resolved, cmd, args, workspace, config)
      {:error, reason} -> PredicateResult.error(%{reason: reason, cmd: cmd, workspace: workspace})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
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
      |> Enum.map(&evaluate_assertion(&1, streams, exit_code))

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
  defp evaluate_assertion(assertion, streams, exit_code) when is_map(assertion) do
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
        evaluate_stream(target, assertion, Map.fetch!(streams, target))

      other ->
        %{target: other, match: nil, expected: nil, found: nil, passed: false}
    end
  end

  # stdout/stderr matchers. A matcher that cannot evaluate the stream (an invalid
  # regex, non-JSON output under json_path, a missing json_path path) is a FAIL —
  # the binary ran and produced output that does not satisfy the assertion — never
  # an :error, which is reserved for a binary that could not launch. The reason is
  # surfaced in the evidence so a fixer sees WHY.
  defp evaluate_stream(target, assertion, stream) do
    match = assertion_key(assertion, "match") || "equals"
    expected = assertion_key(assertion, "expected")

    {passed, extra} = apply_matcher(match, stream, expected, assertion)

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

  defp apply_matcher("equals", stream, expected, _assertion) do
    {stream == to_string_safe(expected), %{}}
  end

  defp apply_matcher("contains", stream, expected, _assertion) do
    {String.contains?(stream, to_string_safe(expected)), %{}}
  end

  defp apply_matcher("regex", stream, expected, _assertion) do
    case Regex.compile(to_string_safe(expected)) do
      {:ok, regex} -> {Regex.match?(regex, stream), %{}}
      {:error, reason} -> {false, %{reason: {:invalid_regex, inspect(reason)}}}
    end
  end

  defp apply_matcher("json_path", stream, expected, assertion) do
    path = assertion_key(assertion, "path")

    with {:ok, data} <- decode_json(stream),
         {:ok, value} <- Kazi.JSONPath.get(data, to_string_safe(path)) do
      {values_equal?(value, expected), %{path: path, extracted: value}}
    else
      {:error, reason} -> {false, %{path: path, reason: reason}}
    end
  end

  defp apply_matcher(other, _stream, _expected, _assertion) do
    {false, %{reason: {:unknown_matcher, other}}}
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
