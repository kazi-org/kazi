defmodule Kazi.Providers.Mutation do
  @moduledoc """
  The `:mutation` predicate provider (T32.8, ADR-0043): mutation testing — the
  only test-QUALITY signal in the catalog.

  Coverage proves a line was EXECUTED; it says nothing about whether a test would
  CATCH a defect on that line. Mutation testing does: it injects small faults
  (mutants) and measures how many the suite kills. The score — `killed / total` —
  is a 0-1 gradient of suite STRENGTH, and the SURVIVING mutants are the most
  actionable evidence a fixer can get ("this exact change to this line went
  undetected — assert on it").

  This provider runs a mutation tool, parses its JSON report, and maps it to an
  envelope-v2 result:

    * `score` is the 0-1 mutation score (`direction: :higher_better`).
    * the verdict is `score >= threshold` — and the threshold is NEVER 100%
      (the loader rejects `>= 1.0`). A perfect mutation score is an unrealistic,
      gameable target (equivalent mutants make 100% unreachable); the gate is a
      pragmatic floor that ratchets up, not a demand for perfection.
    * surviving mutants ride in the evidence.

  Scope the run to CHANGED LINES via the tool's own flags (e.g. a `--diff` / `--since`
  argument in `:args`) — mutating the whole tree every iteration is too slow; kazi
  drives the tool, the tool does the diff-scoping.

  The verdict is read from the PARSED score, not the exit code (mutation tools
  commonly exit non-zero when the score is below threshold — gating on the exit
  code would conflate "score too low" with "tool could not run"). The convergence
  gate is unchanged: a mutation predicate contributes only its `:pass`.

  ## Config

    * `:cmd`  — the executable (string). Required. ONE executable, not a command
      line; use `:args` (lore L-0012).
    * `:args` — argument list (list of strings). Optional, defaults to `[]`. This
      is where the diff-scoping flag goes.
    * `:env`  — extra environment, a `{name, value}` list or a `{name => value}`
      map. Optional.
    * `:threshold` — the 0-1 score floor the run must meet. Required, and must be
      `>= 0` and `< 1.0` (NEVER 100%, enforced at load).
    * `:score_path` — a `Kazi.JSONPath` over stdout to a PRECOMPUTED 0-1 score. Use
      this when the tool already reports a ratio.
    * `:killed_path` / `:survived_path` — alternatively, paths to the killed and
      survived COUNTS; the score is `killed / (killed + survived)`. A run with no
      mutants in scope (`killed + survived == 0`) is `:pass` with no score (nothing
      to evaluate — an empty changed-line scope).
    * `:survivors_path` — a `Kazi.JSONPath` to the surviving-mutant list, surfaced
      (bounded) as evidence. Optional.
    * `:merge_stderr` — fold stderr into stdout for the parsed output. Optional,
      defaults `false`.
    * `:timeout_ms` — kill the command after this many ms and map it to `:error`.
      Optional; absent means no timeout.

  ## Context

  `context[:workspace]` is the directory the command runs in (`cd:`). Defaults to
  the current directory when absent.

  ## Evidence

  Every result carries the resolved `:cmd`, `:args`, `:workspace`, the `:exit`
  code, the `:threshold`, the computed `:score`, and a truncated `:output`. When
  computed from counts it adds `:killed` and `:survived`; with a `:survivors_path`
  it adds a bounded `:survivors` list. An `:error` carries a `:reason`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.CommandRunner

  @output_limit 4_000
  # Keep the surviving-mutant sample bounded — enough to orient a fixer, not a
  # full dump.
  @survivor_sample_limit 20

  @impl true
  def evaluate(%Predicate{kind: :mutation, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()

    with {:ok, cmd, args} <- fetch_cmd(config) do
      run(cmd, args, workspace, config)
    else
      {:error, reason} -> PredicateResult.error(%{reason: reason, workspace: workspace})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  defp fetch_cmd(config) do
    case config[:cmd] do
      cmd when is_binary(cmd) and cmd != "" -> {:ok, cmd, List.wrap(config[:args] || [])}
      nil -> {:error, :missing_cmd}
      other -> {:error, {:invalid_cmd, other}}
    end
  end

  defp run(cmd, args, workspace, config) do
    opts = [cd: workspace, stderr_to_stdout: merge_stderr?(config)] ++ env_opt(config)

    case CommandRunner.run(cmd, args, opts, Map.get(config, :timeout_ms)) do
      {:ran, output, exit_code} ->
        evidence = base_evidence(cmd, args, workspace, config, exit_code, output)
        score_and_decide(output, config, evidence)

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

  # Read the score from the PARSED report (not the exit code), compare to the
  # threshold. A JSON parse failure or a missing path is an :error, never a silent
  # pass — the same gotcha the custom_script json verdict designs out.
  defp score_and_decide(output, config, evidence) do
    with {:ok, data} <- decode_json(output),
         {:ok, score, evidence} <- compute_score(data, config, evidence) do
      decide(score, config, evidence)
    else
      :empty_scope ->
        # No mutants in the changed-line scope: nothing to evaluate, so pass with
        # no score (an empty scope is not a quality regression).
        PredicateResult.new(:pass, Map.put(evidence, :note, :no_mutants_in_scope),
          direction: :higher_better
        )

      {:error, reason} ->
        PredicateResult.error(Map.put(evidence, :reason, reason))
    end
  end

  # The threshold is validated < 1.0 at load (NEVER 100%); pass iff score meets it.
  defp decide(score, config, evidence) do
    threshold = numeric(Map.get(config, :threshold))
    evidence = Map.merge(evidence, %{score: score, threshold: threshold})
    status = if score >= threshold, do: :pass, else: :fail

    PredicateResult.new(status, with_survivors(evidence, config, score_data(evidence)),
      score: score,
      direction: :higher_better
    )
  end

  # =============================================================================
  # Score computation
  # =============================================================================

  # Prefer a precomputed score_path; else compute killed/(killed+survived) from the
  # count paths. The returned evidence carries the counts when computed from them.
  defp compute_score(data, config, evidence) do
    cond do
      is_binary(config[:score_path]) ->
        with {:ok, raw} <- Kazi.JSONPath.get(data, config[:score_path]),
             {:ok, number} <- Kazi.JSONPath.to_number(raw) do
          {:ok, number * 1.0, Map.put(evidence, :data, data)}
        end

      is_binary(config[:killed_path]) and is_binary(config[:survived_path]) ->
        score_from_counts(data, config, evidence)

      true ->
        {:error, :missing_score_config}
    end
  end

  defp score_from_counts(data, config, evidence) do
    with {:ok, killed_raw} <- Kazi.JSONPath.get(data, config[:killed_path]),
         {:ok, killed} <- Kazi.JSONPath.to_number(killed_raw),
         {:ok, survived_raw} <- Kazi.JSONPath.get(data, config[:survived_path]),
         {:ok, survived} <- Kazi.JSONPath.to_number(survived_raw) do
      total = killed + survived

      if total == 0 do
        :empty_scope
      else
        evidence = Map.merge(evidence, %{killed: killed, survived: survived, data: data})
        {:ok, killed / total, evidence}
      end
    end
  end

  # The parsed document is stashed on the evidence so with_survivors/3 can read the
  # survivor list without re-decoding.
  defp score_data(evidence), do: Map.get(evidence, :data)

  defp with_survivors(evidence, config, data) do
    evidence = Map.delete(evidence, :data)

    case {Map.get(config, :survivors_path), data} do
      {path, data} when is_binary(path) and not is_nil(data) ->
        case Kazi.JSONPath.get(data, path) do
          {:ok, list} when is_list(list) ->
            Map.put(evidence, :survivors, Enum.take(list, @survivor_sample_limit))

          _ ->
            evidence
        end

      _ ->
        evidence
    end
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  defp merge_stderr?(config), do: Map.get(config, :merge_stderr, false) == true

  defp base_evidence(cmd, args, workspace, config, exit_code, output) do
    %{
      cmd: cmd,
      args: args,
      workspace: workspace,
      threshold: numeric(Map.get(config, :threshold)),
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
