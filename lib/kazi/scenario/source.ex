defmodule Kazi.Scenario.Source do
  @moduledoc """
  Reads ONE Scenario out of a `.feature` file and hashes it (ADR-0064, T49.2).

  This is the identity half of the pin machinery. A pin (`Kazi.Scenario.Pin`)
  records a replayable realization of a single Scenario; that realization is
  only trustworthy while the Scenario it demonstrates is unchanged. So a pin
  carries `scenario_sha` — `sha/1` of the Scenario as it read at pin time — and
  the provider recomputes it before every replay. A Scenario edit therefore
  makes every stale pin *detectable* rather than silently replaying a trace that
  no longer demonstrates the stated behaviour (ADR-0064 decision 2).

  ## What the hash must ignore, and what it must not

  `normalize/1` defines the identity: the `Scenario:` line plus its steps, each
  trimmed with internal whitespace collapsed, keywords kept. The consequences
  are deliberate:

    * **Comments, tags, blank lines and re-indentation do not move the hash.**
      They carry no behavioural meaning, and churning them would invalidate
      every pin in the repo for nothing.
    * **Step text moves the hash.** That is the whole point — the pin's claim is
      about *these* Given/When/Then lines.
    * **The Scenario name moves the hash**, so a rename that re-aims a Scenario
      at different behaviour is caught.
    * **The enclosing Feature name does NOT move the hash.** Renaming a Feature
      re-files a Scenario; it does not change what the Scenario asserts, and a
      Feature rename must not invalidate every pin beneath it.

  ## Step classes

  Each step is decomposed into `%{keyword:, text:, class:}`. `class` is the
  *primary* keyword in effect — `And`, `But` and `*` inherit the class of the
  nearest preceding `Given`/`When`/`Then`, which is what gherkin means by them.
  This is what lets `Kazi.Scenario.Pin.validate/2` hold its structural-
  faithfulness floor ("every When-class step maps to a trace step, every
  Then-class step to an assertion") over an `And`-heavy Scenario. A leading
  `And`/`But`/`*` with no preceding primary keyword is malformed gherkin; it is
  classified `:given`, the class its position implies, rather than rejected —
  extraction is not a linter.

  ## Relationship to `Kazi.Reconcile.GherkinImporter`

  Both walk the same line-scan subset (`Feature:` / `Scenario:` / step lines,
  with tag and comment lines filtered), and this module mirrors that subset
  exactly — including `Scenario Outline:` matching and the `"Scenario"` fallback
  for an unnamed Scenario. It does not *share* the importer's helpers: the
  importer records each step as its verbatim whole line, whereas a pin needs the
  keyword split from the text and classified, so a shared helper would have to
  change the importer's output shape. The importer's output is a goal-file map
  that must stay byte-identical, so the matcher is duplicated here on purpose.
  Keep the two in step if the subset itself ever changes.
  """

  @step_keywords ~w(Given When Then And But *)

  @primary_classes %{"Given" => :given, "When" => :when, "Then" => :then}

  # A leading And/But/* has no primary keyword to inherit from. Its position
  # implies the Given block.
  @default_class :given

  @type step_class :: :given | :when | :then

  @type step :: %{keyword: String.t(), text: String.t(), class: step_class()}

  @type t :: %{feature: String.t() | nil, scenario: String.t(), steps: [step()]}

  @doc """
  Extracts the Scenario named `scenario_name` from one `.feature` file's `text`.

  Returns `{:ok, %{feature:, scenario:, steps:}}`, where `feature` is the name of
  the enclosing `Feature:` (`nil` when the Scenario has none) and each step is
  `%{keyword:, text:, class:}` in document order. Returns
  `{:error, :scenario_not_found}` when no Scenario carries that name.

  A `Scenario Outline:` matches by name like any other Scenario; its steps are
  returned with their `<placeholders>` intact and its `Examples:` table ignored
  (a pin realizes the Scenario, not one expansion of it). Steps above the first
  `Scenario:` — a `Background:` — belong to no Scenario and are dropped. When two
  Scenarios share a name, the first in document order wins.

      iex> feature = "Feature: Checkout\\n  Scenario: A guest checks out\\n    Given an anonymous session\\n    Then the order is confirmed\\n"
      iex> {:ok, extracted} = Kazi.Scenario.Source.extract(feature, "A guest checks out")
      iex> extracted.feature
      "Checkout"
      iex> Enum.map(extracted.steps, &{&1.keyword, &1.class})
      [{"Given", :given}, {"Then", :then}]
  """
  @spec extract(String.t(), String.t()) :: {:ok, t()} | {:error, :scenario_not_found}
  def extract(text, scenario_name) when is_binary(text) and is_binary(scenario_name) do
    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.reduce(%{feature: nil, current: nil, done: []}, &scan_line/2)
    |> finish()
    |> Enum.find(&(&1.scenario == scenario_name))
    |> case do
      nil -> {:error, :scenario_not_found}
      found -> {:ok, classify(found)}
    end
  end

  @doc """
  Renders an extracted Scenario to its canonical text — the input to `sha/1`.

  The `Scenario:` line then one line per step, each trimmed with internal
  whitespace collapsed and its keyword kept. See the moduledoc for what this
  identity deliberately includes and ignores.
  """
  @spec normalize(t()) :: String.t()
  def normalize(%{scenario: scenario, steps: steps}) do
    ["Scenario: " <> collapse(scenario) | Enum.map(steps, &normalize_step/1)]
    |> Enum.join("\n")
  end

  @doc """
  The lowercase hex SHA-256 of `normalize/1` — a Scenario's content identity.

  This is the value a pin stores as `scenario_sha` and the one
  `Kazi.Scenario.Pin.validate/2` recomputes to decide whether a pin is current
  or `{:stale, :spec_changed}`.
  """
  @spec sha(t()) :: String.t()
  def sha(scenario) when is_map(scenario) do
    :sha256
    |> :crypto.hash(normalize(scenario))
    |> Base.encode16(case: :lower)
  end

  # ── Parsing ────────────────────────────────────────────────────────────────

  # A line-based fold mirroring `Kazi.Reconcile.GherkinImporter`'s subset: a
  # `Feature:` line sets the current feature; a `Scenario:`/`Scenario Outline:`
  # line opens a new scenario; a step keyword appends to the open scenario;
  # everything else (comments, tags, Background, Examples, tables, free text) is
  # skipped. Steps are collected as raw lines and classified once the scenario
  # closes, because a step's class depends on the ones before it.
  defp scan_line(line, state) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or comment?(trimmed) or tag?(trimmed) ->
        state

      feature = feature_name(trimmed) ->
        %{close_current(state) | feature: feature}

      scenario = scenario_name(trimmed) ->
        closed = close_current(state)
        %{closed | current: %{feature: state.feature, scenario: scenario, steps: []}}

      step = step_line(trimmed) ->
        append_step(state, step)

      true ->
        state
    end
  end

  # A step above the first `Scenario:` (a Background:) has no open scenario.
  defp append_step(%{current: nil} = state, _step), do: state

  defp append_step(%{current: current} = state, step) do
    %{state | current: %{current | steps: [step | current.steps]}}
  end

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

  defp feature_name("Feature:" <> rest), do: String.trim(rest)
  defp feature_name(_line), do: nil

  # "Scenario Outline:" is checked first so the longer prefix wins.
  defp scenario_name("Scenario Outline:" <> rest), do: presence(String.trim(rest)) || "Scenario"
  defp scenario_name("Scenario:" <> rest), do: presence(String.trim(rest)) || "Scenario"
  defp scenario_name(_line), do: nil

  # A step line: a step keyword followed by whitespace, or a bare `*` bullet.
  # Returns `{keyword, text}`; `nil` when the line is not a step.
  defp step_line(line) do
    Enum.find_value(@step_keywords, fn keyword ->
      if step_prefix?(line, keyword), do: {keyword, step_text(line, keyword)}
    end)
  end

  defp step_prefix?(line, "*"), do: line == "*" or String.starts_with?(line, "* ")

  defp step_prefix?(line, keyword), do: String.starts_with?(line, keyword <> " ")

  defp step_text(line, keyword) do
    line
    |> String.replace_prefix(keyword, "")
    |> String.trim()
  end

  # ── Classification ─────────────────────────────────────────────────────────

  # And/But/* inherit the class of the nearest preceding primary keyword.
  defp classify(%{steps: steps} = scenario) do
    {classified, _last} =
      Enum.map_reduce(steps, @default_class, fn {keyword, text}, last ->
        class = Map.get(@primary_classes, keyword, last)
        {%{keyword: keyword, text: text, class: class}, class}
      end)

    %{scenario | steps: classified}
  end

  # ── Normalization ──────────────────────────────────────────────────────────

  defp normalize_step(%{keyword: keyword, text: text}), do: collapse(keyword <> " " <> text)

  defp collapse(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil
end
