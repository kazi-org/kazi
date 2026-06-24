defmodule Kazi.Scheduler.BudgetTest do
  @moduledoc """
  T21.7 (ADR-0027 step 3; derived from ADR-0020/T12.4): the PURE per-partition
  budget split + derived rollup. `split/2` divides a goal budget into shares that
  SUM BACK to the whole (lossless); `rollup/1` sums per-partition spend into the
  collective total (the inverse). No processes, no clock — pure functions.
  """
  use ExUnit.Case, async: true

  doctest Kazi.Scheduler.Budget

  alias Kazi.Budget
  alias Kazi.Scheduler.Budget, as: SchedulerBudget

  describe "split/2 — derived shares that sum back to the whole" do
    test "splits each bounded dimension evenly when it divides" do
      budget = Budget.new(max_iterations: 12, max_wall_clock_ms: 6_000, max_tokens: 900)

      [a, b, c] = SchedulerBudget.split(budget, 3)

      assert {a.max_iterations, b.max_iterations, c.max_iterations} == {4, 4, 4}

      assert {a.max_wall_clock_ms, b.max_wall_clock_ms, c.max_wall_clock_ms} ==
               {2_000, 2_000, 2_000}

      assert {a.max_tokens, b.max_tokens, c.max_tokens} == {300, 300, 300}
    end

    test "distributes the remainder to the first partitions so shares sum to the total" do
      budget = Budget.new(max_iterations: 10, max_tokens: 100)

      shares = SchedulerBudget.split(budget, 3)

      iterations = Enum.map(shares, & &1.max_iterations)
      tokens = Enum.map(shares, & &1.max_tokens)

      # Remainder rides on the first partitions; nothing is lost or invented.
      assert iterations == [4, 3, 3]
      assert Enum.sum(iterations) == 10
      assert tokens == [34, 33, 33]
      assert Enum.sum(tokens) == 100
    end

    test "an unbounded (nil) dimension stays unbounded in every share" do
      budget = Budget.new(max_iterations: nil, max_tokens: 50)

      shares = SchedulerBudget.split(budget, 2)

      assert Enum.all?(shares, &is_nil(&1.max_iterations))
      assert Enum.map(shares, & &1.max_tokens) == [25, 25]
    end

    test "a single partition gets the WHOLE budget (the serial identity)" do
      budget = Budget.new(max_iterations: 7, max_tokens: 13)

      assert [^budget] = SchedulerBudget.split(budget, 1)
    end
  end

  describe "rollup/1 — derived collective spend (the inverse of split)" do
    test "sums per-partition spend dimension-wise" do
      spents = [
        %{iterations: 3, tokens: 100},
        %{iterations: 2, elapsed_ms: 500, tokens: 50},
        %{iterations: 1}
      ]

      assert SchedulerBudget.rollup(spents) == %{iterations: 6, elapsed_ms: 500, tokens: 150}
    end

    test "missing dimensions count as zero; the empty list rolls up to all-zero" do
      assert SchedulerBudget.rollup([%{}, %{tokens: 7}]) == %{
               iterations: 0,
               elapsed_ms: 0,
               tokens: 7
             }

      assert SchedulerBudget.rollup([]) == %{iterations: 0, elapsed_ms: 0, tokens: 0}
    end

    test "split-then-rollup of a fully-spent budget recovers the original total" do
      budget = Budget.new(max_iterations: 10, max_tokens: 100)

      # Each partition spends its WHOLE share; the rollup must equal the total.
      spents =
        budget
        |> SchedulerBudget.split(3)
        |> Enum.map(fn share -> %{iterations: share.max_iterations, tokens: share.max_tokens} end)

      assert SchedulerBudget.rollup(spents) == %{iterations: 10, elapsed_ms: 0, tokens: 100}
    end
  end
end
