defmodule Kazi.PredicateVectorTest do
  use ExUnit.Case, async: true
  doctest Kazi.PredicateVector

  alias Kazi.{PredicateResult, PredicateVector}

  describe "new/1 and new/0" do
    test "from a map of id => result" do
      r = PredicateResult.pass()
      v = PredicateVector.new(%{unit: r})
      assert PredicateVector.get(v, :unit) == r
    end

    test "from a list of {id, result} pairs" do
      v = PredicateVector.new([{:unit, PredicateResult.fail()}, {:live, PredicateResult.pass()}])
      assert PredicateVector.get(v, :unit).status == :fail
      assert PredicateVector.get(v, :live).status == :pass
    end

    test "empty" do
      assert PredicateVector.new().results == %{}
    end
  end

  describe "put/3 and get/2" do
    test "records and overwrites a result" do
      v =
        PredicateVector.new()
        |> PredicateVector.put(:unit, PredicateResult.fail())
        |> PredicateVector.put(:unit, PredicateResult.pass())

      assert PredicateVector.get(v, :unit).status == :pass
    end

    test "get returns nil for an absent id" do
      assert PredicateVector.get(PredicateVector.new(), :missing) == nil
    end
  end

  describe "satisfied?/1 — the objective-termination basis (T0.8)" do
    test "true when every result is :pass" do
      v = PredicateVector.new(%{code: PredicateResult.pass(), live: PredicateResult.pass()})
      assert PredicateVector.satisfied?(v)
    end

    test "false when any predicate fails" do
      v = PredicateVector.new(%{code: PredicateResult.pass(), live: PredicateResult.fail()})
      refute PredicateVector.satisfied?(v)
    end

    test "a failing LIVE predicate blocks satisfaction even when code passes" do
      # This is the core guarantee for UC-005 / T0.8: cannot declare success
      # while the live probe fails.
      v = PredicateVector.new(%{unit: PredicateResult.pass(), live_probe: PredicateResult.fail()})
      refute PredicateVector.satisfied?(v)
    end

    test "error or unknown are not pass, so they block satisfaction" do
      assert PredicateVector.satisfied?(PredicateVector.new(%{a: PredicateResult.error()})) ==
               false

      assert PredicateVector.satisfied?(PredicateVector.new(%{a: PredicateResult.unknown()})) ==
               false
    end

    test "an empty vector is NOT satisfied (nothing to assert convergence over)" do
      refute PredicateVector.satisfied?(PredicateVector.new())
    end
  end

  describe "failing/1 — the work-list" do
    test "returns only :fail ids" do
      v =
        PredicateVector.new(%{
          a: PredicateResult.pass(),
          b: PredicateResult.fail(),
          c: PredicateResult.error(),
          d: PredicateResult.unknown()
        })

      assert Enum.sort(PredicateVector.failing(v)) == [:b]
    end

    test "empty when nothing fails" do
      v = PredicateVector.new(%{a: PredicateResult.pass()})
      assert PredicateVector.failing(v) == []
    end
  end

  describe "regressions/2 — green to red across iterations" do
    test "flags a predicate that was pass and is now fail" do
      prev = PredicateVector.new(%{a: PredicateResult.pass(), b: PredicateResult.pass()})
      curr = PredicateVector.new(%{a: PredicateResult.pass(), b: PredicateResult.fail()})
      assert PredicateVector.regressions(prev, curr) == [:b]
    end

    test "flags a previously-passing predicate that disappeared from the new vector" do
      prev = PredicateVector.new(%{a: PredicateResult.pass()})
      curr = PredicateVector.new(%{})
      assert PredicateVector.regressions(prev, curr) == [:a]
    end

    test "no regression for a predicate that was already failing" do
      prev = PredicateVector.new(%{a: PredicateResult.fail()})
      curr = PredicateVector.new(%{a: PredicateResult.fail()})
      assert PredicateVector.regressions(prev, curr) == []
    end

    test "fixing a failing predicate is not a regression" do
      prev = PredicateVector.new(%{a: PredicateResult.fail()})
      curr = PredicateVector.new(%{a: PredicateResult.pass()})
      assert PredicateVector.regressions(prev, curr) == []
    end
  end
end
