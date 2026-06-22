defmodule Kazi.PredicateResultTest do
  use ExUnit.Case, async: true
  doctest Kazi.PredicateResult

  alias Kazi.PredicateResult

  describe "new/2" do
    test "builds a result with status and evidence" do
      r = PredicateResult.new(:pass, %{exit: 0, output: "ok"})
      assert r.status == :pass
      assert r.evidence == %{exit: 0, output: "ok"}
    end

    test "defaults evidence to an empty map" do
      assert PredicateResult.new(:fail).evidence == %{}
    end

    test "rejects an invalid status" do
      # Computed at runtime so the type checker does not flag the literal; the
      # guard rejects anything outside the four valid statuses.
      bad = String.to_atom("nope")
      assert_raise FunctionClauseError, fn -> PredicateResult.new(bad) end
    end
  end

  describe "convenience constructors" do
    test "pass/fail/error/unknown set the right status" do
      assert PredicateResult.pass().status == :pass
      assert PredicateResult.fail().status == :fail
      assert PredicateResult.error().status == :error
      assert PredicateResult.unknown().status == :unknown
    end

    test "carry evidence through" do
      assert PredicateResult.error(%{reason: :timeout}).evidence == %{reason: :timeout}
    end
  end

  describe "passed?/1" do
    test "true only for :pass" do
      assert PredicateResult.passed?(PredicateResult.pass())
      refute PredicateResult.passed?(PredicateResult.fail())
      refute PredicateResult.passed?(PredicateResult.error())
      refute PredicateResult.passed?(PredicateResult.unknown())
    end
  end

  test "statuses/0 lists the four statuses" do
    assert PredicateResult.statuses() == [:pass, :fail, :error, :unknown]
  end
end
