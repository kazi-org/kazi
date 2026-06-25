defmodule Kazi.Evidence do
  @moduledoc """
  One structured evidence item — an LSP-`Diagnostic`-shaped finding (ADR-0041
  decision 3).

  Boolean predicate results today carry raw, provider-shaped evidence (an exit
  code + 5KB of stdout for `:tests`; an HTTP status + body for `:http_probe`).
  That is poor fix-context: an automated fixer does far better with the failing
  rule, its `file:line`, and an expected-vs-got than with a log to grep. ADR-0041
  adopts ONE envelope every provider maps onto — the same shape SARIF (static
  findings), JUnit XML (test results), and the LSP `Diagnostic` already speak:

      {file, line, col, rule, level, message, expected, got}

  Every field is optional; a provider fills what it has and leaves the rest `nil`.
  The list of these items rides on `Kazi.PredicateResult.diagnostics`; raw stdout
  is kept only as a truncated fallback in the result's `evidence` map. The
  `custom_script` provider (ADR-0040) and the SARIF/JUnit parsers
  (`Kazi.Evidence.Parser`) produce these same items, so a fixer reads one shape
  regardless of which checker found the issue.

  Serialization is JSON-safe by construction (`to_map/1` stringifies keys and the
  `level` atom), so an item survives the read-model's `:map` column without the
  deep-sanitize a raw provider term needs (cf. lore L-0010).
  """

  @typedoc """
  A finding's severity, normalized across sources: `:error` (a failing test, a
  SARIF `error`), `:warning`, `:note`, or `:info`. `nil` when the source carried
  none.
  """
  @type level :: :error | :warning | :note | :info | nil

  @type t :: %__MODULE__{
          file: String.t() | nil,
          line: non_neg_integer() | nil,
          col: non_neg_integer() | nil,
          rule: String.t() | nil,
          level: level(),
          message: String.t() | nil,
          expected: String.t() | nil,
          got: String.t() | nil
        }

  defstruct file: nil,
            line: nil,
            col: nil,
            rule: nil,
            level: nil,
            message: nil,
            expected: nil,
            got: nil

  @fields [:file, :line, :col, :rule, :level, :message, :expected, :got]

  @doc """
  Builds an evidence item from a keyword list or map of the eight fields. Unknown
  keys are ignored; absent fields default to `nil`.

  ## Examples

      iex> Kazi.Evidence.new(file: "lib/a.ex", line: 12, rule: "no-unused", level: :warning).line
      12

      iex> Kazi.Evidence.new(%{message: "boom"}).message
      "boom"
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    struct(__MODULE__, Map.take(attrs, @fields))
  end

  @doc """
  Renders the item as a JSON-safe, string-keyed map for the read-model and the
  `--json` envelope. Keys whose value is `nil` are OMITTED, so an item carrying
  only a message serializes to `%{"message" => "..."}` — a compact envelope, not
  eight mostly-null fields. The `level` atom is stringified.

  ## Examples

      iex> Kazi.Evidence.to_map(Kazi.Evidence.new(file: "a.ex", line: 3, level: :error))
      %{"file" => "a.ex", "line" => 3, "level" => "error"}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = item) do
    @fields
    |> Enum.reduce(%{}, fn field, acc ->
      case Map.fetch!(item, field) do
        nil -> acc
        value -> Map.put(acc, to_string(field), encode_value(field, value))
      end
    end)
  end

  @doc """
  Rehydrates an evidence item from its string-keyed serialized map (the inverse
  of `to_map/1`). Tolerant of a partial map; absent fields default to `nil`.

  ## Examples

      iex> Kazi.Evidence.from_map(%{"file" => "a.ex", "level" => "error"}).level
      :error
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      file: map["file"],
      line: map["line"],
      col: map["col"],
      rule: map["rule"],
      level: decode_level(map["level"]),
      message: map["message"],
      expected: stringify(map["expected"]),
      got: stringify(map["got"])
    }
  end

  # The level atom serializes as its string name; every other field is already a
  # JSON scalar (string/integer) by construction.
  defp encode_value(:level, level) when is_atom(level), do: to_string(level)
  defp encode_value(_field, value), do: value

  defp decode_level(nil), do: nil
  defp decode_level(level) when is_atom(level), do: level

  defp decode_level(level) when is_binary(level) do
    case level do
      "error" -> :error
      "warning" -> :warning
      "note" -> :note
      "info" -> :info
      _ -> nil
    end
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
