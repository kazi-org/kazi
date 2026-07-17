defmodule Kazi.CLI.EconomyTableTest do
  @moduledoc """
  T60.5 (#1070): the human cost/token/iteration breakdown table renders the EXACT
  numbers it is given (no rounding/formatting drift), and an unavailable cell is
  honest-unknown (`—`), never a fabricated `0`.
  """
  use ExUnit.Case, async: true

  alias Kazi.CLI.EconomyTable

  defp full_row(overrides \\ %{}) do
    Map.merge(
      %{
        goal: "issue-6",
        iterations: 2,
        cost_usd: 1.25,
        passing: 7,
        total: 7,
        input_tokens: 1200,
        output_tokens: 800,
        cached_input_tokens: 400,
        cache_write_tokens: 100
      },
      overrides
    )
  end

  test "renders the exact numbers with no formatting drift" do
    out = EconomyTable.render([full_row()])

    assert out =~ "issue-6"
    assert out =~ "$1.25"
    assert out =~ "7/7 pass"
    # Each token category renders its exact integer.
    for n <- ["1200", "800", "400", "100"], do: assert(out =~ n)
    # Iteration count present as its own cell.
    assert out =~ ~r/\bissue-6\b.*\b2\b/
  end

  test "cost is always two decimals" do
    assert EconomyTable.render([full_row(%{cost_usd: 1.1})]) =~ "$1.10"
    assert EconomyTable.render([full_row(%{cost_usd: 1.0})]) =~ "$1.00"
    assert EconomyTable.render([full_row(%{cost_usd: 2})]) =~ "$2.00"
  end

  test "unavailable cells render em-dash, never a fabricated zero" do
    out =
      EconomyTable.render([
        %{
          goal: "issue-5",
          iterations: 3,
          cost_usd: nil,
          passing: nil,
          total: nil,
          input_tokens: nil,
          output_tokens: nil,
          cached_input_tokens: nil,
          cache_write_tokens: nil
        }
      ])

    assert out =~ "issue-5"
    assert out =~ "—"
    refute out =~ "$0.00"
    refute out =~ "0/0"
  end

  test "has a header row and a separator, and one line per goal" do
    out = EconomyTable.render([full_row(%{goal: "g1"}), full_row(%{goal: "g2"})])
    lines = String.split(out, "\n")

    assert hd(lines) =~ "Goal"
    assert hd(lines) =~ "Cost"
    assert hd(lines) =~ "Predicates"
    assert Enum.at(lines, 1) =~ ~r/^-+/
    assert Enum.any?(lines, &(&1 =~ "g1"))
    assert Enum.any?(lines, &(&1 =~ "g2"))
    # header + separator + 2 goal rows
    assert length(lines) == 4
  end

  test "an empty row list is header + separator only" do
    out = EconomyTable.render([])
    assert length(String.split(out, "\n")) == 2
  end
end
