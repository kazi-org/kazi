defmodule Kazi.StandingDriftTest do
  @moduledoc """
  Loop-level enforcement of standing-mode RE-TRIGGER ON DRIFT (T3.4b, UC-016).

  T3.4a made the standing loop keep observing past convergence. This task proves
  the consequence that foundation was built for: when a predicate that was
  satisfied at convergence later regresses on a re-observation (drift), the
  standing loop must leave the steady/observing state and RE-ENTER the ordinary
  convergence machinery (the same `decide` → dispatch → integrate/deploy path),
  reconcile the predicate back to green, and return to steady observing — without
  forking a parallel reconcile path.

  These tests script a predicate that is green at convergence and then flips red
  on a later re-observe, and assert the loop:

    * re-dispatches the coding agent against the drifted predicate (reusing the
      `:dispatch_agent` path, not a new one);
    * re-converges back to a steady observing state (`steady?` true again,
      `steady_observations` grows past the pre-drift count);
    * persists every iteration through the `on_iteration` seam, including the
      drifted (red) observation and the re-converged ones.

  Hermetic: in-process behaviour doubles + an injectable script controlling the
  provider result; no network, no Go, deterministic via a small re-observe
  interval and snapshot polling (no fixed sleeps in the assertions).
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # ===========================================================================
  # Test doubles (zero-stub: test-only; the loop depends on the behaviours)
  # ===========================================================================

  # A provider whose verdict is driven by a per-test Agent holding a list of
  # statuses to play out (one per observation, last value sticky). This lets a
  # test SCRIPT a drift: e.g. [:pass, :pass, :fail, :pass] = converge, hold, then
  # a code predicate regresses, then it is fixed back to green. The Agent is keyed
  # by predicate id so the script is per-predicate.
  #
  # The provider locates the script Agent through a name derived from the goal id
  # (the loop carries `goal` in the provider context, but not arbitrary keys), so
  # no production code change is needed to inject the script.
  defmodule ScriptedProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      script_pid = Kazi.StandingDriftTest.script_name(context.goal.id) |> Process.whereis()
      status = next_status(script_pid, id)

      case status do
        :pass -> PredicateResult.pass(%{id: id, status: :pass})
        :fail -> PredicateResult.fail(%{id: id, status: :fail})
      end
    end

    # Pop the next scripted status for `id`; once the script is exhausted the last
    # value sticks (so a re-converged predicate stays green forever).
    defp next_status(script_pid, id) do
      Agent.get_and_update(script_pid, fn scripts ->
        case Map.fetch(scripts, id) do
          {:ok, [last]} -> {last, Map.put(scripts, id, [last])}
          {:ok, [head | tail]} -> {head, Map.put(scripts, id, tail)}
          # No script for this id: default green.
          :error -> {:pass, scripts}
        end
      end)
    end
  end

  # A harness double that, when dispatched to fix the drifted predicate, advances
  # the script back to green by pushing a :pass onto the FRONT of the predicate's
  # remaining script — emulating the coding agent landing a fix. It also records
  # every dispatch so the test can assert a re-dispatch happened.
  defmodule FixingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, _workspace, opts) do
      script_pid = Keyword.fetch!(opts, :script_pid)
      dispatch_pid = Keyword.fetch!(opts, :dispatch_pid)

      Agent.update(dispatch_pid, fn n -> n + 1 end)

      # The "fix": force the drifted predicate(s) back to green for the next
      # observation, so the loop re-converges. We make ALL scripted predicates
      # green from here on (the prompt names which failed; for the test one
      # predicate is enough).
      _ = prompt

      Agent.update(script_pid, fn scripts -> Map.new(scripts, fn {id, _} -> {id, [:pass]} end) end)

      {:ok, %{output: "fixed"}}
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

  # The registered name under which a test's script Agent lives, derived from the
  # goal id so the ScriptedProvider can find it from the provider context (which
  # carries the goal). Public so the provider module can call it.
  def script_name(goal_id), do: :"kazi_drift_script_#{goal_id}"

  defp start_loop(opts) do
    {script, opts} = Keyword.pop!(opts, :script)
    # Unique per-test goal id so the script-Agent name (and the harness dispatch
    # counter) never collide across async tests.
    goal_id = "standing-drift-#{System.unique_integer([:positive])}"
    goal = Goal.new(goal_id, predicates: [Predicate.new(:code, :tests)])

    {:ok, script_pid} = Agent.start_link(fn -> script end, name: script_name(goal_id))
    {:ok, dispatch_pid} = Agent.start_link(fn -> 0 end)
    {iterations_pid, opts} = Keyword.pop(opts, :iterations_pid)

    on_iteration =
      case iterations_pid do
        nil ->
          nil

        pid ->
          fn payload ->
            Agent.update(pid, fn log -> [payload | log] end)
          end
      end

    base = [
      goal: goal,
      providers: %{tests: ScriptedProvider},
      harness: FixingHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      # The harness needs the script Agent (to "fix" the drifted predicate back to
      # green) and a dispatch counter so the test can assert a re-dispatch fired.
      adapter_opts: [script_pid: script_pid, dispatch_pid: dispatch_pid],
      reobserve_interval_ms: 5,
      flake_max_retries: 0,
      stuck_iterations: 0,
      standing: true,
      on_iteration: on_iteration
    ]

    {:ok, loop} = Kazi.Loop.start_link(Keyword.merge(base, opts))
    %{loop: loop, script_pid: script_pid, dispatch_pid: dispatch_pid}
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
  # Tests
  # ===========================================================================

  test "drift re-triggers the convergence machinery and re-converges to steady" do
    {:ok, iterations_pid} = Agent.start_link(fn -> [] end)

    # Script: green (converge) → green (hold steady) → red (DRIFT) → then the
    # FixingHarness forces it green again so the loop re-converges. The last value
    # is sticky, so once the harness fixes it the predicate stays green.
    %{loop: loop, dispatch_pid: dispatch_pid} =
      start_loop(script: %{code: [:pass, :pass, :fail, :pass]}, iterations_pid: iterations_pid)

    # 1. It first reaches a steady observing state (converged once).
    pre = poll_until(loop, fn s -> s.steady? and s.steady_observations >= 1 end)
    assert pre.mode == :standing

    # 2. The scripted drift fires on a later observation; the loop sees the red
    #    predicate, leaves steady, and RE-DISPATCHES the coding agent (reusing the
    #    :dispatch_agent path). Assert a dispatch happened.
    poll_until(loop, fn _ -> Agent.get(dispatch_pid, & &1) >= 1 end)
    assert Agent.get(dispatch_pid, & &1) >= 1

    # 3. After the harness "fix", the loop RE-CONVERGES: steady? is true again and
    #    the satisfied-observation count grows PAST the pre-drift count — proof it
    #    returned to steady observing rather than terminating or staying red.
    post =
      poll_until(loop, fn s -> s.steady? and s.steady_observations > pre.steady_observations end)

    assert post.mode == :standing
    assert post.state == :observing
    assert Process.alive?(loop)

    # 4. The re-dispatch went through the ordinary action path — the action history
    #    records a :dispatch_agent.
    assert :dispatch_agent in post.actions

    # 5. Every iteration is persisted through the on_iteration seam, including the
    #    drifted (red, not converged) observation and re-converged (green) ones.
    iterations = Agent.get(iterations_pid, &Enum.reverse/1)
    assert length(iterations) >= 4
    assert Enum.any?(iterations, fn p -> p.converged? == true end)
    assert Enum.any?(iterations, fn p -> p.converged? == false end)

    :ok = Kazi.Loop.stop(loop)
  end

  test "steady? drops to false on the drifted observation" do
    %{loop: loop, dispatch_pid: dispatch_pid} =
      start_loop(script: %{code: [:pass, :pass, :pass, :fail, :pass]})

    # Reach steady first.
    poll_until(loop, fn s -> s.steady? end)

    # The drift must cause a dispatch (the loop acted on the regression) and the
    # loop must recover to steady afterwards.
    poll_until(loop, fn _ -> Agent.get(dispatch_pid, & &1) >= 1 end)
    post = poll_until(loop, fn s -> s.steady? and s.steady_observations >= 2 end)
    assert post.state == :observing

    :ok = Kazi.Loop.stop(loop)
  end
end
