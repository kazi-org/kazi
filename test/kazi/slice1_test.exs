defmodule Kazi.Slice1Test do
  @moduledoc """
  Tier 1+2 — the CONSOLIDATED, cross-cutting suite for the Slice-1 trustworthy
  loop (T1.7, verifying UC-007, UC-008, UC-009, UC-021).

  Each Slice-1 feature already has a focused unit test (`Kazi.Loop.BudgetTest`,
  `Kazi.Loop.FlakeTest`, `Kazi.Loop.StuckDetectorTest`,
  `Kazi.Loop.RegressionDetectorTest`) and a per-feature loop-level enforcement
  test (`Kazi.LoopBudgetTest`, `Kazi.StuckLoopTest`, the flake/regression cases in
  `Kazi.LoopTest`, `Kazi.Providers.ProdLogTest`). Those isolate each feature: the
  budget tests turn stuck OFF, the stuck tests have no budget, the flake/regression
  loop tests turn both OFF. That isolation is correct for proving one feature, but
  it leaves the questions T1.7 exists to answer:

    * Do the four detectors behave correctly *together*, in the real loop, when
      more than one could fire at once? What is the loop's *precedence*?
    * Is a regression recorded by the running loop actually readable back from the
      read-model (not just visible in `snapshot/1`)?
    * Does a `:prod_log` predicate, declared in a goal-file and dispatched through
      the REAL loader + runtime, behave as a *live* (deploy-gated) predicate
      rather than code the loop tries to "fix"?

  This module answers them. It substitutes nothing in `lib/`: it uses test-only
  behaviour doubles (the zero-stub policy is for `lib/` only) for the
  controllable-trajectory scenarios, and the REAL `Kazi.Providers.ProdLog` +
  `Kazi.Goal.Loader` + `Kazi.Runtime` for the prod-log dispatch scenario. It is
  self-contained: its own SQLite Sandbox connection, stub providers, and an
  injectable clock — no Go, no network.

  ## Precedence (the documented order this suite pins, see `Kazi.Loop`)

  Per observation the loop composes its guards in this order (loop `observe_tick/1`
  → `decide/2`):

    1. **Budget** — checked FIRST, at the very top of every tick, BEFORE observing
       or dispatching. If a hard ceiling is crossed the loop stops `:over_budget`
       and never observes again (loop §"the hard ceiling is checked ONCE at the
       start of every tick").
    2. **Flake** — applied DURING observation: a failing predicate is re-run and a
       flake is quarantined (recorded `:unknown`) so it never enters the work-list.
    3. **Stuck** — checked AFTER observation, over the CODE-only history, BEFORE
       `decide`. A persistent non-empty failing set stops `:stopped`/`:stuck`.
    4. **Regression** — recorded each observation (it is observability, never a
       terminator); it can co-exist with any of the above.
    5. **Converge / dispatch / integrate / deploy / poll** — `decide/2`.

  So when two conditions are both true the deciding factor is WHICH GUARD TRIPS ON
  WHICH TICK. The budget guard runs at the TOP of a tick, *before* that tick's
  observation; the stuck verdict is produced *by* a tick's observation. Therefore:

    * a budget ceiling **strictly below** the stuck window trips on an earlier
      tick and stops `:over_budget` before the stuck window can fill;
    * at an equal (or looser) budget the stuck verdict produced mid-tick wins,
      because it fires within that tick, ahead of the budget check at the START of
      the next tick — so `max_iterations == stuck_iterations` stops `:stuck`.

  A quarantined flake is removed from the failing set *before* the stuck detector
  sees it (loop `code_history/1`), so a flaky predicate cannot, by itself, sustain
  a stuck verdict. A regression is flagged regardless of whether the loop also
  stops for budget or stuck — it is observability, never a terminator. Both
  precedence boundaries and the flake/stuck interaction are asserted below.
  """
  use ExUnit.Case, async: false

  alias Kazi.{Budget, Goal, Loop, Predicate, PredicateResult, ReadModel, Repo, Runtime}

  @moduletag :tmp_dir

  # ===========================================================================
  # Test doubles (zero-stub: test-only; the loop depends on the behaviours)
  # ===========================================================================

  # A provider backed by an Agent of per-id status scripts. evaluate/2 pops the
  # next status for that id; once one status remains it is returned forever. Lets
  # a scenario say "keep goes :pass,:pass,:fail" to drive a green→red regression
  # across observations deterministically. The agent pid is read from the goal's
  # metadata (the doubles run inside the loop process, not the test).
  defmodule ScriptedProvider do
    @behaviour Kazi.PredicateProvider
    use Agent

    def start_link(script) when is_map(script), do: Agent.start_link(fn -> script end)

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      pid = context.goal.metadata.script_pid

      status =
        Agent.get_and_update(pid, fn script ->
          case Map.get(script, id, [:pass]) do
            [last] -> {last, script}
            [head | tail] -> {head, Map.put(script, id, tail)}
          end
        end)

      PredicateResult.new(status, %{id: id, status: status})
    end
  end

  # A provider whose result for a predicate ALTERNATES on every evaluation,
  # starting from a per-id seed in metadata.flake_start — a genuine flake the
  # T1.3 re-run policy must catch (the value flips WITHIN one observation's
  # re-runs). Ids absent from flake_start are a steady :fail (real work).
  defmodule AlternatingProvider do
    @behaviour Kazi.PredicateProvider
    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{} end)

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      starts = context.goal.metadata.flake_start

      case Map.get(starts, id) do
        nil ->
          PredicateResult.fail(%{id: id, status: :fail})

        start ->
          pid = context.goal.metadata.alt_pid

          n =
            Agent.get_and_update(pid, fn counts ->
              c = Map.get(counts, id, 0)
              {c, Map.put(counts, id, c + 1)}
            end)

          status = if rem(n, 2) == 0, do: start, else: flip(start)
          PredicateResult.new(status, %{id: id, status: status, eval: n})
      end
    end

    defp flip(:fail), do: :pass
    defp flip(:pass), do: :fail
  end

  # Harness double: reports a configurable per-run token estimate (from
  # adapter_opts) and announces each dispatch to the collector pid (from the
  # goal's metadata) so a scenario can assert whether/when an agent was dispatched.
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, _workspace, opts) do
      tokens = Keyword.get(opts, :tokens_per_run, 0)
      if c = Keyword.get(opts, :collector), do: send(c, {:dispatched, prompt})
      {:ok, %{output: "ok", cost: %{tokens: tokens}}}
    end
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  setup do
    # Several scenarios persist through the read-model on the loop's own process;
    # share this checked-out Sandbox connection so the loop's writes land where
    # the test reads (mirrors Kazi.FullLoopTest).
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp goal(id, predicates, metadata, opts \\ []) do
    Goal.new(id, [predicates: predicates, metadata: metadata] ++ opts)
  end

  # Start a loop with the scripted/alternating providers + recording doubles.
  # Defaults keep every detector controllable; a scenario overrides only what it
  # exercises.
  defp start_loop(goal, providers, opts) do
    base = [
      goal: goal,
      providers: providers,
      harness: RecordingHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      reobserve_interval_ms: 1,
      adapter_opts: [],
      # Off by default — each scenario opts the detectors it tests back on so the
      # OTHER detectors don't terminate the loop first (the same isolation the
      # per-feature tests use, applied per scenario here).
      flake_max_retries: 0,
      stuck_iterations: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        do_wait_until(fun, deadline)
    end
  end

  # ===========================================================================
  # 1. Regression (UC-007) — drive a real dispatch that flips a green predicate
  #    red; assert it is flagged, attributed to that dispatch, and READABLE BACK
  #    from the read-model (not just snapshot/1, which loop_test already covers).
  # ===========================================================================

  describe "regression in the real loop, attributed and persisted (UC-007)" do
    test "a dispatch that flips a previously-green predicate red is flagged + read back" do
      # `fixme` is the failing work that drives the dispatch; `keep` is a guard
      # that is green for the first two observations and goes red on the third —
      # i.e. AFTER the dispatch decided at observation index 1. The loop keeps
      # running (fixme stays red), so we snapshot once the regression appears.
      script_pid = start_scripted(%{fixme: [:fail], keep: [:pass, :pass, :fail]})

      g =
        goal(
          "slice1-regression",
          [Predicate.new(:fixme, :tests), Predicate.new(:keep, :tests)],
          %{script_pid: script_pid, collector: self()}
        )

      {:ok, loop} =
        start_loop(g, %{tests: ScriptedProvider},
          adapter_opts: [collector: self()],
          on_iteration: persist_fn("slice1-regression")
        )

      assert wait_until(fn -> Loop.snapshot(loop).regressions != [] end, 5_000),
             "the green→red regression on :keep was never flagged"

      snap = Loop.snapshot(loop)
      assert [flag] = snap.regressions
      assert flag.predicate_id == :keep
      assert flag.status == :fail
      # Attributed to the agent dispatch decided in the green→red window: a
      # :dispatch_agent action whose failing work-list named :fixme.
      assert %Kazi.Action{kind: :dispatch_agent} = flag.attributed_dispatch
      assert :fixme in flag.attributed_dispatch.params.failing

      Loop.stop(loop)

      # The headline T1.7 assertion beyond loop_test: the regression the running
      # loop detected is queryable from the READ-MODEL (string-keyed on-disk form).
      assert wait_until(fn -> ReadModel.regressions("slice1-regression") != [] end, 2_000)
      regressions = ReadModel.regressions("slice1-regression")
      assert [{_idx, [persisted]} | _] = regressions
      assert persisted["predicate_id"] == "keep"
      assert persisted["status"] == "fail"
    end
  end

  # ===========================================================================
  # 2. Flake (UC-008) — a flaky predicate is quarantined and NOT work; a
  #    consistently-failing one is NOT quarantined and DOES drive a dispatch.
  #    Cross-cutting twist: both live in the SAME goal in the SAME run.
  # ===========================================================================

  describe "flake vs. real failure, together in one goal (UC-008)" do
    test "the flaky predicate is quarantined while the real failure still dispatches" do
      {:ok, alt_pid} = AlternatingProvider.start_link(nil)

      g =
        goal(
          "slice1-flake",
          [Predicate.new(:flaky, :tests), Predicate.new(:real, :tests)],
          %{alt_pid: alt_pid, flake_start: %{flaky: :fail}, collector: self()}
        )

      {:ok, loop} =
        start_loop(g, %{tests: AlternatingProvider},
          # Re-runs ON so the within-observation flip is detected and quarantined.
          flake_max_retries: 2,
          adapter_opts: [collector: self()]
        )

      # The real (steady) failure drives an agent dispatch...
      assert_receive {:dispatched, prompt}, 5_000
      # ...and the dispatch's work-list is the REAL failure, never the flake.
      assert prompt =~ "real"
      refute prompt =~ "flaky"

      assert wait_until(fn -> :flaky in Loop.snapshot(loop).quarantine end, 5_000),
             "the alternating predicate was never quarantined as flaky"

      snap = Loop.snapshot(loop)
      assert :flaky in snap.quarantine
      refute :real in snap.quarantine

      Loop.stop(loop)
    end
  end

  # ===========================================================================
  # 3. Budget (UC-009) — each hard ceiling stops the loop with the right reason,
  #    proven through the REAL goal-carried budget (loader→goal→loop), with stuck
  #    OFF so the budget is the sole terminator.
  # ===========================================================================

  describe "every budget ceiling hard-stops with the right reason (UC-009)" do
    setup do
      script_pid = start_scripted(%{code: [:fail]})

      make = fn id, budget ->
        goal(id, [Predicate.new(:code, :tests)], %{script_pid: script_pid, collector: self()},
          budget: budget
        )
      end

      {:ok, make: make}
    end

    test "iteration ceiling → :max_iterations", %{make: make} do
      g = make.("slice1-budget-iter", Budget.new(max_iterations: 3))
      {:ok, loop} = start_loop(g, %{tests: ScriptedProvider}, [])

      assert {:ok, result} = Loop.await(loop, 5_000)
      assert result.outcome == :over_budget
      assert result.reason == :max_iterations
      assert result.iterations == 3
      assert Loop.snapshot(loop).budget_reason == :max_iterations
    end

    test "wall-clock ceiling via injectable clock → :wall_clock", %{make: make} do
      # Deterministic clock advancing 10ms/read; a 25ms ceiling trips with no real
      # sleeping (the loop reads it once at init + once per budget check).
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      now_fn = fn -> Agent.get_and_update(clock, fn t -> {t, t + 10} end) end

      g = make.("slice1-budget-clock", Budget.new(max_wall_clock_ms: 25))
      {:ok, loop} = start_loop(g, %{tests: ScriptedProvider}, now_fn: now_fn)

      assert {:ok, result} = Loop.await(loop, 5_000)
      assert result.outcome == :over_budget
      assert result.reason == :wall_clock
    end

    test "token-estimate ceiling → :token_budget", %{make: make} do
      g = make.("slice1-budget-tokens", Budget.new(max_tokens: 100))

      {:ok, loop} =
        start_loop(g, %{tests: ScriptedProvider}, adapter_opts: [tokens_per_run: 40])

      assert {:ok, result} = Loop.await(loop, 5_000)
      assert result.outcome == :over_budget
      assert result.reason == :token_budget
      assert Loop.snapshot(loop).tokens_used >= 100
    end
  end

  # ===========================================================================
  # 4. Stuck (UC-009) — the same failing set across N iterations fires the
  #    escalation hook ONCE and stops :stuck. (No budget, so stuck is the sole
  #    terminator.)
  # ===========================================================================

  describe "a persistent failing set escalates once and stops :stuck (UC-009)" do
    test "the escalation hook fires exactly once and the loop stops :stuck" do
      test_pid = self()
      script_pid = start_scripted(%{code: [:fail]})

      g = goal("slice1-stuck", [Predicate.new(:code, :tests)], %{script_pid: script_pid})

      {:ok, loop} =
        start_loop(g, %{tests: ScriptedProvider},
          stuck_iterations: 3,
          on_escalation: fn ctx -> send(test_pid, {:escalation, ctx}) end
        )

      assert {:ok, result} = Loop.await(loop, 5_000)
      assert result.outcome == :stopped
      assert result.reason == :stuck
      assert result.iterations == 3

      assert_receive {:escalation, ctx}, 1_000
      assert ctx.failing == MapSet.new([:code])
      # Exactly once — no second escalation after the terminal stop.
      refute_receive {:escalation, _}, 100

      assert Loop.snapshot(loop).stuck_failing == [:code]
    end
  end

  # ===========================================================================
  # 5. Prod-log (UC-021) — the REAL ProdLog provider, declared in a goal-file and
  #    dispatched through the REAL loader + runtime. Clean logs pass; 5xx/panic
  #    over threshold fail. AND it is treated as a LIVE predicate (deploy-gated),
  #    not code — the cross-cutting behaviour the per-provider unit test cannot see.
  # ===========================================================================

  describe "prod-log declared in a goal-file, dispatched live through the runtime (UC-021)" do
    test "loader maps prod_log → :prod_log and the runtime resolves the real provider",
         %{tmp_dir: tmp_dir} do
      logs = Path.join(tmp_dir, "clean.log")
      File.write!(logs, "2026-06-21T10:00:00Z GET /healthz status: 200 ok\n")

      goal_file = Path.join(tmp_dir, "goal.toml")

      File.write!(goal_file, """
      id = "slice1-prodlog-goal"

      [[predicate]]
      id = "prod"
      provider = "prod_log"
      cmd = "cat"
      args = ["#{logs}"]
      """)

      assert {:ok, loaded} = Kazi.Goal.Loader.load(goal_file)
      [predicate] = loaded.predicates
      assert predicate.kind == :prod_log

      # The runtime's provider table resolves the real ProdLog for that kind.
      assert Runtime.provider_modules()[:prod_log] == Kazi.Providers.ProdLog
    end

    test "clean logs pass; logs over threshold fail (real provider, real System.cmd)",
         %{tmp_dir: tmp_dir} do
      clean = Path.join(tmp_dir, "clean.log")
      File.write!(clean, "2026-06-21T10:00:00Z GET /healthz status: 200 ok\n")

      noisy = Path.join(tmp_dir, "noisy.log")
      File.write!(noisy, "GET /a status: 500\nGET /b status: 503\npanic: boom\n")

      clean_p = Predicate.new("prod", :prod_log, config: %{cmd: "cat", args: [clean]})
      noisy_p = Predicate.new("prod", :prod_log, config: %{cmd: "cat", args: [noisy]})

      assert %PredicateResult{status: :pass} =
               Kazi.Providers.ProdLog.evaluate(clean_p, %{workspace: tmp_dir})

      assert %PredicateResult{status: :fail} =
               Kazi.Providers.ProdLog.evaluate(noisy_p, %{workspace: tmp_dir})
    end

    test "a red prod_log is treated as a LIVE predicate: it does NOT dispatch a fixer agent" do
      # This is the cross-cutting behaviour T1.7 must lock in (and the bug it
      # surfaced): prod_log probes the DEPLOYED system, so a red prod-log is live
      # work the loop reconciles toward via deploy — NOT code an agent is sent to
      # "fix". If prod_log were mis-classified as a CODE kind the loop would
      # dispatch the harness against production logs, which is nonsensical.
      #
      # Use a steadily-failing prod_log predicate and prove the harness is never
      # dispatched (a live failure does not seed a code work-list). The loop is
      # driven directly with the default live_kinds (NOT overridden) so this
      # asserts the SHIPPED classification.
      g =
        goal(
          "slice1-prodlog-live",
          [Predicate.new(:prod, :prod_log)],
          %{flake_start: %{}, collector: self()}
        )

      {:ok, loop} =
        Loop.start_link(
          goal: g,
          # A provider that always fails for this kind (a red live probe).
          providers: %{prod_log: AlternatingProvider},
          harness: RecordingHarness,
          integrate: NoopIntegrate,
          deploy: NoopDeploy,
          reobserve_interval_ms: 1,
          flake_max_retries: 0,
          stuck_iterations: 0,
          adapter_opts: [collector: self()]
        )

      # Give the loop ample observations: a code predicate would have dispatched
      # many times by now. A live predicate never seeds a dispatch.
      refute_receive {:dispatched, _}, 300

      # It is genuinely live: not converged, no dispatch, and (since code is green
      # by absence) it tried to integrate/deploy and now polls the live predicate.
      snap = Loop.snapshot(loop)
      refute snap.state in [:converged]
      assert snap.iterations >= 1

      Loop.stop(loop)
    end
  end

  # ===========================================================================
  # 6. Interactions / precedence — at least one scenario where two conditions
  #    could fire; assert the loop's documented, deterministic precedence.
  # ===========================================================================

  describe "precedence when two conditions could fire at once (cross-cutting)" do
    test "budget wins over stuck when the iteration ceiling is below the stuck window" do
      # The failing set is constant (:code always :fail) — that is BOTH a stuck
      # condition (same non-empty set across N) AND will exhaust any iteration
      # budget. The budget guard runs at the TOP of every tick (before that tick's
      # observation); the stuck verdict is produced BY a tick's observation. So a
      # budget ceiling STRICTLY BELOW the stuck window trips on an earlier tick,
      # before the stuck window can fill: with max_iterations: 2 and
      # stuck_iterations: 3 the loop stops :over_budget at iteration 2, before the
      # 3rd observation that would declare it stuck. This is the verified,
      # deterministic precedence (see this module's @moduledoc).
      script_pid = start_scripted(%{code: [:fail]})

      g =
        goal(
          "slice1-precedence-budget",
          [Predicate.new(:code, :tests)],
          %{script_pid: script_pid},
          budget: Budget.new(max_iterations: 2)
        )

      {:ok, loop} =
        start_loop(g, %{tests: ScriptedProvider}, stuck_iterations: 3)

      assert {:ok, result} = Loop.await(loop, 5_000)

      assert result.outcome == :over_budget
      assert result.reason == :max_iterations
      assert result.iterations == 2
      refute Loop.snapshot(loop).stuck_failing
    end

    test "stuck wins when the stuck window is reached before the budget ceiling" do
      # The complementary case proving the precedence is about WHICH GUARD TRIPS ON
      # WHICH TICK, not "budget always wins". With a stuck window (3) reached at or
      # before the budget ceiling, the stuck verdict produced by observation index
      # 2 terminates the loop :stuck before the budget guard at the top of the next
      # tick could fire. Equal windows (max_iterations: 3, stuck_iterations: 3) is
      # the boundary: the stuck verdict from observation 3 fires WITHIN tick 3,
      # ahead of the budget check that would occur at the START of tick 4 — so
      # stuck wins at the boundary.
      script_pid = start_scripted(%{code: [:fail]})

      g =
        goal("slice1-precedence-stuck", [Predicate.new(:code, :tests)], %{script_pid: script_pid},
          budget: Budget.new(max_iterations: 3)
        )

      {:ok, loop} =
        start_loop(g, %{tests: ScriptedProvider}, stuck_iterations: 3)

      assert {:ok, result} = Loop.await(loop, 5_000)
      assert result.outcome == :stopped
      assert result.reason == :stuck
      assert result.iterations == 3
    end

    test "a flake in the failing set does NOT, by itself, sustain the ORDINARY same-failing-set stuck detector" do
      # The ORDINARY (T1.5) stuck detector sees the CODE-only history with
      # quarantined ids removed (loop `code_history/1`). So a predicate that
      # flakes (and is quarantined) cannot keep the failing set non-empty for its
      # window: once quarantined it leaves the failing set, and a goal whose ONLY
      # predicate is the flake then has an EMPTY failing set for that detector —
      # it can never fire on this goal, no matter how large its window.
      #
      # #820 note: the vector is still blocked SOLELY by quarantine with nothing
      # dispatchable, so the loop DOES eventually stop honestly `:stuck` via the
      # independent `Flake.quarantine_only_stuck_ticks/0` path (not idle forever,
      # the pre-#820 bug). `stuck_iterations` is set far above that bound here so
      # a stop this soon can only be #820's path, never the ordinary detector —
      # proving the two are independent.
      {:ok, alt_pid} = AlternatingProvider.start_link(nil)

      g =
        goal(
          "slice1-precedence-flake",
          [Predicate.new(:flaky, :tests)],
          %{alt_pid: alt_pid, flake_start: %{flaky: :fail}, collector: self()}
        )

      {:ok, loop} =
        start_loop(g, %{tests: AlternatingProvider},
          flake_max_retries: 2,
          stuck_iterations: 1_000,
          adapter_opts: [collector: self()]
        )

      assert {:ok, result} = Loop.await(loop, 5_000)

      assert result.outcome == :stopped
      assert result.reason == :stuck
      assert result.iterations < 1_000
      refute_receive {:dispatched, _}
      assert :flaky in Loop.snapshot(loop).quarantine
    end
  end

  # ===========================================================================
  # Local persistence seam: project each iteration into the read-model exactly as
  # the runtime does (so the regression read-back assertion uses the real path).
  # ===========================================================================

  defp persist_fn(goal_ref) do
    fn payload ->
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: payload.iteration,
        predicate_vector: payload.vector,
        converged: payload.converged?,
        regressions: Map.get(payload, :regressions, [])
      })

      :ok
    end
  end

  defp start_scripted(script) do
    {:ok, pid} = ScriptedProvider.start_link(script)
    pid
  end
end
