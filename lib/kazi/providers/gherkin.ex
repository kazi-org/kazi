defmodule Kazi.Providers.Gherkin do
  @moduledoc """
  The `:gherkin` predicate provider (ADR-0071): reconciles a `.feature` file's
  Scenarios into per-scenario verdicts by running a caller-supplied BDD runner
  once per feature and ingesting its machine report.

  A single goal-file `[[predicate]] provider = "gherkin"` entry is EXPANDED at
  goal-load (`Kazi.Goal.Loader`, via `Kazi.Reconcile.GherkinExpander`) into one
  real sub-predicate per Scenario — and, for a `Scenario Outline`, one per
  Examples row — each carrying `kind: :gherkin` (T62.1). That load-time expansion
  preserves kazi's one-`[[predicate]]`-to-one-verdict invariant while giving
  `kazi status` per-scenario granularity (ADR-0071 decision 1). Every expanded
  sub-predicate points at the SHARED runner spec (`runner_cmd`/`runner_args`/
  `verdict_format`/`report_path`) copied from the parent entry.

  ## Verdict ingestion (T62.2, ADR-0071 decisions 2–4)

  `evaluate/2` is the RUNTIME half. The sibling sub-predicates of one feature
  share a single runner invocation:

    * **The runner runs ONCE per `(feature, runner)`, memoized** across every
      sibling in the SAME reconcile pass (decision 2). The parsed report is cached
      in the process dictionary, keyed by the current iteration so a fresh pass
      re-runs the runner but the N siblings of one pass never do. Observation is
      sequential in one process (`Kazi.Loop.observe/2`), so the cache is naturally
      per-goal-eval, never global — correct under `--parallel`/fleet because each
      loop process owns its own dictionary.
    * **Runner-agnostic ingestion, two formats** (decision 3): `cucumber_json`
      (default) — the array both godog (`--format=cucumber`) and playwright-bdd
      emit — or `scenario_map`, a minimal `{"<scenario>": "pass"|"fail"}` object.
      The report is read from the runner's **stdout** by default, or from
      `report_path` when set.
    * **Honest-unknown** (decision 4, ADR-0046): a Scenario present in the
      `.feature` but ABSENT from the report is `:unknown`, never `:fail` — kazi
      never fabricates a verdict it did not observe. A runner that fails to
      execute at all (could not spawn, timed out, or emitted no parseable report)
      makes every one of its sub-predicates `:unknown` with the runner's captured
      output (its stderr, merged into the captured stream) as evidence.

  Verdicts are read by scenario identity: the sub-predicate's `scenario` name is
  matched VERBATIM against the report. A `Scenario Outline` row additionally tries
  its example-substituted name (`Payment declined for <card>` → `... expired`)
  before the raw outline name, so a runner that substitutes the row values into
  the reported scenario name still matches. Where a runner reports every row under
  the identical outline name, the rows share the last-seen verdict — a documented
  limitation hardened against real godog output in T62.3.

  ## Atom-safety (L-0041 / #1112)

  The report is parsed with `Jason.decode/1` (string keys) and every scenario name
  is matched as a STRING — no `String.to_atom/1` on report content — so a goal
  loads and evaluates identically under `mix` and the release binary.

  ## The provider owns its config-key atoms (ADR-0071 decision 6, #1112)

  The loader admits a predicate config key only if its atom already exists
  (`String.to_existing_atom/1`, its atom-exhaustion guard, `Loader.safe_config_key/1`)
  and interns a provider's keys by force-loading the provider module named by the
  predicate's `kind`. So this module names `feature`, `scenario`, `steps`,
  `verdict_format`, `runner_cmd`, `runner_args`, `report_path`, `row_key`, and
  `example` as literal atoms PURELY so `ensure_provider_loaded(:gherkin)` interns
  them at goal-load. Without this the released binary would reject a real
  `provider = "gherkin"` goal as "unknown config key" even though every test
  passed under `mix` (the #1112 / devlog 2026-07-15 trap: `mix` loads sibling
  modules that happen to name the same atoms; the release binary does not).
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.CommandRunner

  # The provider's own config keys, named as literal atoms so the loader interns
  # them when it force-loads this module (Loader.safe_config_key/1 relies on it).
  # `feature`/`scenario`/`steps` are ALSO in the loader's @gherkin_doc_keys, but
  # naming them here too keeps the ownership honest and self-contained.
  @gherkin_keys [
    :feature,
    :scenario,
    :steps,
    :verdict_format,
    :runner_cmd,
    :runner_args,
    :report_path,
    :row_key,
    :example
  ]

  # The process-dictionary slot holding the per-pass memoized runner reports.
  # Shape: `%{gen: iteration, runs: %{run_key => outcome}}` — reset whenever the
  # observed iteration changes, so it bounds to one pass's worth of reports.
  @memo_key :kazi_gherkin_report_memo

  # Keep the retained runner output seed-sized (mirrors CustomScript): enough to
  # orient a fixer, not a full dump.
  @output_limit 4_000

  # The two supported report formats (ADR-0071 decision 3).
  @verdict_formats ~w(cucumber_json scenario_map)

  # Report/scenario-map values that mean "passed"; anything else is a fail.
  @pass_tokens ~w(pass passed ok true green success)

  @doc "The config-key atoms this provider owns (interned at goal-load)."
  @spec config_keys() :: [atom(), ...]
  def config_keys, do: @gherkin_keys

  @doc "The report formats this provider ingests."
  @spec verdict_formats() :: [String.t()]
  def verdict_formats, do: @verdict_formats

  @impl true
  def evaluate(%Predicate{kind: :gherkin, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()

    case runner_spec(config, workspace) do
      {:ok, key, spec} ->
        context
        |> memoized_report(key, spec, workspace)
        |> verdict_for(config)

      {:error, reason} ->
        # No runnable runner spec — kazi cannot observe this scenario, so it is
        # honestly :unknown (ADR-0046), never a fabricated pass or fail.
        PredicateResult.unknown(Map.put(scenario_evidence(config), :reason, reason))
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  # ── Runner spec ──────────────────────────────────────────────────────────────

  # Resolve the SHARED runner spec off the sub-predicate's config. The runner
  # command must be a non-empty string; without it there is nothing to run (a
  # goal that expanded but named no runner), so evaluation is honest :unknown.
  # The returned `key` is what siblings memoize on: it excludes the scenario, so
  # every sibling of one feature collapses to ONE cached run.
  defp runner_spec(config, workspace) do
    case config[:runner_cmd] do
      cmd when is_binary(cmd) and cmd != "" ->
        spec = %{
          cmd: cmd,
          args: List.wrap(config[:runner_args] || []),
          report_path: config[:report_path],
          verdict_format: verdict_format(config)
        }

        key =
          {workspace, config[:feature], spec.cmd, spec.args, spec.report_path,
           spec.verdict_format}

        {:ok, key, spec}

      _ ->
        {:error, :missing_runner_cmd}
    end
  end

  defp verdict_format(config) do
    case config[:verdict_format] do
      v when v in @verdict_formats -> v
      _ -> "cucumber_json"
    end
  end

  # ── Per-pass memoization (ADR-0071 decision 2) ────────────────────────────────

  # Run the runner at most once per `(feature, runner)` per reconcile pass. The
  # cache generation is the observed iteration (all siblings of one pass share it,
  # a new pass bumps it), so this re-runs each iteration for a fresh verdict while
  # the N siblings within a pass reuse the one parsed report.
  defp memoized_report(context, key, spec, workspace) do
    gen = Map.get(context, :iteration, 0)

    memo =
      case Process.get(@memo_key) do
        %{gen: ^gen} = current -> current
        _ -> %{gen: gen, runs: %{}}
      end

    case Map.fetch(memo.runs, key) do
      {:ok, outcome} ->
        outcome

      :error ->
        outcome = run_and_parse(spec, workspace)
        Process.put(@memo_key, %{memo | runs: Map.put(memo.runs, key, outcome)})
        outcome
    end
  end

  # Run the runner and parse its report into a verdict map, OR classify why kazi
  # could not observe a report at all. The captured stream MERGES stderr (a
  # runner's diagnostics land in `output`), so a runner that failed carries its
  # stderr as evidence. A well-behaved runner writing cucumber-json to stdout
  # writes only the report there; a noisy runner should write to `report_path`.
  #
  # A NONZERO exit is NOT a failure to observe: a BDD runner exits nonzero
  # precisely when a scenario fails (godog exits 1), and its report still lists
  # every scenario's real verdict — so the exit code never gates ingestion.
  defp run_and_parse(spec, workspace) do
    cmd = resolve_cmd(spec.cmd, workspace)
    opts = [cd: workspace, stderr_to_stdout: true]

    case CommandRunner.run(cmd, spec.args, opts) do
      {:ran, output, exit_code} ->
        base = %{cmd: cmd, args: spec.args, workspace: workspace, exit: exit_code}

        with {:ok, content} <- report_content(spec, workspace, output),
             {:ok, verdicts, feature_names} <- parse_report(spec.verdict_format, content) do
          {:observed,
           Map.merge(base, %{
             verdicts: verdicts,
             feature_names: feature_names,
             output: truncate(output)
           })}
        else
          {:error, reason} ->
            {:unobserved, Map.merge(base, %{reason: reason, output: truncate(output)})}
        end

      {:raised, message} ->
        {:unobserved,
         %{cmd: cmd, args: spec.args, workspace: workspace, reason: {:runner_unrunnable, message}}}
    end
  end

  # The report bytes: the runner's captured stdout by default, or the contents of
  # `report_path` when set (some runners only write a file). A missing/unreadable
  # report file is a failure to observe (not a fail), so every sibling is :unknown.
  defp report_content(%{report_path: nil}, _workspace, output), do: {:ok, output}

  defp report_content(%{report_path: path}, workspace, _output) when is_binary(path) do
    case File.read(Path.expand(path, workspace)) do
      {:ok, content} -> {:ok, content}
      {:error, posix} -> {:error, {:report_path_unreadable, path, posix}}
    end
  end

  # ── Report parsing (atom-safe: string keys throughout) ────────────────────────

  # cucumber-json: an array of features, each with `name` + `elements`. A scenario
  # element passes iff it has steps and every step's `result.status` is "passed";
  # anything else (a failed/undefined/pending/ambiguous/skipped step, or no steps)
  # is a fail. Background elements are ignored.
  defp parse_report("cucumber_json", content) do
    case Jason.decode(content) do
      {:ok, features} when is_list(features) ->
        verdicts =
          for feature <- features,
              is_map(feature),
              element <- List.wrap(feature["elements"]),
              is_map(element),
              scenario_element?(element),
              is_binary(element["name"]),
              into: %{} do
            {element["name"], scenario_verdict(element)}
          end

        names = for f <- features, is_map(f), is_binary(f["name"]), do: f["name"]
        {:ok, verdicts, names}

      {:ok, _other} ->
        {:error, :not_cucumber_json_array}

      {:error, _} ->
        {:error, :invalid_cucumber_json}
    end
  end

  # scenario_map: a flat `{"<scenario>": "pass"|"fail"}` object.
  defp parse_report("scenario_map", content) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) ->
        verdicts =
          for {name, value} <- map, is_binary(name), into: %{} do
            {name, token_verdict(value)}
          end

        {:ok, verdicts, []}

      {:ok, _other} ->
        {:error, :not_scenario_map_object}

      {:error, _} ->
        {:error, :invalid_scenario_map_json}
    end
  end

  defp scenario_element?(%{"type" => "background"}), do: false
  defp scenario_element?(_element), do: true

  defp scenario_verdict(%{"steps" => steps}) when is_list(steps) and steps != [] do
    if Enum.all?(steps, &(step_status(&1) == "passed")), do: :pass, else: :fail
  end

  # No steps (or a malformed element) never counts as a pass.
  defp scenario_verdict(_element), do: :fail

  defp step_status(%{"result" => %{"status" => status}}) when is_binary(status), do: status
  defp step_status(_step), do: "unknown"

  defp token_verdict(value) when is_binary(value) do
    if String.downcase(value) in @pass_tokens, do: :pass, else: :fail
  end

  defp token_verdict(true), do: :pass
  defp token_verdict(_value), do: :fail

  # ── Per-scenario verdict lookup ───────────────────────────────────────────────

  defp verdict_for({:unobserved, evidence}, config) do
    # The runner could not be observed — honest :unknown for EVERY sibling, with
    # the runner's captured output (its stderr) as evidence (ADR-0046, decision 4).
    PredicateResult.unknown(Map.merge(scenario_evidence(config), evidence))
  end

  defp verdict_for({:observed, %{verdicts: verdicts} = data}, config) do
    evidence =
      config
      |> scenario_evidence()
      |> Map.merge(%{exit: data.exit, output: data.output})

    case find_verdict(verdicts, candidate_names(config)) do
      {:ok, :pass} ->
        PredicateResult.pass(evidence)

      {:ok, :fail} ->
        PredicateResult.fail(evidence)

      :error ->
        # Present in the .feature, ABSENT from the report: :unknown, never :fail.
        PredicateResult.unknown(
          Map.merge(evidence, %{
            reason: :scenario_absent_from_report,
            available_scenarios: Map.keys(verdicts)
          })
        )
    end
  end

  # The report keys to try, in order: for a Scenario Outline row, the
  # example-substituted name FIRST (a runner that substitutes row values into the
  # reported name matches here), then the raw scenario name.
  defp candidate_names(config) do
    scenario = config[:scenario]

    case config[:example] do
      example when is_map(example) and map_size(example) > 0 ->
        [substitute(scenario, example), scenario] |> Enum.uniq()

      _ ->
        [scenario]
    end
  end

  defp find_verdict(verdicts, names) do
    Enum.find_value(names, :error, fn name ->
      case Map.fetch(verdicts, name) do
        {:ok, verdict} -> {:ok, verdict}
        :error -> nil
      end
    end)
  end

  defp substitute(scenario, example) when is_binary(scenario) do
    Enum.reduce(example, scenario, fn {col, val}, acc ->
      String.replace(acc, "<#{col}>", to_string(val))
    end)
  end

  defp substitute(scenario, _example), do: scenario

  # ── Evidence + command resolution ─────────────────────────────────────────────

  # The self-describing base evidence every result carries: which scenario, in
  # which feature, run by which runner and format.
  defp scenario_evidence(config) do
    %{
      feature: config[:feature],
      scenario: config[:scenario],
      runner_cmd: config[:runner_cmd],
      runner_args: config[:runner_args],
      verdict_format: verdict_format(config)
    }
  end

  # Resolve a workspace-relative `cmd` against the workspace, mirroring
  # `Kazi.Providers.CustomScript.resolve_cmd/2` (#1096): a path-shaped, executable
  # file in the workspace runs from there; a bare name stays a PATH lookup;
  # anything unresolved is left verbatim so the exec surfaces as a captured error.
  defp resolve_cmd(cmd, workspace) do
    candidate = Path.expand(cmd, workspace)

    if Path.type(cmd) == :relative and String.contains?(cmd, "/") and
         executable_file?(candidate) do
      candidate
    else
      cmd
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
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
