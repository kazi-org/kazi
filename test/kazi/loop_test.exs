defmodule Kazi.LoopTest do
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # ===========================================================================
  # Test doubles
  #
  # Test-only modules implementing the behaviours, scripted to drive the machine
  # through the full lifecycle. Per the zero-stub policy these live ONLY here;
  # the loop depends on the BEHAVIOURS, never on a concrete impl.
  #
  # The doubles run *inside the loop's gen_statem process*, so `self()` there is
  # the loop — not the test. They therefore read everything they need (the
  # scripted-status Agent pid, the collector pid the test listens on) out of the
  # context the loop threads through:
  #
  #   * providers   — from the goal's `metadata` (carried in provider_context as
  #                   `context.goal.metadata`);
  #   * actions     — same, via `context.goal.metadata`;
  #   * the harness — from `adapter_opts`.
  # ===========================================================================

  # A predicate provider backed by an Agent returning a scripted sequence of
  # statuses per predicate id. evaluate/2 pops the next status for that id; once
  # one status remains it is returned forever. Lets a test say "code is :fail
  # then :pass", driving the machine deterministically.
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

  # A live provider gated on deploy: :fail until context.deployed? is true, then
  # :pass. Proves the loop only converges once deploy happened AND the live
  # predicate is re-observed against the deployed artifact.
  defmodule DeployGatedLiveProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, %{deployed?: true}),
      do: PredicateResult.pass(%{id: id, live: :up})

    def evaluate(%Predicate{id: id}, _context),
      do: PredicateResult.fail(%{id: id, live: :down})
  end

  # A live provider that is ALWAYS down — :fail regardless of deploy state. Used
  # by the objective-termination guard test (T0.8): with code green and the
  # change landed + deployed, this red live probe must still block :converged.
  defmodule AlwaysDownLiveProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, _context),
      do: PredicateResult.fail(%{id: id, live: :down})
  end

  # A provider whose result for a predicate ALTERNATES on every evaluation:
  # :fail, :pass, :fail, :pass, … starting from a configurable first status. This
  # is a genuine flake — within a single observation the loop's re-runs see the
  # value flip — which the T1.3 re-run policy must detect and quarantine. The
  # starting status per id is read from context.goal.metadata.flake_start.
  defmodule AlternatingProvider do
    @behaviour Kazi.PredicateProvider
    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{} end)

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      pid = context.goal.metadata.alt_pid
      start = Map.get(context.goal.metadata.flake_start, id, :fail)

      n =
        Agent.get_and_update(pid, fn counts ->
          c = Map.get(counts, id, 0)
          {c, Map.put(counts, id, c + 1)}
        end)

      status = if rem(n, 2) == 0, do: start, else: flip(start)
      PredicateResult.new(status, %{id: id, status: status, eval: n})
    end

    defp flip(:fail), do: :pass
    defp flip(:pass), do: :fail
    defp flip(other), do: other
  end

  # Harness double: records each invocation to the collector (from adapter_opts)
  # and reports success.
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, workspace, opts) do
      send(Keyword.fetch!(opts, :collector), {:dispatched, prompt, workspace})
      {:ok, %{output: "ok", cost: %{tokens: 1}}}
    end
  end

  # Action doubles: record to the collector (from context.goal.metadata) and
  # return {:ok, _}.
  defmodule RecordingIntegrate do
    @behaviour Kazi.Action

    @impl true
    def execute(%Action{kind: :integrate}, context) do
      send(context.goal.metadata.collector, {:integrate, context.failing})
      {:ok, %{pr: 1}}
    end
  end

  defmodule RecordingDeploy do
    @behaviour Kazi.Action

    @impl true
    def execute(%Action{kind: :deploy}, context) do
      send(context.goal.metadata.collector, {:deploy, context.landed?})
      {:ok, %{ref: "v1"}}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # Build a goal whose metadata carries the scripted-status Agent pid and the
  # collector pid the doubles report to.
  defp goal_with(predicates, script_pid, collector) do
    Goal.new("loop-test",
      predicates: predicates,
      metadata: %{script_pid: script_pid, collector: collector}
    )
  end

  defp start_scripted(script) do
    {:ok, pid} = ScriptedProvider.start_link(script)
    pid
  end

  defp start_loop(goal, providers, collector, opts \\ []) do
    Kazi.Loop.start_link(
      [
        goal: goal,
        providers: providers,
        harness: RecordingHarness,
        integrate: RecordingIntegrate,
        deploy: RecordingDeploy,
        adapter_opts: [collector: collector],
        # Poll the live predicate fast so tests don't wait on the production
        # default interval.
        reobserve_interval_ms: 5,
        # These lifecycle tests use the ScriptedProvider to express status flips
        # ACROSS observations (fail this iteration, pass the next, once the agent
        # has "fixed" the code). Disable the T1.3 re-run policy here so a single
        # observation consumes exactly one scripted status and those across-
        # observation flips are not (correctly!) read as within-observation
        # flakes. The dedicated flake tests below opt the policy back in.
        flake_max_retries: 0
      ]
      |> Keyword.merge(opts)
    )
  end

  # ===========================================================================
  # Tests
  # ===========================================================================

  test "full happy path: failing → dispatch → green → integrate → deploy → live-pass → converged" do
    script_pid = start_scripted(%{code: [:fail, :pass]})

    goal =
      goal_with(
        [Predicate.new(:code, :tests), Predicate.new(:live, :http_probe)],
        script_pid,
        self()
      )

    {:ok, loop} =
      start_loop(goal, %{tests: ScriptedProvider, http_probe: DeployGatedLiveProvider}, self())

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged

    # The action sequence: dispatch (code failing) → integrate (code green, not
    # landed) → deploy (landed, not deployed) → converge once the live predicate
    # passes against the deployed artifact.
    assert result.actions == [:dispatch_agent, :integrate, :deploy]

    # The agent was dispatched with the failing CODE predicate as evidence.
    assert_received {:dispatched, prompt, _ws}
    assert prompt =~ "code"

    # Integrate ran while the code predicate was the failing/just-fixed work.
    assert_received {:integrate, _failing}
    # Deploy ran with the change already landed.
    assert_received {:deploy, true}
  end

  test "picks integrate after code goes green (between dispatch and deploy)" do
    script_pid = start_scripted(%{code: [:fail, :pass]})

    goal =
      goal_with(
        [Predicate.new(:code, :tests), Predicate.new(:live, :http_probe)],
        script_pid,
        self()
      )

    {:ok, loop} =
      start_loop(goal, %{tests: ScriptedProvider, http_probe: DeployGatedLiveProvider}, self())

    assert {:ok, result} = Kazi.Loop.await(loop)

    assert Enum.find_index(result.actions, &(&1 == :dispatch_agent)) <
             Enum.find_index(result.actions, &(&1 == :integrate))

    assert Enum.find_index(result.actions, &(&1 == :integrate)) <
             Enum.find_index(result.actions, &(&1 == :deploy))
  end

  test "picks deploy only after integrate; converges only once the live predicate passes" do
    # code is green from the first observation — no dispatch should happen.
    script_pid = start_scripted(%{code: [:pass]})

    goal =
      goal_with(
        [Predicate.new(:code, :tests), Predicate.new(:live, :http_probe)],
        script_pid,
        self()
      )

    {:ok, loop} =
      start_loop(goal, %{tests: ScriptedProvider, http_probe: DeployGatedLiveProvider}, self())

    assert {:ok, result} = Kazi.Loop.await(loop)
    assert result.outcome == :converged
    refute :dispatch_agent in result.actions
    assert result.actions == [:integrate, :deploy]
    assert_received {:deploy, true}
  end

  test "stays running while a code predicate keeps failing, then stops on request" do
    # code never goes green; the loop keeps dispatching and never converges.
    script_pid = start_scripted(%{code: [:fail]})

    goal =
      goal_with(
        [Predicate.new(:code, :tests), Predicate.new(:live, :http_probe)],
        script_pid,
        self()
      )

    {:ok, loop} =
      start_loop(goal, %{tests: ScriptedProvider, http_probe: DeployGatedLiveProvider}, self())

    # Let it churn through several dispatch cycles without converging.
    assert {:error, :timeout} = Kazi.Loop.await(loop, 200)

    snap = Kazi.Loop.snapshot(loop)
    assert snap.iterations >= 1
    assert :dispatch_agent in snap.actions
    refute snap.deployed?

    :ok = Kazi.Loop.stop(loop)
    assert {:ok, result} = Kazi.Loop.await(loop, 1_000)
    assert result.outcome == :stopped
    refute Enum.empty?(result.actions)
  end

  test "converges immediately, with no actions, when the whole vector is already satisfied" do
    script_pid = start_scripted(%{code: [:pass], live: [:pass]})

    # Both predicates are plain code-kind here so neither is deploy-gated: the
    # very first observation is already satisfied.
    goal =
      goal_with(
        [Predicate.new(:code, :tests), Predicate.new(:live, :tests)],
        script_pid,
        self()
      )

    {:ok, loop} = start_loop(goal, %{tests: ScriptedProvider}, self())

    assert {:ok, result} = Kazi.Loop.await(loop)
    assert result.outcome == :converged
    assert result.actions == []
    assert result.iterations == 1
  end

  test "does NOT converge on an all-pass over zero predicates (vacuous guard)" do
    # A goal with no predicates can never satisfy the vector, so it must keep
    # running rather than declare a vacuous convergence.
    script_pid = start_scripted(%{})
    goal = goal_with([], script_pid, self())

    {:ok, loop} = start_loop(goal, %{}, self())

    # No code predicate is failing (there are none), so the loop integrates,
    # deploys, then spins re-observing without ever satisfying the empty vector.
    assert {:error, :timeout} = Kazi.Loop.await(loop, 200)
    :ok = Kazi.Loop.stop(loop)
    assert {:ok, result} = Kazi.Loop.await(loop, 1_000)
    assert result.outcome == :stopped
  end

  # ===========================================================================
  # Objective-termination guard (T0.8, UC-005)
  #
  # The headline guarantee: success is objective and includes LIVE predicates.
  # `:converged` must be unreachable while any live probe is red, even when all
  # code/test predicates pass and the change is landed + deployed.
  # ===========================================================================

  test "a failing live probe blocks :converged even when all code predicates pass (T0.8)" do
    # Code is green from the first observation; the live http_probe is always
    # down. The loop should integrate + deploy (code is green and the change is
    # not yet landed/deployed) and then spin re-observing the live predicate —
    # but it must NEVER declare :converged while that probe is red.
    script_pid = start_scripted(%{code: [:pass]})

    goal =
      goal_with(
        [Predicate.new(:code, :tests), Predicate.new(:live, :http_probe)],
        script_pid,
        self()
      )

    {:ok, loop} =
      start_loop(goal, %{tests: ScriptedProvider, http_probe: AlwaysDownLiveProvider}, self())

    # It cannot converge: await must time out, and the loop is still running.
    assert {:error, :timeout} = Kazi.Loop.await(loop, 200)

    # It did do the deploy-chain work (code was green), yet stayed un-converged.
    snap = Kazi.Loop.snapshot(loop)
    refute snap.state == :converged
    assert snap.deployed?, "code was green so the change should have been deployed"
    assert :deploy in snap.actions
    refute :dispatch_agent in snap.actions

    # Stopping yields :stopped — confirming it never reached the success state on
    # its own while the live predicate was failing.
    :ok = Kazi.Loop.stop(loop)
    assert {:ok, result} = Kazi.Loop.await(loop, 1_000)
    assert result.outcome == :stopped
    refute result.outcome == :converged
  end

  test "converges once the live probe flips to pass after deploy (live red → green, T0.8)" do
    # Companion to the failing-live-probe test: same code-green setup, but the
    # live provider passes once the change is deployed (DeployGatedLiveProvider).
    # This proves the guard is not merely refusing to ever converge — it lets
    # :converged through precisely when the WHOLE vector (code + live) holds.
    script_pid = start_scripted(%{code: [:pass]})

    goal =
      goal_with(
        [Predicate.new(:code, :tests), Predicate.new(:live, :http_probe)],
        script_pid,
        self()
      )

    {:ok, loop} =
      start_loop(goal, %{tests: ScriptedProvider, http_probe: DeployGatedLiveProvider}, self())

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged
    # Converged only after the live predicate could pass — i.e. post-deploy.
    assert result.actions == [:integrate, :deploy]
  end

  # ===========================================================================
  # Per-iteration vector history (T1.1, UC-007)
  #
  # The loop keeps an in-state, ordered history of the FULL predicate vector for
  # every iteration, exposed via snapshot/1 (`:history`) and history/1. This is
  # the read seam the regression (T1.2) and stuck (T1.5) detectors consume.
  # ===========================================================================

  test "accumulates the full per-iteration vector history in observation order (T1.1)" do
    # code: :fail then :pass drives several observations before convergence, so
    # the history captures the trajectory (code red → code green → live up).
    script_pid = start_scripted(%{code: [:fail, :pass]})

    goal =
      goal_with(
        [Predicate.new(:code, :tests), Predicate.new(:live, :http_probe)],
        script_pid,
        self()
      )

    {:ok, loop} =
      start_loop(goal, %{tests: ScriptedProvider, http_probe: DeployGatedLiveProvider}, self())

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged

    history = Kazi.Loop.history(loop)

    # One entry per observation, indices ascending and contiguous from 0.
    indices = Enum.map(history, fn {index, _vector} -> index end)
    assert indices == Enum.to_list(0..(result.iterations - 1))

    # Every entry carries the WHOLE vector (both predicate ids), not just the
    # failing/changed one.
    assert Enum.all?(history, fn {_index, vector} ->
             MapSet.new(Map.keys(vector.results)) == MapSet.new([:code, :live])
           end)

    # The trajectory is faithful: the first observation has code failing (and the
    # live probe down, since it is deploy-gated); the final observation is fully
    # satisfied (the convergence vector).
    {0, first} = hd(history)
    assert MapSet.new(Kazi.PredicateVector.failing(first)) == MapSet.new([:code, :live])

    {_last_index, last} = List.last(history)
    assert Kazi.PredicateVector.satisfied?(last)
    assert last == result.vector

    # snapshot/1 exposes the same history.
    assert Kazi.Loop.snapshot(loop).history == history
  end

  test "history grows by one full vector per observation, oldest-first (T1.1)" do
    # Never converges (code stays red) so we can observe the history accumulating
    # across multiple ticks before stopping the loop.
    script_pid = start_scripted(%{code: [:fail]})

    goal =
      goal_with(
        [Predicate.new(:code, :tests), Predicate.new(:live, :http_probe)],
        script_pid,
        self()
      )

    {:ok, loop} =
      start_loop(goal, %{tests: ScriptedProvider, http_probe: DeployGatedLiveProvider}, self())

    # Let it churn through several dispatch cycles.
    assert {:error, :timeout} = Kazi.Loop.await(loop, 200)

    snap = Kazi.Loop.snapshot(loop)
    history = snap.history

    # history length tracks the iteration count exactly.
    assert length(history) == snap.iterations
    assert snap.iterations >= 2

    # Oldest-first, contiguous indices from 0.
    indices = Enum.map(history, fn {index, _vector} -> index end)
    assert indices == Enum.sort(indices)
    assert indices == Enum.to_list(0..(snap.iterations - 1))

    # Code is failing in every observed vector (it never went green).
    assert Enum.all?(history, fn {_index, vector} ->
             :code in Kazi.PredicateVector.failing(vector)
           end)

    :ok = Kazi.Loop.stop(loop)
  end

  test "history is empty only before the first observation, then non-empty (T1.1)" do
    script_pid = start_scripted(%{code: [:pass], live: [:pass]})

    goal =
      goal_with(
        [Predicate.new(:code, :tests), Predicate.new(:live, :tests)],
        script_pid,
        self()
      )

    {:ok, loop} = start_loop(goal, %{tests: ScriptedProvider}, self())

    assert {:ok, result} = Kazi.Loop.await(loop)
    assert result.outcome == :converged

    # Converged on the first observation → exactly one history entry, the
    # satisfied vector.
    assert [{0, vector}] = Kazi.Loop.history(loop)
    assert Kazi.PredicateVector.satisfied?(vector)
  end

  # ===========================================================================
  # Flake handling: re-run policy + quarantine (T1.3, UC-008)
  #
  # A nondeterministic predicate must not be treated as work. The loop re-runs a
  # failing predicate through the REAL provider path; a flip (fail↔pass) is
  # classified flaky, quarantined (surfaced via snapshot/1), kept out of the
  # work-list (no dispatch), and excluded from convergence. A consistently-
  # failing predicate is NOT quarantined and still drives a dispatch.
  # ===========================================================================

  test "a flaky predicate (alternating fail/pass) is quarantined and NOT dispatched as work" do
    {:ok, alt_pid} = AlternatingProvider.start_link(nil)
    script_pid = start_scripted(%{})

    # The goal carries BOTH the alternating (flaky) provider's metadata and the
    # scripted provider's (unused) pid so both behaviours can read context.
    goal =
      Goal.new("flake-test",
        predicates: [Predicate.new(:flaky, :tests)],
        metadata: %{
          alt_pid: alt_pid,
          flake_start: %{flaky: :fail},
          script_pid: script_pid,
          collector: self()
        }
      )

    {:ok, loop} =
      start_loop(goal, %{tests: AlternatingProvider}, self(), flake_max_retries: 2)

    # The flaky predicate is the only predicate; once quarantined it is excluded
    # from convergence, so the vector (with nothing left to assert) cannot
    # converge — the loop runs on. We just need it to have observed + quarantined.
    assert {:error, :timeout} = Kazi.Loop.await(loop, 200)

    snap = Kazi.Loop.snapshot(loop)
    assert :flaky in snap.quarantine, "the alternating predicate must be quarantined"

    # It was never dispatched as work: a quarantined flake is not the work-list.
    refute :dispatch_agent in snap.actions
    refute_received {:dispatched, _prompt, _ws}

    :ok = Kazi.Loop.stop(loop)
  end

  test "a quarantined flaky predicate does NOT block convergence of the real requirements" do
    {:ok, alt_pid} = AlternatingProvider.start_link(nil)

    # Two predicates: a genuinely-flaky one and a code predicate that is solidly
    # green. Once the flaky one is quarantined, convergence is evaluated over the
    # remaining (green) predicate only, so the loop converges despite the flake.
    goal =
      Goal.new("flake-converge",
        predicates: [
          Predicate.new(:flaky, :tests),
          Predicate.new(:solid, :solid_tests)
        ],
        metadata: %{alt_pid: alt_pid, flake_start: %{flaky: :fail}, collector: self()}
      )

    # :solid is a plain code-kind predicate that always passes (a tiny inline
    # always-pass provider via the existing DeployGated trick would gate on
    # deploy; we want unconditional pass, so use AlternatingProvider with a start
    # that never flips — start :pass and only one eval needed since pass is taken
    # at face value, no re-run).
    solid_provider = AlternatingProvider

    goal = %{
      goal
      | metadata: Map.put(goal.metadata, :flake_start, %{flaky: :fail, solid: :pass})
    }

    {:ok, loop} =
      start_loop(
        goal,
        %{tests: solid_provider, solid_tests: solid_provider},
        self(),
        flake_max_retries: 2
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged

    # The flaky predicate was quarantined and never dispatched as work.
    snap = Kazi.Loop.snapshot(loop)
    assert :flaky in snap.quarantine
    refute :dispatch_agent in result.actions
  end

  test "a consistently-failing predicate is NOT quarantined and still drives a dispatch" do
    # ScriptedProvider returns :fail forever for :code — re-runs all see :fail, so
    # classify/1 returns :fail (real work), NOT flaky. The loop must dispatch.
    script_pid = start_scripted(%{code: [:fail]})

    goal = goal_with([Predicate.new(:code, :tests)], script_pid, self())

    {:ok, loop} =
      start_loop(goal, %{tests: ScriptedProvider}, self(), flake_max_retries: 2)

    assert {:error, :timeout} = Kazi.Loop.await(loop, 200)

    snap = Kazi.Loop.snapshot(loop)
    # A real failure: not quarantined, dispatched as work.
    refute :code in snap.quarantine
    assert :dispatch_agent in snap.actions
    assert_received {:dispatched, prompt, _ws}
    assert prompt =~ "code"

    :ok = Kazi.Loop.stop(loop)
  end

  test "start_link fails when a required dependency option is missing" do
    Process.flag(:trap_exit, true)
    script_pid = start_scripted(%{code: [:pass]})
    goal = goal_with([Predicate.new(:code, :tests)], script_pid, self())

    assert {:error, %ArgumentError{message: msg}} =
             Kazi.Loop.start_link(
               goal: goal,
               # :providers omitted
               harness: RecordingHarness,
               integrate: RecordingIntegrate,
               deploy: RecordingDeploy
             )

    assert msg =~ ":providers"
  end
end
