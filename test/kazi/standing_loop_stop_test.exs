defmodule Kazi.StandingLoopStopTest do
  @moduledoc """
  Graceful stop + supervision safety for STANDING goals (T3.4c, UC-016).

  T3.4a gave the loop a standing (continuous/maintenance) mode: once its
  predicates pass it enters a steady observing state and keeps re-observing on
  the bounded `:reobserve_interval_ms` instead of terminating. This suite proves
  the operability properties that mode needs in production:

    * a standing loop in steady-observe stops CLEANLY and PROMPTLY on the stop
      signal — it does not have to wait out a full re-observe interval, even when
      that interval is long;
    * the re-observe interval is RESPECTED — the loop does not busy-spin: within a
      real time window a long-interval loop re-observes at most a small bounded
      number of times, while a short-interval loop re-observes many more times,
      so the interval (not a tight CPU loop) governs the cadence;
    * a standing loop is safe under a real OTP supervisor — `Kazi.Loop` exposes a
      `child_spec/1`, a supervisor starts it, a graceful `stop/1` leaves it inert
      WITHOUT the supervisor restarting it, and tearing the supervisor down does
      not leak the loop.

  Hermetic: in-process behaviour doubles only, no network, no Go. Timing
  assertions use a real (short) monotonic deadline and snapshot polling, never a
  fixed sleep that asserts an exact count.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # ===========================================================================
  # Test doubles (zero-stub: test-only; the loop depends on the behaviours)
  # ===========================================================================

  # Always-green so the whole vector is satisfied from the first observation: a
  # standing loop then enters steady-observe and keeps re-observing on the
  # interval, which is exactly the state these properties are about.
  defmodule AlwaysGreenProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, _context),
      do: PredicateResult.pass(%{id: id, status: :pass})
  end

  defmodule NoopHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "ok"}}
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

  defp green_goal do
    Goal.new("standing-stop-test", predicates: [Predicate.new(:code, :tests)])
  end

  # Start a standing loop. `reobserve_interval_ms` is left to each test so it can
  # pick a long interval (to prove prompt stop / no busy-spin) or a short one (to
  # prove the interval drives the cadence).
  defp start_standing(opts) do
    base = [
      goal: green_goal(),
      providers: %{tests: AlwaysGreenProvider},
      harness: NoopHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      standing: true,
      # Always-green vectors: the flake/stuck policies are irrelevant here.
      flake_max_retries: 0,
      stuck_iterations: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  defp poll_until(loop, fun, timeout_ms \\ 1_000) do
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

  # Poll `fun` until it returns a truthy value or the deadline passes; returns
  # that value, or fails on timeout. Unlike `poll_until/3` it does not assume a
  # live, named loop — used to wait out the brief gap while a supervisor restarts
  # a killed child and re-registers its name.
  defp poll_for(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_for(fun, deadline)
  end

  defp do_poll_for(fun, deadline) do
    cond do
      value = fun.() ->
        value

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("poll_for timed out")

      true ->
        Process.sleep(2)
        do_poll_for(fun, deadline)
    end
  end

  # ===========================================================================
  # Graceful + prompt stop
  # ===========================================================================

  test "stop/1 ends a steady standing loop promptly, not after a full interval" do
    # A deliberately LONG interval: if stop had to wait out the interval the loop
    # would still be observing for ~minutes. A prompt stop proves the `:stop`
    # cast is drained before the pending re-observe state timeout fires.
    {:ok, loop} = start_standing(reobserve_interval_ms: 60_000)

    # Settle into steady-observe (predicates satisfied, holding them true).
    poll_until(loop, fn s -> s.steady? end)

    before_ms = System.monotonic_time(:millisecond)
    :ok = Kazi.Loop.stop(loop)
    assert {:ok, result} = Kazi.Loop.await(loop, 1_000)
    elapsed = System.monotonic_time(:millisecond) - before_ms

    assert result.outcome == :stopped
    # Far below the 60s interval — the loop did not wait out the interval.
    assert elapsed < 1_000

    snap = Kazi.Loop.snapshot(loop)
    assert snap.state == :stopped
  end

  test "stop/1 on a standing loop is clean: terminal :stopped, no further actions" do
    {:ok, loop} = start_standing(reobserve_interval_ms: 5)

    # Let it re-observe a few times so we know it is genuinely cycling.
    poll_until(loop, fn s -> s.steady_observations >= 2 end)

    :ok = Kazi.Loop.stop(loop)
    assert {:ok, result} = Kazi.Loop.await(loop, 1_000)
    assert result.outcome == :stopped

    # An always-green standing loop dispatches/integrates/deploys nothing — the
    # clean stop leaves the action history empty (no work was ever needed).
    assert result.actions == []

    # Terminal and still answerable (inert, not crashed): a second stop is a
    # no-op and the snapshot still reports the terminal state.
    assert :ok = Kazi.Loop.stop(loop)
    snap = Kazi.Loop.snapshot(loop)
    assert snap.state == :stopped
    assert Process.alive?(loop)
  end

  # ===========================================================================
  # Bounded interval — no busy-spin
  # ===========================================================================

  test "the re-observe interval bounds the cadence (no busy-spin)" do
    # A long interval over a short observation window must yield very few
    # re-observations: if the loop busy-spun it would tick thousands of times.
    window_ms = 120
    long_interval = 1_000

    {:ok, loop} = start_standing(reobserve_interval_ms: long_interval)
    poll_until(loop, fn s -> s.steady? end)

    base = Kazi.Loop.snapshot(loop).steady_observations
    Process.sleep(window_ms)
    after_long = Kazi.Loop.snapshot(loop).steady_observations

    # With a 1s interval and a 120ms window, at most one extra observation can
    # land. A busy-spin (no interval) would produce far more than this.
    assert after_long - base <= 1

    :ok = Kazi.Loop.stop(loop)

    # Contrast: a short interval over the SAME window re-observes many more
    # times. This proves the interval — not a tight CPU loop — sets the cadence:
    # shrinking it speeds the loop up rather than the loop already running flat
    # out.
    short_interval = 5
    {:ok, fast} = start_standing(reobserve_interval_ms: short_interval)
    poll_until(fast, fn s -> s.steady? end)

    fast_base = Kazi.Loop.snapshot(fast).steady_observations
    Process.sleep(window_ms)
    fast_after = Kazi.Loop.snapshot(fast).steady_observations

    assert fast_after - fast_base > after_long - base
    :ok = Kazi.Loop.stop(fast)
  end

  # ===========================================================================
  # Supervision safety
  # ===========================================================================

  test "a standing loop runs under a Supervisor and a clean stop is not restarted" do
    # Boot the loop as a real supervised child via child_spec/1. Register it under
    # a name so we can find the (single) child instance after stopping it.
    name = {:global, {__MODULE__, :supervised_loop, make_ref()}}

    child =
      Supervisor.child_spec(
        {Kazi.Loop,
         goal: green_goal(),
         providers: %{tests: AlwaysGreenProvider},
         harness: NoopHarness,
         integrate: NoopIntegrate,
         deploy: NoopDeploy,
         standing: true,
         flake_max_retries: 0,
         stuck_iterations: 0,
         reobserve_interval_ms: 5,
         name: name},
        id: :standing_goal
      )

    {:ok, sup} = Supervisor.start_link([child], strategy: :one_for_one)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    # The supervised loop is up and reaches steady-observe.
    poll_until(name, fn s -> s.steady? end)
    pid = GenServer.whereis(name)
    assert is_pid(pid) and Process.alive?(pid)

    # A graceful stop leaves the loop alive in the terminal :stopped state. Under
    # :transient restart that is no exit, so the supervisor must NOT restart it:
    # the same pid stays put and stays :stopped.
    :ok = Kazi.Loop.stop(name)
    assert {:ok, %{outcome: :stopped}} = Kazi.Loop.await(name, 1_000)

    # Give any (erroneous) restart a chance to happen, then confirm none did.
    Process.sleep(30)
    assert GenServer.whereis(name) == pid
    assert Kazi.Loop.snapshot(name).state == :stopped
    assert Supervisor.count_children(sup).active == 1

    # Tearing the supervisor down terminates the child — no leak.
    Supervisor.stop(sup)
    refute Process.alive?(pid)
  end

  test "an abnormally-killed supervised standing loop IS restarted (:transient)" do
    name = {:global, {__MODULE__, :restartable_loop, make_ref()}}

    child =
      Supervisor.child_spec(
        {Kazi.Loop,
         goal: green_goal(),
         providers: %{tests: AlwaysGreenProvider},
         harness: NoopHarness,
         integrate: NoopIntegrate,
         deploy: NoopDeploy,
         standing: true,
         flake_max_retries: 0,
         stuck_iterations: 0,
         reobserve_interval_ms: 5,
         name: name},
        id: :restartable_goal
      )

    {:ok, sup} = Supervisor.start_link([child], strategy: :one_for_one)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    poll_until(name, fn s -> s.steady? end)
    pid = GenServer.whereis(name)

    # Abnormal exit: :transient must restart it. The new instance comes back up
    # under the same registered name with a fresh pid. Poll for a NEW pid (the
    # name is briefly unregistered between the kill and the restart, so tolerate
    # `whereis` returning nil or the old pid during the gap).
    Process.exit(pid, :kill)

    new_pid =
      poll_for(
        fn ->
          case GenServer.whereis(name) do
            p when is_pid(p) and p != pid -> p
            _ -> nil
          end
        end,
        2_000
      )

    assert is_pid(new_pid)
    assert new_pid != pid
    # The restarted instance re-enters steady-observe.
    assert poll_until(name, fn s -> s.steady? end, 2_000).mode == :standing

    Supervisor.stop(sup)
  end
end
