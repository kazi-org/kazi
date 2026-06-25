defmodule Kazi.Providers.Static do
  @moduledoc """
  The `:static` predicate provider (T32.7, ADR-0043 decision 1): analysis /
  type-check / lint — the cheapest, most deterministic check, run every iteration,
  catching defects on paths the tests never execute.

  It LEADS with **Dialyzer** (kazi-native, zero false positives) and generalizes
  to the polyglot SARIF tools (`tsc`, `mypy`, `golangci-lint`, Semgrep) in the
  SAME provider — a `format` selects how the analyzer's stdout is read into
  structured, `file:line`-localized findings (`Kazi.Evidence`). The verdict is
  gated on those PARSED findings, never the exit code (a SARIF tool that exits `0`
  *with* findings is still failed — the ADR-0040 "exit 0 == pass" hazard, designed
  out), and a checker that could not run at all is an `:error`, never a `:fail`
  (ADR-0002, ADR-0040 decision 5).

  ## Two gate modes

    * **Zero-findings (no `baseline`)** — the headline Dialyzer mode: `:pass` iff
      the analyzer reports NO findings, else `:fail`. Dialyzer's zero-false-positive
      output makes failing directly on any finding safe.
    * **Baseline ratchet (a `baseline` is set)** — for the polyglot CLAIMS tools
      (generic SAST) that carry pre-existing debt: the finding COUNT is handed to
      the shared `Kazi.Ratchet` machinery (T32.3, ADR-0041) with
      `direction = :lower_better`, so the predicate IGNORES pre-existing findings
      and fails only on NEW ones (the count rising past the baseline). Security
      debt can only shrink (ADR-0043 decision 4), never block on what was already
      there.

  Either way it reports `score = finding count` and `direction = :lower_better`,
  so the loop's progress classifier and stuck-detector read the gradient (am I
  removing findings?) WITHOUT per-provider knowledge (envelope v2, ADR-0041). The
  convergence gate is unchanged: `:static` contributes only its `:pass`.

  ## Config

    * `:cmd` — the analyzer executable (string). Required. ONE executable, not a
      command line (`cmd: "mix"`, `args: ["dialyzer", "--format", "short"]`), like
      every command-runner provider (docs/lore.md L-0012).
    * `:args` — argument list (list of strings). Optional, defaults to `[]`.
    * `:env` — extra environment, a `{name, value}` list or `{name => value}` map.
      Optional.
    * `:format` — how to read findings from stdout: `"dialyzer"` (the default —
      parse Dialyzer short-format lines `file:line[:col][:tag] message`) or
      `"sarif"` (parse a SARIF log via the shared `Kazi.Evidence.Parser`). A SARIF
      parse failure is an `:error`, never a silent pass.
    * `:baseline` — selects the gate. ABSENT means zero-findings. A NUMBER, the
      strings `"stored"`/`"prior"` (the finding count's own last passing value,
      persisted and tightened on a pass; the first run seeds it), or a GIT REF
      (`"HEAD~1"`, `"main"`: the analyzer re-run at that ref in a throwaway
      worktree, its findings counted) selects the ratchet gate.
    * `:allowed_regression` — ratchet mode: how many NEW findings are tolerated
      (number, default `0` — "no new findings").
    * `:merge_stderr` — fold the analyzer's stderr into stdout for parsing/evidence.
      Optional, defaults `false`.
    * `:error_codes` — exit codes that mean the analyzer COULD NOT RUN (bad config,
      missing PLT), mapped to `:error` BEFORE findings are read. Optional.
    * `:timeout_ms` — kill the analyzer after this many milliseconds and map it to
      `:error`. Optional; absent means no timeout.

  The loader validates these at load time, so an unknown `format`, a missing
  `cmd`, or a non-numeric `allowed_regression` fails loudly at load, not at
  dispatch. See `kazi schema static`.

  ## Context

  `context[:workspace]` is where the analyzer runs and a git-ref baseline resolves;
  `context[:ratchet_store_dir]` overrides the stored-baseline directory (the same
  key the `:ratchet` provider uses, so the anti-gaming work (T32.4) relocates both
  baselines at once).

  ## Evidence

  Every result carries `:diagnostics` — the `file:line:col`/`rule`/`level`/`message`
  findings a fixer needs — plus an `evidence` map with the resolved `:cmd`,
  `:args`, `:workspace`, `:format`, the `:findings_count`, the `:exit` code, and a
  truncated `:output`. The ratchet gate adds the resolved `:baseline`,
  `:regression`, `:new_findings`, `:allowed_regression`, `:direction`,
  `:baseline_source`, and whether a new baseline was `:stored`. An `:error` carries
  a `:reason` and is never read as a pass.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Evidence, Predicate, PredicateResult, Ratchet}
  alias Kazi.Evidence.Parser
  alias Kazi.Providers.CommandRunner
  alias Kazi.Ratchet.Store

  # The recognised stdout formats. "dialyzer" is the kazi-native lead; "sarif" is
  # the polyglot path (tsc/mypy/golangci-lint/Semgrep) via the shared parser.
  @formats ~w(dialyzer sarif)

  # A static check is always lower-is-better: fewer findings is the improvement.
  @direction :lower_better

  # The baseline strings that select the metric's own stored prior count.
  @stored_keywords ~w(stored prior)

  # Keep retained raw output seed-sized — enough to orient a fixer, not a dump
  # (the structured findings are the real evidence; ADR-0041 decision 3).
  @output_limit 4_000

  # Bound the structured diagnostics so a noisy analyzer cannot flood the
  # read-model; the count is still exact in `:findings_count`.
  @diagnostics_limit 50

  # A Dialyzer short-format header line: a source file, a line, an optional column,
  # an optional colon-delimited warning TAG (`no_return`, `pattern_match`, …), then
  # the message. Anchored on a source-file extension so a summary/footer line is
  # never miscounted as a finding. A multi-line message's continuation lines do not
  # match (no `file:line`), so each warning counts exactly once.
  @dialyzer_re ~r/^\s*(?<file>\S+\.(?:ex|exs|erl|hrl)):(?<line>\d+)(?::(?<col>\d+))?(?::(?<tag>[a-z][a-z0-9_]*))?:?\s*(?<msg>.*?)\s*$/

  @doc "The stdout formats this provider accepts."
  @spec formats() :: [String.t()]
  def formats, do: @formats

  @impl true
  def evaluate(%Predicate{kind: :static, id: id, config: config}, context) do
    evaluate_config(id, config, context)
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  # Run the analyzer, parse its findings, then gate. A malformed config (missing
  # cmd, unknown format) is an :error surfaced before any work runs.
  defp evaluate_config(id, config, context) do
    workspace = context[:workspace] || File.cwd!()

    with {:ok, cmd, args} <- fetch_cmd(config),
         {:ok, format} <- fetch_format(config) do
      case run_and_parse(cmd, args, workspace, config, format) do
        {:ok, findings, exit_code, output} ->
          decide(id, config, context, workspace, format, cmd, args, findings, exit_code, output)

        {:error, evidence} ->
          PredicateResult.error(evidence)
      end
    else
      {:error, reason} -> PredicateResult.error(%{reason: reason, workspace: workspace})
    end
  end

  # =============================================================================
  # Run + parse
  # =============================================================================

  # Run the analyzer in `workspace` via the shared command-execution core, then
  # parse its stdout into findings per `format`. A declared :error_code, a missing
  # binary, a timeout, or a SARIF parse failure is an :error (never a false pass);
  # the exit code OTHERWISE does NOT decide the verdict (the SARIF gotcha) — the
  # parsed findings do.
  defp run_and_parse(cmd, args, workspace, config, format) do
    opts = [cd: workspace, stderr_to_stdout: merge_stderr?(config)] ++ env_opt(config)

    case CommandRunner.run(cmd, args, opts, Map.get(config, :timeout_ms)) do
      {:ran, output, exit_code} ->
        if error_code?(config, exit_code) do
          {:error,
           run_evidence(cmd, args, workspace, format, exit_code, output, {:error_exit, exit_code})}
        else
          case parse_findings(output, format) do
            {:ok, findings} ->
              {:ok, findings, exit_code, output}

            {:error, reason} ->
              {:error, run_evidence(cmd, args, workspace, format, exit_code, output, reason)}
          end
        end

      {:raised, message} ->
        {:error,
         %{reason: {:cmd_unrunnable, message}, cmd: cmd, args: args, workspace: workspace}}

      {:timeout, ms} ->
        {:error, %{reason: {:timeout_ms, ms}, cmd: cmd, args: args, workspace: workspace}}
    end
  end

  defp run_evidence(cmd, args, workspace, format, exit_code, output, reason) do
    %{
      reason: reason,
      cmd: cmd,
      args: args,
      workspace: workspace,
      format: format,
      exit: exit_code,
      output: truncate(output)
    }
  end

  defp parse_findings(output, "sarif"), do: Parser.sarif(output)
  defp parse_findings(output, "dialyzer"), do: {:ok, parse_dialyzer(output)}

  # Parse Dialyzer short-format output into one Evidence per warning header line.
  defp parse_dialyzer(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.flat_map(&dialyzer_line/1)
  end

  defp dialyzer_line(line) do
    case Regex.named_captures(@dialyzer_re, line) do
      nil ->
        []

      caps ->
        [
          Evidence.new(
            file: caps["file"],
            line: to_int(caps["line"]),
            col: to_int(caps["col"]),
            rule: blank_to_nil(caps["tag"]),
            level: :warning,
            message: blank_to_nil(caps["msg"])
          )
        ]
    end
  end

  # =============================================================================
  # Verdict
  # =============================================================================

  # No baseline → the Dialyzer-led zero-findings gate: any finding fails. With a
  # baseline → the ratchet gate, which ignores pre-existing findings.
  defp decide(id, config, context, workspace, format, cmd, args, findings, exit_code, output) do
    count = length(findings)
    base = base_evidence(cmd, args, workspace, format, count, exit_code, output)
    diagnostics = Enum.take(findings, @diagnostics_limit)

    case Map.get(config, :baseline) do
      nil ->
        status = if count == 0, do: :pass, else: :fail

        PredicateResult.new(status, Map.put(base, :gate, :zero_findings),
          score: count * 1.0,
          direction: @direction,
          diagnostics: diagnostics
        )

      baseline_spec ->
        ratchet_decide(
          id,
          config,
          context,
          workspace,
          format,
          cmd,
          args,
          base,
          diagnostics,
          count,
          baseline_spec
        )
    end
  end

  # The baseline ratchet on NEW findings (reuses the T32.3 machinery: the pure
  # comparison `Kazi.Ratchet.verdict/regression/tighten` and the `Store`). The
  # signal is the finding COUNT, lower-better — so a count at/below baseline passes
  # (pre-existing findings are ignored) and a count above it fails (new findings).
  defp ratchet_decide(
         id,
         config,
         context,
         workspace,
         format,
         cmd,
         args,
         base,
         diagnostics,
         count,
         baseline_spec
       ) do
    allowed = numeric(Map.get(config, :allowed_regression, 0)) || 0.0
    signal = count * 1.0

    case resolve_baseline(baseline_spec, id, config, context, workspace, format, cmd, args) do
      {:seed, _} ->
        # First stored run: nothing to regress from. Seed the baseline (record the
        # current count as the floor) and pass.
        stored? = Store.write(store_dir(config, context, workspace), id, signal) == :ok

        evidence =
          Map.merge(base, %{
            baseline: nil,
            regression: nil,
            new_findings: nil,
            allowed_regression: allowed,
            direction: @direction,
            baseline_source: :seed,
            stored: stored?
          })

        PredicateResult.new(:pass, evidence,
          score: signal,
          direction: @direction,
          diagnostics: diagnostics
        )

      {:ok, source, baseline} ->
        status = Ratchet.verdict(signal, baseline, allowed, @direction)
        regression = Ratchet.regression(signal, baseline, @direction)

        # On a pass against the STORED baseline, tighten the floor (min, since
        # lower-better) so a removed finding cannot silently creep back.
        stored? =
          if status == :pass and source == :stored do
            tightened = Ratchet.tighten(baseline, signal, @direction)
            Store.write(store_dir(config, context, workspace), id, tightened) == :ok
          else
            false
          end

        evidence =
          Map.merge(base, %{
            baseline: baseline,
            regression: regression,
            new_findings: max(regression, 0.0),
            allowed_regression: allowed,
            direction: @direction,
            baseline_source: source,
            stored: stored?
          })

        PredicateResult.new(status, evidence,
          score: signal,
          direction: @direction,
          diagnostics: diagnostics
        )

      {:error, reason} ->
        PredicateResult.error(Map.put(base, :reason, reason))
    end
  end

  # =============================================================================
  # Baseline resolution (mirrors Kazi.Ratchet's sources, over the finding count)
  # =============================================================================

  defp resolve_baseline(baseline, _id, _config, _context, _ws, _format, _cmd, _args)
       when is_number(baseline),
       do: {:ok, :literal, baseline * 1.0}

  defp resolve_baseline(baseline, id, config, context, workspace, format, cmd, args)
       when is_binary(baseline) do
    if String.downcase(baseline) in @stored_keywords do
      case Store.read(store_dir(config, context, workspace), id) do
        {:ok, value} -> {:ok, :stored, value}
        :none -> {:seed, nil}
      end
    else
      recompute_at_ref(baseline, workspace, format, cmd, args, config)
    end
  end

  defp resolve_baseline(other, _id, _config, _context, _ws, _format, _cmd, _args),
    do: {:error, {:invalid_baseline, other}}

  # Recompute the finding count against a git ref by re-running the analyzer in a
  # throwaway detached worktree, so "no new findings vs <ref>" is a real, recomputed
  # comparison. The worktree is always removed, even on an analyzer error.
  defp recompute_at_ref(ref, workspace, format, cmd, args, config) do
    tmp = Path.join(System.tmp_dir!(), "kazi-static-#{System.unique_integer([:positive])}")

    case git(workspace, ["worktree", "add", "--detach", tmp, ref]) do
      {:ok, _} ->
        try do
          case run_and_parse(cmd, args, tmp, config, format) do
            {:ok, findings, _exit, _output} -> {:ok, :git_ref, length(findings) * 1.0}
            {:error, evidence} -> {:error, {:baseline_analyzer, Map.get(evidence, :reason)}}
          end
        after
          git(workspace, ["worktree", "remove", "--force", tmp])
        end

      {:error, output} ->
        {:error, {:baseline_ref_unresolved, ref, String.trim(output)}}
    end
  end

  defp git(workspace, args) do
    {output, exit_code} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
    if exit_code == 0, do: {:ok, output}, else: {:error, output}
  rescue
    error in [ErlangError, File.Error] -> {:error, Exception.message(error)}
  end

  # =============================================================================
  # Config / helpers
  # =============================================================================

  defp fetch_cmd(config) do
    case config[:cmd] do
      cmd when is_binary(cmd) and cmd != "" -> {:ok, cmd, List.wrap(config[:args] || [])}
      nil -> {:error, :missing_cmd}
      other -> {:error, {:invalid_cmd, other}}
    end
  end

  defp fetch_format(config) do
    case Map.get(config, :format, "dialyzer") do
      format when format in @formats -> {:ok, format}
      other -> {:error, {:unknown_format, other}}
    end
  end

  defp base_evidence(cmd, args, workspace, format, count, exit_code, output) do
    %{
      cmd: cmd,
      args: args,
      workspace: workspace,
      format: format,
      findings_count: count,
      exit: exit_code,
      output: truncate(output)
    }
  end

  defp merge_stderr?(config), do: Map.get(config, :merge_stderr, false) == true

  defp error_code?(config, exit_code) do
    case Map.get(config, :error_codes) do
      codes when is_list(codes) -> exit_code in codes
      _ -> false
    end
  end

  defp store_dir(config, context, workspace) do
    config[:store_dir] || context[:ratchet_store_dir] || Path.join(workspace, ".kazi")
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

  defp to_int(nil), do: nil
  defp to_int(""), do: nil

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp numeric(n) when is_integer(n), do: n * 1.0
  defp numeric(n) when is_float(n), do: n
  defp numeric(_), do: nil

  defp truncate(output) when is_binary(output) do
    if String.length(output) > @output_limit do
      String.slice(output, 0, @output_limit) <> "…[truncated]"
    else
      output
    end
  end

  defp truncate(output), do: output
end
