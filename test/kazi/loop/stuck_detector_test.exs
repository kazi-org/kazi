defmodule Kazi.Loop.StuckDetectorTest do
  @moduledoc """
  Unit tests for the pure stuck detector (T1.5, UC-009).

  The loop-level enforcement (the human-escalation hook firing and the loop
  stopping with reason `:stuck`) is proven in `Kazi.StuckLoopTest`; here we test
  the decision in isolation: given a per-iteration history and a window N, is the
  loop stuck and on which failing set?
  """
  use ExUnit.Case, async: true

  alias Kazi.{PredicateResult, PredicateVector}
  alias Kazi.Loop.StuckDetector

  # A vector whose given ids are :fail and the rest :pass.
  defp vector(fail_ids, pass_ids \\ []) do
    fails = Map.new(fail_ids, fn id -> {id, PredicateResult.fail()} end)
    passes = Map.new(pass_ids, fn id -> {id, PredicateResult.pass()} end)
    PredicateVector.new(Map.merge(passes, fails))
  end

  # Build an oldest-first history (`[{index, vector}]`) from a list of vectors.
  defp history(vectors) do
    vectors |> Enum.with_index() |> Enum.map(fn {v, i} -> {i, v} end)
  end

  describe "stuck?/2 — the same failing set persisting across N iterations" do
    test "same non-empty failing set for exactly N iterations is stuck on that set" do
      h = history([vector([:a]), vector([:a]), vector([:a])])

      assert StuckDetector.stuck?(h, 3) == {:stuck, MapSet.new([:a])}
    end

    test "same failing set for MORE than N iterations is stuck (only the last N window matters)" do
      h = history([vector([:a]), vector([:a]), vector([:a]), vector([:a]), vector([:a])])

      assert StuckDetector.stuck?(h, 3) == {:stuck, MapSet.new([:a])}
    end

    test "set equality, not ordering: a multi-id failing set is matched as a set" do
      h = history([vector([:a, :b]), vector([:b, :a]), vector([:a, :b])])

      assert StuckDetector.stuck?(h, 3) == {:stuck, MapSet.new([:a, :b])}
    end

    test "only the most recent N observations count: an earlier different set does not block stuck" do
      # The first observation differs, but the last 3 are identical → stuck.
      h = history([vector([:a, :b]), vector([:a]), vector([:a]), vector([:a])])

      assert StuckDetector.stuck?(h, 3) == {:stuck, MapSet.new([:a])}
    end
  end

  describe "stuck?/2 — not stuck" do
    test "a changing failing set across the window is not stuck (progressing)" do
      h = history([vector([:a]), vector([:b]), vector([:a])])

      assert StuckDetector.stuck?(h, 3) == :not_stuck
    end

    test "a shrinking failing set is progress, not stuck" do
      h = history([vector([:a, :b, :c]), vector([:a, :b]), vector([:a])])

      assert StuckDetector.stuck?(h, 3) == :not_stuck
    end

    test "a fully-converging (all-pass) window is not stuck — empty failing set never sticks" do
      h = history([vector([], [:a]), vector([], [:a]), vector([], [:a])])

      assert StuckDetector.stuck?(h, 3) == :not_stuck
    end

    test "fewer than N observations is not stuck (not enough evidence)" do
      h = history([vector([:a]), vector([:a])])

      assert StuckDetector.stuck?(h, 3) == :not_stuck
    end

    test "an empty history is not stuck" do
      assert StuckDetector.stuck?([], 3) == :not_stuck
    end

    test ":error / :unknown results do not count as failing, so they never sustain stuck" do
      # `failing/1` returns only genuine :fail; a window of :error results has an
      # empty failing set and must not be declared stuck.
      err = PredicateVector.new(%{a: PredicateResult.error(%{reason: :boom})})
      h = history([err, err, err])

      assert StuckDetector.stuck?(h, 3) == :not_stuck
    end

    test "the failing set flipping only on the last iteration is not stuck" do
      h = history([vector([:a]), vector([:a]), vector([:b])])

      assert StuckDetector.stuck?(h, 3) == :not_stuck
    end
  end

  describe "stuck?/2 — window configuration" do
    test "a non-positive window disables detection (always not stuck)" do
      h = history([vector([:a]), vector([:a]), vector([:a])])

      assert StuckDetector.stuck?(h, 0) == :not_stuck
      assert StuckDetector.stuck?(h, -1) == :not_stuck
    end

    test "N=1: a single non-empty failing observation is stuck" do
      assert StuckDetector.stuck?(history([vector([:a])]), 1) == {:stuck, MapSet.new([:a])}
    end

    test "N=2: respects a custom window" do
      assert StuckDetector.stuck?(history([vector([:a]), vector([:a])]), 2) ==
               {:stuck, MapSet.new([:a])}

      assert StuckDetector.stuck?(history([vector([:a]), vector([:b])]), 2) == :not_stuck
    end
  end

  test "default_iterations/0 is a sensible positive default" do
    assert StuckDetector.default_iterations() == 3
  end

  # ===========================================================================
  # Graded-score escape (ADR-0041 / T32.2) — the stuck-detector sees the delta
  # ===========================================================================

  describe "stuck?/2 — same failing set, but the graded score is moving" do
    # A vector with a single failing, SCORED predicate :a (the others pass).
    defp scored_vector(score, direction) do
      PredicateVector.new(%{
        a: PredicateResult.new(:fail, %{}, score: score, direction: direction)
      })
    end

    test "a :lower_better count shrinking across the window is progress, not stuck" do
      # Same failing set {:a} for 3 iterations — boolean-equivalent would be STUCK —
      # but the score falls 30 → 20 → 12, which for lower_better is real progress.
      h =
        history([
          scored_vector(30.0, :lower_better),
          scored_vector(20.0, :lower_better),
          scored_vector(12.0, :lower_better)
        ])

      assert StuckDetector.stuck?(h, 3) == :not_stuck
    end

    test "a :higher_better score climbing across the window is progress, not stuck" do
      h =
        history([
          scored_vector(0.40, :higher_better),
          scored_vector(0.55, :higher_better),
          scored_vector(0.70, :higher_better)
        ])

      assert StuckDetector.stuck?(h, 3) == :not_stuck
    end

    test "a FLAT score (no movement) with the same failing set is still stuck" do
      h =
        history([
          scored_vector(12.0, :lower_better),
          scored_vector(12.0, :lower_better),
          scored_vector(12.0, :lower_better)
        ])

      assert StuckDetector.stuck?(h, 3) == {:stuck, MapSet.new([:a])}
    end

    test "a score moving the WRONG way (regressing) does not rescue from stuck" do
      # lower_better but the count is RISING 12 → 20 → 30: not progress → stuck.
      h =
        history([
          scored_vector(12.0, :lower_better),
          scored_vector(20.0, :lower_better),
          scored_vector(30.0, :lower_better)
        ])

      assert StuckDetector.stuck?(h, 3) == {:stuck, MapSet.new([:a])}
    end

    test "net improvement across the window counts even if it dips mid-window" do
      # 30 → 31 → 12: first-to-last net improvement (lower_better) → not stuck.
      h =
        history([
          scored_vector(30.0, :lower_better),
          scored_vector(31.0, :lower_better),
          scored_vector(12.0, :lower_better)
        ])

      assert StuckDetector.stuck?(h, 3) == :not_stuck
    end

    test "a boolean predicate (no score) is unaffected — still stuck (back-compat)" do
      # Identical to the legacy stuck case: no score means no escape.
      h = history([vector([:a]), vector([:a]), vector([:a])])
      assert StuckDetector.stuck?(h, 3) == {:stuck, MapSet.new([:a])}
    end
  end
end
