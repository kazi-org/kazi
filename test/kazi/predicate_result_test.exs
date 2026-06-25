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

  # ===========================================================================
  # Envelope v2 — score / direction / prior_score / diagnostics (ADR-0041)
  # ===========================================================================

  describe "back-compat: the boolean path is byte-identical (ADR-0041 thesis)" do
    test "every pre-v2 constructor yields the boolean default shape" do
      boolean = %PredicateResult{status: :fail, evidence: %{}}

      assert PredicateResult.fail() == boolean
      assert PredicateResult.new(:fail) == boolean
      assert PredicateResult.new(:fail, %{}) == boolean

      # The v2 fields are present on the struct but at their boolean defaults, so a
      # boolean result is indistinguishable from the pre-v2 one.
      assert boolean.score == nil
      assert boolean.direction == nil
      assert boolean.prior_score == nil
      assert boolean.diagnostics == []
      refute PredicateResult.scored?(boolean)
    end

    test "a boolean result with evidence keeps exactly status + evidence populated" do
      r = PredicateResult.pass(%{exit: 0, output: "ok"})

      assert %PredicateResult{
               status: :pass,
               evidence: %{exit: 0, output: "ok"},
               score: nil,
               direction: nil,
               prior_score: nil,
               diagnostics: []
             } = r
    end
  end

  describe "new/3 — graded opts" do
    test "carries score, direction, prior_score, and diagnostics" do
      diag = Kazi.Evidence.new(rule: "r", level: :error)

      r =
        PredicateResult.new(:fail, %{output: "raw"},
          score: 12.0,
          direction: :lower_better,
          prior_score: 30.0,
          diagnostics: [diag]
        )

      assert r.status == :fail
      assert r.evidence == %{output: "raw"}
      assert r.score == 12.0
      assert r.direction == :lower_better
      assert r.prior_score == 30.0
      assert r.diagnostics == [diag]
      assert PredicateResult.scored?(r)
    end

    test "coerces an integer score to a float" do
      r = PredicateResult.new(:fail, %{}, score: 47)
      assert r.score == 47.0
    end
  end

  describe "with_prior_score/2 — the loop threads the prior" do
    test "sets the prior score on a graded result" do
      r = PredicateResult.new(:fail, %{}, score: 5.0, direction: :lower_better)
      assert PredicateResult.with_prior_score(r, 8.0).prior_score == 8.0
    end

    test "a nil prior leaves the result a boolean shape" do
      r = PredicateResult.new(:fail, %{}, score: 5.0, direction: :lower_better)
      assert PredicateResult.with_prior_score(r, nil).prior_score == nil
    end
  end

  describe "delta/1 and progress/1 — the direction-interpreted gradient" do
    test "a :lower_better count improving (going DOWN) is progress" do
      r =
        PredicateResult.new(:fail, %{},
          score: 12.0,
          direction: :lower_better,
          prior_score: 30.0
        )

      assert PredicateResult.delta(r) == -18.0
      assert PredicateResult.progress(r) == :progressed
    end

    test "a :lower_better count rising is a regression" do
      r =
        PredicateResult.new(:fail, %{}, score: 30.0, direction: :lower_better, prior_score: 12.0)

      assert PredicateResult.progress(r) == :regressed
    end

    test "a :higher_better score rising is progress; falling is regression" do
      up =
        PredicateResult.new(:fail, %{}, score: 0.9, direction: :higher_better, prior_score: 0.7)

      down =
        PredicateResult.new(:fail, %{}, score: 0.7, direction: :higher_better, prior_score: 0.9)

      assert PredicateResult.progress(up) == :progressed
      assert PredicateResult.progress(down) == :regressed
    end

    test "an unchanged score is :unchanged" do
      r = PredicateResult.new(:fail, %{}, score: 5.0, direction: :lower_better, prior_score: 5.0)
      assert PredicateResult.progress(r) == :unchanged
    end

    test "no score, no prior, or no direction is :unknown (and delta nil)" do
      assert PredicateResult.delta(PredicateResult.fail()) == nil
      assert PredicateResult.progress(PredicateResult.fail()) == :unknown

      # Score but no prior yet (first iteration) → unknown gradient.
      first = PredicateResult.new(:fail, %{}, score: 5.0, direction: :lower_better)
      assert PredicateResult.progress(first) == :unknown

      # Score + prior but no direction to interpret it → unknown.
      no_dir = PredicateResult.new(:fail, %{}, score: 5.0, prior_score: 8.0)
      assert PredicateResult.progress(no_dir) == :unknown
    end
  end
end
