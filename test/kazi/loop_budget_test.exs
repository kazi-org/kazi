defmodule Kazi.LoopBudgetTest do
  @moduledoc """
  Loop-level enforcement of the hard budget ceiling (T1.4, UC-009).

  The pure decision is unit-tested in `Kazi.Loop.BudgetTest`; here we prove the
  loop ENFORCES it as a hard stop — with a never-converging predicate set so the
  only way the loop terminates is the budget. Each dimension (iterations,
  wall-clock, tokens) stops the loop with the correct reason, and the stop is
  visible in `Kazi.Loop.snapshot/1` and the terminal result.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # ===========================================================================
  # Test doubles (zero-stub: test-only; the loop depends on the behaviours)
  # ===========================================================================

  # A provider whose predicate is ALWAYS :fail, so the loop can never converge —
  # the only terminator is the budget guard.
  defmodule NeverConvergingProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, _context),
      do: PredicateResult.fail(%{id: id, status: :fail})
  end

  # A harness double that reports a configurable per-run token estimate, read from
  # adapter_opts (`:tokens_per_run`), so the token dimension is driveable.
  defmodule TokenHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, opts) do
      tokens = Keyword.get(opts, :tokens_per_run, 0)
      {:ok, %{output: "ok", cost: %{tokens: tokens}}}
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
    Goal.new("budget-test",
      predicates: [Predicate.new(:code, :tests)],
      budget: budget
    )
  end

  defp start_loop(goal, opts) do
    base = [
      goal: goal,
      providers: %{tests: NeverConvergingProvider},
      harness: TokenHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      # Poll fast so the budget trips quickly rather than waiting on the prod
      # default re-observe interval.
      reobserve_interval_ms: 1
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  # ===========================================================================
  # Iteration ceiling
  # ===========================================================================

  test "stops at the iteration ceiling with reason :max_iterations" do
    goal = never_converging_goal(Kazi.Budget.new(max_iterations: 3))

    {:ok, loop} = start_loop(goal, adapter_opts: [tokens_per_run: 0])

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :over_budget
    assert result.reason == :max_iterations

    # A hard ceiling: exactly the permitted number of iterations ran (0..N-1),
    # then the guard stopped the loop before a 4th.
    assert result.iterations == 3

    snap = Kazi.Loop.snapshot(loop)
    assert snap.state == :over_budget
    assert snap.budget_reason == :max_iterations
  end

  test "the iteration stop is a HARD stop: no further work is dispatched once over budget" do
    # max_iterations: 1 → only iteration 0 runs; the loop must not keep churning.
    goal = never_converging_goal(Kazi.Budget.new(max_iterations: 1))

    {:ok, loop} = start_loop(goal, adapter_opts: [tokens_per_run: 0])

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :over_budget
    assert result.reason == :max_iterations
    assert result.iterations == 1

    # It is genuinely terminal: it stays over_budget and a later await still
    # returns the cached over-budget result rather than running more.
    assert Kazi.Loop.snapshot(loop).state == :over_budget
    assert {:ok, ^result} = Kazi.Loop.await(loop, 1_000)
  end

  # ===========================================================================
  # Wall-clock ceiling (deterministic via the injectable clock)
  # ===========================================================================

  test "stops at the wall-clock ceiling with reason :wall_clock (injectable clock)" do
    # A deterministic monotonic clock that advances 10ms per reading. The loop
    # reads the clock once at init (started_at) and once per budget check; with a
    # 25ms ceiling it crosses the limit without any real sleeping.
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    now_fn = fn -> Agent.get_and_update(clock, fn t -> {t, t + 10} end) end

    goal = never_converging_goal(Kazi.Budget.new(max_wall_clock_ms: 25))

    {:ok, loop} = start_loop(goal, adapter_opts: [tokens_per_run: 0], now_fn: now_fn)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :over_budget
    assert result.reason == :wall_clock

    snap = Kazi.Loop.snapshot(loop)
    assert snap.state == :over_budget
    assert snap.budget_reason == :wall_clock
  end

  # ===========================================================================
  # Token-estimate ceiling
  # ===========================================================================

  test "stops at the token ceiling with reason :token_budget, accumulating harness estimates" do
    # Each dispatch reports 40 tokens; with a 100-token ceiling the loop trips on
    # the third check (0 → 40 → 80 → 120 ≥ 100). Iterations are left unbounded so
    # the token dimension is what stops it.
    goal = never_converging_goal(Kazi.Budget.new(max_tokens: 100))

    {:ok, loop} = start_loop(goal, adapter_opts: [tokens_per_run: 40])

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :over_budget
    assert result.reason == :token_budget

    snap = Kazi.Loop.snapshot(loop)
    assert snap.state == :over_budget
    assert snap.budget_reason == :token_budget
    # Accumulated token estimate crossed the ceiling.
    assert snap.tokens_used >= 100
  end

  # ===========================================================================
  # Unbounded budget never trips
  # ===========================================================================

  test "an unbounded (all-nil) budget never forces an over-budget stop" do
    goal = never_converging_goal(%Kazi.Budget{})

    {:ok, loop} = start_loop(goal, adapter_opts: [tokens_per_run: 1])

    # It can never converge (predicate always fails) and has no budget, so it
    # keeps running: await times out and the loop is still going.
    assert {:error, :timeout} = Kazi.Loop.await(loop, 150)
    snap = Kazi.Loop.snapshot(loop)
    refute snap.state == :over_budget
    assert snap.budget_reason == nil
    assert snap.iterations >= 1

    :ok = Kazi.Loop.stop(loop)
  end

  test "the budget opt overrides the goal's own budget" do
    # Goal carries no budget; the loop opt supplies one and is enforced.
    goal = never_converging_goal(%Kazi.Budget{})

    {:ok, loop} =
      start_loop(goal,
        adapter_opts: [tokens_per_run: 0],
        budget: Kazi.Budget.new(max_iterations: 2)
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :over_budget
    assert result.reason == :max_iterations
    assert result.iterations == 2
  end
end
