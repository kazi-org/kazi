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
      entry (so the importer always declares every group it references),
    * `"role"` / `"priority"` / `"interface"` — present ONLY when the Scenario
      carries the matching kazi tag (see "Tags"); an untagged Scenario emits
      none of them.

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
    * `@tag` lines annotate the Feature or Scenario they sit above (see "Tags"),
    * comment lines (`#`), `Background:`, `Examples:` tables, and
      doc-strings/data-tables are skipped for predicate emission (a Scenario is
      one predicate regardless of its Examples rows).

  This is intentionally a SUBSET of full gherkin — enough to turn the
  Feature/Scenario skeleton into grouped acceptance predicates deterministically.

  ## Tags (T41.1, ADR-0054)

  The tag MECHANISM is standard Cucumber (`@tag` lines above a `Feature:` or
  `Scenario:`, several per line, Feature tags inherited by its Scenarios). The
  VOCABULARY below is kazi's own documented convention — the same honesty this
  module already applies to its gherkin subset:

    * `@role:<role>` — who the use case is for. Recorded as `role` config.
    * `@priority:P0`..`@priority:P3` — recorded as `priority` config.
    * `@interface:web|api|cli|sdk|grpc|background|ws` — how the use case is
      exercised. Recorded as `interface` config, and selects the provider (below).

  `role`/`priority`/`interface` are self-describing metadata on the predicate,
  exactly as `steps` already are: NO provider consumes them (which is why
  `Kazi.Goal.Loader` must intern their atoms — see its `@gherkin_doc_keys`).

  A tag outside this vocabulary is **IGNORED, never an error** — a team's house
  tags (`@smoke`, `@wip`, `@owner:growth`), and malformed values
  (`@priority:P9`), must not stop a real, pre-existing `.feature` file from
  importing. A Scenario's own tag wins over an inherited Feature tag.

  An UNTAGGED Scenario — and one carrying only tags outside this vocabulary —
  derives exactly the predicate it derived before tags existed, byte-identically
  (pinned by golden snapshots of the pre-T41.1 importer in
  `test/kazi/reconcile/gherkin_importer_backcompat_test.exs`). Tags are ADDITIVE.

  ## Which provider a tagged Scenario derives

  `@interface:web` derives a `browser` predicate and `@interface:api` an
  `http_probe` — but ONLY when the caller supplies a `:base_url` to probe.
  kazi never invents a url (ADR-0013: kazi scaffolds, never guesses — cf.
  `Kazi.Adopt.Writer.live_predicate_scaffold/0`, which leaves the url a `TODO`
  for a human), and a url-less `browser`/`http_probe` predicate is a LOAD error
  anyway (ADR-0058/T48.1). Without a base url the tag records its metadata and
  the `custom_script` scaffold stands. Every other interface (`cli`, `sdk`,
  `grpc`, `background`, `ws`) has no provider that could check it from a
  `.feature` alone, so it records metadata and keeps the scaffold.

  A derived live predicate is a SCAFFOLD too, and is honestly RED for the same
  reason the `custom_script` placeholder is. This needs care the command scaffold
  does not: a live provider's default is to PASS (a `browser` predicate with no
  assertions passes on any page that renders; an `http_probe` with no expectation
  passes on any completed request), so a bare derived probe would report a use
  case green while verifying nothing. Each therefore carries a placeholder
  EXPECTATION that cannot hold until a human replaces it.
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

  # kazi's own tag vocabulary (T41.1, ADR-0054), layered on real Cucumber tag
  # syntax. A value outside these sets is not recognized, so the tag is ignored.
  @priorities ~w(P0 P1 P2 P3)
  @interfaces ~w(web api cli sdk grpc background ws)

  # The `@interface` values with a dedicated live provider. Every other value
  # (cli, sdk, grpc, background, ws) has no provider that could check it from a
  # `.feature` alone, so it records metadata and keeps the scaffold.
  @interface_providers %{"web" => "browser", "api" => "http_probe"}

  # A derived LIVE predicate is a scaffold too, and must be honestly RED for the
  # same reason the cmd/args placeholder is: a `.feature` says WHAT must hold,
  # never HOW to check it. But unlike a failing command, a live provider's
  # default is to PASS — a `browser` predicate with no assertions passes on any
  # page that renders, an `http_probe` with no expectation passes on any
  # completed request. Emitting one bare would report a use case green while
  # verifying nothing, and a goal whose whole vector went green that way is
  # rejected by `Kazi.Runtime`'s t0 vacuous-goal guard. So the derived predicate
  # carries a placeholder EXPECTATION that cannot hold until replaced.
  @live_scaffold_todo "kazi: behavior-spec scaffold — replace this placeholder assertion " <>
                        "with the real check for this scenario (edit the PREDICATE, not the " <>
                        "app; the scenario's Given/When/Then steps are recorded on it)."

  @typedoc """
  Options for `import_map/2` and `import_goal/2`:

    * `:id` — the goal id (string). Defaults to `"gherkin-import"`.
    * `:name` — the goal display name. Defaults to the first Feature name when
      present, else omitted.
    * `:base_url` — the live target an `@interface:web`/`@interface:api` Scenario
      probes (string). Absent (the default), those tags record their metadata but
      keep the `custom_script` scaffold: kazi never invents a url. See "Which
      provider a tagged Scenario derives".
    * `:lower` — the lowering mode (`:test_runner` | `:scenario`, ADR-0054 d3).
      See "Lowering mode" below. Defaults to `:test_runner`.
    * `:spec_paths` — the on-disk `.feature` path for each source, aligned by
      index with `sources` (a list). Under `:scenario` lowering a derived
      `scenario` predicate records the path of the file its Scenario came from
      (the runtime `Kazi.Providers.Scenario` re-reads that spec at evaluation
      time). Ignored under `:test_runner` lowering. Only the CLI, which reads the
      files, knows these paths; a bare in-memory `import_map/2` supplies them
      explicitly.

  ## Lowering mode (ADR-0054 d3)

  `:lower` selects what a TAGGED Scenario derives; it never changes ids, groups,
  or what an UNTAGGED Scenario derives:

    * `:test_runner` (DEFAULT) — the output is byte-identical to a pre-lowering
      import (pinned by the backcompat golden snapshots). Tag-driven live
      providers (`@interface:web`/`@interface:api` + `:base_url`) still apply.
    * `:scenario` — a Scenario tagged `@interface:web` derives a `scenario`
      predicate on the `browser` surface, and `@interface:cli` a `scenario`
      predicate on the `cli` surface, wiring it to the runtime
      `Kazi.Providers.Scenario` (demonstrate-then-pin, ADR-0064) instead of the
      `custom_script` scaffold. An UNTAGGED Scenario, and one tagged with any
      OTHER interface (`api`/`sdk`/`grpc`/`background`/`ws`), stays
      `test_runner` — lowering never FORCES a Scenario into the scenario-provider
      shape it was not explicitly tagged for.
  """
  @type opts :: keyword()

  # The lowering modes `:lower` accepts (ADR-0054 d3). `:test_runner` is the
  # default and byte-identical to a pre-lowering import.
  @lower_modes [:test_runner, :scenario]

  # Under `:scenario` lowering, the `@interface` value → the scenario provider's
  # surface. Only web/cli lower; every other interface keeps the scaffold.
  @scenario_surfaces %{"web" => "browser", "cli" => "cli"}

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
    lower = Keyword.get(opts, :lower, :test_runner)

    cond do
      not Enum.all?(sources, &is_binary/1) ->
        {:error, "gherkin source must be a string or a list of strings"}

      lower not in @lower_modes ->
        {:error,
         "unknown lower mode #{inspect(lower)} (expected one of: " <>
           "#{Enum.map_join(@lower_modes, ", ", &inspect/1)})"}

      true ->
        case parse_sources(sources, opts) do
          [] ->
            {:error, "no Scenario found in the gherkin source (nothing to accept)"}

          scenarios ->
            goal = %{
              "id" => Keyword.get(opts, :id, @default_goal_id),
              "mode" => "create",
              "group" => build_groups(scenarios),
              "predicate" => build_predicates(scenarios, opts)
            }

            {:ok, maybe_put_name(goal, scenarios, opts)}
        end
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

  # Parse every source in document order, tagging each Scenario with the on-disk
  # `.feature` path of the source it came from (aligned by index with
  # `:spec_paths`). The spec path is internal bookkeeping used ONLY by `:scenario`
  # lowering; it never appears in a `:test_runner` predicate, so the default
  # output is unchanged.
  defp parse_sources(sources, opts) do
    spec_paths = Keyword.get(opts, :spec_paths, [])

    sources
    |> Enum.with_index()
    |> Enum.flat_map(fn {text, index} ->
      spec = Enum.at(spec_paths, index)
      Enum.map(parse(text), &Map.put(&1, :spec, spec))
    end)
  end

  # Parse one `.feature` file's text into a stable, document-ordered list of
  # `%{feature: name, scenario: name, steps: [line]}`. A line-based fold: a
  # `Feature:` line sets the current feature; a `Scenario:`/`Scenario Outline:`
  # line opens a new scenario; a step keyword appends to the open scenario's
  # steps; everything else (comments, tags, Background, Examples, tables) is
  # skipped. Scenarios are reversed at the end to restore document order.
  defp parse(text) do
    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.reduce(
      %{feature: nil, feature_tags: [], pending: [], current: nil, done: []},
      &parse_line/2
    )
    |> finish()
  end

  defp parse_line(line, state) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or comment?(trimmed) ->
        state

      tag?(trimmed) ->
        # Tags sit on the line(s) ABOVE the Feature/Scenario they annotate, so
        # they are held pending until that line opens.
        %{state | pending: state.pending ++ tags_on(trimmed)}

      feature = feature_name(trimmed) ->
        # A new Feature: close any open scenario, set the feature name. Its tags
        # are inherited by every Scenario under it (Cucumber semantics).
        %{close_current(state) | feature: feature, feature_tags: state.pending, pending: []}

      scenario = scenario_name(trimmed) ->
        # A new Scenario: close any open scenario, open a fresh one. Feature tags
        # come first so a Scenario's own tag WINS on conflict (last one wins).
        closed = close_current(state)

        current = %{
          feature: state.feature,
          scenario: scenario,
          steps: [],
          tags: state.feature_tags ++ state.pending
        }

        %{closed | current: current, pending: []}

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

  # A tag line carries one or more whitespace-separated tags (`@smoke @role:admin`).
  defp tags_on(line) do
    line
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&tag?/1)
  end

  # ── Tag vocabulary (T41.1, ADR-0054) ───────────────────────────────────────

  # Reduce a Scenario's tags to the recognized metadata. The tag MECHANISM is
  # standard Cucumber; this VOCABULARY is kazi's own documented convention. A tag
  # outside it — a team's house tags (`@smoke`, `@wip`), or a malformed value
  # (`@priority:P9`) — is IGNORED, never an error: a `.feature` file authored for
  # some other tool must import unchanged.
  defp tag_metadata(tags) do
    Enum.reduce(tags, %{}, fn tag, acc ->
      case recognize(tag) do
        {key, value} -> Map.put(acc, key, value)
        :unknown -> acc
      end
    end)
  end

  defp recognize("@role:" <> role) do
    case presence(String.trim(role)) do
      nil -> :unknown
      role -> {"role", role}
    end
  end

  defp recognize("@priority:" <> priority) do
    canonical = priority |> String.trim() |> String.upcase()
    if canonical in @priorities, do: {"priority", canonical}, else: :unknown
  end

  defp recognize("@interface:" <> interface) do
    canonical = interface |> String.trim() |> String.downcase()
    if canonical in @interfaces, do: {"interface", canonical}, else: :unknown
  end

  defp recognize(_tag), do: :unknown

  defp tags_of(%{tags: tags}) when is_list(tags), do: tags
  defp tags_of(_scenario), do: []

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
  defp build_predicates(scenarios, opts) do
    scenarios
    |> Enum.map(&predicate(&1, opts))
    |> Enum.uniq_by(fn predicate -> predicate["id"] end)
  end

  defp predicate(scenario, opts) do
    {group_id, _name} = group_for(scenario)
    metadata = scenario |> tags_of() |> tag_metadata()

    base = %{
      "id" => predicate_id(scenario),
      "acceptance" => true,
      "feature" => feature_name_of(scenario),
      "scenario" => scenario.scenario,
      "steps" => scenario.steps,
      "group" => group_id,
      "description" => description(scenario)
    }

    base
    |> Map.merge(provider_config(scenario, metadata, opts))
    |> Map.merge(metadata)
  end

  # The provider the Scenario derives. An `@interface` with a dedicated live
  # provider upgrades the scaffold — but ONLY when the caller supplied a
  # `:base_url` to probe: kazi never invents a url (ADR-0013 §3, live predicates
  # are scaffolded, never guessed), and a url-less browser/http_probe predicate
  # is a LOAD error anyway (ADR-0058/T48.1). With no base url the tag still
  # records its metadata and today's `custom_script` scaffold stands — which is
  # also exactly what an UNTAGGED Scenario derives, byte-identically.
  defp provider_config(scenario, metadata, opts) do
    interface = Map.get(metadata, "interface")

    case scenario_lowering(opts, interface) do
      nil ->
        base_url = Keyword.get(opts, :base_url)
        provider = Map.get(@interface_providers, interface)
        live_config(provider, base_url) || scaffold_config()

      surface ->
        scenario_config(scenario, surface)
    end
  end

  # Under `:scenario` lowering (ADR-0054 d3), a Scenario tagged `@interface:web`
  # or `@interface:cli` lowers to the runtime `scenario` provider on the matching
  # surface. Returns the surface (`"browser"`/`"cli"`) when this Scenario lowers,
  # `nil` otherwise (untagged, an other-interface tag, or `:test_runner` mode) —
  # in which case the caller keeps today's behavior. Lowering never FORCES a
  # Scenario that was not explicitly tagged for a lowerable interface.
  defp scenario_lowering(opts, interface) do
    if Keyword.get(opts, :lower, :test_runner) == :scenario do
      Map.get(@scenario_surfaces, interface)
    end
  end

  # A `scenario` predicate (demonstrate-then-pin, ADR-0064): the runtime
  # `Kazi.Providers.Scenario` re-reads `spec` at evaluation time, extracts the
  # named `scenario`, and validates/replays its committed pin on `surface`. The
  # importer records the spec path and scenario name; the pin is minted later (by
  # a demonstrator dispatch), so the predicate is honestly RED until then — the
  # same posture the `custom_script`/live scaffolds hold.
  defp scenario_config(scenario, surface) do
    %{
      "provider" => "scenario",
      "spec" => scenario_spec(scenario),
      "scenario" => scenario.scenario,
      "surface" => surface
    }
  end

  defp scenario_spec(%{spec: spec}) when is_binary(spec) and spec != "", do: spec
  defp scenario_spec(_scenario), do: ""

  defp live_config("browser", url) when is_binary(url) and url != "" do
    %{
      "provider" => "browser",
      "url" => url,
      "assertions" => [
        %{"type" => "text", "selector" => "body", "contains" => @live_scaffold_todo}
      ]
    }
  end

  defp live_config("http_probe", url) when is_binary(url) and url != "" do
    %{"provider" => "http_probe", "url" => url, "expect_body" => @live_scaffold_todo}
  end

  defp live_config(_provider, _url), do: nil

  defp scaffold_config do
    %{
      "provider" => "custom_script",
      "verdict" => @scaffold_verdict,
      "cmd" => @scaffold_cmd,
      "args" => @scaffold_args
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
