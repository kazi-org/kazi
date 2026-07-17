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
  defp reasons_for({:stale, _} = stale), do: [stale]
  defp reasons_for({:invalid, reasons}), do: reasons

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

        %{result | evidence: Map.merge(result.evidence, extension)}
    end
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
