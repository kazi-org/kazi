defmodule Kazi.StuckLoopTest do
  @moduledoc """
  Loop-level enforcement of the stuck detector + human-escalation hook (T1.5,
  UC-009).

  The pure detection rule is unit-tested in `Kazi.Loop.StuckDetectorTest`; here
  we prove the loop ENFORCES it — with a never-progressing predicate (always the
  same failing set) so the only terminator is the stuck detector. The
  human-escalation hook fires exactly once with the stuck context, and the loop
  stops as `:stopped` with reason `:stuck`, visible in `Kazi.Loop.snapshot/1` and
  the terminal result.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # ===========================================================================
  # Test doubles (zero-stub: test-only; the loop depends on the behaviours)
  # ===========================================================================

  # A provider whose predicate is ALWAYS :fail, so the failing set never changes
  # and the loop makes no progress — the only terminator is the stuck detector.
  defmodule NeverProgressingProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, _context),
      do: PredicateResult.fail(%{id: id, status: :fail})
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

  defp never_progressing_goal do
    Goal.new("stuck-test", predicates: [Predicate.new(:code, :tests)])
  end

  defp start_loop(opts) do
    base = [
      goal: never_progressing_goal(),
      providers: %{tests: NeverProgressingProvider},
      harness: NoopHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      # Poll fast so the stuck window fills quickly rather than waiting on the
      # prod default re-observe interval.
      reobserve_interval_ms: 1,
      # Disable flake re-runs so each observation is a single evaluation (keeps
      # the iteration accounting simple); the predicate is genuinely always :fail.
      flake_max_retries: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  # ===========================================================================
  # Tests
  # ===========================================================================

  test "the same failing set across N iterations stops the loop with reason :stuck" do
    test_pid = self()

    {:ok, loop} =
      start_loop(
        stuck_iterations: 3,
        on_escalation: fn ctx -> send(test_pid, {:escalation, ctx}) end
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :stopped
    assert result.reason == :stuck

    # Stuck after exactly the window fills: observations 0,1,2 carry the same
    # failing set, so the verdict fires on iteration index 2 (3 iterations ran).
    assert result.iterations == 3

    snap = Kazi.Loop.snapshot(loop)
    assert snap.state == :stopped
    # `Predicate.new(:code, :tests)` → id `:code`, kind `:tests`; the failing set
    # is keyed by predicate id.
    assert snap.stuck_failing == [:code]
  end

  test "the human-escalation hook fires exactly once with the stuck context" do
    test_pid = self()

    {:ok, loop} =
      start_loop(
        stuck_iterations: 3,
        on_escalation: fn ctx -> send(test_pid, {:escalation, ctx}) end
      )

    assert {:ok, _result} = Kazi.Loop.await(loop, 5_000)

    # Fired with the persistent failing set, goal, and the iteration index.
    assert_receive {:escalation, ctx}, 1_000
    assert ctx.failing == MapSet.new([:code])
    assert ctx.goal.id == "stuck-test"
    assert ctx.iterations == 2

    # Exactly once: no second escalation after the terminal stop.
    refute_receive {:escalation, _}, 100
  end

  test "stuck is a HARD stop: no further work is dispatched and the result is cached" do
    {:ok, loop} = start_loop(stuck_iterations: 2, on_escalation: fn _ -> :ok end)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :stopped
    assert result.reason == :stuck
    assert result.iterations == 2

    # Genuinely terminal: a later await returns the SAME cached result.
    assert {:ok, ^result} = Kazi.Loop.await(loop, 1_000)
    assert Kazi.Loop.snapshot(loop).state == :stopped
  end

  test "stuck_iterations: 0 disables detection — the loop is not stopped by stuck" do
    {:ok, loop} = start_loop(stuck_iterations: 0, on_escalation: fn _ -> :ok end)

    # The predicate always fails and stuck detection is off, so the loop keeps
    # running: await times out and it is still going (not stopped-stuck).
    assert {:error, :timeout} = Kazi.Loop.await(loop, 150)
    snap = Kazi.Loop.snapshot(loop)
    refute snap.state == :stopped
    assert snap.stuck_failing == nil

    :ok = Kazi.Loop.stop(loop)
  end

  test "the stuck stop is projected through the on_iteration persistence seam with :stuck reason" do
    test_pid = self()

    {:ok, loop} =
      start_loop(
        stuck_iterations: 2,
        on_escalation: fn _ -> :ok end,
        on_iteration: fn payload -> send(test_pid, {:iteration, payload}) end
      )

    assert {:ok, _result} = Kazi.Loop.await(loop, 5_000)

    # The terminal stuck stop is recorded through the same seam the read-model
    # consumes, carrying :stop_reason :stuck.
    assert_receive {:iteration, %{stop_reason: :stuck} = stop_payload}, 1_000
    assert stop_payload.converged? == false
    refute is_nil(stop_payload.vector)
  end
end
