defmodule Kazi.Attention.QueueTest do
  @moduledoc """
  Unit tests for the pure fleet-wide attention-queue ranking (T46.6, UC-061).

  `Kazi.Attention.Queue.build/2` is tested in isolation here: `:history_fn`/
  `:regressions_fn` are injected fixtures (no DB, no run registry) so each
  signal — stuck, budget, flake suspicion, regression-recovered — and the
  documented ranking can be pinned directly. The rendering of these entries as
  Mission Control alert cards over the REAL read-model is proven in
  `KaziWeb.MissionControlLiveTest`.
  """
  use ExUnit.Case, async: true

  alias Kazi.Attention.Queue
  alias Kazi.ReadModel.Run
  alias Kazi.{PredicateResult, PredicateVector}

  defp run(overrides \\ %{}) do
    struct(
      %Run{
        run_id: "run-#{System.unique_integer([:positive])}",
        goal_ref: "goal-#{System.unique_integer([:positive])}",
        max_iterations: nil
      },
      overrides
    )
  end

  defp vector(fail_ids, pass_ids \\ [], error_ids \\ []) do
    fails = Map.new(fail_ids, fn id -> {id, PredicateResult.fail()} end)
    passes = Map.new(pass_ids, fn id -> {id, PredicateResult.pass()} end)
    errors = Map.new(error_ids, fn id -> {id, PredicateResult.error()} end)
    PredicateVector.new(Map.merge(Map.merge(passes, fails), errors))
  end

  defp history(vectors) do
    vectors |> Enum.with_index() |> Enum.map(fn {v, i} -> {i, v} end)
  end

  defp build(runs, history_by_ref, regressions_by_ref \\ %{}) do
    Queue.build(runs,
      history_fn: fn ref -> Map.get(history_by_ref, ref, []) end,
      regressions_fn: fn ref -> Map.get(regressions_by_ref, ref, []) end
    )
  end

  describe "empty fleet" do
    test "no runs yields an empty queue" do
      assert build([], %{}) == []
    end
  end

  describe ":cause signal (T48.14)" do
    test "a finished run with an error_wedged cause raises a :cause entry with the cause detail" do
      r =
        run(%{
          outcome_cause_class: "error_wedged",
          outcome_cause_detail: %{
            "ids" => ["live_route"],
            "reasons" => %{"live_route" => "missing_url"},
            "exhausted" => nil
          }
        })

      [entry] = build([r], %{})

      assert entry.signal == :cause
      assert entry.severity == 5
      assert entry.predicate_id == "live_route"
      assert entry.detail.cause_class == "error_wedged"
      assert entry.detail.cause_detail["reasons"] == %{"live_route" => "missing_url"}
    end

    test "a finished run with a quarantine_blocked cause raises a :cause entry" do
      r =
        run(%{
          outcome_cause_class: "quarantine_blocked",
          outcome_cause_detail: %{"ids" => ["flappy"], "reasons" => %{}, "exhausted" => nil}
        })

      [entry] = build([r], %{})

      assert entry.signal == :cause
      assert entry.severity == 5
      assert entry.predicate_id == "flappy"
    end

    test "a budget_exhausted cause raises NO :cause entry (the operator can raise the budget)" do
      r =
        run(%{
          outcome_cause_class: "budget_exhausted",
          outcome_cause_detail: %{"ids" => [], "reasons" => %{}, "exhausted" => "max_iterations"}
        })

      assert build([r], %{}) == []
    end

    test "a run with no cause classified raises nothing -- byte-identical to today" do
      r = run(%{outcome_cause_class: nil, outcome_cause_detail: nil})

      assert build([r], %{}) == []
    end
  end

  describe ":stuck signal" do
    test "the same non-empty failing set for the stuck window raises a :stuck entry" do
      r = run()
      h = history([vector(["a"]), vector(["a"]), vector(["a"])])

      [entry] = build([r], %{r.goal_ref => h})

      assert entry.signal == :stuck
      assert entry.severity == 4
      assert entry.goal_ref == r.goal_ref
      assert entry.predicate_id == "a"
      assert entry.iteration_index == 2
    end

    test "a changing failing set does not raise :stuck" do
      r = run()
      h = history([vector(["a"]), vector(["b"]), vector(["a"])])

      assert build([r], %{r.goal_ref => h}) == []
    end
  end

  describe ":budget signal" do
    test ">=85% of max_iterations consumed raises a :budget entry" do
      r = run(%{max_iterations: 10})
      # 9 observed iterations (indices 0..8) => 90% consumed.
      h = history(for _ <- 1..9, do: vector([], ["a"]))

      [entry] = build([r], %{r.goal_ref => h})

      assert entry.signal == :budget
      assert entry.severity == 3
      assert entry.detail.consumed_iterations == 9
      assert entry.detail.max_iterations == 10
    end

    test "below the threshold raises nothing" do
      r = run(%{max_iterations: 10})
      h = history(for _ <- 1..8, do: vector([], ["a"]))

      assert build([r], %{r.goal_ref => h}) == []
    end

    test "no declared max_iterations never raises :budget" do
      r = run(%{max_iterations: nil})
      h = history(for _ <- 1..40, do: vector([], ["a"]))

      assert build([r], %{r.goal_ref => h}) == []
    end
  end

  describe ":flake_suspicion signal" do
    test "a predicate flipping status more than once raises a :flake_suspicion entry" do
      r = run()
      h = history([vector(["a"], ["b"]), vector([], ["a", "b"]), vector(["a"], ["b"])])

      entries = build([r], %{r.goal_ref => h})
      assert [%{signal: :flake_suspicion, predicate_id: "a"}] = entries
    end

    test "a predicate that only ever fails once is not flagged as flaky" do
      r = run()
      h = history([vector([], ["a"]), vector([], ["a"]), vector(["a"], [])])

      assert build([r], %{r.goal_ref => h}) == []
    end
  end

  describe ":regression_recovered signal" do
    test "a past green->red flag whose predicate is back to :pass raises an entry" do
      r = run()
      h = history([vector(["a"]), vector([], ["a"])])

      regressions = %{
        r.goal_ref => [
          {0, [%{"predicate_id" => "a", "green_iteration" => 0, "red_iteration" => 1}]}
        ]
      }

      [entry] = build([r], %{r.goal_ref => h}, regressions)

      assert entry.signal == :regression_recovered
      assert entry.severity == 1
      assert entry.predicate_id == "a"
    end

    test "a regression whose predicate is STILL red is not (yet) recovered" do
      r = run()
      h = history([vector(["a"]), vector(["a"])])

      regressions = %{
        r.goal_ref => [
          {0, [%{"predicate_id" => "a", "green_iteration" => 0, "red_iteration" => 1}]}
        ]
      }

      assert build([r], %{r.goal_ref => h}, regressions) == []
    end
  end

  describe "ranking" do
    test "an error_wedged cause outranks an otherwise-equal ordinary stuck run (T48.14)" do
      stuck_run = run()
      stuck_history = history([vector(["a"]), vector(["a"]), vector(["a"])])

      wedged_run =
        run(%{outcome_cause_class: "error_wedged", outcome_cause_detail: %{"ids" => ["live"]}})

      entries =
        build([stuck_run, wedged_run], %{stuck_run.goal_ref => stuck_history})

      assert Enum.map(entries, & &1.signal) == [:cause, :stuck]
    end

    test "a quarantine_blocked cause outranks an otherwise-equal ordinary stuck run (T48.14)" do
      stuck_run = run()
      stuck_history = history([vector(["a"]), vector(["a"]), vector(["a"])])

      blocked_run =
        run(%{
          outcome_cause_class: "quarantine_blocked",
          outcome_cause_detail: %{"ids" => ["flappy"]}
        })

      entries =
        build([stuck_run, blocked_run], %{stuck_run.goal_ref => stuck_history})

      assert Enum.map(entries, & &1.signal) == [:cause, :stuck]
    end

    test "stuck outranks budget outranks regression-recovered" do
      stuck_run = run()
      stuck_history = history([vector(["a"]), vector(["a"]), vector(["a"])])

      budget_run = run(%{max_iterations: 10})
      budget_history = history(for _ <- 1..9, do: vector([], ["a"]))

      recovered_run = run()
      recovered_history = history([vector(["a"]), vector([], ["a"])])

      recovered_regressions = %{
        recovered_run.goal_ref => [
          {0, [%{"predicate_id" => "a", "green_iteration" => 0, "red_iteration" => 1}]}
        ]
      }

      entries =
        build(
          [budget_run, recovered_run, stuck_run],
          %{
            stuck_run.goal_ref => stuck_history,
            budget_run.goal_ref => budget_history,
            recovered_run.goal_ref => recovered_history
          },
          recovered_regressions
        )

      assert Enum.map(entries, & &1.signal) == [:stuck, :budget, :regression_recovered]
    end

    test "ties on severity are broken by recency (most recent iteration first)" do
      older = run()
      older_history = history([vector(["a"]), vector(["a"]), vector(["a"])])

      newer = run()

      newer_history =
        history([vector(["a"]), vector(["a"]), vector(["a"]), vector(["a"]), vector(["a"])])

      entries =
        build([older, newer], %{
          older.goal_ref => older_history,
          newer.goal_ref => newer_history
        })

      assert Enum.map(entries, & &1.goal_ref) == [newer.goal_ref, older.goal_ref]
    end
  end
end
