defmodule Kazi.Pool.GateTest do
  @moduledoc """
  T20.2 (ADR-0026 L1): the pre-merge VERIFICATION GATE decision.

  The load-bearing rule of the L1 gate is "block the merge UNLESS kazi reports
  `converged`". `Kazi.Pool.Gate.decide/1` makes that rule a pure function of the
  decoded `kazi run --json` terminal result (`docs/schemas/run-result.md`), so it
  is asserted here directly rather than only described in prose:

    * a CONVERGED result → `:merge`;
    * a NON-converged result (`stuck` / `over_budget` / `error`) → `{:block,
      reason}` with a clear, copy-pasteable reason the session reports + escalates;
    * the gate FAILS CLOSED — an unexpected `schema_version`, a missing/unknown
      `status`, or a non-object is blocked, never merged.

  The fixtures are decoded from REAL `kazi run --json` JSON text (the exact shape
  `Kazi.CLI` emits — see `test/kazi/cli_run_json_test.exs`), so the gate is
  exercised against the genuine contract, not a hand-built map.
  """
  use ExUnit.Case, async: true

  doctest Kazi.Pool.Gate

  alias Kazi.Pool.Gate

  # A real CONVERGED `kazi apply --json` terminal result (schema_version 2; `kazi
  # run --json` is the deprecated alias emitting the same object), the exact object
  # the CLI emits on a clean converge (both predicates pass, incl. the live probe),
  # decoded as the session would after shelling out.
  @converged_json """
  {
    "schema_version": 2,
    "goal_id": "deploy-target-slice0",
    "status": "converged",
    "predicates": [
      { "id": "go-tests", "verdict": "pass" },
      { "id": "livez-live", "verdict": "pass" }
    ],
    "iterations": 4,
    "budget_spent": { "iterations": 4, "exceeded": null },
    "next_action": "done",
    "reason": null,
    "release_ref": "v2026.06.23-abc1234"
  }
  """

  # A real NON-converged (`stuck`) result: the same failing predicate set
  # persisted across iterations, so kazi stopped without converging.
  @stuck_json """
  {
    "schema_version": 2,
    "goal_id": "deploy-target-slice0",
    "status": "stuck",
    "predicates": [
      { "id": "go-tests", "verdict": "fail" },
      { "id": "livez-live", "verdict": "fail" }
    ],
    "iterations": 6,
    "budget_spent": { "iterations": 6, "exceeded": null },
    "next_action": "investigate",
    "reason": "stuck",
    "release_ref": null
  }
  """

  # A real `over_budget` result: a hard budget ceiling was hit before convergence.
  @over_budget_json """
  {
    "schema_version": 2,
    "goal_id": "deploy-target-slice0",
    "status": "over_budget",
    "predicates": [
      { "id": "go-tests", "verdict": "pass" },
      { "id": "livez-live", "verdict": "fail" }
    ],
    "iterations": 10,
    "budget_spent": { "iterations": 10, "exceeded": "max_iterations" },
    "next_action": "raise_budget",
    "reason": "max_iterations",
    "release_ref": null
  }
  """

  # A real pre-loop `error` envelope (a vacuous goal), the shape the CLI emits
  # when the run could not start.
  @error_json """
  {
    "schema_version": 2,
    "goal_id": "cli-vacuous",
    "status": "error",
    "error": "goal is vacuous — every predicate already passes at t0, so there is nothing to build or repair.",
    "reason": "vacuous_goal",
    "next_action": "investigate"
  }
  """

  describe "decide/1 — converged merges" do
    test "a converged run-result returns :merge" do
      assert :merge = @converged_json |> Jason.decode!() |> Gate.decide()
    end
  end

  describe "decide/1 — non-converged blocks with a clear reason" do
    test "a stuck result blocks and names the escalation" do
      assert {:block, reason} = @stuck_json |> Jason.decode!() |> Gate.decide()
      assert reason =~ "status=stuck"
      assert reason =~ "investigate"
      assert reason =~ "do NOT merge"
    end

    test "an over_budget result blocks and names the budget dimension" do
      assert {:block, reason} = @over_budget_json |> Jason.decode!() |> Gate.decide()
      assert reason =~ "status=over_budget"
      assert reason =~ "raise_budget"
      assert reason =~ "max_iterations"
      assert reason =~ "do NOT merge"
    end

    test "an error result blocks and surfaces the failure message" do
      assert {:block, reason} = @error_json |> Jason.decode!() |> Gate.decide()
      assert reason =~ "status=error"
      assert reason =~ "vacuous"
      assert reason =~ "do NOT merge"
    end
  end

  describe "decide/1 — fails CLOSED on an unexpected result" do
    test "an unexpected schema_version blocks (no stale-field read)" do
      # A version the gate is NOT pinned to (it pins 2): even at status=converged,
      # a mismatched version must block rather than be read with stale assumptions.
      result = @converged_json |> Jason.decode!() |> Map.put("schema_version", 3)
      # Even with status=converged, a wrong version must NOT merge — the
      # `{:block, _}` match (not `:merge`) is itself the proof the gate held.
      assert {:block, reason} = Gate.decide(result)
      assert reason =~ "schema_version"
      assert reason =~ "do NOT merge"
    end

    test "a missing status blocks" do
      result = @converged_json |> Jason.decode!() |> Map.delete("status")
      assert {:block, reason} = Gate.decide(result)
      assert reason =~ "no \"status\""
    end

    test "an unrecognized status string blocks" do
      result = @converged_json |> Jason.decode!() |> Map.put("status", "partially-done")
      assert {:block, reason} = Gate.decide(result)
      assert reason =~ "unrecognized status=partially-done"
    end

    test "a non-object input blocks" do
      assert {:block, reason} = Gate.decide("not a map")
      assert reason =~ "not a JSON object"
    end
  end
end
