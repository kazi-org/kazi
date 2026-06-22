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

  defp start_loop(goal, providers, collector) do
    Kazi.Loop.start_link(
      goal: goal,
      providers: providers,
      harness: RecordingHarness,
      integrate: RecordingIntegrate,
      deploy: RecordingDeploy,
      adapter_opts: [collector: collector],
      # Poll the live predicate fast so tests don't wait on the production
      # default interval.
      reobserve_interval_ms: 5
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
