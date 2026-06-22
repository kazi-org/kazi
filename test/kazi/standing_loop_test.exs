defmodule Kazi.StandingLoopTest do
  @moduledoc """
  Loop-level enforcement of standing (continuous/maintenance) mode (T3.4a,
  UC-016).

  A DEFAULT loop converges-and-stops: the first satisfied observation terminates
  it at `:converged` (the T0.8 guard). A STANDING loop (`standing: true`) is a
  maintenance reconciler: a satisfied observation does NOT terminate it — it
  records the converged observation, enters a steady observing state, and keeps
  re-observing on the bounded `:reobserve_interval_ms` to hold the predicates
  true forever.

  These tests prove the foundation T3.4b (drift re-trigger) and T3.4c (graceful
  stop) build on:

    * a standing loop, once its predicates pass, reaches `steady? == true`,
      stays ALIVE (never reaches a terminal state), and RE-OBSERVES past
      convergence (`steady_observations` keeps growing);
    * the default loop is UNCHANGED — it still terminates at `:converged` on the
      first satisfied observation;
    * a standing loop is still interruptible: `stop/1` ends it as `:stopped`.

  Hermetic: in-process behaviour doubles only, no network, no Go, deterministic
  via a small injectable re-observe interval and snapshot polling (no fixed
  sleeps in the assertions).
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # ===========================================================================
  # Test doubles (zero-stub: test-only; the loop depends on the behaviours)
  # ===========================================================================

  # A provider whose predicate is ALWAYS :pass — the whole vector is satisfied
  # from the first observation. A standing loop must then enter steady-observe
  # and keep re-observing; a default loop must converge-and-stop immediately.
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

  # A goal whose single predicate is a plain code-kind (not deploy-gated), so the
  # AlwaysGreenProvider satisfies the whole vector on the very first observation.
  defp green_goal do
    Goal.new("standing-test", predicates: [Predicate.new(:code, :tests)])
  end

  defp start_loop(opts) do
    base = [
      goal: green_goal(),
      providers: %{tests: AlwaysGreenProvider},
      harness: NoopHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      # Fast, bounded re-observe interval so the standing loop ticks quickly in
      # the test without a fixed sleep; still a real state timeout (no busy-spin).
      reobserve_interval_ms: 5,
      # These tests express satisfaction directly (always green), so disable the
      # flake re-run and stuck policies that the lifecycle/stuck suites exercise.
      flake_max_retries: 0,
      stuck_iterations: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  # Poll snapshot/1 until `fun.(snapshot)` is truthy or the deadline passes.
  # Returns the satisfying snapshot, or fails the test on timeout. Uses a real
  # (short) monotonic deadline — no fixed sleep, no network.
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

  # ===========================================================================
  # Tests
  # ===========================================================================

  test "standing loop reaches a steady observing state and does NOT terminate" do
    {:ok, loop} = start_loop(standing: true)

    # It never converges-and-stops: await must time out because the loop stays
    # alive holding the predicates true.
    assert {:error, :timeout} = Kazi.Loop.await(loop, 150)

    # The process is still alive and in the (non-terminal) :observing state.
    assert Process.alive?(loop)
    snap = Kazi.Loop.snapshot(loop)
    assert snap.state == :observing
    assert snap.mode == :standing
    assert snap.state not in [:converged, :stopped, :over_budget]

    # It reached a steady observing state (its latest observation satisfied the
    # whole vector) and recorded at least one converged observation.
    assert snap.steady? == true
    assert snap.steady_observations >= 1
  end

  test "standing loop RE-OBSERVES past convergence on the bounded interval" do
    {:ok, loop} = start_loop(standing: true)

    # Wait until it has made at least two satisfied observations — proof it did
    # not stop at the first convergence but kept re-observing on the interval.
    snap = poll_until(loop, fn s -> s.steady_observations >= 2 end)

    assert snap.mode == :standing
    assert snap.steady? == true
    assert snap.steady_observations >= 2
    # Still alive and observing — never reached a terminal state.
    assert snap.state == :observing
    assert Process.alive?(loop)
  end

  test "a standing loop is still interruptible: stop/1 ends it as :stopped" do
    {:ok, loop} = start_loop(standing: true)

    # Let it settle into the steady observing state first.
    poll_until(loop, fn s -> s.steady? end)

    :ok = Kazi.Loop.stop(loop)
    assert {:ok, result} = Kazi.Loop.await(loop, 1_000)
    assert result.outcome == :stopped

    snap = Kazi.Loop.snapshot(loop)
    assert snap.state == :stopped
  end

  test "DEFAULT loop is unchanged: it converges-and-stops on the first satisfied observation" do
    {:ok, loop} = start_loop([])

    assert {:ok, result} = Kazi.Loop.await(loop, 1_000)
    assert result.outcome == :converged
    # Converged on the first observation; no remediation actions were needed.
    assert result.iterations == 1

    snap = Kazi.Loop.snapshot(loop)
    assert snap.state == :converged
    # The default loop reports converge mode and never enters a steady state.
    assert snap.mode == :converge
    assert snap.steady? == false
    assert snap.steady_observations == 0
  end

  test "explicit standing: false matches the default converge-and-stop contract" do
    {:ok, loop} = start_loop(standing: false)

    assert {:ok, result} = Kazi.Loop.await(loop, 1_000)
    assert result.outcome == :converged

    snap = Kazi.Loop.snapshot(loop)
    assert snap.mode == :converge
    assert snap.steady? == false
  end
end
