defmodule Kazi.LoopBudgetTest do
  @moduledoc """
  Loop-level enforcement of the hard budget ceiling (T1.4, UC-009).

  The pure decision is unit-tested in `Kazi.Loop.BudgetTest`; here we prove the
  loop ENFORCES it as a hard stop — with a never-converging predicate set so the
  only way the loop terminates is the budget. Each dimension (iterations,
  wall-clock, tokens, dispatches) stops the loop with the correct reason, and the
  stop is visible in `Kazi.Loop.snapshot/1` and the terminal result.

  The `max_dispatches` dimension (T48.6, ADR-0058) additionally needs proof that
  it counts ONLY `:dispatch_agent` actions, not observe ticks — see the "dispatch
  ceiling" section below.
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

  # A harness double that reports BOTH the rolled-up token estimate
  # (`cost.tokens`, what `budget_spent.tokens` accumulates) AND the per-field
  # economy envelope split (`usage`, T34.2), so the T34.4 cached-read discount
  # is driveable. `:tokens_per_run` is the full total (cached reads counted at
  # full weight, as a provider sums them); `:cached_per_run` is how many of those
  # were cached reads.
  defmodule CachedUsageHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, opts) do
      total = Keyword.get(opts, :tokens_per_run, 0)
      cached = Keyword.get(opts, :cached_per_run, 0)

      {:ok,
       %{
         output: "ok",
         cost: %{tokens: total},
         usage: %{input_tokens: total - cached, cached_input_tokens: cached}
       }}
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

  # A provider whose predicate is ALWAYS :pass — the vector is satisfied from the
  # first observation, so `decide/2` never reaches the dispatch clause. Paired
  # with `standing: true` this proves an observe-only loop (no agent dispatch,
  # ever) cannot trip `max_dispatches` no matter how many times it re-observes.
  defmodule AlwaysGreenProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, _context),
      do: PredicateResult.pass(%{id: id, status: :pass})
  end

  # A provider driven by a per-test Agent holding a list of scripted statuses (one
  # per observation, last value sticky) keyed by predicate id — mirrors
  # `Kazi.StandingDriftTest.ScriptedProvider`. Lets a test interleave dispatch-
  # triggering `:fail`s with `:pass` no-op ticks, and the test process can push a
  # fresh `:fail` mid-run to script a SECOND drift after some no-op ticks have run.
  defmodule ScriptedProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      script_pid = Kazi.LoopBudgetTest.script_name(context.goal.id) |> Process.whereis()

      case next_status(script_pid, id) do
        :pass -> PredicateResult.pass(%{id: id, status: :pass})
        :fail -> PredicateResult.fail(%{id: id, status: :fail})
      end
    end

    defp next_status(script_pid, id) do
      Agent.get_and_update(script_pid, fn scripts ->
        case Map.fetch(scripts, id) do
          {:ok, [last]} -> {last, Map.put(scripts, id, [last])}
          {:ok, [head | tail]} -> {head, Map.put(scripts, id, tail)}
          :error -> {:pass, scripts}
        end
      end)
    end
  end

  # A harness double that counts dispatches (via `dispatch_pid`) and, like
  # `Kazi.StandingDriftTest.FixingHarness`, "fixes" the drifted predicate by
  # forcing the script back to sticky `:pass` — emulating the coding agent landing
  # a fix so the loop re-converges rather than dispatching every tick.
  defmodule CountingFixingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, opts) do
      dispatch_pid = Keyword.fetch!(opts, :dispatch_pid)
      script_pid = Keyword.fetch!(opts, :script_pid)

      Agent.update(dispatch_pid, fn n -> n + 1 end)

      Agent.update(script_pid, fn scripts -> Map.new(scripts, fn {id, _} -> {id, [:pass]} end) end)

      {:ok, %{output: "fixed"}}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # The registered name under which a test's script Agent lives, derived from the
  # goal id so `ScriptedProvider` can find it from the provider context (which
  # carries the goal but not arbitrary test-only keys). Public so the provider
  # module can call it.
  def script_name(goal_id), do: :"kazi_loop_budget_script_#{goal_id}"

  defp never_converging_goal(budget) do
    Goal.new("budget-test",
      predicates: [Predicate.new(:code, :tests)],
      budget: budget
    )
  end

  defp start_loop(goal, opts) do
    {harness, opts} = Keyword.pop(opts, :harness, TokenHarness)

    base = [
      goal: goal,
      providers: %{tests: NeverConvergingProvider},
      harness: harness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      # Poll fast so the budget trips quickly rather than waiting on the prod
      # default re-observe interval.
      reobserve_interval_ms: 1,
      # T1.5 stuck: these tests isolate the BUDGET dimension with a never-
      # converging code predicate (a constant failing set), which the stuck
      # detector would otherwise escalate first. Disable it here so the budget
      # is the sole terminator; stuck is exercised in Kazi.StuckLoopTest.
      stuck_iterations: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  defp poll_until(loop, fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_until(loop, fun, deadline)
  end

  defp do_poll_until(loop, fun, deadline) do
    snap = Kazi.Loop.snapshot(loop)

    cond do
      fun.(snap) ->
        snap

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("poll_until timed out; last snapshot: #{inspect(snap)}")

      true ->
        Process.sleep(2)
        do_poll_until(loop, fun, deadline)
    end
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

  # ===========================================================================
  # Dispatch-count ceiling (T48.6, ADR-0058): max_dispatches counts ONLY
  # :dispatch_agent actions — an observe-only tick never consumes it. This is
  # what makes it a better proxy for spend than max_iterations for a wedged run:
  # a run stuck polling a persistently-erroring live predicate can burn dozens of
  # cheap observe ticks against max_iterations while dispatching nothing.
  # ===========================================================================

  test "stops at the dispatch ceiling with reason :max_dispatches" do
    # NeverConvergingProvider dispatches the agent on every tick, so dispatches
    # == iterations here — a direct trip of the new dimension.
    goal = never_converging_goal(Kazi.Budget.new(max_dispatches: 3))

    {:ok, loop} = start_loop(goal, adapter_opts: [tokens_per_run: 0])

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :over_budget
    assert result.reason == :max_dispatches

    snap = Kazi.Loop.snapshot(loop)
    assert snap.state == :over_budget
    assert snap.budget_reason == :max_dispatches
    assert snap.dispatches == 3
  end

  test "a loop with only observe ticks never trips max_dispatches" do
    # AlwaysGreenProvider satisfies the vector from the first observation, so
    # decide/2 never reaches the dispatch clause — every tick past the first is a
    # standing-mode re-observe (T3.4a), never a dispatch. A max_dispatches: 1
    # ceiling must NOT trip no matter how many times it re-observes.
    goal =
      Goal.new("budget-test-observe-only",
        predicates: [Predicate.new(:code, :tests)],
        budget: Kazi.Budget.new(max_dispatches: 1)
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: AlwaysGreenProvider},
        harness: TokenHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        adapter_opts: [tokens_per_run: 0],
        reobserve_interval_ms: 2,
        standing: true,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    # Let it re-observe well past the ceiling's count.
    snap = poll_until(loop, fn s -> s.steady_observations >= 5 end)

    refute snap.state == :over_budget
    assert snap.dispatches == 0
    assert snap.budget_reason == nil

    :ok = Kazi.Loop.stop(loop)
  end

  test "the gate stops after N dispatches regardless of intervening no-op ticks" do
    # Script: an initial failure (dispatch #1), then several ticks holding
    # steady (no-op — the standing loop re-observing past convergence, T3.4a),
    # then the test injects a SECOND drift (dispatch #2). max_dispatches: 2 must
    # trip on dispatch #2 even though many no-op ticks ran in between and
    # `iterations` is far larger than the dispatch ceiling.
    goal_id = "budget-test-dispatch-ceiling-#{System.unique_integer([:positive])}"

    goal =
      Goal.new(goal_id,
        predicates: [Predicate.new(:code, :tests)],
        budget: Kazi.Budget.new(max_dispatches: 2)
      )

    {:ok, script_pid} = Agent.start_link(fn -> %{code: [:fail]} end, name: script_name(goal_id))
    {:ok, dispatch_pid} = Agent.start_link(fn -> 0 end)

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: ScriptedProvider},
        harness: CountingFixingHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        adapter_opts: [script_pid: script_pid, dispatch_pid: dispatch_pid],
        reobserve_interval_ms: 2,
        standing: true,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    # 1. The scripted failure fires dispatch #1; the harness "fixes" it.
    poll_until(loop, fn _ -> Agent.get(dispatch_pid, & &1) >= 1 end)
    assert Kazi.Loop.snapshot(loop).dispatches == 1

    # 2. Let SEVERAL no-op (steady, re-observe) ticks run before the next drift —
    #    these must NOT move the dispatch counter.
    pre_drift = poll_until(loop, fn s -> s.steady_observations >= 3 end)
    assert pre_drift.dispatches == 1
    assert pre_drift.iterations > pre_drift.dispatches

    # 3. Inject a second drift from the test process (simulating a later
    #    regression) — this fires dispatch #2, which trips the ceiling.
    Agent.update(script_pid, fn scripts -> Map.new(scripts, fn {id, _} -> {id, [:fail]} end) end)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :over_budget
    assert result.reason == :max_dispatches

    snap = Kazi.Loop.snapshot(loop)
    assert snap.dispatches == 2
    assert Agent.get(dispatch_pid, & &1) == 2
    # The hard proof this counts DISPATCHES, not ticks: iterations vastly
    # exceeds the 2-dispatch ceiling because of the no-op ticks in between.
    assert snap.iterations > snap.dispatches
  end

  # ===========================================================================
  # T34.4 (ADR-0046 #4): the budget guard discounts cached reads, so a fresh-
  # cheap but cache-hit-heavy run is NOT falsely flagged over_budget. The
  # terminal gate logic is unchanged — only the token COST arithmetic.
  # ===========================================================================

  describe "cached-read discount on the token dimension" do
    # 60 tokens/run, 58 of them cached reads (fresh-cheap, cache-heavy). The same
    # spend trips the token ceiling under the old all-equal arithmetic but not
    # under the default discount — proven below by flipping ONLY the weight.
    @cache_heavy adapter_opts: [tokens_per_run: 60, cached_per_run: 58]

    test "a cache-heavy run stays under the token budget with the default discount" do
      # max_tokens: 100 would trip on the raw 60+60=120 total by iteration 2, but
      # discounted (cached at 0.1) the token spend stays far under 100, so the run
      # instead reaches the iteration ceiling. The TOKEN gate never fires.
      goal = never_converging_goal(Kazi.Budget.new(max_tokens: 100, max_iterations: 10))

      {:ok, loop} = start_loop(goal, [harness: CachedUsageHarness] ++ @cache_heavy)

      assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
      assert result.outcome == :over_budget
      # NOT :token_budget — the discount kept the cache-heavy spend under the ceiling.
      assert result.reason == :max_iterations
      assert result.iterations == 10

      # The rolled-up total still accumulated at full weight (back-compat):
      # `budget_spent.tokens` reports raw tokens, the discount is gate-only.
      assert Kazi.Loop.snapshot(loop).tokens_used == 600
    end

    test "the SAME run trips :token_budget when cached reads are weighted as fresh" do
      # cached_read_weight: 1.0 is the pre-T34.4 all-equal arithmetic. Same
      # harness, same ceiling — only the weight differs — and now the cached
      # reads count full, so the token gate fires. This isolates the discount as
      # the sole cause of the different outcome; the gate logic is identical.
      goal =
        never_converging_goal(
          Kazi.Budget.new(max_tokens: 100, max_iterations: 10, cached_read_weight: 1.0)
        )

      {:ok, loop} = start_loop(goal, [harness: CachedUsageHarness] ++ @cache_heavy)

      assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
      assert result.outcome == :over_budget
      assert result.reason == :token_budget
    end

    test "a run with NO cached reads trips :token_budget identically (discount is a no-op)" do
      # Fresh-only spend: the discount has nothing to rebate, so behaviour is
      # byte-identical to the pre-T34.4 token dimension regardless of the weight.
      goal = never_converging_goal(Kazi.Budget.new(max_tokens: 100, max_iterations: 10))

      {:ok, loop} =
        start_loop(goal, harness: CachedUsageHarness, adapter_opts: [tokens_per_run: 60])

      assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
      assert result.outcome == :over_budget
      assert result.reason == :token_budget
    end
  end
end
