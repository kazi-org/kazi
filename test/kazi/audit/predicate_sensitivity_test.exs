defmodule Kazi.Audit.PredicateSensitivityTest do
  use ExUnit.Case, async: true

  alias Kazi.{PredicateResult, PredicateVector}
  alias Kazi.Audit.PredicateSensitivity

  doctest PredicateSensitivity

  defp vector(pairs) do
    PredicateVector.new(Map.new(pairs, fn {id, status} -> {id, result(status)} end))
  end

  defp result(:pass), do: PredicateResult.pass()
  defp result(:fail), do: PredicateResult.fail()
  defp result(:error), do: PredicateResult.error()

  describe "score/2" do
    test "counts constrained (flipped) vs survived (stayed green) predicates" do
      baseline = vector(a: :pass, b: :pass, c: :pass)
      mutated = vector(a: :fail, b: :pass, c: :error)

      assert %{tested: 3, constrained: 2, survived: 1, survivors: [:b], sensitivity: s} =
               PredicateSensitivity.score(baseline, mutated)

      assert_in_delta s, 2 / 3, 1.0e-9
    end

    test "only baseline-passing predicates are audited (a red-at-convergence id is ignored)" do
      # `c` was not green at convergence, so it is not part of the audit set even
      # though it is red in the mutated vector.
      baseline = vector(a: :pass, b: :pass, c: :fail)
      mutated = vector(a: :fail, b: :pass, c: :fail)

      assert %{tested: 2, constrained: 1, survived: 1, survivors: [:b]} =
               PredicateSensitivity.score(baseline, mutated)
    end

    test "a predicate ABSENT from the mutated vector counts as constrained (not a survivor)" do
      baseline = vector(a: :pass, b: :pass)
      mutated = vector(a: :pass)

      assert %{tested: 2, constrained: 1, survived: 1, survivors: [:a]} =
               PredicateSensitivity.score(baseline, mutated)
    end

    test "all survive -> sensitivity 0.0 (predicates do not constrain at all)" do
      baseline = vector(a: :pass, b: :pass)

      assert %{constrained: 0, survived: 2, sensitivity: sensitivity} =
               PredicateSensitivity.score(baseline, baseline)

      assert sensitivity == 0.0
    end

    test "all flip -> sensitivity 1.0 (every predicate constrains)" do
      baseline = vector(a: :pass, b: :pass)
      mutated = vector(a: :fail, b: :fail)

      assert %{constrained: 2, survived: 0, sensitivity: 1.0} =
               PredicateSensitivity.score(baseline, mutated)
    end

    test "no baseline-passing predicate -> nil sensitivity (nothing to audit)" do
      baseline = vector(a: :fail)

      assert %{tested: 0, sensitivity: nil, survivors: []} =
               PredicateSensitivity.score(baseline, baseline)
    end
  end

  describe "audit/2" do
    test "scores the injected re-evaluation against the baseline" do
      baseline = vector(a: :pass, b: :pass)
      # reevaluate mutates the workspace (here: just returns a sabotaged vector).
      reevaluate = fn -> vector(a: :fail, b: :pass) end

      assert %{tested: 2, constrained: 1, survived: 1, survivors: [:b]} =
               PredicateSensitivity.audit(baseline, reevaluate)
    end
  end

  describe "should_sample?/2" do
    test "0.0 never samples, 1.0 always samples" do
      refute PredicateSensitivity.should_sample?("goal-x", 0.0)
      assert PredicateSensitivity.should_sample?("goal-x", 1.0)
    end

    test "is deterministic for a given key+rate" do
      assert PredicateSensitivity.should_sample?("goal-y", 0.5) ==
               PredicateSensitivity.should_sample?("goal-y", 0.5)
    end

    test "samples approximately `rate` of a large key population" do
      sampled =
        1..10_000
        |> Enum.count(fn i -> PredicateSensitivity.should_sample?("goal-#{i}", 0.25) end)

      # ~2500 of 10000; allow generous slack for hash distribution.
      assert sampled > 2000 and sampled < 3000
    end
  end
end
