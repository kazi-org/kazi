defmodule Kazi.SerialLandedIntegrateRoutingTest do
  @moduledoc """
  Issue #1290: in the SERIAL, single-workspace `kazi apply` loop, a failing
  `:landed` predicate must route to the controller's `Integrate` action
  (`decide/2` clause 3), NOT to agent re-dispatch (clause 2). Landing is
  controller-owned (the `Integrate` action, T44.3) — the inner agent does the
  code work; kazi's own action pushes the branch and opens the verification-report
  PR. Before the fix, the synthesized `:landed`-kind predicate (added when a goal
  declares `[integration] mode`) was treated as ordinary agent-fixable code by
  `code_failing?`, so clause 2 shadowed clause 3 and a failing landed predicate
  was misrouted to the harness (observed live in T44.14's dogfood, PR #1281: the
  goal went STUCK on `[:landed]` with clean, correctly-committed-but-unpushed
  code, because the "code-green-but-not-landed -> :integrate" transition never
  fired).

  These are loop-level pins on the ROUTING, using the same in-process scripted
  provider / recording seam pattern as `Kazi.StandingDriftTest`:

    * a goal WITH a `:landed`-kind predicate whose landed predicate fails while
      code stays green routes to `:integrate`, never `:dispatch_agent` — both on
      the FIRST land (code green, not yet landed) and on a REGRESSION after a
      prior successful integrate;
    * a goal WITHOUT a `:landed` predicate (`[integration] mode = none`, the shape
      every fleet member / `--parallel` group uses, whose landing is a
      scheduler-level git step OUTSIDE `decide/2`) is UNAFFECTED: a code
      regression still routes to `:dispatch_agent`. This is the "parallel path
      stays correct" regression pin at the loop level.

  Hermetic: in-process behaviour doubles + an injectable script controlling the
  provider result; no network, no git, deterministic via a small re-observe
  interval and snapshot polling.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # A provider whose verdict is driven by a per-test Agent holding a list of
  # statuses to play out (one per observation, last value sticky), keyed by
  # predicate id. Located through a name derived from the goal id (carried in the
  # provider context), so no production change is needed to inject the script.
  defmodule ScriptedProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      script_pid =
        Kazi.SerialLandedIntegrateRoutingTest.script_name(context.goal.id) |> Process.whereis()

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

  # A harness double that records every dispatch and forces all scripted
  # predicates green from here on (emulating the coding agent landing a code fix),
  # so a legitimate code regression re-converges.
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, opts) do
      script_pid = Keyword.fetch!(opts, :script_pid)
      dispatch_pid = Keyword.fetch!(opts, :dispatch_pid)

      Agent.update(dispatch_pid, fn n -> n + 1 end)

      Agent.update(script_pid, fn scripts -> Map.new(scripts, fn {id, _} -> {id, [:pass]} end) end)

      {:ok, %{output: "fixed"}}
    end
  end

  # An integrate action double that records every invocation. It does NOT fix the
  # script — the landed predicate's own script recovers on the next observation,
  # so an integrate invocation is proof of ROUTING, independent of landing side
  # effects.
  defmodule RecordingIntegrate do
    @behaviour Kazi.Action

    @impl true
    def execute(%Action{kind: :integrate}, context) do
      pid =
        Kazi.SerialLandedIntegrateRoutingTest.integrate_name(context.goal.id) |> Process.whereis()

      if pid, do: Agent.update(pid, fn n -> n + 1 end)
      {:ok, %{pr: 1}}
    end
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  def script_name(goal_id), do: :"kazi_1290_script_#{goal_id}"
  def integrate_name(goal_id), do: :"kazi_1290_integrate_#{goal_id}"

  # Start a loop with a scripted code predicate (kind `:tests`) and, when
  # `:with_landed?` is true, a `:landed`-kind predicate — the shape a goal with
  # `[integration] mode` synthesizes.
  defp start_loop(opts) do
    {script, opts} = Keyword.pop!(opts, :script)
    {with_landed?, opts} = Keyword.pop(opts, :with_landed?, true)

    goal_id = "serial-landed-#{System.unique_integer([:positive])}"

    predicates =
      [Predicate.new(:code, :tests)] ++
        if(with_landed?, do: [Predicate.new(:land, :landed)], else: [])

    goal = Goal.new(goal_id, predicates: predicates)

    {:ok, script_pid} = Agent.start_link(fn -> script end, name: script_name(goal_id))
    {:ok, integrate_pid} = Agent.start_link(fn -> 0 end, name: integrate_name(goal_id))
    {:ok, dispatch_pid} = Agent.start_link(fn -> 0 end)

    base = [
      goal: goal,
      providers: %{tests: ScriptedProvider, landed: ScriptedProvider},
      harness: RecordingHarness,
      integrate: RecordingIntegrate,
      deploy: NoopDeploy,
      adapter_opts: [script_pid: script_pid, dispatch_pid: dispatch_pid],
      reobserve_interval_ms: 5,
      flake_max_retries: 0,
      stuck_iterations: 0,
      standing: true
    ]

    {:ok, loop} = Kazi.Loop.start_link(Keyword.merge(base, opts))
    %{loop: loop, integrate_pid: integrate_pid, dispatch_pid: dispatch_pid}
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

  describe "a failing `:landed` predicate routes to Integrate, not agent dispatch (#1290)" do
    test "FIRST land: code green but not landed converges via :integrate, never :dispatch_agent" do
      # code always green; landed fails on the first observation (nothing pushed
      # yet), then recovers once landing has happened.
      %{loop: loop, integrate_pid: integrate_pid, dispatch_pid: dispatch_pid} =
        start_loop(script: %{code: [:pass], land: [:fail, :pass]})

      # The loop reaches a steady (converged) observing state...
      poll_until(loop, fn s -> s.steady? end)
      snap = Kazi.Loop.snapshot(loop)

      # ...via at least one :integrate action (the code-green-but-not-landed
      # transition, decide/2 clause 3) and ZERO agent dispatches (code never
      # failed, and the landed predicate is controller-owned).
      assert Agent.get(integrate_pid, & &1) >= 1
      assert Agent.get(dispatch_pid, & &1) == 0
      assert :integrate in snap.actions
      refute :dispatch_agent in snap.actions

      :ok = Kazi.Loop.stop(loop)
    end

    test "REGRESSION: a landed predicate that fails after a successful integrate re-routes to :integrate" do
      # Converge (both green), hold, then the landed predicate REGRESSES while code
      # stays green — the branch was force-pushed away / commits stripped. The
      # sticky script recovers on the following observation.
      %{loop: loop, integrate_pid: integrate_pid, dispatch_pid: dispatch_pid} =
        start_loop(script: %{code: [:pass], land: [:pass, :pass, :fail, :pass]})

      # 1. Reach steady with the landed predicate green — no integrate needed yet.
      pre = poll_until(loop, fn s -> s.steady? and s.steady_observations >= 1 end)
      integrates_before = Agent.get(integrate_pid, & &1)

      # 2. The scripted regression fires; the loop must re-integrate (clause 3),
      #    NOT re-dispatch the agent (clause 2 must not shadow it).
      poll_until(loop, fn _ -> Agent.get(integrate_pid, & &1) > integrates_before end)

      # 3. It re-converges to steady past the pre-regression count.
      post =
        poll_until(loop, fn s -> s.steady? and s.steady_observations > pre.steady_observations end)

      assert Agent.get(integrate_pid, & &1) > integrates_before,
             "a regressed landed predicate must route to :integrate"

      assert Agent.get(dispatch_pid, & &1) == 0,
             "a regressed landed predicate must NOT route to agent dispatch (code stayed green)"

      assert :integrate in post.actions
      refute :dispatch_agent in post.actions

      :ok = Kazi.Loop.stop(loop)
    end
  end

  describe "the mode=none path (fleet member / --parallel group shape) is unaffected" do
    test "a code regression on a goal WITHOUT a landed predicate still routes to :dispatch_agent" do
      # No `:landed` predicate: reconcile_landed/1 is a no-op, and a genuine code
      # regression must still re-dispatch the agent (the parallel path lands at the
      # scheduler level, outside decide/2 — this pins that my fix did not leak into
      # the everyday code-fix routing).
      %{loop: loop, dispatch_pid: dispatch_pid} =
        start_loop(script: %{code: [:pass, :pass, :fail, :pass]}, with_landed?: false)

      poll_until(loop, fn s -> s.steady? end)
      poll_until(loop, fn _ -> Agent.get(dispatch_pid, & &1) >= 1 end)

      post = poll_until(loop, fn s -> s.steady? and s.steady_observations >= 2 end)

      assert Agent.get(dispatch_pid, & &1) >= 1
      assert :dispatch_agent in post.actions

      :ok = Kazi.Loop.stop(loop)
    end
  end
end
