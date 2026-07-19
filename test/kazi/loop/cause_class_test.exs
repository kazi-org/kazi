defmodule Kazi.Loop.CauseClassTest do
  @moduledoc """
  Pure unit coverage for `Kazi.Loop.CauseClass.classify/1` (T48.4, UC-064,
  ADR-0058 decision 4), in complete isolation from `Kazi.Loop` — no gen_statem,
  no providers. Mirrors the isolation style of `Kazi.Loop.ErrorPermanenceTest`
  / `Kazi.Loop.StuckDetectorTest`.
  """
  use ExUnit.Case, async: true

  doctest Kazi.Loop.CauseClass

  alias Kazi.Loop.CauseClass
  alias Kazi.{PredicateResult, PredicateVector}

  defp inputs(overrides) do
    Map.merge(
      %{
        outcome: :converged,
        reason: nil,
        vector: nil,
        stuck_cause: nil,
        stuck_failing: nil,
        stuck_reasons: nil
      },
      overrides
    )
  end

  describe "budget_exhausted -- an over_budget stop with real failing work" do
    test "carries the exhausted budget dimension and the sorted failing ids" do
      vector =
        PredicateVector.new(%{
          b: PredicateResult.fail(),
          a: PredicateResult.fail(),
          live: PredicateResult.pass()
        })

      result =
        CauseClass.classify(
          inputs(%{outcome: :over_budget, reason: :max_iterations, vector: vector})
        )

      assert result == %{
               class: :budget_exhausted,
               ids: [:a, :b],
               reasons: nil,
               exhausted: :max_iterations
             }
    end

    test "preserves whichever budget dimension tripped (wall_clock / token_budget / max_dispatches)" do
      vector = PredicateVector.new(%{code: PredicateResult.fail()})

      for dimension <- [:max_iterations, :wall_clock, :token_budget, :max_dispatches] do
        result =
          CauseClass.classify(inputs(%{outcome: :over_budget, reason: dimension, vector: vector}))

        assert result.class == :budget_exhausted
        assert result.exhausted == dimension
      end
    end

    test "an over_budget stop with nothing blocking (a live predicate legitimately pending) still classifies budget_exhausted with no ids" do
      vector = PredicateVector.new(%{live: PredicateResult.unknown()})

      result =
        CauseClass.classify(inputs(%{outcome: :over_budget, reason: :wall_clock, vector: vector}))

      assert result == %{class: :budget_exhausted, ids: [], reasons: nil, exhausted: :wall_clock}
    end
  end

  describe "error_wedged -- an over_budget stop that is really a config error" do
    test "zero :fail but a persistent :error classifies error_wedged, deriving ids/reasons from the terminal vector" do
      vector =
        PredicateVector.new(%{
          code: PredicateResult.pass(),
          live: PredicateResult.error(%{reason: :missing_url})
        })

      result =
        CauseClass.classify(
          inputs(%{outcome: :over_budget, reason: :max_iterations, vector: vector})
        )

      assert result == %{
               class: :error_wedged,
               ids: [:live],
               reasons: %{live: :missing_url},
               exhausted: nil
             }
    end

    test "multiple erroring ids are all named, sorted" do
      vector =
        PredicateVector.new(%{
          b: PredicateResult.error(%{reason: :no_provider}),
          a: PredicateResult.error(%{reason: :missing_url})
        })

      result =
        CauseClass.classify(
          inputs(%{outcome: :over_budget, reason: :max_dispatches, vector: vector})
        )

      assert result.class == :error_wedged
      assert result.ids == [:a, :b]
      assert result.reasons == %{a: :missing_url, b: :no_provider}
      assert result.exhausted == nil
    end

    test "an error with no reason evidence at all still names the id, reason nil" do
      vector = PredicateVector.new(%{live: PredicateResult.error()})

      result =
        CauseClass.classify(
          inputs(%{outcome: :over_budget, reason: :max_iterations, vector: vector})
        )

      assert result.class == :error_wedged
      assert result.ids == [:live]
      assert result.reasons == %{live: nil}
    end
  end

  describe "error_wedged -- the T48.3 live-permanent-error stuck path" do
    test "reuses stuck_failing/stuck_reasons verbatim when stuck_cause is :error_wedged" do
      result =
        CauseClass.classify(
          inputs(%{
            outcome: :stopped,
            reason: :stuck,
            stuck_cause: :error_wedged,
            stuck_failing: [:live],
            stuck_reasons: %{live: :missing_url}
          })
        )

      assert result == %{
               class: :error_wedged,
               ids: [:live],
               reasons: %{live: :missing_url},
               exhausted: nil
             }
    end
  end

  describe "quarantine_blocked -- the #820 quarantine-only stuck path" do
    test "names the quarantined ids with no reasons" do
      result =
        CauseClass.classify(
          inputs(%{
            outcome: :stopped,
            reason: :stuck,
            stuck_cause: :quarantine_blocked,
            stuck_failing: [:flappy, :another]
          })
        )

      assert result == %{
               class: :quarantine_blocked,
               ids: [:another, :flappy],
               reasons: nil,
               exhausted: nil
             }
    end
  end

  describe "capability_unreachable -- the T49.8 stalled-demonstration path" do
    test "names the scenario ids and carries the demonstration reasons" do
      result =
        CauseClass.classify(
          inputs(%{
            outcome: :stopped,
            reason: :stuck,
            stuck_cause: :capability_unreachable,
            stuck_failing: [:cap],
            stuck_reasons: %{cap: [:replay_red]}
          })
        )

      assert result == %{
               class: :capability_unreachable,
               ids: [:cap],
               reasons: %{cap: [:replay_red]},
               exhausted: nil
             }
    end
  end

  describe "parked_on_background -- the T68.4 (#1546) parked-on-background-jobs path" do
    test "names the failing ids with no reasons" do
      result =
        CauseClass.classify(
          inputs(%{
            outcome: :stopped,
            reason: :stuck,
            stuck_cause: :parked_on_background,
            stuck_failing: [:code, :adr]
          })
        )

      assert result == %{
               class: :parked_on_background,
               ids: [:adr, :code],
               reasons: nil,
               exhausted: nil
             }
    end

    test "renders in status/attention output via format/2 with its implicated ids" do
      # The read-model persists the classified detail; format/2 is the single
      # renderer kazi status / attention / mission-control all read (T48.14).
      assert CauseClass.format("parked_on_background", %{"ids" => ["code", "adr"]}) ==
               "parked_on_background (code, adr)"
    end
  end

  describe "no cause class -- plain converged/stuck-on-failing-work runs" do
    test "a converged outcome classifies nil" do
      refute CauseClass.classify(inputs(%{outcome: :converged}))
    end

    test "an ordinary T1.5 failing-set stuck stop (stuck_cause nil) classifies nil" do
      refute CauseClass.classify(
               inputs(%{
                 outcome: :stopped,
                 reason: :stuck,
                 stuck_cause: nil,
                 stuck_failing: [:code]
               })
             )
    end

    test "the pre-existing code error_stuck? (M5) stop classifies nil" do
      refute CauseClass.classify(
               inputs(%{
                 outcome: :stopped,
                 reason: :stuck,
                 stuck_cause: nil,
                 stuck_failing: [:code],
                 stuck_reasons: nil
               })
             )
    end

    test "a non-terminal snapshot (any other outcome/reason shape) classifies nil" do
      refute CauseClass.classify(inputs(%{outcome: :stopped, reason: nil}))
    end
  end
end
