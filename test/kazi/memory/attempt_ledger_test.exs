defmodule Kazi.Memory.AttemptLedgerTest do
  use ExUnit.Case, async: true

  doctest Kazi.Memory.AttemptLedger

  alias Kazi.{Action, PredicateResult, PredicateVector}
  alias Kazi.Memory.AttemptLedger

  # ---------------------------------------------------------------------------
  # Helpers: build history entries + dispatch-log entries tersely (mirrors
  # `Kazi.Loop.RegressionDetectorTest`'s shape — the sibling fold-consumer).
  # ---------------------------------------------------------------------------

  defp vec(results), do: PredicateVector.new(Map.new(results, fn {id, s} -> {id, res(s)} end))

  defp res(:pass), do: PredicateResult.pass()
  defp res(:fail), do: PredicateResult.fail(%{output: "boom: undefined function foo/0"})

  defp dispatch(index, failing, opts \\ []) do
    params =
      %{failing: failing, evidence: Keyword.get(opts, :evidence, %{})}
      |> maybe_put_touched(Keyword.get(opts, :touched))

    {index, Action.new(:dispatch_agent, params: params)}
  end

  defp maybe_put_touched(params, nil), do: params
  defp maybe_put_touched(params, touched), do: Map.put(params, :touched, touched)

  # ===========================================================================
  # Deterministic fold
  # ===========================================================================

  describe "fold/2 — deterministic" do
    test "the same history + dispatch log always folds to the same ledger" do
      history = [{0, vec(a: :fail)}, {1, vec(a: :fail)}]
      dispatch_log = [dispatch(0, [:a], evidence: %{a: "same error"})]

      first = AttemptLedger.fold(history, dispatch_log)
      second = AttemptLedger.fold(history, dispatch_log)

      assert first == second
      assert [entry] = first
      assert entry.failing == MapSet.new([:a])
      assert entry.iterations == [0]
      assert entry.repeats == 1
    end

    test "an empty dispatch log folds to an empty ledger" do
      history = [{0, vec(a: :fail)}]

      assert AttemptLedger.fold(history, []) == []
      assert AttemptLedger.fold([], []) == []
    end

    test "the empty ledger renders NO prompt section" do
      assert AttemptLedger.render([]) == ""
      assert AttemptLedger.render(AttemptLedger.fold([], [])) == ""
    end
  end

  # ===========================================================================
  # Repeat detection (fingerprint) — decision 3
  # ===========================================================================

  describe "fingerprint repeat detection" do
    test "two attempts with the same (failing, touched, error) triple share a fingerprint and repeat" do
      history = [
        {0, vec(a: :fail)},
        {1, vec(a: :fail)},
        {2, vec(a: :fail)}
      ]

      dispatch_log = [
        dispatch(0, [:a],
          evidence: %{a: "boom: undefined function foo/0"},
          touched: ["lib/a.ex"]
        ),
        dispatch(1, [:a], evidence: %{a: "boom: undefined function foo/0"}, touched: ["lib/a.ex"])
      ]

      assert [entry] = AttemptLedger.fold(history, dispatch_log)
      assert entry.repeats == 2
      assert entry.iterations == [0, 1]
      # the failing set persisted unchanged through both attempts -> :no_change
      assert entry.effect == :no_change

      rendered = AttemptLedger.render([entry])
      assert rendered =~ "do not repeat it"
      assert rendered =~ entry.fingerprint
    end

    test "a differing touched-file set yields a DIFFERENT fingerprint" do
      history = [{0, vec(a: :fail)}, {1, vec(a: :fail)}, {2, vec(a: :fail)}]

      dispatch_log = [
        dispatch(0, [:a], evidence: %{a: "same"}, touched: ["lib/a.ex"]),
        dispatch(1, [:a], evidence: %{a: "same"}, touched: ["lib/b.ex"])
      ]

      entries = AttemptLedger.fold(history, dispatch_log)
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.repeats == 1))
    end

    test "fingerprint/3 is order-independent over set members" do
      a = AttemptLedger.fingerprint(MapSet.new([:x, :y]), MapSet.new(["b.ex", "a.ex"]), "e")
      b = AttemptLedger.fingerprint(MapSet.new([:y, :x]), MapSet.new(["a.ex", "b.ex"]), "e")

      assert a == b
    end
  end

  # ===========================================================================
  # Effect derivation
  # ===========================================================================

  describe "effect derivation" do
    test "a failing set that clears by the next observation is :changed" do
      history = [{0, vec(a: :fail)}, {1, vec(a: :pass)}]
      dispatch_log = [dispatch(0, [:a])]

      assert [entry] = AttemptLedger.fold(history, dispatch_log)
      assert entry.effect == :changed
    end

    test "a dispatch with no later recorded observation is :unknown" do
      history = [{0, vec(a: :fail)}]
      dispatch_log = [dispatch(0, [:a])]

      assert [entry] = AttemptLedger.fold(history, dispatch_log)
      assert entry.effect == :unknown
    end
  end

  # ===========================================================================
  # Token-cap enforcement — decision 2
  # ===========================================================================

  describe "render/2 — token cap" do
    test "an oversized ledger truncates, keeping most-recent/most-repeated entries first" do
      history =
        for i <- 0..40, do: {i, vec(a: :fail)}

      dispatch_log =
        for i <- 0..39 do
          dispatch(i, [:a], evidence: %{a: "distinct failure #{i}"}, touched: ["lib/f#{i}.ex"])
        end

      entries = AttemptLedger.fold(history, dispatch_log)
      assert length(entries) == 40

      full = AttemptLedger.render(entries, max_tokens: 100_000)
      capped = AttemptLedger.render(entries, max_tokens: 20)

      assert byte_size(capped) < byte_size(full)
      assert capped != ""
      # the most-recent entry (iteration 39) survives the cap; an early one does not.
      assert capped =~ "39"
      refute capped =~ "iteration(s) 0 "
    end

    test "the whole ledger fits under a generous cap" do
      history = [{0, vec(a: :fail)}, {1, vec(a: :fail)}]
      dispatch_log = [dispatch(0, [:a])]

      entries = AttemptLedger.fold(history, dispatch_log)
      rendered = AttemptLedger.render(entries, max_tokens: 800)

      assert rendered =~ "Attempt ledger"
    end
  end

  # ===========================================================================
  # Cross-run inclusion — decision 1
  # ===========================================================================

  describe "cross-run inclusion (same goal identity)" do
    test "an attempt from a prior run and a matching attempt from the current run repeat-fold together" do
      # Simulate two runs of the same goal: the caller queries the read-model by
      # GOAL identity (not run id) and concatenates both runs' history/dispatch
      # log before folding — exactly what a resumed goal's prompt-builder does.
      prior_run_history = [{0, vec(a: :fail)}, {1, vec(a: :fail)}]

      prior_run_dispatch = [
        dispatch(0, [:a], evidence: %{a: "same error"}, touched: ["lib/a.ex"])
      ]

      current_run_history = [{2, vec(a: :fail)}, {3, vec(a: :fail)}]

      current_run_dispatch = [
        dispatch(2, [:a], evidence: %{a: "same error"}, touched: ["lib/a.ex"])
      ]

      combined_history = prior_run_history ++ current_run_history
      combined_dispatch = prior_run_dispatch ++ current_run_dispatch

      assert [entry] = AttemptLedger.fold(combined_history, combined_dispatch)
      assert entry.repeats == 2
      assert entry.iterations == [0, 2]
    end
  end

  # ===========================================================================
  # Shared fold (decision 4 — read by Kazi.Loop.StuckDetector too)
  # ===========================================================================

  describe "failing_sets/1" do
    test "one MapSet per recorded observation, oldest-first" do
      history = [{0, vec(a: :fail)}, {1, vec(a: :pass)}]

      assert AttemptLedger.failing_sets(history) == [MapSet.new([:a]), MapSet.new([])]
    end
  end
end
