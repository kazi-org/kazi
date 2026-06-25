defmodule Kazi.Loop.ContextEscalationTest do
  @moduledoc """
  Loop-level enforcement of context-tier escalation on non-progress (T36.4,
  ADR-0047 §2/§4, verifies UC-033/UC-043).

  The pure policy is unit-tested in `Kazi.Context.EscalationTest`; here we prove
  the loop WIRES it: a stalled run (the same failing set forever) steps the active
  context tier up the ladder, the thresholds come from config (a non-default
  config changes the behaviour), and the stop rule reverts a tier bump that raised
  cost without progress. Stuck detection is disabled (`stuck_iterations: 0`) so the
  ONLY tier mover is escalation and the loop keeps running long enough to observe
  the climb.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # ===========================================================================
  # Test doubles (zero-stub: test-only; the loop depends on the behaviours)
  # ===========================================================================

  # Always the SAME failing set, never any progress — the only tier mover is
  # escalation (stuck detection is disabled in the loop opts below).
  defmodule NeverProgressingProvider do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{id: id}, _context),
      do: PredicateResult.fail(%{id: id, status: :fail})
  end

  # A zero-cost harness: it reports no token/cost estimate, so the per-iteration
  # cost is flat (0) and the stop rule never fires — the ladder climbs freely.
  defmodule FlatCostHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "ok"}}
  end

  # A harness whose per-dispatch cost RISES every call (via an injected counter),
  # so an escalated rung costs strictly more than the rung below — the net-negative
  # case the stop rule reverts.
  defmodule RisingCostHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, opts) do
      agent = Keyword.fetch!(opts, :cost_agent)
      n = Agent.get_and_update(agent, fn k -> {k + 1, k + 1} end)
      {:ok, %{output: "ok", cost: %{tokens: n * 100}}}
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

  defp start_loop(opts) do
    base = [
      goal: Goal.new("escalation-test", predicates: [Predicate.new(:code, :tests)]),
      providers: %{tests: NeverProgressingProvider},
      harness: FlatCostHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      reobserve_interval_ms: 1,
      flake_max_retries: 0,
      # Disable the stuck stop so escalation is the only tier mover and the loop
      # keeps observing long enough to climb.
      stuck_iterations: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  # Poll the snapshot until `fun` returns true or we run out of attempts; returns
  # the last snapshot. The loop is never-progressing so it runs until stopped.
  defp eventually(loop, fun, attempts \\ 300) do
    snap = Kazi.Loop.snapshot(loop)

    cond do
      fun.(snap) ->
        snap

      attempts <= 0 ->
        snap

      true ->
        # Yield so the never-progressing loop advances another observation or two
        # between polls (it re-observes on the 1 ms interval set in start_loop/1).
        Process.sleep(2)
        eventually(loop, fun, attempts - 1)
    end
  end

  # ===========================================================================
  # Tests
  # ===========================================================================

  test "a stalled run escalates the active context tier up the ladder" do
    {:ok, loop} = start_loop([])

    snap = eventually(loop, &(&1.context_tier >= 2))
    assert snap.context_tier >= 2

    # The escalation reaches the cap (tier 4) on a sustained stall.
    snap = eventually(loop, &(&1.context_tier == 4))
    assert snap.context_tier == 4

    # The change is logged: the first event is an escalation 1 → 2.
    assert [%{kind: :escalate, from: 1, to: 2} | _] = snap.context_tier_escalations

    :ok = Kazi.Loop.stop(loop)
  end

  test "thresholds load from config — enabled: false pins the base tier" do
    {:ok, loop} = start_loop(context_escalation: [enabled: false])

    # Give the loop plenty of iterations; with escalation off the tier never moves.
    assert {:error, :timeout} = Kazi.Loop.await(loop, 150)
    snap = Kazi.Loop.snapshot(loop)
    assert snap.context_tier == 1
    assert snap.context_tier_escalations == []

    :ok = Kazi.Loop.stop(loop)
  end

  test "thresholds load from config — a non-default max_tier caps the climb" do
    {:ok, loop} = start_loop(context_escalation: [max_tier: 2])

    # It climbs to 2 and then stops — the non-default cap changed the behaviour.
    snap = eventually(loop, &(&1.context_tier == 2))
    assert snap.context_tier == 2

    # Stays capped at 2 across many further stalled observations (never reaches 3).
    snap = eventually(loop, fn s -> length(s.context_tier_escalations) >= 1 end)
    assert Enum.all?(snap.context_tier_escalations, &(&1.to <= 2))

    :ok = Kazi.Loop.stop(loop)
  end

  test "the stop rule reverts a net-negative (cost-up, no-progress) escalation" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    {:ok, loop} =
      start_loop(
        harness: RisingCostHarness,
        adapter_opts: [cost_agent: agent]
      )

    # The loop escalates 1 → 2, then the escalated rung costs more without
    # progressing, so the stop rule reverts back to tier 1 and stops climbing.
    snap =
      eventually(loop, fn s ->
        Enum.any?(s.context_tier_escalations, &(&1.kind == :revert))
      end)

    assert Enum.any?(
             snap.context_tier_escalations,
             &match?(%{kind: :escalate, from: 1, to: 2}, &1)
           )

    assert Enum.any?(snap.context_tier_escalations, &match?(%{kind: :revert, from: 2, to: 1}, &1))

    # After the revert the active tier is back at the base and climbing has stopped:
    # no escalation event appears after the revert.
    snap = eventually(loop, fn s -> length(s.context_tier_escalations) >= 2 end)
    assert snap.context_tier == 1

    {revert_idx, _} =
      snap.context_tier_escalations
      |> Enum.with_index()
      |> Enum.find(fn {e, _} -> e.kind == :revert end)
      |> then(fn {e, i} -> {i, e} end)

    after_revert = Enum.drop(snap.context_tier_escalations, revert_idx + 1)
    refute Enum.any?(after_revert, &(&1.kind == :escalate))

    :ok = Kazi.Loop.stop(loop)
    Agent.stop(agent)
  end
end
