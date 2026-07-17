defmodule Kazi.CLI.EconomyTable do
  @moduledoc """
  T60.5 (#1070): the human-readable per-goal cost/token/iteration breakdown table
  printed on `kazi apply` / `kazi apply --fleet` convergence or budget exhaustion.

  Single-goal apply renders a one-row table; a fleet renders one row per member —
  the SAME shape, never a special-cased simpler format. This module is pure string
  formatting over already-computed numbers (the `--json` path is untouched); an
  unavailable cell prints `—` (honest-unknown, never a fabricated `0`), and the
  output is byte-stable for a given row list so a test can assert exact numbers.
  """

  @typedoc """
  One goal's row. Any numeric field may be `nil` (the harness did not report it);
  `nil` renders as `—`, never `0`.
  """
  @type row :: %{
          required(:goal) => String.t(),
          optional(:iterations) => non_neg_integer() | nil,
          optional(:cost_usd) => number() | nil,
          optional(:passing) => non_neg_integer() | nil,
          optional(:total) => non_neg_integer() | nil,
          optional(:input_tokens) => non_neg_integer() | nil,
          optional(:output_tokens) => non_neg_integer() | nil,
          optional(:cached_input_tokens) => non_neg_integer() | nil,
          optional(:cache_write_tokens) => non_neg_integer() | nil
        }

  @unavailable "—"

  # {header, cell-fn, alignment}. Order is the column order.
  @columns [
    {"Goal", :goal, :left},
    {"Iterations", :iterations_cell, :right},
    {"Cost", :cost_cell, :right},
    {"Predicates", :predicates_cell, :right},
    {"Input", :input_cell, :right},
    {"Output", :output_cell, :right},
    {"Cached", :cached_cell, :right},
    {"Cache-write", :cachew_cell, :right}
  ]

  @doc """
  Render `rows` as a header + separator + one line per row. Returns the table as a
  single string (no trailing newline). An empty list yields the header + separator
  only.
  """
  @spec render([row()]) :: String.t()
  def render(rows) when is_list(rows) do
    cell_rows = Enum.map(rows, &cells/1)
    headers = Enum.map(@columns, fn {h, _f, _a} -> h end)
    aligns = Enum.map(@columns, fn {_h, _f, a} -> a end)
    widths = widths(headers, cell_rows)

    [headers | [separator(widths) | cell_rows]]
    |> Enum.map(fn
      :separator_marker -> separator_line(widths)
      line -> format_line(line, widths, aligns)
    end)
    |> Enum.join("\n")
  end

  defp separator(_widths), do: :separator_marker
  defp separator_line(widths), do: Enum.map_join(widths, "  ", &String.duplicate("-", &1))

  defp cells(row) do
    [
      to_string(Map.get(row, :goal, "")),
      int_cell(Map.get(row, :iterations)),
      cost_cell(Map.get(row, :cost_usd)),
      predicates_cell(Map.get(row, :passing), Map.get(row, :total)),
      int_cell(Map.get(row, :input_tokens)),
      int_cell(Map.get(row, :output_tokens)),
      int_cell(Map.get(row, :cached_input_tokens)),
      int_cell(Map.get(row, :cache_write_tokens))
    ]
  end

  defp int_cell(n) when is_integer(n) and n >= 0, do: Integer.to_string(n)
  defp int_cell(_), do: @unavailable

  defp cost_cell(n) when is_number(n), do: "$" <> :erlang.float_to_binary(n / 1.0, decimals: 2)
  defp cost_cell(_), do: @unavailable

  defp predicates_cell(passing, total) when is_integer(passing) and is_integer(total),
    do: "#{passing}/#{total} pass"

  defp predicates_cell(_passing, _total), do: @unavailable

  defp widths(headers, cell_rows) do
    all = [headers | cell_rows]

    Enum.map(0..(length(headers) - 1), fn i ->
      all
      |> Enum.map(fn line -> line |> Enum.at(i) |> String.length() end)
      |> Enum.max()
    end)
  end

  defp format_line(cells, widths, aligns) do
    cells
    |> Enum.zip(Enum.zip(widths, aligns))
    |> Enum.map_join("  ", &pad/1)
    |> String.trim_trailing()
  end

  defp pad({cell, {width, :left}}), do: String.pad_trailing(cell, width)
  defp pad({cell, {width, :right}}), do: String.pad_leading(cell, width)
end
