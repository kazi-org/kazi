defmodule Kazi.CLI.EconomyRowTest do
  @moduledoc """
  T60.5 (#1070): the economy table's rows are built from already-computed data —
  a single-goal run result (`economy_row/2`) and a fleet member's threaded
  `:report` (`fleet_economy_row/2`) — with honest-unknown (`nil`) preserved and
  no fabrication. This is the HUMAN path only; `--json` builders are untouched.
  """
  use ExUnit.Case, async: true

  alias Kazi.{PredicateResult, PredicateVector}

  defp vector(pass, fail) do
    results =
      Map.new(
        Enum.map(1..pass//1, &{:"p#{&1}", PredicateResult.pass()}) ++
          Enum.map(1..fail//1, &{:"f#{&1}", PredicateResult.fail()})
      )

    PredicateVector.new(results)
  end

  describe "economy_row/2 (single goal)" do
    test "extracts iterations, cost, predicate pass/total, and the token breakdown" do
      result = %{
        iterations: 2,
        usage: %{
          input_tokens: 1200,
          output_tokens: 800,
          cached_input_tokens: 400,
          cache_write_tokens: 100,
          cost_usd: 1.25
        },
        vector: vector(7, 0)
      }

      row = Kazi.CLI.economy_row("issue-6", result)

      assert row.goal == "issue-6"
      assert row.iterations == 2
      assert row.cost_usd == 1.25
      assert row.passing == 7
      assert row.total == 7
      assert row.input_tokens == 1200
      assert row.output_tokens == 800
      assert row.cached_input_tokens == 400
      assert row.cache_write_tokens == 100
    end

    test "honest-unknown: an empty usage envelope and no vector leave cost/tokens/predicates nil" do
      row = Kazi.CLI.economy_row("g", %{iterations: 1, usage: %{}, vector: nil})

      assert row.iterations == 1
      assert row.cost_usd == nil
      assert row.input_tokens == nil
      assert row.passing == nil
      assert row.total == nil
    end

    test "tolerates a string-keyed usage envelope" do
      row = Kazi.CLI.economy_row("g", %{iterations: 1, usage: %{"cost_usd" => 1.25}, vector: nil})
      assert row.cost_usd == 1.25
    end
  end

  describe "fleet_economy_row/2 (per member)" do
    test "a member with no report is goal-only (every cell honest-unknown)" do
      assert Kazi.CLI.fleet_economy_row("m1", nil) == %{goal: "m1"}
    end

    test "extracts the member's threaded report" do
      report = %{
        iterations: 3,
        usage: %{input_tokens: 10, output_tokens: 5, cost_usd: 1.1},
        passing: 2,
        total: 3
      }

      row = Kazi.CLI.fleet_economy_row("issue-5", report)

      assert row.goal == "issue-5"
      assert row.iterations == 3
      assert row.cost_usd == 1.1
      assert row.passing == 2
      assert row.total == 3
      assert row.input_tokens == 10
      assert row.output_tokens == 5
      assert row.cached_input_tokens == nil
    end
  end
end
