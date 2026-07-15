defmodule Kazi.Reconcile.GherkinExpander do
  @moduledoc """
  Enumerates the RUNTIME sub-predicate set a `.feature` produces for the
  `gherkin` provider (ADR-0071): one entry per Scenario, and -- unlike the
  author-time `Kazi.Reconcile.GherkinImporter` (ADR-0021/T13.2), which collapses
  a `Scenario Outline` to a single scaffold -- **one entry per Examples row** for
  an outline, so `kazi status` can show which row is red.

  This is the load-time expansion keystone: the loader turns one
  `[[predicate]] provider = "gherkin"` entry into these entries (each a real
  sub-predicate, preserving one-predicate-one-verdict), and the provider matches
  each against the runner's cucumber-json by scenario identity.

  Pure over its input (a `.feature` string). Deterministic: entries are emitted
  in document order, outline rows in table order.

  ## Entry shape

      %{
        id: "feature-slug__scenario-slug"            # + "__row-slug" for outline rows
        feature: "Checkout",                          # verbatim Feature name
        scenario: "A shopper checks out",             # verbatim Scenario name
        steps: ["Given ...", ...],                    # <placeholders> substituted for outline rows
        outline?: false,
        example: nil,                                 # %{"card" => "expired"} for an outline row
        row_key: nil                                  # "expired" for an outline row
      }

  The id scheme matches `GherkinImporter` for a plain Scenario
  (`<feature>__<scenario>`), so a feature that has no outlines expands to the
  same ids the author-time importer derives.

  ## Parsed subset

  `Feature:`, `Scenario:`, `Scenario Outline:` (also `Scenario Template:`),
  `Given/When/Then/And/But/*` steps, and `Examples:` tables. Comments (`#`), tags
  (`@tag`), `Background:` steps, and doc-strings are skipped. A `Scenario Outline`
  with no Examples rows yields no entries (there is nothing to run).
  """

  alias Kazi.Goal.Group

  @step_keywords ~w(Given When Then And But *)

  @typedoc "One expanded sub-predicate the `gherkin` provider reconciles."
  @type entry :: %{
          id: String.t(),
          feature: String.t(),
          scenario: String.t(),
          steps: [String.t()],
          outline?: boolean(),
          example: %{String.t() => String.t()} | nil,
          row_key: String.t() | nil
        }

  @doc """
  Expands `.feature` text into the ordered list of runtime sub-predicate entries.
  Returns `{:ok, entries}` or `{:error, reason}` when no Scenario is present
  (nothing to reconcile).
  """
  @spec expand(String.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def expand(text) when is_binary(text) do
    scenarios =
      text
      |> String.split(~r/\r\n|\r|\n/)
      |> Enum.reduce(new_state(), &parse_line/2)
      |> finish()

    case Enum.flat_map(scenarios, &expand_scenario/1) do
      [] -> {:error, "no runnable Scenario found in the gherkin source"}
      entries -> {:ok, entries}
    end
  end

  def expand(_other), do: {:error, "gherkin source must be a string"}

  # ── Parsing ────────────────────────────────────────────────────────────────

  defp new_state, do: %{feature: nil, current: nil, in_examples: false, done: []}

  defp parse_line(line, state) do
    trimmed = String.trim(line)
    # Bind these before the `cond` -- a destructuring match (`{n, o} = nil`) as a
    # cond clause would RAISE rather than be falsy.
    header = scenario_header(trimmed)
    row = table_row(trimmed)

    cond do
      trimmed == "" or comment?(trimmed) or tag?(trimmed) ->
        state

      feature = feature_name(trimmed) ->
        %{close_current(state) | feature: feature, in_examples: false}

      header != nil ->
        {name, outline?} = header
        closed = close_current(state)

        %{
          closed
          | in_examples: false,
            current: %{
              feature: state.feature,
              scenario: name,
              outline?: outline?,
              steps: [],
              example_header: nil,
              example_rows: []
            }
        }

      examples?(trimmed) ->
        %{state | in_examples: true}

      row != nil ->
        add_table_row(state, row)

      step = step_line(trimmed) ->
        # A step after Examples has begun is not part of the scenario body.
        if state.in_examples, do: state, else: append_step(state, step)

      true ->
        state
    end
  end

  # `scenario_header/1` matches nil when not a header; a `{name, outline?}` tuple
  # is truthy so the `cond` clause fires. Guard the match with a helper so a plain
  # `nil` never binds the pattern.
  defp scenario_header(line) do
    cond do
      rest = after_prefix(line, "Scenario Outline:") -> {presence(rest) || "Scenario", true}
      rest = after_prefix(line, "Scenario Template:") -> {presence(rest) || "Scenario", true}
      rest = after_prefix(line, "Scenario:") -> {presence(rest) || "Scenario", false}
      true -> nil
    end
  end

  defp after_prefix(line, prefix) do
    if String.starts_with?(line, prefix) do
      line |> binary_part(byte_size(prefix), byte_size(line) - byte_size(prefix)) |> String.trim()
    end
  end

  defp examples?(line),
    do: String.starts_with?(line, "Examples:") or String.starts_with?(line, "Examples ")

  # A `| a | b |` table row -> the list of trimmed cell strings. `nil` otherwise.
  defp table_row("|" <> _ = line) do
    line
    |> String.trim()
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp table_row(_line), do: nil

  # The first table row under Examples is the header; the rest are data rows.
  defp add_table_row(%{current: nil} = state, _row), do: state

  defp add_table_row(%{in_examples: false} = state, _row), do: state

  defp add_table_row(%{current: %{example_header: nil} = cur} = state, row) do
    %{state | current: %{cur | example_header: row}}
  end

  defp add_table_row(%{current: %{example_rows: rows} = cur} = state, row) do
    %{state | current: %{cur | example_rows: rows ++ [row]}}
  end

  defp append_step(%{current: nil} = state, _step), do: state

  defp append_step(%{current: %{steps: steps} = cur} = state, step) do
    %{state | current: %{cur | steps: steps ++ [step]}}
  end

  defp close_current(%{current: nil} = state), do: state

  defp close_current(%{current: cur, done: done} = state) do
    %{state | current: nil, in_examples: false, done: [cur | done]}
  end

  defp finish(state) do
    state |> close_current() |> Map.fetch!(:done) |> Enum.reverse()
  end

  # ── Expansion ────────────────────────────────────────────────────────────────

  # A plain Scenario -> one entry. An outline -> one entry per Examples data row,
  # with `<placeholder>` cells substituted into the steps and a stable row key.
  defp expand_scenario(%{outline?: false} = sc) do
    [
      %{
        id: base_id(sc),
        feature: feature_of(sc),
        scenario: sc.scenario,
        steps: sc.steps,
        outline?: false,
        example: nil,
        row_key: nil
      }
    ]
  end

  defp expand_scenario(%{outline?: true, example_header: header, example_rows: rows} = sc)
       when is_list(header) and rows != [] do
    Enum.map(rows, fn row ->
      example = header |> Enum.zip(row) |> Map.new()
      key = row_key(header, row)

      %{
        id: base_id(sc) <> "__" <> key,
        feature: feature_of(sc),
        scenario: sc.scenario,
        steps: Enum.map(sc.steps, &substitute(&1, example)),
        outline?: true,
        example: example,
        row_key: key
      }
    end)
  end

  # An outline with no Examples rows has nothing to run.
  defp expand_scenario(%{outline?: true}), do: []

  defp base_id(sc) do
    feature_slug =
      case presence(feature_of(sc)) do
        nil -> "ungrouped"
        name -> Group.normalize_id(name)
      end

    "#{feature_slug}__#{slug(sc.scenario)}"
  end

  defp feature_of(%{feature: f}) when is_binary(f), do: f
  defp feature_of(_), do: ""

  # A stable, legible key for an Examples row: prefer a single distinguishing
  # column when the table has one, else the joined slug of all cells. Falls back
  # to the row index-free joined values so re-running the same table is stable.
  defp row_key(header, row) do
    cells = if length(header) == 1, do: row, else: Enum.zip(header, row) |> Enum.map(&elem(&1, 1))

    cells
    |> Enum.map(&slug/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("-")
    |> case do
      "" -> "row"
      key -> key
    end
  end

  # Substitute `<col>` occurrences in a step with the row's value for that column.
  defp substitute(step, example) do
    Enum.reduce(example, step, fn {col, val}, acc ->
      String.replace(acc, "<#{col}>", val)
    end)
  end

  defp slug(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp comment?("#" <> _), do: true
  defp comment?(_), do: false

  defp tag?("@" <> _), do: true
  defp tag?(_), do: false

  defp feature_name("Feature:" <> rest), do: String.trim(rest)
  defp feature_name(_), do: nil

  defp step_line(line) do
    if Enum.any?(@step_keywords, &step_prefix?(line, &1)), do: line, else: nil
  end

  defp step_prefix?(line, "*"), do: line == "*" or String.starts_with?(line, "* ")
  defp step_prefix?(line, keyword), do: String.starts_with?(line, keyword <> " ")

  defp presence(v) when is_binary(v) and v != "", do: v
  defp presence(_), do: nil
end
