defmodule Kazi.Scenario.Pin do
  @moduledoc """
  The **pin**: a committed, replayable realization of one Gherkin Scenario
  (ADR-0064 decision 2).

  A `scenario` predicate binds one tagged Scenario in the `docs/specs/` tier
  (ADR-0050) to exactly one pin, and passes ONLY when that pin validates here
  and then REPLAYS green through the underlying surface provider. No
  demonstration transcript or agent claim can satisfy it (the ADR-0064
  decision-1 truth invariant). This module owns the deterministic half of that
  contract: parsing the artifact and validating it, before any replay happens.

  ## Purity

  This module performs NO I/O. It takes the pin file's contents as a string and
  the extracted Scenario as a map; callers (`Kazi.Providers.Scenario`) read the
  files. Validation is a pure function of those two inputs, which is what keeps
  evaluation cheap and deterministic while the agentic nondeterminism stays
  quarantined at demonstration time.

  ## The artifact

  One JSON file per Scenario, at `docs/specs/pins/<derived-id>.pin.json` (the
  `Kazi.Reconcile.GherkinImporter` derived id, so the name is stable and
  upsert-safe):

      {
        "pin_version": 1,
        "spec": "docs/specs/pat.feature",
        "scenario": "User can create and download a PAT",
        "scenario_sha": "<lowercase hex SHA-256 of the normalized Scenario text>",
        "surface": "browser",
        "minted": {"commit": "0f1e2d3c4b5a"},
        "inputs": {"pat_name": "unique_slug"},
        "trace": {
          "url": "/settings/tokens",
          "steps": [
            {"action": "click", "selector": "#new-token"},
            {"action": "type", "selector": "#name", "text": "{{pat_name}}"}
          ],
          "assertions": [{"type": "visible", "selector": "#token-value"}]
        },
        "map": [
          {"step": "I create a token", "steps": [0, 1], "assertions": []},
          {"step": "the token value is shown", "steps": [], "assertions": [0]}
        ]
      }

  `trace` is the executable realization expressed in EXACTLY the surface
  provider's existing config vocabulary, and is kept verbatim (string-keyed,
  undisturbed) through parsing — a pin is a compile target onto the
  `:browser`/`:cli` providers, not a second execution grammar, so it inherits
  `samples`/consecutive-pass and every future assertion type for free.

  `map` records which trace entries realize each Gherkin step, and `inputs`
  names the `{{placeholder}}` generators the provider substitutes fresh at
  every replay (T49.4) so replays are collision-free and a fixer cannot
  hardcode a happy path.

  ## Validation rules

  Each rule reports its own named reason, and `validate/3` reports every rule
  that is violated rather than stopping at the first:

    * `{:pin_version, %{expected:, found:}}` — the artifact version is not 1.
    * `{:stale, :spec_changed}` — `scenario_sha` does not match the current
      Scenario. Reported bare (no detail map) because the pin-state enum uses
      this tuple directly.
    * `{:bad_surface, %{found:, allowed:}}` — `surface` is outside
      `"browser"`/`"cli"`.
    * `{:unknown_trace_key, %{key:, surface:, allowed:}}` — `trace` carries a
      key outside its surface's whitelist.
    * `{:unmapped_when, %{step:}}` — a When-class step maps to zero trace
      steps.
    * `{:unmapped_then, %{step:}}` — a Then-class step maps to zero trace
      assertions.
    * `{:index_out_of_range, %{step:, list:, index:, count:}}` — a `map` index
      does not address an entry in the trace list it names.
    * `{:uncovered_placeholder, %{name:}}` — a `{{name}}` appears in `trace`
      with no `inputs` entry to generate it.

  The two `unmapped_*` rules are the **structural-faithfulness floor** of
  ADR-0064 decision 2: every `When` must map to >= 1 step and every `Then` to
  >= 1 assertion, so a structurally vacuous pin does not load. This guarantees
  structural, not semantic, faithfulness — a pin whose steps and assertions are
  well-formed but describe the wrong behavior still validates. That residual
  gap is named honestly in the ADR's Consequences and is why a freshly minted
  pin must also replay green before it is accepted.

  Given-class steps need no mapping: they describe preconditions, which the
  trace may reach without a distinct step of its own.

  ## The scenario SHA seam

  `validate/3` never computes the SHA itself, so that this module stays pure
  and free of a dependency on `Kazi.Scenario.Source` (T49.2). The current
  Scenario's SHA arrives one of two ways:

      Pin.validate(pin, scenario, sha_fun: &Kazi.Scenario.Source.sha/1)
      Pin.validate(pin, Map.put(scenario, :sha, Kazi.Scenario.Source.sha(scenario)))

  Composition happens in `Kazi.Providers.Scenario` (T49.3), which owns both.
  """

  @pin_version 1

  @surfaces ["browser", "cli"]

  # Per-surface trace contract. `keys` is the whitelist of keys a pin's trace
  # may carry: the REALIZATION only. Execution passthrough the goal-file owns
  # (browser `cmd`/`args`/`env`, cli `cmd`/`env`/`cd`) is deliberately absent —
  # a pin records what was done, never which binary does it.
  #
  # `steps`/`assertions` name the trace lists that `map` indices address.
  # The cli entry follows the ADR-0053 section 2 config vocabulary; its
  # provider lands in T43.7/T43.8.
  @trace_contract %{
    "browser" => %{
      keys: ["url", "steps", "assertions", "timeout_ms", "samples"],
      steps: "steps",
      assertions: "assertions"
    },
    "cli" => %{
      keys: ["args", "script", "assertions", "golden", "timeout_ms", "samples"],
      steps: "script",
      assertions: "assertions"
    }
  }

  @placeholder_pattern ~r/\{\{\s*([A-Za-z0-9_]+)\s*\}\}/

  defstruct pin_version: nil,
            spec: nil,
            scenario: nil,
            scenario_sha: nil,
            surface: nil,
            minted: %{},
            inputs: %{},
            trace: %{},
            map: []

  @type t :: %__MODULE__{
          pin_version: integer() | nil,
          spec: String.t() | nil,
          scenario: String.t() | nil,
          scenario_sha: String.t() | nil,
          surface: String.t() | nil,
          minted: map(),
          inputs: map(),
          trace: map(),
          map: list()
        }

  @typedoc """
  The Scenario as `Kazi.Scenario.Source.extract/2` (T49.2) produces it. May
  additionally carry `:sha` to supply the current hash without a `:sha_fun`.
  """
  @type scenario :: %{
          optional(:feature) => String.t(),
          optional(:scenario) => String.t(),
          optional(:sha) => String.t(),
          optional(:steps) => [%{keyword: String.t(), text: String.t(), class: step_class()}]
        }

  @type step_class :: :given | :when | :then

  @type reason ::
          {:malformed_json, map()}
          | {:malformed_pin, map()}
          | {:pin_version, map()}
          | {:stale, :spec_changed}
          | {:bad_surface, map()}
          | {:unknown_trace_key, map()}
          | {:unmapped_when, map()}
          | {:unmapped_then, map()}
          | {:index_out_of_range, map()}
          | {:uncovered_placeholder, map()}

  @typedoc """
  Which artifact blocks the predicate (ADR-0064 decision 4). Only `:pinned`
  can lead to a `:pass`; every other state is `:fail` — routed work, never
  `:error`.
  """
  @type state ::
          :pinned
          | :unpinned
          | {:stale, :spec_changed | :code_drift}
          | {:invalid, [reason()]}

  @doc """
  Parses a pin file's contents into a `t:t/0`.

  Structural only — every semantic rule lives in `validate/3`. `trace`, `map`,
  `inputs` and `minted` are kept exactly as decoded (string-keyed) so a trace
  reaches its surface provider byte-identical to what was demonstrated.

  Returns `{:error, {:malformed_json, _}}` for undecodable input and
  `{:error, {:malformed_pin, _}}` for a JSON document that is not an object.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, reason()}
  def parse(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, json} when is_map(json) ->
        {:ok, from_json(json)}

      {:ok, other} ->
        {:error, {:malformed_pin, %{expected: :object, found: json_type(other)}}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:malformed_json, %{detail: Exception.message(error)}}}
    end
  end

  defp from_json(json) do
    %__MODULE__{
      pin_version: Map.get(json, "pin_version"),
      spec: Map.get(json, "spec"),
      scenario: Map.get(json, "scenario"),
      scenario_sha: Map.get(json, "scenario_sha"),
      surface: Map.get(json, "surface"),
      minted: Map.get(json, "minted") || %{},
      inputs: Map.get(json, "inputs") || %{},
      trace: Map.get(json, "trace") || %{},
      map: Map.get(json, "map") || []
    }
  end

  defp json_type(term) when is_list(term), do: :list
  defp json_type(term) when is_binary(term), do: :string
  defp json_type(term) when is_number(term), do: :number
  defp json_type(term) when is_boolean(term), do: :boolean
  defp json_type(nil), do: :null

  @doc """
  Validates a pin against the current Scenario.

  Returns `:ok`, or `{:error, reasons}` listing EVERY violated rule (see the
  moduledoc for the rule/reason table). Runs before any replay, so a pin that
  cannot be trusted never reaches the surface provider.

  ## Options

    * `:sha_fun` — a 1-arity function taking the scenario and returning its
      current lowercase-hex SHA-256, normally `&Kazi.Scenario.Source.sha/1`.

  Without `:sha_fun` the scenario map must carry `:sha`. Supplying neither is a
  caller bug, not a validation failure, and raises `ArgumentError`.
  """
  @spec validate(t(), scenario(), keyword()) :: :ok | {:error, [reason()]}
  def validate(pin, scenario, opts \\ [])

  def validate(%__MODULE__{} = pin, scenario, opts) when is_map(scenario) and is_list(opts) do
    reasons =
      version_reasons(pin) ++
        sha_reasons(pin, current_sha(scenario, opts)) ++
        surface_reasons(pin) ++
        trace_key_reasons(pin) ++
        map_reasons(pin, scenario) ++
        placeholder_reasons(pin)

    case reasons do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  end

  defp current_sha(scenario, opts) do
    case Keyword.fetch(opts, :sha_fun) do
      {:ok, fun} when is_function(fun, 1) ->
        fun.(scenario)

      _ ->
        case Map.fetch(scenario, :sha) do
          {:ok, sha} ->
            sha

          :error ->
            raise ArgumentError,
                  "Kazi.Scenario.Pin.validate/3 needs the current Scenario SHA: pass " <>
                    "sha_fun: &Kazi.Scenario.Source.sha/1, or put it on the scenario map " <>
                    "under :sha"
        end
    end
  end

  defp version_reasons(%__MODULE__{pin_version: @pin_version}), do: []

  defp version_reasons(%__MODULE__{pin_version: found}),
    do: [{:pin_version, %{expected: @pin_version, found: found}}]

  defp sha_reasons(%__MODULE__{scenario_sha: sha}, sha), do: []
  defp sha_reasons(%__MODULE__{}, _current), do: [{:stale, :spec_changed}]

  defp surface_reasons(%__MODULE__{surface: surface}) when surface in @surfaces, do: []

  defp surface_reasons(%__MODULE__{surface: found}),
    do: [{:bad_surface, %{found: found, allowed: @surfaces}}]

  defp trace_key_reasons(%__MODULE__{surface: surface, trace: trace}) when is_map(trace) do
    case contract(surface) do
      nil ->
        []

      %{keys: allowed} ->
        trace
        |> Map.keys()
        |> Enum.reject(&(&1 in allowed))
        |> Enum.sort()
        |> Enum.map(&{:unknown_trace_key, %{key: &1, surface: surface, allowed: allowed}})
    end
  end

  defp trace_key_reasons(%__MODULE__{}), do: []

  defp contract(surface), do: Map.get(@trace_contract, surface)

  # Coverage (the structural-faithfulness floor) plus index range. Both need
  # the surface's trace contract to know WHICH lists the map addresses, so an
  # unknown surface reports only :bad_surface rather than a cascade.
  defp map_reasons(%__MODULE__{surface: surface} = pin, scenario) do
    case contract(surface) do
      nil -> []
      contract -> coverage_reasons(pin, scenario) ++ range_reasons(pin, contract)
    end
  end

  # A map entry always names its indices under "steps"/"assertions"; only the
  # TRACE list those indices address changes with the surface.
  defp coverage_reasons(%__MODULE__{} = pin, scenario) do
    scenario
    |> Map.get(:steps, [])
    |> Enum.flat_map(fn step ->
      case Map.get(step, :class) do
        :when -> unmapped(pin, step, "steps", :unmapped_when)
        :then -> unmapped(pin, step, "assertions", :unmapped_then)
        _other -> []
      end
    end)
  end

  defp unmapped(%__MODULE__{map: map}, step, field, reason) do
    case entry_for(map, step) do
      nil ->
        [{reason, %{step: step_label(step), detail: :no_map_entry}}]

      entry ->
        case indices(entry, field) do
          [] -> [{reason, %{step: step_label(step), detail: :empty_mapping}}]
          _ -> []
        end
    end
  end

  # A pin's map entry may name the bare step text or the full keyword line;
  # both are compared with the whitespace normalization T49.2's hash uses, so
  # a reflowed .feature file does not read as an unmapped step.
  defp entry_for(map, step) when is_list(map) do
    targets =
      MapSet.new([
        normalize(Map.get(step, :text)),
        normalize("#{Map.get(step, :keyword)} #{Map.get(step, :text)}")
      ])

    Enum.find(map, fn
      entry when is_map(entry) -> MapSet.member?(targets, normalize(Map.get(entry, "step")))
      _ -> false
    end)
  end

  defp entry_for(_map, _step), do: nil

  defp indices(entry, field) when is_map(entry) do
    case Map.get(entry, field) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp range_reasons(%__MODULE__{map: map} = pin, contract) when is_list(map) do
    counts = %{
      "steps" => pin |> trace_list(contract.steps) |> length(),
      "assertions" => pin |> trace_list(contract.assertions) |> length()
    }

    lists = %{"steps" => contract.steps, "assertions" => contract.assertions}

    Enum.flat_map(map, fn entry ->
      Enum.flat_map(["steps", "assertions"], fn field ->
        entry
        |> indices(field)
        |> Enum.reject(&in_range?(&1, counts[field]))
        |> Enum.map(fn index ->
          {:index_out_of_range,
           %{
             step: entry |> Map.get("step") |> normalize(),
             list: lists[field],
             index: index,
             count: counts[field]
           }}
        end)
      end)
    end)
  end

  defp range_reasons(%__MODULE__{}, _contract), do: []

  defp in_range?(index, count) when is_integer(index), do: index >= 0 and index < count
  defp in_range?(_index, _count), do: false

  defp trace_list(%__MODULE__{trace: trace}, key) when is_map(trace) do
    case Map.get(trace, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp trace_list(%__MODULE__{}, _key), do: []

  # Every {{name}} the trace interpolates must have a generator, or the replay
  # would drive a literal "{{name}}" into the surface (ADR-0064 decision 2:
  # fresh values per replay are what keep replays collision-free).
  defp placeholder_reasons(%__MODULE__{trace: trace, inputs: inputs}) do
    declared = inputs |> keys_of() |> MapSet.new()

    trace
    |> placeholders()
    |> Enum.reject(&MapSet.member?(declared, &1))
    |> Enum.map(&{:uncovered_placeholder, %{name: &1}})
  end

  defp keys_of(inputs) when is_map(inputs), do: Map.keys(inputs)
  defp keys_of(_inputs), do: []

  defp placeholders(term) do
    term
    |> strings([])
    |> Enum.flat_map(&Regex.scan(@placeholder_pattern, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
  end

  defp strings(term, acc) when is_binary(term), do: [term | acc]

  defp strings(term, acc) when is_map(term) do
    Enum.reduce(term, acc, fn {key, value}, acc ->
      acc |> then(&strings(key, &1)) |> then(&strings(value, &1))
    end)
  end

  defp strings(term, acc) when is_list(term), do: Enum.reduce(term, acc, &strings/2)
  defp strings(_term, acc), do: acc

  defp normalize(nil), do: ""

  defp normalize(text) when is_binary(text),
    do: text |> String.trim() |> String.replace(~r/\s+/, " ")

  defp normalize(other), do: inspect(other)

  defp step_label(step) do
    normalize("#{Map.get(step, :keyword)} #{Map.get(step, :text)}")
  end

  @doc """
  Classifies which artifact blocks the predicate (ADR-0064 decision 4).

  Takes the pin file's contents (`nil` when the file is absent — callers own
  the read), the `parse/1` result, and the current Scenario. Only `:pinned`
  permits a replay, and only a green replay may then produce `:pass`; every
  other state is `:fail` carrying routed work, never `:error`.

  A changed Scenario reports `{:stale, :spec_changed}` even when the pin is
  also invalid: the spec moved, so the pin is re-demonstrated wholesale rather
  than repaired.

  Accepts the same options as `validate/3`.
  """
  @spec classify(String.t() | nil, t() | {:error, reason()} | nil, scenario(), keyword()) ::
          state()
  def classify(contents, pin, scenario, opts \\ [])

  def classify(nil, _pin, _scenario, _opts), do: :unpinned

  def classify(_contents, {:error, reason}, _scenario, _opts), do: {:invalid, [reason]}

  def classify(_contents, %__MODULE__{} = pin, scenario, opts) do
    case validate(pin, scenario, opts) do
      :ok ->
        :pinned

      {:error, reasons} ->
        if {:stale, :spec_changed} in reasons do
          {:stale, :spec_changed}
        else
          {:invalid, reasons}
        end
    end
  end
end
