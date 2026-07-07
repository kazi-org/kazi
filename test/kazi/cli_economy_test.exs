defmodule Kazi.CLIEconomyTest do
  @moduledoc """
  T48.8 (ADR-0058 decision 2 precursor): `kazi economy [--goal <ref>] [--json]`
  (NEW command) — a pure read aggregating the persisted run-end economics
  (T48.7) into p50/p95 history groups via `Kazi.Economy.History`.

  Tier 1 pins the argv boundary. Tier 2 drives the REAL CLI exec core
  (`Kazi.CLI.run/2`) through `ExUnit.CaptureIO` against the test SQLite
  Sandbox read-model, seeding runs through the real `RunRegistry` write path —
  no real harness, git, or network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp seed_run(overrides) do
    run_id = "cli-econ-#{System.unique_integer([:positive])}"

    base = %{
      run_id: run_id,
      pid: "#PID<0.1.0>",
      workspace: "/tmp/ws",
      goal_ref: Map.get(overrides, :goal_ref, "cli-econ-goal"),
      harness: "claude",
      model: "claude-sonnet-5"
    }

    attrs = Map.merge(base, Map.take(overrides, [:goal_ref, :harness, :model]))
    {:ok, _} = RunRegistry.start(attrs)

    economics =
      Map.take(overrides, [
        :budget_tokens,
        :budget_cost_usd,
        :dispatch_count,
        :predicate_count
      ])

    {:ok, finished} = RunRegistry.finish(run_id, "converged", economics)
    finished
  end

  # ===========================================================================
  # Tier 1 — argv boundary
  # ===========================================================================

  describe "parse/1 — economy" do
    test "parses `economy` with no args, defaulting goal/json" do
      assert {:economy, opts} = Kazi.CLI.parse(["economy"])
      assert opts[:goal] == nil
      assert opts[:json] == false
    end

    test "parses `economy --goal <ref> --json`" do
      assert {:economy, opts} = Kazi.CLI.parse(["economy", "--goal", "my-goal", "--json"])
      assert opts[:goal] == "my-goal"
      assert opts[:json] == true
    end

    test "an unexpected positional is a usage error" do
      assert {:error, message} = Kazi.CLI.parse(["economy", "extra"])
      assert message =~ "unexpected argument"
    end
  end

  # ===========================================================================
  # Tier 2 — economy --json (seeded aggregate)
  # ===========================================================================

  describe "economy --json — seeded history" do
    test "returns the aggregate object with correct groups on a seeded db" do
      goal_ref = "cli-econ-seeded"

      seed_run(%{goal_ref: goal_ref, predicate_count: 2, budget_tokens: 1000, dispatch_count: 1})
      seed_run(%{goal_ref: goal_ref, predicate_count: 2, budget_tokens: 2000, dispatch_count: 3})

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["economy", "--goal", goal_ref, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["goal_filter"] == goal_ref
      assert [group] = payload["groups"]
      assert group["goal_shape_bucket"] == "1-3"
      assert group["model"] == "claude-sonnet-5"
      assert group["harness"] == "claude"
      assert group["n"] == 2
      assert group["n_with_usage"] == 2
      assert group["tokens"]["p50"] == 1000
      assert group["tokens"]["p95"] == 2000
    end

    test "an unreported-value group yields nil fields, never 0" do
      goal_ref = "cli-econ-unreported"
      seed_run(%{goal_ref: goal_ref, predicate_count: 1, dispatch_count: 1})

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["economy", "--goal", goal_ref, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert [group] = payload["groups"]
      assert group["n_with_usage"] == 0
      assert group["tokens"]["p50"] == nil
      assert group["tokens"]["p95"] == nil
      assert group["cost_usd"]["p50"] == nil
    end

    test "an honest empty aggregate on a fresh/unseen goal_ref filter" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["economy", "--goal", "never-seen-goal-ref", "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["groups"] == []
    end
  end

  describe "economy (human) — unchanged default surface" do
    test "reports groups in human prose" do
      goal_ref = "cli-econ-human"
      seed_run(%{goal_ref: goal_ref, predicate_count: 3, budget_tokens: 500})

      {code, out} =
        with_io(fn -> Kazi.CLI.run(["economy", "--goal", goal_ref]) end)

      assert code == 0
      assert out =~ "ECONOMY"
      assert out =~ "bucket=1-3"
      refute out =~ "schema_version"
    end

    test "an empty history reports a clear human message, not a crash" do
      {code, out} =
        with_io(fn -> Kazi.CLI.run(["economy", "--goal", "no-history-at-all"]) end)

      assert code == 0
      assert out =~ "no finished-run history yet"
    end
  end
end
