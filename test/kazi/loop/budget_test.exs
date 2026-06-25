defmodule Kazi.Loop.BudgetTest do
  @moduledoc """
  Unit tests for the pure budget-ceiling guard (T1.4, UC-009). The decision is
  pure — no clock, no I/O — so each dimension is tested in isolation against a
  fed-in usage map.
  """
  use ExUnit.Case, async: true

  doctest Kazi.Loop.Budget

  alias Kazi.Budget
  alias Kazi.Loop.Budget, as: Guard

  describe "max_iterations dimension" do
    test "ok while iterations are within the ceiling" do
      budget = Budget.new(max_iterations: 3)
      assert Guard.check(budget, %{iterations: 0}) == :ok
      assert Guard.check(budget, %{iterations: 2}) == :ok
    end

    test "stops with :max_iterations once iterations reach the ceiling (>=)" do
      budget = Budget.new(max_iterations: 3)
      assert Guard.check(budget, %{iterations: 3}) == {:stop, :max_iterations}
      assert Guard.check(budget, %{iterations: 10}) == {:stop, :max_iterations}
    end

    test "is unbounded when nil" do
      assert Guard.check(%Budget{max_iterations: nil}, %{iterations: 1_000_000}) == :ok
    end
  end

  describe "wall-clock dimension" do
    test "ok while elapsed wall-clock is within the ceiling" do
      budget = Budget.new(max_wall_clock_ms: 5_000)
      assert Guard.check(budget, %{elapsed_ms: 0}) == :ok
      assert Guard.check(budget, %{elapsed_ms: 4_999}) == :ok
    end

    test "stops with :wall_clock once elapsed reaches the ceiling (>=)" do
      budget = Budget.new(max_wall_clock_ms: 5_000)
      assert Guard.check(budget, %{elapsed_ms: 5_000}) == {:stop, :wall_clock}
      assert Guard.check(budget, %{elapsed_ms: 9_999}) == {:stop, :wall_clock}
    end

    test "is unbounded when nil" do
      assert Guard.check(%Budget{max_wall_clock_ms: nil}, %{elapsed_ms: 10_000_000}) == :ok
    end
  end

  describe "token-estimate dimension" do
    test "ok while tokens are within the ceiling" do
      budget = Budget.new(max_tokens: 1_000)
      assert Guard.check(budget, %{tokens: 0}) == :ok
      assert Guard.check(budget, %{tokens: 999}) == :ok
    end

    test "stops with :token_budget once tokens reach the ceiling (>=)" do
      budget = Budget.new(max_tokens: 1_000)
      assert Guard.check(budget, %{tokens: 1_000}) == {:stop, :token_budget}
      assert Guard.check(budget, %{tokens: 50_000}) == {:stop, :token_budget}
    end

    test "is unbounded when nil" do
      assert Guard.check(%Budget{max_tokens: nil}, %{tokens: 10_000_000}) == :ok
    end
  end

  describe "missing usage fields default to zero spend" do
    test "an empty usage map never trips a bounded budget" do
      budget = Budget.new(max_iterations: 1, max_wall_clock_ms: 1, max_tokens: 1)
      assert Guard.check(budget, %{}) == :ok
    end
  end

  describe "an empty (all-nil) budget" do
    test "never trips regardless of usage" do
      usage = %{iterations: 9_999, elapsed_ms: 9_999_999, tokens: 9_999_999}
      assert Guard.check(%Budget{}, usage) == :ok
    end
  end

  describe "ordering when several dimensions are exceeded at once" do
    test "iterations is reported before wall-clock and tokens" do
      budget = Budget.new(max_iterations: 1, max_wall_clock_ms: 1, max_tokens: 1)
      usage = %{iterations: 5, elapsed_ms: 5, tokens: 5}
      assert Guard.check(budget, usage) == {:stop, :max_iterations}
    end

    test "wall-clock is reported before tokens" do
      budget = Budget.new(max_wall_clock_ms: 1, max_tokens: 1)
      usage = %{elapsed_ms: 5, tokens: 5}
      assert Guard.check(budget, usage) == {:stop, :wall_clock}
    end
  end

  # ===========================================================================
  # T34.4 (ADR-0046 #4): cached-read discount — the COST ARITHMETIC that feeds
  # the token dimension. `check/2` is unchanged; only the `tokens` it is handed
  # is reweighted, here computed by the pure `budgeted_tokens/3`.
  # ===========================================================================

  describe "budgeted_tokens/3 — discounting cached reads" do
    test "no cached reads → identical to the raw total (gate behaviour unchanged)" do
      assert Guard.budgeted_tokens(1_000, 0, 0.1) == 1_000
    end

    test "cached reads are rebated to a fraction of a fresh token" do
      # 900 cached reads at weight 0.1 cost 90 instead of 900: a 810 rebate.
      assert Guard.budgeted_tokens(1_000, 900, 0.1) == 190
    end

    test "weight 1.0 counts cached reads as fresh — the old all-equal arithmetic" do
      assert Guard.budgeted_tokens(1_000, 900, 1.0) == 1_000
    end

    test "weight 0.0 makes cached reads free" do
      assert Guard.budgeted_tokens(1_000, 900, 0.0) == 100
    end

    test "weight is clamped to 0.0..1.0 (a cached read is never >fresh or <0)" do
      assert Guard.budgeted_tokens(1_000, 900, 2.0) == 1_000
      assert Guard.budgeted_tokens(1_000, 900, -1.0) == 100
    end

    test "the discounted total is floored at zero" do
      # Pathological: more cached reads than the raw total. Never goes negative.
      assert Guard.budgeted_tokens(100, 1_000, 0.1) == 0
    end

    test "a cache-heavy run stays under a ceiling the raw total would trip" do
      budget = Budget.new(max_tokens: 1_000)
      raw = 1_500
      cached = 1_400

      # Old all-equal arithmetic: 1500 ≥ 1000 → over budget.
      assert Guard.check(budget, %{tokens: raw}) == {:stop, :token_budget}

      # Discounted (weight 0.1): 1500 − 1400×0.9 = 240 → under budget.
      discounted = Guard.budgeted_tokens(raw, cached, budget.cached_read_weight)
      assert discounted == 240
      assert Guard.check(budget, %{tokens: discounted}) == :ok
    end
  end
end
