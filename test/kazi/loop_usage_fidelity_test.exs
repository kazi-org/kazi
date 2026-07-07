defmodule Kazi.LoopUsageFidelityTest do
  @moduledoc """
  T48.5 (ADR-0058 §4): the token-ceiling honesty warning.

  `Kazi.LoopBudgetTest` proves the token dimension enforces a `max_tokens`
  ceiling WHEN the harness reports usage. Here we prove the honest-unknown
  counterpart: when the harness reports NO usage at all (the `claw` profile,
  ADR-0022, by design — no cost, no tokens, no per-dispatch fidelity), the
  ceiling can never bind (the loop's token total never grows past 0), so the
  run must say so — a warning logged exactly ONCE (not once per dispatch,
  which would just be noise against a harness that never reports usage) and a
  `usage_fidelity: :unreported` flag on both `snapshot/1` and the terminal
  result. A harness that DOES report usage, or a goal with no `max_tokens`
  ceiling at all, stays byte-identical: no warning, `usage_fidelity: nil`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # ===========================================================================
  # Test doubles (zero-stub: test-only; the loop depends on the behaviours)
  # ===========================================================================

  # A provider whose predicate is ALWAYS :fail, so the loop can never converge
  # — the only terminator is the budget guard (mirrors Kazi.LoopBudgetTest).
  defmodule NeverConvergingProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, _context),
      do: PredicateResult.fail(%{id: id, status: :fail})
  end

  # A best-effort harness double mirroring the `claw` profile (ADR-0022):
  # reports NO usage at all — no `cost`, no `usage` split, no per-dispatch
  # `usage_fidelity`.
  defmodule NoUsageHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{result: "did some work"}}
  end

  # A harness double that reports usage every dispatch — a ceiling that CAN
  # bind.
  defmodule ReportingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok, %{output: "ok", cost: %{tokens: 40}, usage_fidelity: :full}}
    end
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp never_converging_goal(budget) do
    Goal.new("usage-fidelity-test",
      predicates: [Predicate.new(:code, :tests)],
      budget: budget
    )
  end

  defp start_loop(goal, opts) do
    {harness, opts} = Keyword.pop(opts, :harness, NoUsageHarness)

    base = [
      goal: goal,
      providers: %{tests: NeverConvergingProvider},
      harness: harness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      # Poll fast so the iteration ceiling (the only terminator once the token
      # dimension can never bind) trips quickly.
      reobserve_interval_ms: 1,
      # Isolate the budget/usage-fidelity dimension from the stuck detector,
      # exactly as Kazi.LoopBudgetTest does.
      stuck_iterations: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  # ===========================================================================
  # max_tokens set, harness reports no usage: the ceiling cannot bind
  # ===========================================================================

  test "warns exactly once and flags :unreported when max_tokens is set but the harness reports no usage" do
    goal = never_converging_goal(Kazi.Budget.new(max_tokens: 100, max_iterations: 5))

    log =
      capture_log(fn ->
        {:ok, loop} = start_loop(goal, harness: NoUsageHarness)

        assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

        # The token dimension never grew (nothing reported), so the run was
        # forced to stop on the iteration ceiling instead — direct proof the
        # max_tokens ceiling never bound.
        assert result.outcome == :over_budget
        assert result.reason == :max_iterations
        assert result.iterations == 5
        assert result.usage_fidelity == :unreported

        snap = Kazi.Loop.snapshot(loop)
        assert snap.usage_fidelity == :unreported
      end)

    # Exactly once across the whole run, even though every one of the 5
    # dispatches reported no usage — a warning per dispatch would be noise.
    occurrences =
      log
      |> String.split("the token ceiling cannot bind")
      |> length()
      |> Kernel.-(1)

    assert occurrences == 1
  end

  # ===========================================================================
  # max_tokens set, harness DOES report usage: a ceiling that can bind
  # ===========================================================================

  test "emits no warning and no flag when the harness reports usage" do
    goal = never_converging_goal(Kazi.Budget.new(max_tokens: 1_000, max_iterations: 3))

    log =
      capture_log(fn ->
        {:ok, loop} = start_loop(goal, harness: ReportingHarness)

        assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

        assert result.outcome == :over_budget
        assert result.reason == :max_iterations
        assert result.usage_fidelity == nil

        assert Kazi.Loop.snapshot(loop).usage_fidelity == nil
      end)

    refute log =~ "cannot bind"
  end

  # ===========================================================================
  # No max_tokens ceiling at all: byte-identical to today regardless of usage
  # ===========================================================================

  test "no max_tokens ceiling means no warning and no flag, even with a no-usage harness" do
    goal = never_converging_goal(Kazi.Budget.new(max_iterations: 3))

    log =
      capture_log(fn ->
        {:ok, loop} = start_loop(goal, harness: NoUsageHarness)

        assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

        assert result.outcome == :over_budget
        assert result.reason == :max_iterations
        assert result.usage_fidelity == nil

        assert Kazi.Loop.snapshot(loop).usage_fidelity == nil
      end)

    refute log =~ "cannot bind"
  end
end
