defmodule Kazi.Providers.Scenario do
  @moduledoc """
  The `:scenario` predicate provider (ADR-0064, T49.3): replay a pinned Gherkin
  Scenario by DELEGATING to a surface provider.

  This is the composing half of the pin machinery. `Kazi.Scenario.Source` (T49.2)
  reads and hashes one Scenario out of a `.feature` file; `Kazi.Scenario.Pin`
  (T49.1) parses and validates the committed pin against it. Both are pure. This
  provider owns the I/O (reading the spec and the pin file) and the composition:
  it classifies the pin, and only a `:pinned` classification is REPLAYED through
  the underlying surface provider (`:browser`, `:cli`, …). The predicate passes
  only when that replay passes — no demonstration transcript or agent claim can
  satisfy it (the ADR-0064 decision-1 truth invariant).

  ## Pin state is failing work, not error

  A pin that is `:unpinned`, `{:stale, _}` or `{:invalid, _}` is a real,
  actionable FAILURE (`:fail`) the loop routes work at — re-demonstrate or repair
  the pin — never an ambiguous provider `:error`. Only a genuinely un-runnable
  condition (the spec file is missing, the named Scenario is absent, the surface
  has no registered provider) is `:error`.

  ## Config

  Read from `Kazi.Predicate.config`:

    * `:spec`     — required. Path to the `.feature` file holding the Scenario.
    * `:scenario` — required. The Scenario name to bind and replay.
    * `:surface`  — optional. Which surface provider replays the pin's trace
      (default `"browser"`); resolved through `Kazi.Runtime.provider_modules/0`.
    * `:pin`      — optional. Path to the pin artifact. Defaults to
      `docs/specs/pins/<derived-id>.pin.json`, the derived id being the same
      Feature+Scenario slug the Gherkin importer mints (upsert-safe).
    * `:repin`    — optional. `"auto"` (default) or `"manual"`; consumed by the
      minting path (T49.4), inert here.

  Every other key passes through UNCHANGED to the delegate provider, so the
  `url`/`base_url`/`samples`/`cmd` stub-seam config works exactly as it does when
  authoring against that provider directly. On a `:pinned` replay the pin's
  `trace` (already the surface provider's own config vocabulary) is merged OVER
  that passthrough, so a pin is a compile target onto the surface provider, not a
  second execution grammar.

  ## Evidence

  A non-pinned `:fail` carries `%{pin_state:, pin_path:, scenario_steps:,
  reasons:}` so a fixer knows which artifact blocks the predicate and why. A
  `:pinned` replay returns the delegate's status/score/direction VERBATIM, with
  its evidence EXTENDED (not replaced) by `%{scenario:, spec:, surface:,
  pin_state: :pinned}`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Goal.Group
  alias Kazi.Scenario.{Inputs, Pin, Source}

  @default_surface "browser"
  @pin_dir "docs/specs/pins"

  # The provider's own config keys; everything else is passthrough to the
  # delegate. Listed as literal atoms so the loader interns them when it
  # force-loads this module (safe_config_key/1 relies on that).
  @scenario_keys [:spec, :scenario, :surface, :pin, :repin]

  # T49.12: the delegate config keys a scenario predicate passes through, named
  # here as literal atoms PURELY so they are interned when this module loads.
  #
  # Why this is needed even though `resolve_delegate/1` already force-loads the
  # delegate: that happens inside `evaluate/2`, at RUNTIME. The goal LOADER runs
  # much earlier and admits a config key only if its atom already exists
  # (`String.to_existing_atom/1`, its atom-exhaustion guard), interning keys by
  # force-loading the predicate's OWN provider — `:scenario` — and nothing else.
  # So a goal-file saying `provider = "scenario"` + `samples = 3` was rejected as
  # "unknown config key \"samples\"" before evaluate ever ran, even though the
  # passthrough itself works and the docs promise it. `mix` hid this: it loads
  # Kazi.Providers.Browser (which names :samples), so the atom happened to exist.
  # Purge Browser and the loader rejects it — the same trap as the Gherkin
  # doc-keys (loader's @gherkin_doc_keys, devlog 2026-07-15).
  #
  # A bounded, fixed list — no atom-exhaustion risk. It only needs the keys a
  # delegate accepts that no OTHER always-loaded module already names; listing a
  # few extra is harmless. If a surface provider grows a config key, add it here
  # (pinned by a loader test).
  @delegate_passthrough_keys [
    :url,
    :base_url,
    :samples,
    :steps,
    :assertions,
    :viewport,
    :screenshot,
    :timeout_ms,
    :cmd,
    :args,
    :env
  ]

  @doc false
  def delegate_passthrough_keys, do: @delegate_passthrough_keys

  @impl true
  def evaluate(%Predicate{kind: :scenario, config: config} = predicate, context) do
    surface = config[:surface] || @default_surface

    with {:ok, spec_text} <- read_spec(config[:spec]),
         {:ok, scenario} <- extract_scenario(spec_text, config[:scenario]) do
      pin_path = config[:pin] || default_pin_path(scenario)
      contents = read_pin(pin_path)
      parsed = parse_pin(contents)

      case Pin.classify(contents, parsed, scenario, sha_fun: &Source.sha/1) do
        :pinned ->
          pinned(parsed, predicate, config, scenario, surface, pin_path, context)

        {:stale, _} = stale ->
          # T49.8: `repin = "manual"` parks a stale pin as `:stale_manual` — never
          # auto-demonstrated, deliberately operator/attention-queue work.
          fail_state(stale_or_manual(stale, config), scenario, pin_path)

        state ->
          fail_state(state, scenario, pin_path)
      end
    else
      {:error, result} -> result
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  defp read_spec(path) when is_binary(path) do
    case File.read(path) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        {:error, PredicateResult.error(%{reason: :spec_not_found, path: path, detail: reason})}
    end
  end

  defp read_spec(path),
    do: {:error, PredicateResult.error(%{reason: :spec_not_found, path: path})}

  defp extract_scenario(text, name) when is_binary(name) do
    case Source.extract(text, name) do
      {:ok, scenario} ->
        {:ok, scenario}

      {:error, :scenario_not_found} ->
        {:error, PredicateResult.error(%{reason: :scenario_not_found, scenario: name})}
    end
  end

  defp extract_scenario(_text, name),
    do: {:error, PredicateResult.error(%{reason: :scenario_not_found, scenario: name})}

  defp read_pin(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _} -> nil
    end
  end

  defp parse_pin(nil), do: nil

  defp parse_pin(contents) do
    case Pin.parse(contents) do
      {:ok, pin} -> pin
      {:error, _reason} = err -> err
    end
  end

  # :unpinned | {:stale, _} | {:invalid, _} — routed failing work, never :error.
  defp fail_state(state, scenario, pin_path) do
    PredicateResult.fail(%{
      pin_state: state,
      pin_path: pin_path,
      scenario_steps: Map.get(scenario, :steps, []),
      reasons: reasons_for(state)
    })
  end

  defp reasons_for(:unpinned), do: []
  defp reasons_for(:stale_manual), do: [:stale_manual]
  defp reasons_for({:stale, _} = stale), do: [stale]
  defp reasons_for({:invalid, reasons}), do: reasons

  # `repin = "manual"` re-tags any stale state as `:stale_manual` (T49.8) so the
  # loop never auto-dispatches a demonstrator for it — it is operator work.
  defp stale_or_manual(stale, config) do
    if Map.get(config, :repin, "auto") == "manual", do: :stale_manual, else: stale
  end

  defp pinned(pin, predicate, config, scenario, surface, pin_path, context) do
    case resolve_delegate(surface) do
      {:ok, surface_atom, module} ->
        replay(module, surface_atom, pin, predicate, config, scenario, surface, pin_path, context)

      :error ->
        PredicateResult.error(%{
          reason: :surface_unavailable,
          surface: surface,
          pin_path: pin_path
        })
    end
  end

  # Fresh input generation (T49.4) happens HERE, before delegation: every
  # `{{placeholder}}` in the trace is substituted with a value generated fresh for
  # this replay so replays stay collision-free and un-hardcodeable (ADR-0064 d2).
  # An unresolvable generator is a pin defect — an :invalid FAIL, never a silent
  # literal driven into the surface. The generated values land in evidence so a
  # failing replay is reproducible.
  defp replay(module, surface_atom, pin, predicate, config, scenario, surface, pin_path, context) do
    case Inputs.substitute(pin.trace, pin.inputs, rand_fun(context)) do
      {:error, {:unknown_generator, name}} ->
        fail_state({:invalid, [{:unknown_generator, name}]}, scenario, pin_path)

      {trace, generated} ->
        delegate_config = build_delegate_config(config, trace)
        delegate = Predicate.new(predicate.id, surface_atom, config: delegate_config)
        result = module.evaluate(delegate, context)

        extension = %{
          scenario: scenario.scenario,
          spec: config[:spec],
          surface: surface,
          pin_state: :pinned,
          inputs: generated
        }

        result = %{result | evidence: Map.merge(result.evidence, extension)}
        reclassify_replay(result, pin, config, scenario, pin_path, context)
    end
  end

  # T49.8: a RED replay of a `:pinned` scenario is re-classified as
  # `{:stale, :code_drift}` (demonstrator work) ONLY when `HEAD` has moved since
  # the pin was minted — the code changed, so a red replay is plausibly the pin
  # gone stale rather than a regression. At the minted commit (or with no minted
  # commit / unreadable HEAD) a red replay stays a plain `:pinned` `:fail` — a real
  # regression, which is FIXER work. `repin = "manual"` parks drift as
  # `:stale_manual` (never auto-demonstrated).
  defp reclassify_replay(%{status: :fail} = result, pin, config, scenario, pin_path, context) do
    if code_drifted?(pin, context) do
      state = stale_or_manual({:stale, :code_drift}, config)

      PredicateResult.fail(%{
        pin_state: state,
        pin_path: pin_path,
        scenario_steps: Map.get(scenario, :steps, []),
        reasons: reasons_for(state),
        replay_evidence: Map.take(result.evidence, [:assertions, :url, :runs])
      })
    else
      result
    end
  end

  defp reclassify_replay(result, _pin, _config, _scenario, _pin_path, _context), do: result

  defp code_drifted?(%Pin{minted: minted}, context) when is_map(minted) do
    case {Map.get(minted, "commit"), head_commit(context)} do
      {minted_commit, head} when is_binary(minted_commit) and is_binary(head) ->
        minted_commit != head

      _ ->
        false
    end
  end

  defp code_drifted?(_pin, _context), do: false

  defp head_commit(context) do
    workspace = context[:workspace] || File.cwd!()

    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The randomness seam: a test injects a fixed rand fun via context for
  # determinism; production falls back to Inputs' strong-random default.
  defp rand_fun(context), do: context[:rand_fun] || (&:crypto.strong_rand_bytes/1)

  # The pin's trace (string-keyed, the surface provider's vocabulary) merged OVER
  # the passthrough config, so a pinned scenario replays through the delegate with
  # its demonstrated url/steps/assertions and the goal-file's own cmd/env seam.
  defp build_delegate_config(config, trace) when is_map(trace) do
    passthrough = Map.drop(config, @scenario_keys)
    Map.merge(passthrough, atomize_trace(trace))
  end

  defp build_delegate_config(config, _trace), do: Map.drop(config, @scenario_keys)

  defp atomize_trace(trace) do
    Map.new(trace, fn {key, value} -> {trace_key(key), value} end)
  end

  defp trace_key(key) when is_atom(key), do: key
  defp trace_key(key) when is_binary(key), do: String.to_existing_atom(key)

  # Force-loads the delegate module so its config-key atoms (`:url`, `:samples`,
  # …) are interned before `atomize_trace/1` maps the pin's string-keyed trace
  # onto them with String.to_existing_atom/1 — the release binary would otherwise
  # reject a valid trace key that no loaded module had named yet (the atom-
  # interning landmine, devlog 2026-07-15). An unknown surface, or one whose
  # module cannot load, is :surface_unavailable.
  defp resolve_delegate(surface) do
    modules = Kazi.Runtime.provider_modules()

    try do
      atom = String.to_existing_atom(surface)

      with {:ok, module} <- Map.fetch(modules, atom),
           {:module, ^module} <- Code.ensure_loaded(module) do
        {:ok, atom, module}
      else
        _ -> :error
      end
    rescue
      ArgumentError -> :error
    end
  end

  @doc """
  The effective pin path for a scenario predicate's `config`: the explicit
  `config[:pin]` when set, else the derived `docs/specs/pins/<derived-id>.pin.json`
  (reading the spec to recover the Feature for the derived id).

  Returns `nil` when the pin is not configured AND the default cannot be derived
  (the spec is unreadable or the named Scenario is absent) — the same inputs the
  provider would `:error` on at evaluation. Total and crash-safe, so a caller
  (the loader's role-default derivation, T49.6) never fails on a malformed goal.
  """
  @spec pin_path(map()) :: String.t() | nil
  def pin_path(config) when is_map(config) do
    config[:pin] || derived_pin_path(config)
  end

  defp derived_pin_path(config) do
    with spec when is_binary(spec) <- config[:spec],
         name when is_binary(name) <- config[:scenario],
         {:ok, text} <- File.read(spec),
         {:ok, scenario} <- Source.extract(text, name) do
      default_pin_path(scenario)
    else
      _ -> nil
    end
  end

  defp default_pin_path(scenario) do
    Path.join(@pin_dir, derived_id(scenario) <> ".pin.json")
  end

  # Mirrors Kazi.Reconcile.GherkinImporter's derived id (Feature slug, two
  # underscores, Scenario slug) so a scenario predicate and its imported twin name
  # the same pin file.
  defp derived_id(scenario) do
    feature_slug =
      case Map.get(scenario, :feature) do
        name when is_binary(name) and name != "" -> Group.normalize_id(name)
        _ -> "ungrouped"
      end

    "#{feature_slug}__#{slug(scenario.scenario)}"
  end

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
