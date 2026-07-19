defmodule Kazi.CLIEconomyTest do
  @moduledoc """
  ADR-0058: `kazi economy [--goal <ref>] [--json]` and `kazi economy
  --rediscovery <goal> [--json]`.

  T48.8 (decision 2 precursor): the default (no `--rediscovery`) view is a
  pure read aggregating the persisted run-end economics (T48.7) into p50/p95
  history groups via `Kazi.Economy.History`.

  T48.10 (decision 3): `--rediscovery` folds a goal's RECORDED per-iteration
  `tools` counters (T34.3) into a ranked, report-only rediscovery-pressure
  candidate list — a pure read over the read-model, no goal loaded, no
  harness touched, and (the hard boundary this task pins) nothing here
  reaches a dispatch prompt.

  Tier 1 pins the argv boundary. Tier 2 drives the REAL CLI exec core
  (`Kazi.CLI.run/2`) through `ExUnit.CaptureIO` against the test SQLite
  Sandbox read-model, seeding runs/iterations through the real write paths —
  no real harness, git, or network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{PredicateResult, PredicateVector, ReadModel, Repo}
  alias Kazi.ReadModel.RunRegistry

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
    test "parses `economy` with no args, defaulting goal/json (aggregate view)" do
      assert {:economy, opts} = Kazi.CLI.parse(["economy"])
      assert opts[:goal] == nil
      assert opts[:rediscovery] == nil
      assert opts[:json] == false
    end

    test "parses `economy --goal <ref> --json`" do
      assert {:economy, opts} = Kazi.CLI.parse(["economy", "--goal", "my-goal", "--json"])
      assert opts[:goal] == "my-goal"
      assert opts[:json] == true
    end

    test "parses `economy --rediscovery <goal>` with and without --json" do
      assert {:economy, opts} = Kazi.CLI.parse(["economy", "--rediscovery", "cli-e2e"])
      assert opts[:rediscovery] == "cli-e2e"
      assert opts[:json] == false

      assert {:economy, json_opts} =
               Kazi.CLI.parse(["economy", "--rediscovery", "cli-e2e", "--json"])

      assert json_opts[:json] == true
    end

    test "an extra positional is an error" do
      assert {:error, message} = Kazi.CLI.parse(["economy", "extra"])
      assert message =~ "unexpected argument"
    end
  end

  # ===========================================================================
  # Tier 2 — economy --json (seeded aggregate, T48.8)
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

  describe "economy --json — dispatch_by_role (T49.9)" do
    test "reports the per-role split on a seeded db" do
      goal_ref = "cli-econ-roles"
      base = DateTime.utc_now()

      run = seed_run(%{goal_ref: goal_ref, predicate_count: 2, dispatch_count: 2})

      run
      |> Kazi.ReadModel.Run.changeset(%{
        "started_at" => DateTime.add(base, -60, :second),
        "finished_at" => base
      })
      |> Kazi.Repo.update!()

      # One dispatch per role, inside the run's window (iterations carry no run id;
      # they correlate by goal_ref + the run's [started_at, finished_at]).
      for {index, kind} <- [{0, :dispatch_agent}, {1, :dispatch_demonstrator}] do
        {:ok, _} =
          Kazi.ReadModel.record_iteration(%{
            goal_ref: goal_ref,
            iteration_index: index,
            action: %Kazi.Action{kind: kind, params: %{}},
            observed_at: DateTime.add(base, -30, :second)
          })
      end

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["economy", "--goal", goal_ref, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert [group] = payload["groups"]

      # The total is unchanged and still both-roles; the split names who spent it.
      assert group["dispatch_count"]["p50"] == 2
      assert group["dispatch_by_role"]["dispatch_agent"]["p50"] == 1
      assert group["dispatch_by_role"]["dispatch_demonstrator"]["p50"] == 1
    end

    test "a run with no demonstrator reports an honest 0 for it" do
      goal_ref = "cli-econ-fixer-only"
      seed_run(%{goal_ref: goal_ref, predicate_count: 2, dispatch_count: 0})

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["economy", "--goal", goal_ref, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert [group] = payload["groups"]
      assert group["dispatch_by_role"]["dispatch_agent"]["p50"] == 0
      assert group["dispatch_by_role"]["dispatch_demonstrator"]["p50"] == 0
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

  # ===========================================================================
  # Tier 2 — economy --rediscovery reports the folded signal (T48.10)
  # ===========================================================================

  describe "economy --rediscovery --json — a goal with recurring tool calls" do
    test "returns a ranked candidate list" do
      goal_ref = "econ-cli-recurring"
      failing = PredicateVector.new(%{code: PredicateResult.fail()})

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: goal_ref,
          iteration_index: 0,
          predicate_vector: failing,
          converged: false,
          tools: %{tool_calls: 12, file_reads: 8, search_calls: 3, graph_calls: 1}
        })

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: goal_ref,
          iteration_index: 1,
          predicate_vector: failing,
          converged: false,
          tools: %{tool_calls: 5, file_reads: 0, search_calls: 4, graph_calls: 0}
        })

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: goal_ref,
          iteration_index: 2,
          predicate_vector: failing,
          converged: false,
          tools: %{tool_calls: 4, file_reads: 0, search_calls: 3, graph_calls: 0}
        })

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["economy", "--rediscovery", goal_ref, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["goal_ref"] == goal_ref
      assert payload["status"] == "ranked"
      assert [top | _] = payload["candidates"]
      assert top["category"] == "search_calls"
      assert top["recurring_calls"] == 7
    end
  end

  describe "economy --rediscovery --json — a goal with no tool-use stream" do
    test "reports unknown, never a fabricated empty ranking" do
      goal_ref = "econ-cli-no-tools"
      vector = PredicateVector.new(%{code: PredicateResult.pass()})

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: goal_ref,
          iteration_index: 0,
          predicate_vector: vector,
          converged: true
        })

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["economy", "--rediscovery", goal_ref, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "unknown"
      assert payload["reason"] =~ "no tool-use stream recorded"
      refute Map.has_key?(payload, "candidates")
    end

    test "an unregistered goal ref reports unknown (zero recorded iterations)" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["economy", "--rediscovery", "goal-that-never-ran", "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "unknown"
      assert payload["reason"] =~ "no iterations recorded"
    end
  end

  describe "economy --rediscovery (human) — unchanged default surface" do
    test "reports the ranked candidates in human prose" do
      goal_ref = "econ-cli-human"
      failing = PredicateVector.new(%{code: PredicateResult.fail()})

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: goal_ref,
          iteration_index: 0,
          predicate_vector: failing,
          converged: false,
          tools: %{tool_calls: 10, file_reads: 8, search_calls: 2, graph_calls: 0}
        })

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: goal_ref,
          iteration_index: 1,
          predicate_vector: failing,
          converged: false,
          tools: %{tool_calls: 6, file_reads: 5, search_calls: 0, graph_calls: 0}
        })

      {code, out} =
        with_io(fn -> Kazi.CLI.run(["economy", "--rediscovery", goal_ref]) end)

      assert code == 0
      assert out =~ "REDISCOVERY"
      assert out =~ "status=ranked"
      assert out =~ "file_reads"
      assert out =~ "report-only"
      refute out =~ "schema_version"
    end

    test "an unknown goal prints the honest-unknown reason, still exit 0" do
      {code, out} =
        with_io(fn -> Kazi.CLI.run(["economy", "--rediscovery", "nope-human"]) end)

      assert code == 0
      assert out =~ "status=unknown"
      assert out =~ "no iterations recorded"
    end
  end
end
