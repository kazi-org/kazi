defmodule Kazi.Context.EscalationTest do
  @moduledoc """
  The pure context-tier escalation policy (T36.4, ADR-0047 §2/§4).

  The loop-level wiring (a stalled run actually escalating, the config knob
  changing behaviour, the stop rule reverting a net-negative bump) is proven in
  `Kazi.Loop.ContextEscalationTest`; here we pin the pure state machine: the
  threshold-driven climb, the cap, the config overrides, and the cost-based stop
  rule — all without a running loop.
  """
  use ExUnit.Case, async: true

  alias Kazi.Context.Escalation

  doctest Kazi.Context.Escalation

  # A non-progress observation at `cost`; a progressing one.
  defp stall(cost), do: %{progressing?: false, cost: cost}
  defp progress(cost), do: %{progressing?: true, cost: cost}

  defp cfg(overrides \\ []), do: Escalation.config(overrides)

  # Fold a sequence of signals, returning the final state + the ordered decisions.
  defp run(state, config, signals) do
    Enum.reduce(signals, {state, []}, fn signal, {state, decisions} ->
      {state, decision} = Escalation.step(state, config, signal)
      {state, [decision | decisions]}
    end)
    |> then(fn {state, decisions} -> {state, Enum.reverse(decisions)} end)
  end

  describe "config/1" do
    test "resolves the provisional defaults" do
      config = cfg([])
      assert config.enabled
      assert config.threshold == Escalation.default_threshold()
      assert config.threshold == 2
      assert config.min_tier == 0
      assert config.max_tier == 4
      assert config.stop_rule
    end

    test "overrides win and malformed values fall back to the default" do
      config = cfg(threshold: 5, enabled: false, max_tier: 3, stop_rule: false)
      assert config.threshold == 5
      refute config.enabled
      assert config.max_tier == 3
      refute config.stop_rule

      # A non-positive threshold / out-of-range tier is rejected (back to default).
      assert cfg(threshold: 0).threshold == 2
      assert cfg(threshold: -1).threshold == 2
      assert cfg(max_tier: 9).max_tier == 4
    end

    test "is idempotent on a Config and accepts a map" do
      config = cfg(threshold: 3)
      assert Escalation.config(config) == config
      assert Escalation.config(%{threshold: 1}).threshold == 1
    end
  end

  describe "init/2 + tier/1" do
    test "seeds the active tier at the base tier" do
      assert Escalation.init(1, cfg()) |> Escalation.tier() == 1
      assert Escalation.init(3, cfg()) |> Escalation.tier() == 3
      # A malformed base normalizes to the Tier default (1).
      assert Escalation.init(99, cfg()) |> Escalation.tier() == 1
    end

    test "clamps the base into the config tier window" do
      assert Escalation.init(0, cfg(min_tier: 2)) |> Escalation.tier() == 2
    end
  end

  describe "escalate on non-progress (ADR-0047 §2)" do
    test "holds until the threshold of consecutive non-progress observations is reached" do
      state = Escalation.init(1, cfg(threshold: 2))

      {state, [d1]} = run(state, cfg(threshold: 2), [stall(10)])
      assert d1 == :hold
      assert Escalation.tier(state) == 1

      {state, [d2]} = run(state, cfg(threshold: 2), [stall(10)])
      assert d2 == {:escalate, 1, 2}
      assert Escalation.tier(state) == 2
    end

    test "progress resets the streak and holds the (working) tier" do
      config = cfg(threshold: 2)
      state = Escalation.init(1, config)

      {state, _} = run(state, config, [stall(10), progress(10), stall(10)])
      # The progress observation reset the streak, so one more stall is not enough.
      assert Escalation.tier(state) == 1
    end

    test "thresholds load from config — a non-default threshold changes when it escalates" do
      # threshold 1: escalates on the FIRST non-progress observation.
      {state1, [d1]} = run(Escalation.init(1, cfg(threshold: 1)), cfg(threshold: 1), [stall(10)])
      assert d1 == {:escalate, 1, 2}
      assert Escalation.tier(state1) == 2

      # threshold 3: still holding after two non-progress observations.
      {state3, _} =
        run(Escalation.init(1, cfg(threshold: 3)), cfg(threshold: 3), [stall(10), stall(10)])

      assert Escalation.tier(state3) == 1
    end

    test "climbs 1 → 2 → 3 → 4 on sustained flat-cost non-progress and caps at max_tier" do
      config = cfg(threshold: 2)
      state = Escalation.init(1, config)

      # Flat cost ⇒ the stop rule never fires; ten stalls climb to the cap.
      {state, decisions} = run(state, config, List.duplicate(stall(10), 10))

      assert Escalation.tier(state) == 4
      escalations = Enum.filter(decisions, &match?({:escalate, _, _}, &1))
      assert escalations == [{:escalate, 1, 2}, {:escalate, 2, 3}, {:escalate, 3, 4}]
      # No revert on flat cost.
      refute Enum.any?(decisions, &match?({:revert, _, _}, &1))
    end

    test "a non-default max_tier caps the climb earlier" do
      config = cfg(threshold: 2, max_tier: 2)
      state = Escalation.init(1, config)

      {state, decisions} = run(state, config, List.duplicate(stall(10), 10))
      assert Escalation.tier(state) == 2
      assert Enum.filter(decisions, &match?({:escalate, _, _}, &1)) == [{:escalate, 1, 2}]
    end

    test "enabled: false pins the active tier at the base" do
      config = cfg(enabled: false)
      state = Escalation.init(1, config)
      {state, decisions} = run(state, config, List.duplicate(stall(10), 6))
      assert Escalation.tier(state) == 1
      assert Enum.all?(decisions, &(&1 == :hold))
    end
  end

  describe "stop rule (ADR-0047 §4)" do
    test "reverts a net-negative escalation (cost up, no progress) and stops climbing" do
      config = cfg(threshold: 2)
      state = Escalation.init(1, config)

      # Two stalls escalate 1→2 (baseline cost 10); the next stall costs MORE (20)
      # without progressing ⇒ the bump was net-negative ⇒ revert to 1.
      {state, decisions} = run(state, config, [stall(10), stall(10), stall(20)])

      assert {:escalate, 1, 2} in decisions
      assert {:revert, 2, 1} in decisions
      assert Escalation.tier(state) == 1

      # Climbing is stopped for the rest of the run: further sustained non-progress
      # never escalates again, even though cost is now flat.
      {state, more} = run(state, config, List.duplicate(stall(20), 6))
      assert Escalation.tier(state) == 1
      assert Enum.all?(more, &(&1 == :hold))
    end

    test "a cost-neutral escalation is not reverted and the climb continues" do
      config = cfg(threshold: 2)
      state = Escalation.init(1, config)

      # Escalate 1→2 at cost 10; the escalated rung costs the SAME (10) — not net
      # negative — so no revert, and a further streak escalates 2→3.
      {state, decisions} = run(state, config, [stall(10), stall(10), stall(10), stall(10)])

      assert {:escalate, 1, 2} in decisions
      assert {:escalate, 2, 3} in decisions
      refute Enum.any?(decisions, &match?({:revert, _, _}, &1))
      assert Escalation.tier(state) == 3
    end

    test "stop_rule: false keeps climbing even when cost rises after a bump" do
      config = cfg(threshold: 2, stop_rule: false)
      state = Escalation.init(1, config)

      {state, decisions} = run(state, config, [stall(10), stall(10), stall(20), stall(30)])

      refute Enum.any?(decisions, &match?({:revert, _, _}, &1))
      assert {:escalate, 2, 3} in decisions
      assert Escalation.tier(state) == 3
    end

    test "a nil baseline cost never trips the stop rule" do
      # Defensive: even if cost is missing, cost_rose? is false (no revert).
      config = cfg(threshold: 1)
      state = Escalation.init(1, config)
      {state, _} = run(state, config, [%{progressing?: false, cost: nil}])
      assert Escalation.tier(state) == 2
    end
  end
end
