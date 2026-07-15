defmodule Kazi.Reconcile.GherkinImporter do
  @moduledoc """
  Imports the *intended set* `I` from Cucumber/gherkin `.feature` files
  (ADR-0021, decision 1): one `test_runner` **acceptance** predicate per
  Scenario, GROUPED by its Feature into the declared `[[group]]` taxonomy
  (ADR-0020). The output is a goal-file **map** in exactly the shape
  `Kazi.Goal.Loader.from_map/1` accepts, so the import round-trips through the
  same validated loader the CLI uses — no bespoke deserialiser. This is the
  gherkin sibling of `Kazi.Reconcile.OpenApiImporter` (T13.1).

  This is the deterministic, hermetic backbone of the general importer: a
  `.feature` file is pure data, so the same features always yield the same goal
  (and the same goal-file). It is NOT the prose-via-harness path (that is
  `Kazi.Authoring`, ADR-0021 decision 1 / T13.3); a behavioural spec is trusted
  directly.

  ## What it produces

  Given the text of one or more `.feature` files (a string, or a list of
  strings), `import_map/2` emits a goal map with:

    * a top-level `"id"` (caller-supplied or derived) and optional `"name"`,
    * `"mode" => "create"` — the predicates are acceptance criteria for the
      INTENDED behaviour, authored to be driven to `:pass` (T2.1, ADR-0021),
    * a `"group"` array — one `[[group]]` per distinct Feature, the group `id`
      being the NORMALIZED Feature name (`Kazi.Goal.Group.normalize_id/1`, so
      `"Sign Up"` and `"sign-up"` collapse to one group and the tree cannot
      fragment on spelling, ADR-0020), the group `name` the verbatim Feature
      name. A Scenario under a Feature with a blank or missing name falls into a
      single default group (`"ungrouped"`),
    * a `"predicate"` array — one `custom_script` acceptance predicate per
      Scenario, each carrying the `feature` it belongs to, the `scenario` name,
      the `steps` it asserts, the group it belongs to (its `group` config key),
      and a human `description`.

  ## Why `custom_script` (scaffold, not a runnable check)

  A Cucumber Scenario IS a behavioural acceptance test: its Given/When/Then
  steps describe a unit that passes or fails. But the `.feature` says WHAT must
  hold, never HOW to run it — so the derived predicate maps to the generic
  command-runner (`custom_script`, `verdict = "exit_zero"`, ADR-0040, the
  first-class successor to the deprecated `test_runner`) as a SCAFFOLD, not a
  ready-to-run check. It carries a placeholder `cmd`/`args` that LOADS
  (`custom_script` requires a non-empty `cmd`) but exits non-zero, so an imported
  goal is honestly RED until a human or coding agent replaces the command with
  the real check for that scenario (ADR-0013: kazi scaffolds, never guesses). The
  scenario's steps are recorded on the predicate so whoever wires the runner
  knows exactly what behaviour to assert (and the surface-coverage
  meta-predicate, T13.5, can match it).

  ## Config shape per predicate

  Each predicate is the goal-file shape (string keys; the loader's RESERVED keys
  `id`/`provider`/`description`/`acceptance`/`group`, and every other key
  collected verbatim into the provider's `config`):

    * `"verdict"` — `"exit_zero"`: the scenario passes when its command exits 0,
    * `"cmd"` / `"args"` — the placeholder scaffold command (exits non-zero) a
      human replaces with the scenario's real check,
    * `"feature"` — the verbatim Feature name the Scenario belongs to,
    * `"scenario"` — the verbatim Scenario name,
    * `"steps"` — the ordered list of step lines (`"Given a user"`, …), recorded
      so the predicate is self-describing,
    * `"group"` — the normalized group id this Scenario belongs to (its
      Feature). A RESERVED predicate key (T12.2): the loader lands it on
      `Kazi.Predicate.group` and VALIDATES it references a declared `[[group]]`
      entry (so the importer always declares every group it references).

  ## Determinism, hermeticity & re-import (upsert)

  Pure over its input: no network, no clock, no filesystem (the caller reads the
  files; this module takes their text). The same features yield a byte-identical
  goal map — Scenarios are emitted in document order, grouped by Feature, and
  groups in sorted id order. Predicate ids are DERIVED from the Feature + the
  Scenario name (`"sign-up__a-new-user-signs-up"`), so a re-import of the same
  features produces the same ids: an upsert, not a duplicate. Two Scenarios that
  would derive the same id are de-duplicated, keeping the first.

  ## Line-based parser (no gherkin dependency)

  kazi does not depend on a gherkin/cucumber parser and adding one is an
  ADR-gated decision (per the project's stack-conventions: "do not pull heavy
  deps without an ADR"). This importer therefore parses the simple
  `Feature:` / `Scenario:` / `Scenario Outline:` structure with a small,
  pure line-based parser:

    * a `Feature:` line opens a Feature (its trailing text is the name),
    * a `Scenario:` or `Scenario Outline:` line opens a Scenario,
    * `Given` / `When` / `Then` / `And` / `But` / `*` lines are the Scenario's
      steps (carried verbatim as the predicate's recorded steps),
    * comment lines (`#`), tags (`@tag`), `Background:`, `Examples:` tables, and
      doc-strings/data-tables are skipped for predicate emission (a Scenario is
      one predicate regardless of its Examples rows).

  This is intentionally a SUBSET of full gherkin — enough to turn the
  Feature/Scenario skeleton into grouped acceptance predicates deterministically.
  """

  alias Kazi.Goal
  alias Kazi.Goal.Group

  # The group a Scenario whose Feature has a blank/missing name falls into. A
  # normalized slug so it never collides with a real Feature's normalized id.
  @default_group_id "ungrouped"
  @default_group_name "Ungrouped"

  @default_goal_id "gherkin-import"

  # Step keywords that open a step line. `*` is the gherkin "bullet" step.
  @step_keywords ~w(Given When Then And But *)

  # A behavior spec states WHAT behavior must hold, not HOW to check it — so the
  # derived predicate is a SCAFFOLD, not a runnable check (ADR-0013: kazi
  # scaffolds, never guesses). It carries a placeholder `cmd`/`args` that LOADS
  # (custom_script requires a non-empty cmd) but exits non-zero, so the goal is
  # honestly RED until a human or coding agent replaces the command with the real
  # check for this scenario. The scenario's Given/When/Then steps ride along on
  # the predicate (its `steps` config) so whoever wires the runner knows exactly
  # what behavior to assert.
  @scaffold_verdict "exit_zero"
  @scaffold_cmd "sh"
  @scaffold_args [
    "-c",
    "echo 'kazi: behavior-spec scaffold — replace cmd/args with the real check " <>
      "for this scenario (its Given/When/Then steps are recorded on this predicate).' >&2; exit 1"
  ]

  @typedoc """
  Options for `import_map/2` and `import_goal/2`:

    * `:id` — the goal id (string). Defaults to `"gherkin-import"`.
    * `:name` — the goal display name. Defaults to the first Feature name when
      present, else omitted.
  """
  @type opts :: keyword()

  @doc """
  Imports gherkin `.feature` text into a goal **map** (the
  `Kazi.Goal.Loader.from_map/1` shape).

  `source` is the text of one `.feature` file (a string) or a LIST of such
  strings (one per file). Returns `{:ok, goal_map}` or `{:error, reason}` with a
  human-readable reason when no Scenario could be parsed (an empty or
  Feature-only input has nothing to accept).

  The returned map round-trips: `Kazi.Goal.Loader.from_map(goal_map)` loads it
  into a `Kazi.Goal` with the grouped acceptance predicates. See the moduledoc
  for options and the per-predicate config shape.

  ## Examples

      iex> feature = \"""
      ...> Feature: Sign Up
      ...>   Scenario: A new user signs up
      ...>     Given a visitor on the home page
      ...>     When they submit the sign-up form
      ...>     Then their account is created
      ...> \"""
      iex> {:ok, map} = Kazi.Reconcile.GherkinImporter.import_map(feature)
      iex> map["mode"]
      "create"
      iex> [predicate] = map["predicate"]
      iex> {predicate["provider"], predicate["scenario"], predicate["group"]}
      {"custom_script", "A new user signs up", "sign-up"}
  """
  @spec import_map(String.t() | [String.t()], opts()) :: {:ok, map()} | {:error, String.t()}
  def import_map(source, opts \\ [])

  def import_map(source, opts) when is_binary(source) and is_list(opts) do
    import_map([source], opts)
  end

  def import_map(sources, opts) when is_list(sources) and is_list(opts) do
    if Enum.all?(sources, &is_binary/1) do
      scenarios = Enum.flat_map(sources, &parse/1)

      case scenarios do
        [] ->
          {:error, "no Scenario found in the gherkin source (nothing to accept)"}

        scenarios ->
          goal = %{
            "id" => Keyword.get(opts, :id, @default_goal_id),
            "mode" => "create",
            "group" => build_groups(scenarios),
            "predicate" => build_predicates(scenarios)
          }

          {:ok, maybe_put_name(goal, scenarios, opts)}
      end
    else
      {:error, "gherkin source must be a string or a list of strings"}
    end
  end

  def import_map(_source, _opts),
    do: {:error, "gherkin source must be a string or a list of strings"}

  @doc """
  Imports gherkin `.feature` text directly into a `Kazi.Goal` (via the loader).

  Convenience over `import_map/2` + `Kazi.Goal.Loader.from_map/1`: returns
  `{:ok, %Kazi.Goal{}}` or `{:error, reason}`. The goal is in `:create` mode
  with the grouped `test_runner` acceptance predicates and the declared group
  taxonomy.
  """
  @spec import_goal(String.t() | [String.t()], opts()) :: {:ok, Goal.t()} | {:error, String.t()}
  def import_goal(source, opts \\ []) do
    with {:ok, map} <- import_map(source, opts) do
      Goal.Loader.from_map(map)
    end
  end

  # ── Parsing ────────────────────────────────────────────────────────────────

  # Parse one `.feature` file's text into a stable, document-ordered list of
  # `%{feature: name, scenario: name, steps: [line]}`. A line-based fold: a
  # `Feature:` line sets the current feature; a `Scenario:`/`Scenario Outline:`
  # line opens a new scenario; a step keyword appends to the open scenario's
  # steps; everything else (comments, tags, Background, Examples, tables) is
  # skipped. Scenarios are reversed at the end to restore document order.
  defp parse(text) do
    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.reduce(%{feature: nil, current: nil, done: []}, &parse_line/2)
    |> finish()
  end

  defp parse_line(line, state) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or comment?(trimmed) or tag?(trimmed) ->
        state

      feature = feature_name(trimmed) ->
        # A new Feature: close any open scenario, set the feature name.
        %{close_current(state) | feature: feature}

      scenario = scenario_name(trimmed) ->
        # A new Scenario: close any open scenario, open a fresh one.
        closed = close_current(state)
        %{closed | current: %{feature: state.feature, scenario: scenario, steps: []}}

      step = step_line(trimmed) ->
        append_step(state, step)

      true ->
        # Background:, Examples:, table rows, doc-strings, free text — skipped.
        state
    end
  end

  # Append a step to the currently-open scenario. A step before any Scenario:
  # (e.g. under Background:) has no open scenario and is dropped.
  defp append_step(%{current: nil} = state, _step), do: state

  defp append_step(%{current: current} = state, step) do
    %{state | current: %{current | steps: [step | current.steps]}}
  end

  # Move the open scenario (if any) onto the done list, restoring its step order.
  defp close_current(%{current: nil} = state), do: state

  defp close_current(%{current: current, done: done} = state) do
    finished = %{current | steps: Enum.reverse(current.steps)}
    %{state | current: nil, done: [finished | done]}
  end

  defp finish(state) do
    state
    |> close_current()
    |> Map.fetch!(:done)
    |> Enum.reverse()
  end

  defp comment?("#" <> _rest), do: true
  defp comment?(_line), do: false

  defp tag?("@" <> _rest), do: true
  defp tag?(_line), do: false

  # A `Feature:` line. Returns the trimmed name (possibly empty → handled by the
  # default group). `nil` when the line is not a Feature line.
  defp feature_name("Feature:" <> rest), do: String.trim(rest)
  defp feature_name(_line), do: nil

  # A `Scenario:` or `Scenario Outline:` line. Returns the trimmed scenario name.
  # `nil` when the line is neither. "Scenario Outline:" is checked first so the
  # longer prefix wins.
  defp scenario_name("Scenario Outline:" <> rest), do: presence(String.trim(rest)) || "Scenario"
  defp scenario_name("Scenario:" <> rest), do: presence(String.trim(rest)) || "Scenario"
  defp scenario_name(_line), do: nil

  # A step line: starts with a step keyword followed by whitespace (or is a bare
  # `*` bullet). Returns the whole line verbatim so the recorded step reads
  # naturally ("Given a user"). `nil` when the line is not a step.
  defp step_line(line) do
    if Enum.any?(@step_keywords, &step_prefix?(line, &1)), do: line, else: nil
  end

  defp step_prefix?(line, "*"), do: line == "*" or String.starts_with?(line, "* ")

  defp step_prefix?(line, keyword) do
    String.starts_with?(line, keyword <> " ")
  end

  # ── Emission ─────────────────────────────────────────────────────────────────

  # One `[[group]]` per distinct Feature, keyed by the NORMALIZED id so spelling
  # variants collapse to a single group (ADR-0020). The group `name` is the
  # verbatim first-seen Feature name. Sorted by id for determinism.
  defp build_groups(scenarios) do
    scenarios
    |> Enum.map(&group_for/1)
    |> Enum.uniq_by(fn {id, _name} -> id end)
    |> Enum.sort_by(fn {id, _name} -> id end)
    |> Enum.map(fn {id, name} -> %{"id" => id, "name" => name} end)
  end

  # One `test_runner` acceptance predicate per Scenario, in document order. A
  # derived id (Feature + Scenario name) makes re-import an UPSERT: the same
  # features yield the same ids, never duplicates. A same-id collision (two
  # Scenarios that derive the same id) is de-duplicated, keeping the first.
  defp build_predicates(scenarios) do
    scenarios
    |> Enum.map(&predicate/1)
    |> Enum.uniq_by(fn predicate -> predicate["id"] end)
  end

  defp predicate(scenario) do
    {group_id, _name} = group_for(scenario)

    %{
      "id" => predicate_id(scenario),
      "provider" => "custom_script",
      "verdict" => @scaffold_verdict,
      "acceptance" => true,
      "cmd" => @scaffold_cmd,
      "args" => @scaffold_args,
      "feature" => feature_name_of(scenario),
      "scenario" => scenario.scenario,
      "steps" => scenario.steps,
      "group" => group_id,
      "description" => description(scenario)
    }
  end

  # The group a Scenario belongs to: its Feature, normalized to a canonical slug.
  # A blank/missing Feature name → the default group. Returns
  # `{normalized_id, display_name}`.
  defp group_for(scenario) do
    case presence(feature_name_of(scenario)) do
      nil -> {@default_group_id, @default_group_name}
      name -> {Group.normalize_id(name), name}
    end
  end

  defp feature_name_of(%{feature: feature}) when is_binary(feature), do: feature
  defp feature_name_of(_scenario), do: ""

  # A stable predicate id derived from Feature + Scenario name so re-import
  # upserts: the normalized Feature slug, two underscores, then the Scenario name
  # with non-alphanumerics collapsed to hyphens. Pure and total.
  defp predicate_id(scenario) do
    feature_slug =
      case presence(feature_name_of(scenario)) do
        nil -> @default_group_id
        name -> Group.normalize_id(name)
      end

    scenario_slug = slug(scenario.scenario)

    "#{feature_slug}__#{scenario_slug}"
  end

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  # The predicate's human description: the Scenario name, plus its steps joined
  # on a separator so the grouped view reads as the behaviour being accepted.
  defp description(%{scenario: name, steps: []}), do: name

  defp description(%{scenario: name, steps: steps}) do
    "#{name}: #{Enum.join(steps, "; ")}"
  end

  # The goal name: an explicit `:name` opt wins; else the first Scenario's
  # Feature name (the first feature seen, document order).
  defp maybe_put_name(goal, scenarios, opts) do
    case Keyword.get(opts, :name) || first_feature_name(scenarios) do
      nil -> goal
      name -> Map.put(goal, "name", name)
    end
  end

  defp first_feature_name(scenarios) do
    scenarios
    |> Enum.map(&feature_name_of/1)
    |> Enum.find_value(&presence/1)
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil
end
