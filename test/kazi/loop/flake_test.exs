defmodule Kazi.Loop.FlakeTest do
  use ExUnit.Case, async: true

  alias Kazi.Loop.Flake
  alias Kazi.PredicateResult

  doctest Kazi.Loop.Flake

  defp r(status, evidence \\ %{}), do: PredicateResult.new(status, evidence)

  describe "needs_rerun?/1" do
    test "a pass is taken at face value (no re-run)" do
      refute Flake.needs_rerun?(r(:pass))
    end

    test "a fail or error warrants a re-run" do
      assert Flake.needs_rerun?(r(:fail))
      assert Flake.needs_rerun?(r(:error))
    end
  end

  describe "classify/1" do
    test "all-pass sequence is :pass" do
      assert Flake.classify([r(:pass)]) == :pass
      assert Flake.classify([r(:pass), r(:pass)]) == :pass
    end

    test "a deterministic fail (every run :fail) stays :fail — NOT flaky" do
      assert Flake.classify([r(:fail)]) == :fail
      assert Flake.classify([r(:fail), r(:fail), r(:fail)]) == :fail
    end

    test "an all-error sequence is a consistent non-pass: :fail (surfaced as real)" do
      assert Flake.classify([r(:error), r(:error)]) == :fail
    end

    test "fail then pass (a flip) is :flaky" do
      assert Flake.classify([r(:fail), r(:pass)]) == :flaky
    end

    test "pass then fail (the other flip direction) is :flaky" do
      assert Flake.classify([r(:pass), r(:fail)]) == :flaky
    end

    test "error then pass (nondeterministic) is :flaky" do
      assert Flake.classify([r(:error), r(:pass)]) == :flaky
    end

    test "any pass anywhere in a longer sequence makes it flaky" do
      assert Flake.classify([r(:fail), r(:fail), r(:pass)]) == :flaky
    end
  end

  describe "quarantine bookkeeping" do
    test "a :flaky verdict adds the id; :pass/:fail leave the set unchanged" do
      assert Flake.quarantine(MapSet.new(), :a, :flaky) |> Flake.quarantined?(:a)
      refute Flake.quarantine(MapSet.new(), :a, :fail) |> Flake.quarantined?(:a)
      refute Flake.quarantine(MapSet.new(), :a, :pass) |> Flake.quarantined?(:a)
    end

    test "quarantine is sticky: an already-quarantined id stays in regardless of later verdict" do
      set = Flake.quarantine(MapSet.new(), :a, :flaky)
      # A later :fail or :pass verdict must not re-admit it.
      assert set |> Flake.quarantine(:a, :fail) |> Flake.quarantined?(:a)
      assert set |> Flake.quarantine(:a, :pass) |> Flake.quarantined?(:a)
    end

    test "quarantined?/2 is false for an id never quarantined" do
      refute Flake.quarantined?(MapSet.new(), :nope)
    end
  end

  describe "quarantined_result/1" do
    test "records :unknown (no convergence claim) and preserves evidence + flake marker" do
      result = Flake.quarantined_result(r(:fail, %{exit: 1, output: "boom"}))

      assert result.status == :unknown
      assert result.evidence[:quarantined] == :flaky
      assert result.evidence[:exit] == 1
      assert result.evidence[:output] == "boom"
      # :unknown is neither pass nor failing work.
      refute PredicateResult.passed?(result)
    end
  end

  test "max_retries/0 default" do
    assert Flake.max_retries() == 2
  end
end
