defmodule Kazi.Loop.RegressionDetectorTest do
  use ExUnit.Case, async: true

  doctest Kazi.Loop.RegressionDetector

  alias Kazi.{Action, PredicateResult, PredicateVector}
  alias Kazi.Loop.RegressionDetector

  # ---------------------------------------------------------------------------
  # Helpers: build history entries + dispatch-log entries tersely.
  # ---------------------------------------------------------------------------

  defp vec(results), do: PredicateVector.new(Map.new(results, fn {id, s} -> {id, res(s)} end))

  defp res(:pass), do: PredicateResult.pass()
  defp res(:fail), do: PredicateResult.fail()
  defp res(:error), do: PredicateResult.error()
  defp res(:unknown), do: PredicateResult.unknown()

  defp dispatch(index, failing) do
    {index, Action.new(:dispatch_agent, params: %{failing: failing})}
  end

  # ===========================================================================
  # Detection
  # ===========================================================================

  describe "detect/2 — green→red detection" do
    test "a predicate that was green then red is flagged" do
      history = [{0, vec(a: :pass)}, {1, vec(a: :fail)}]

      assert [flag] = RegressionDetector.detect(history, [])
      assert flag.predicate_id == :a
      assert flag.green_iteration == 0
      assert flag.red_iteration == 1
      assert flag.status == :fail
    end

    test "green → :error is a regression (error is a red endpoint)" do
      history = [{0, vec(a: :pass)}, {1, vec(a: :error)}]

      assert [flag] = RegressionDetector.detect(history, [])
      assert flag.status == :error
    end

    test "a never-green predicate (failing from the start) is NOT a regression" do
      history = [{0, vec(a: :fail)}, {1, vec(a: :fail)}]

      assert RegressionDetector.detect(history, []) == []
    end

    test "a first-time fail after only being unknown is NOT a regression" do
      history = [{0, vec(a: :unknown)}, {1, vec(a: :fail)}]

      assert RegressionDetector.detect(history, []) == []
    end

    test "a still-green predicate is NOT flagged" do
      history = [{0, vec(a: :pass)}, {1, vec(a: :pass)}, {2, vec(a: :pass)}]

      assert RegressionDetector.detect(history, []) == []
    end

    test "red → green (a fix) is NOT a regression" do
      history = [{0, vec(a: :fail)}, {1, vec(a: :pass)}]

      assert RegressionDetector.detect(history, []) == []
    end

    test "a single observation cannot carry a regression" do
      assert RegressionDetector.detect([{0, vec(a: :pass)}], []) == []
    end

    test "empty history yields no flags" do
      assert RegressionDetector.detect([], []) == []
    end

    test "an :unknown between a green and a later red does not break the green run" do
      # green(0) → unknown(1) → fail(2): the regression is green(0) → red(2);
      # the :unknown carries no claim so it is neither green nor a red endpoint.
      history = [{0, vec(a: :pass)}, {1, vec(a: :unknown)}, {2, vec(a: :fail)}]

      assert [flag] = RegressionDetector.detect(history, [])
      assert flag.green_iteration == 0
      assert flag.red_iteration == 2
    end

    test "an absent predicate between green and red does not break the green run" do
      history = [{0, vec(a: :pass)}, {1, vec(b: :pass)}, {2, vec(a: :fail)}]

      assert [flag] = RegressionDetector.detect(history, [])
      assert flag.predicate_id == :a
      assert flag.green_iteration == 0
      assert flag.red_iteration == 2
    end

    test "oscillation green→red→green→red flags each distinct green→red edge" do
      history = [
        {0, vec(a: :pass)},
        {1, vec(a: :fail)},
        {2, vec(a: :pass)},
        {3, vec(a: :fail)}
      ]

      flags = RegressionDetector.detect(history, [])
      assert Enum.map(flags, & &1.red_iteration) == [1, 3]
      assert Enum.map(flags, & &1.green_iteration) == [0, 2]
    end

    test "multiple predicates regressing in the same iteration are each flagged" do
      history = [{0, vec(a: :pass, b: :pass)}, {1, vec(a: :fail, b: :error)}]

      flags = RegressionDetector.detect(history, [])
      assert Enum.map(flags, & &1.predicate_id) == [:a, :b]
      assert Enum.map(flags, & &1.status) == [:fail, :error]
    end

    test "history is sorted by iteration index regardless of input order" do
      history = [{1, vec(a: :fail)}, {0, vec(a: :pass)}]

      assert [flag] = RegressionDetector.detect(history, [])
      assert flag.green_iteration == 0
      assert flag.red_iteration == 1
    end
  end

  # ===========================================================================
  # Attribution
  # ===========================================================================

  describe "detect/2 — dispatch attribution" do
    test "attributes the regression to the dispatch in the green→red window" do
      history = [{0, vec(a: :pass)}, {1, vec(a: :fail)}]
      # The dispatch decided after observing green(0), before re-observing red(1).
      {_idx, action} = entry = dispatch(0, [:b])

      assert [flag] = RegressionDetector.detect(history, [entry])
      assert flag.attributed_dispatch == action
    end

    test "attributes to the MOST RECENT dispatch in the window" do
      history = [{0, vec(a: :pass)}, {1, vec(a: :pass)}, {2, vec(a: :fail)}]
      earlier = dispatch(0, [:x])
      {_idx, later_action} = later = dispatch(1, [:y])

      assert [flag] = RegressionDetector.detect(history, [earlier, later])
      assert flag.attributed_dispatch == later_action
    end

    test "no dispatch in the window → attribution is nil but the regression is still flagged" do
      history = [{0, vec(a: :pass)}, {1, vec(a: :fail)}]

      assert [flag] = RegressionDetector.detect(history, [])
      assert flag.attributed_dispatch == nil
    end

    test "a dispatch outside the [green, red) window is not attributed" do
      # green(1) → red(2); a dispatch at index 0 is before the window.
      history = [{0, vec(a: :fail)}, {1, vec(a: :pass)}, {2, vec(a: :fail)}]
      before_window = dispatch(0, [:a])

      assert [flag] = RegressionDetector.detect(history, [before_window])
      # The flag is for the green(1)→red(2) edge; the only dispatch (idx 0) is
      # before it, so nothing is attributed.
      assert flag.green_iteration == 1
      assert flag.red_iteration == 2
      assert flag.attributed_dispatch == nil
    end

    test "non-:dispatch_agent log entries are ignored for attribution" do
      history = [{0, vec(a: :pass)}, {1, vec(a: :fail)}]
      integrate = {0, Action.new(:integrate)}

      assert [flag] = RegressionDetector.detect(history, [integrate])
      assert flag.attributed_dispatch == nil
    end
  end
end
