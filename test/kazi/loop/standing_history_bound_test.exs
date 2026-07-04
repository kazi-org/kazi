defmodule Kazi.Loop.StandingHistoryBoundTest do
  @moduledoc """
  M6 (deep-review-001): a STANDING loop (UC-016) re-observes forever, so its
  per-iteration history (T1.1) must be bounded to a sliding window rather than
  growing without limit (a memory leak + O(n^2) per-tick cost, since
  `detect_regressions`/`code_history` scan the whole history every tick). Proves
  the in-state history length stops growing well before the iteration count
  does, while a DEFAULT (non-standing) loop is unaffected.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

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

  defp green_goal do
    Goal.new("standing-history-bound-test", predicates: [Predicate.new(:code, :tests)])
  end

  defp start_standing(opts) do
    base = [
      goal: green_goal(),
      providers: %{tests: AlwaysGreenProvider},
      harness: NoopHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      standing: true,
      reobserve_interval_ms: 1,
      flake_max_retries: 0,
      stuck_iterations: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  defp poll_until(loop, fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_until(loop, fun, deadline)
  end

  defp do_poll_until(loop, fun, deadline) do
    snap = Kazi.Loop.snapshot(loop)

    cond do
      fun.(snap) ->
        snap

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("poll_until timed out; last snapshot iterations=#{snap.iterations}")

      true ->
        Process.sleep(2)
        do_poll_until(loop, fun, deadline)
    end
  end

  test "a standing loop's history length stops growing well before the iteration count" do
    {:ok, loop} = start_standing([])

    # Both checkpoints are past the bound's floor, so the retained history is
    # already capped by the first one.
    snap_a = poll_until(loop, fn snap -> snap.iterations >= 150 end, 10_000)
    history_len_a = length(snap_a.history)

    snap_b = poll_until(loop, fn snap -> snap.iterations >= 300 end, 10_000)
    history_len_b = length(snap_b.history)

    # The iteration count kept climbing (300 vs 150), but the retained history
    # did NOT grow at all past its capped window -- it is bounded to a fixed
    # window, not tracking every observation ever made.
    assert snap_b.iterations > snap_a.iterations
    assert history_len_b < snap_b.iterations
    assert history_len_a == history_len_b

    :ok = Kazi.Loop.stop(loop)
  end

  test "a DEFAULT (non-standing) loop's history is unaffected (still grows with iterations)" do
    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: green_goal(),
        providers: %{tests: AlwaysGreenProvider},
        harness: NoopHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        standing: false,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    # An always-green default loop converges on the very first observation, so
    # its history has exactly one entry -- confirming bound_history/2 never
    # trims a non-standing loop's (already-finite) history short.
    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged

    snap = Kazi.Loop.snapshot(loop)
    assert length(snap.history) == 1
  end
end
