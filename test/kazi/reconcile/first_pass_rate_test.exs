defmodule Kazi.Reconcile.FirstPassRateTest do
  use ExUnit.Case, async: true

  alias Kazi.{PredicateResult, PredicateVector}
  alias Kazi.Reconcile.FirstPassRate

  doctest FirstPassRate

  defp vector(pairs) do
    PredicateVector.new(Map.new(pairs, fn {id, status} -> {id, result(status)} end))
  end

  defp result(:pass), do: PredicateResult.pass()
  defp result(:fail), do: PredicateResult.fail()
  defp result(:error), do: PredicateResult.error()
  defp result(:unknown), do: PredicateResult.unknown()

  describe "from_history/1" do
    test "scores the FIRST iteration, not the converged one" do
      first = vector(a: :pass, b: :fail, c: :fail)
      mid = vector(a: :pass, b: :pass, c: :fail)
      last = vector(a: :pass, b: :pass, c: :pass)

      assert %{total: 3, first_pass: 1, reworked: 2, rate: rate} =
               FirstPassRate.from_history([{0, first}, {1, mid}, {2, last}])

      assert_in_delta rate, 1 / 3, 1.0e-9
    end

    test "picks the lowest index regardless of list order" do
      first = vector(a: :pass, b: :fail)
      last = vector(a: :pass, b: :pass)

      # Unordered input still scores index 0.
      assert %{first_pass: 1, total: 2} = FirstPassRate.from_history([{1, last}, {0, first}])
    end

    test "all-green first observation is a perfect first-pass rate" do
      assert %{total: 2, first_pass: 2, reworked: 0, rate: 1.0} =
               FirstPassRate.from_history([{0, vector(a: :pass, b: :pass)}])
    end

    test ":error and :unknown count as reworked, not first-pass" do
      assert %{total: 3, first_pass: 1, reworked: 2} =
               FirstPassRate.from_history([{0, vector(a: :pass, b: :error, c: :unknown)}])
    end

    test "empty history is nil (nothing to measure)" do
      assert FirstPassRate.from_history([]) == nil
    end

    test "an empty first vector is nil (no authored surface)" do
      assert FirstPassRate.from_history([{0, PredicateVector.new()}]) == nil
    end
  end

  describe "aggregate/1" do
    test "pools by summing numerators and denominators (predicate-weighted)" do
      a = %{total: 4, first_pass: 3, reworked: 1, rate: 0.75}
      b = %{total: 1, first_pass: 0, reworked: 1, rate: 0.0}

      assert %{total: 5, first_pass: 3, reworked: 2, rate: 0.6} = FirstPassRate.aggregate([a, b])
    end

    test "ignores nil summaries" do
      a = %{total: 2, first_pass: 2, reworked: 0, rate: 1.0}
      assert %{total: 2, first_pass: 2, rate: 1.0} = FirstPassRate.aggregate([nil, a, nil])
    end

    test "all-nil (or empty) input is nil" do
      assert FirstPassRate.aggregate([]) == nil
      assert FirstPassRate.aggregate([nil, nil]) == nil
    end
  end
end
