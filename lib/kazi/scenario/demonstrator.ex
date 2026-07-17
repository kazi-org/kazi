defmodule Kazi.Scenario.Demonstrator do
  @moduledoc """
  The **demonstrator**: a second dispatch role for `scenario` predicates (ADR-0064
  decision 3, T49.7).

  When a `scenario` predicate fails because the PIN is the blocker — `:unpinned` or
  `{:stale, :spec_changed}` — the loop dispatches a demonstrator instead of a fixer
  (routed in `Kazi.Loop`). Its job: operate the running surface, accomplish the
  Scenario literally, and write the pin that encodes how. It copies the posture of
  `Kazi.Adopt.enrich/2`: an injectable `:harness` seam, a fixed controller-owned
  prompt, validate-before-accept, and best-effort (a harness error or a bad pin
  never crashes the loop).

  ## Born reproducible (the acceptance gate)

  A freshly minted pin is accepted ONLY if, in the same dispatch, it both
  VALIDATES (the T49.1 contract) and REPLAYS green through the surface provider
  (the T49.3 delegation path). Both are exactly what `Kazi.Providers.Scenario`
  evaluates, so the gate is: run the harness, then re-evaluate the predicate — a
  `:pass` means validate-and-replay-green both held. Otherwise the write is
  DISCARDED (the pin file deleted) and the outcome carries `demonstration:
  :rejected` with the rejection reasons. This quarantines the agentic,
  nondeterministic authoring at demonstration time; evaluation stays deterministic
  and a demonstration that cannot be reproduced never lands.

  ## Write-disjoint from the fixer

  The demonstrator may write ONLY the pin path (ADR-0064 d3, enforced by the T49.6
  demonstrator-role lease the loop applies around the dispatch). The prompt states
  this constraint explicitly so the harness does not touch code, specs, or the
  goal-file — if the capability is broken, the demonstration fails honestly and
  becomes grounded evidence for the next fixer dispatch.
  """

  @prompt_version 1

  alias Kazi.Providers.Scenario
  alias Kazi.Scenario.Source

  @default_harness Kazi.Harness.ClaudeAdapter

  @typedoc "The outcome of a demonstration dispatch."
  @type outcome :: {:accepted | :rejected | :error, map()}

  @doc """
  Drives the injectable harness to mint the pin for `predicate`, then applies the
  acceptance gate.

  Returns one of:

    * `{:accepted, %{result: PredicateResult.t(), harness: term()}}` — the harness
      wrote a pin that validates AND replays green; the file is kept.
    * `{:rejected, %{demonstration: :rejected, reasons: [...], harness: term()}}` —
      the pin was missing/invalid or replayed red; the file is discarded.
    * `{:error, %{demonstration: :error, reason: term(), harness: term()}}` — the
      harness errored or raised, or the spec was unreadable; any pin is discarded.

  Best-effort: never raises. `context` needs `:workspace` (the harness cwd and the
  replay workspace). Options: `:harness` (the `Kazi.HarnessAdapter` module — the
  test seam) and `:adapter_opts` (forwarded to `run/3`).
  """
  @spec demonstrate(Kazi.Predicate.t(), map(), keyword()) :: outcome()
  def demonstrate(%Kazi.Predicate{} = predicate, context, opts \\ [])
      when is_map(context) and is_list(opts) do
    case build_payload(predicate) do
      {:ok, payload} -> drive(predicate, payload, context, opts)
      {:error, reason} -> {:error, %{demonstration: :error, reason: reason, harness: nil}}
    end
  end

  @doc """
  The fixed, versioned demonstrator prompt for a scenario `payload`.

  Byte-stable modulo the payload — the SAME scenario yields the SAME bytes every
  dispatch (the `Kazi.Harness.Debrief.question/0` precedent), so it composes with
  the prompt-cache stability discipline. Carries the Scenario text, the surface +
  exec context, the T49.1 pin contract, the T49.4 `{{name}}` inputs instruction,
  and the write-ONLY-the-pin constraint.
  """
  @spec prompt(map()) :: String.t()
  def prompt(payload) when is_map(payload) do
    """
    # Demonstrate a capability and pin it (v#{@prompt_version})

    Operate the running #{payload.surface} surface to accomplish this Gherkin
    Scenario literally, end to end, then write a PIN that replays it.

    ## Scenario: #{payload.scenario}
    #{render_steps(payload.steps)}

    ## Execution context
    #{render_exec_context(payload)}

    ## Write the pin — and ONLY the pin

    Write your realization to EXACTLY this file, and touch NOTHING else (not code,
    not the spec, not the goal-file — you are write-disjoint from the fixer):

        #{payload.pin_path}

    The pin is a JSON object in the surface provider's OWN config vocabulary:

        {
          "pin_version": 1,
          "spec": "<the .feature path>",
          "scenario": "#{payload.scenario}",
          "scenario_sha": "<SHA-256 of the normalized Scenario text>",
          "surface": "#{payload.surface}",
          "inputs": { "<name>": "<generator>" },
          "trace": { ...the steps + assertions that realize the Scenario... },
          "map": [ { "step": "<Gherkin line>", "steps": [i], "assertions": [j] } ]
        }

    Contract (the pin is REJECTED and your work discarded unless ALL hold):
      - every `When`-class step maps to >= 1 trace step, every `Then` to >= 1
        assertion (a structurally vacuous pin does not load);
      - `scenario_sha` matches the current Scenario;
      - the trace REPLAYS GREEN through the #{payload.surface} provider right now.

    ## Fresh inputs

    For any value that must be unique per replay (a name, an email), put a
    `{{placeholder}}` in the trace and declare its generator in `inputs`:
    `unique_slug`, `random_email`, or `random_string:<n>`. kazi substitutes a fresh
    value every replay, so replays are collision-free — never hardcode test data.
    #{render_inputs(payload.inputs)}
    """
  end

  @doc "The demonstrator prompt version (a versioned controller-owned constant)."
  @spec prompt_version() :: pos_integer()
  def prompt_version, do: @prompt_version

  # --- driving + the acceptance gate -----------------------------------------

  defp drive(predicate, payload, context, opts) do
    {harness, harness_opts} = resolve_harness(opts)
    workspace = context[:workspace] || File.cwd!()
    # The pin that existed BEFORE this dispatch — nil for a fresh mint, the old
    # bytes for a REPIN (a stale re-demonstration), so acceptance can diff them.
    old_pin = read_pin(payload.pin_path)

    try do
      case harness.run(prompt(payload), workspace, harness_opts) do
        {:ok, _result} = ok ->
          gate(predicate, context, payload.pin_path, old_pin, ok)

        other ->
          discard(payload.pin_path)
          {:error, %{demonstration: :error, reason: {:harness_error, other}, harness: other}}
      end
    rescue
      error ->
        discard(payload.pin_path)

        {:error,
         %{
           demonstration: :error,
           reason: {:harness_raised, Exception.message(error)},
           harness: nil
         }}
    end
  end

  # Born reproducible: the pin the harness wrote is accepted ONLY if re-evaluating
  # the predicate now returns :pass (validate AND replay-green both held). Anything
  # else discards the write. On acceptance the pin is stamped with the minted
  # commit (so a later red replay can distinguish code drift from a regression,
  # T49.8), and a REPIN carries the old-vs-new unified diff as evidence.
  defp gate(predicate, context, pin_path, old_pin, harness) do
    result = Scenario.evaluate(predicate, context)

    case result.status do
      :pass ->
        stamp_minted(pin_path, context)

        {:accepted,
         Map.merge(%{result: result, harness: harness}, repin_evidence(old_pin, pin_path))}

      _ ->
        discard(pin_path)

        {:rejected,
         %{demonstration: :rejected, reasons: rejection_reasons(result), harness: harness}}
    end
  end

  # Stamp the pin with `minted.commit = HEAD` at acceptance time. `minted` is
  # provenance only (Kazi.Scenario.Pin ignores it when validating), so re-writing
  # here does not disturb the just-validated pin. Best-effort: a non-git workspace
  # or unreadable pin simply leaves `minted` unstamped.
  defp stamp_minted(pin_path, context) do
    with head when is_binary(head) <- head_commit(context),
         {:ok, contents} <- File.read(pin_path),
         {:ok, json} when is_map(json) <- Jason.decode(contents) do
      minted = json |> Map.get("minted", %{}) |> Map.put("commit", head)
      _ = File.write(pin_path, Jason.encode!(Map.put(json, "minted", minted)))
    end

    :ok
  end

  # A REPIN (an old pin existed) carries the old→new unified diff as evidence, so
  # the operator reviewing the run sees exactly what the re-demonstration changed
  # (selector rot vs a genuine behaviour change). A fresh mint carries nothing.
  defp repin_evidence(nil, _pin_path), do: %{}

  defp repin_evidence(old_pin, pin_path) do
    case File.read(pin_path) do
      {:ok, new_pin} -> %{repin_diff: unified_diff(old_pin, new_pin)}
      _ -> %{}
    end
  end

  # A simple line-oriented unified diff over `List.myers_difference/2` (stdlib —
  # no new dependency): context lines prefixed "  ", deletions "- ", insertions
  # "+ ".
  defp unified_diff(old, new) do
    String.split(old, "\n")
    |> List.myers_difference(String.split(new, "\n"))
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &("  " <> &1))
      {:del, lines} -> Enum.map(lines, &("- " <> &1))
      {:ins, lines} -> Enum.map(lines, &("+ " <> &1))
    end)
    |> Enum.join("\n")
  end

  defp read_pin(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      _ -> nil
    end
  end

  defp head_commit(context) do
    workspace = context[:workspace] || File.cwd!()

    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp rejection_reasons(%{evidence: evidence}) do
    cond do
      is_list(evidence[:reasons]) and evidence[:reasons] != [] -> evidence[:reasons]
      Map.has_key?(evidence, :pin_state) -> [evidence[:pin_state]]
      Map.has_key?(evidence, :reason) -> [evidence[:reason]]
      true -> [:replay_red]
    end
  end

  defp discard(nil), do: :ok

  defp discard(pin_path) when is_binary(pin_path) do
    _ = File.rm(pin_path)
    :ok
  end

  defp resolve_harness(opts) do
    harness = Keyword.get(opts, :harness, @default_harness)
    {harness, Keyword.get(opts, :adapter_opts, [])}
  end

  # --- payload + prompt rendering --------------------------------------------

  defp build_payload(%Kazi.Predicate{config: config}) do
    with spec when is_binary(spec) <- config[:spec],
         name when is_binary(name) <- config[:scenario],
         {:ok, text} <- File.read(spec),
         {:ok, scenario} <- Source.extract(text, name) do
      {:ok,
       %{
         scenario: scenario.scenario,
         steps: scenario.steps,
         surface: config[:surface] || "browser",
         url: config[:url] || config[:base_url],
         cmd: config[:cmd],
         pin_path: Scenario.pin_path(config),
         inputs: config[:inputs] || %{}
       }}
    else
      _ -> {:error, :spec_unreadable}
    end
  end

  defp render_steps(steps) when is_list(steps) do
    Enum.map_join(steps, "\n", fn step -> "    #{step.keyword} #{step.text}" end)
  end

  defp render_steps(_), do: ""

  defp render_exec_context(payload) do
    [
      payload.url && "URL: #{payload.url}",
      payload.cmd && "Command: #{payload.cmd}"
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "(none configured — use the surface the goal-file already points at)"
      lines -> Enum.join(lines, "\n")
    end
  end

  defp render_inputs(inputs) when is_map(inputs) and map_size(inputs) > 0 do
    declared = inputs |> Map.keys() |> Enum.sort() |> Enum.join(", ")
    "\nThis Scenario already declares generators for: #{declared}."
  end

  defp render_inputs(_), do: ""
end
