defmodule Kazi.ReadModel.RunRegistryTest do
  @moduledoc """
  Tier 2 — real SQLite boundary (T46.1, ADR-0057, UC-061). Exercises the fleet
  run registry against a real read-model: a `kazi apply` process inserts a row
  and heartbeats it across ticks, a terminal verdict persists, and the
  staleness query classifies a hung run correctly. Hermetic: per-test Sandbox
  transaction, no network, no real process spawned.
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp run_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: "run-#{System.unique_integer([:positive])}",
        pid: "#PID<0.123.0>",
        workspace: "/tmp/ws",
        goal_ref: "goal-a",
        harness: "claude",
        model: "claude-sonnet-5"
      },
      overrides
    )
  end

  describe "start/1" do
    test "inserts a new run row as running with a fresh heartbeat" do
      attrs = run_attrs()

      assert {:ok, %Run{} = run} = RunRegistry.start(attrs)
      assert run.run_id == attrs.run_id
      assert run.status == "running"
      assert run.finished_at == nil
      assert %DateTime{} = run.heartbeat_at
      assert %DateTime{} = run.started_at
    end

    test "re-starting the same run_id upserts rather than erroring" do
      attrs = run_attrs()
      assert {:ok, first} = RunRegistry.start(attrs)

      assert {:ok, second} = RunRegistry.start(attrs)
      assert second.run_id == first.run_id
      assert RunRegistry.list() |> Enum.count(&(&1.run_id == attrs.run_id)) == 1
    end
  end

  describe "heartbeat/1" do
    test "advances the heartbeat timestamp across ticks" do
      attrs = run_attrs()
      assert {:ok, run} = RunRegistry.start(attrs)

      # Force the initial heartbeat into the past so a subsequent tick is
      # observably later (heartbeats can otherwise land within the same
      # microsecond in a fast test).
      past = DateTime.add(run.heartbeat_at, -5, :second)

      run
      |> Run.changeset(%{"heartbeat_at" => past})
      |> Repo.update!()

      assert {:ok, updated} = RunRegistry.heartbeat(attrs.run_id)
      assert DateTime.compare(updated.heartbeat_at, past) == :gt
    end

    test "heartbeating an unregistered run_id reports :not_found" do
      assert {:error, :not_found} = RunRegistry.heartbeat("does-not-exist")
    end
  end

  describe "finish/2" do
    test "records a terminal status and finished_at" do
      attrs = run_attrs()
      assert {:ok, _} = RunRegistry.start(attrs)

      assert {:ok, finished} = RunRegistry.finish(attrs.run_id, "converged")
      assert finished.status == "converged"
      assert %DateTime{} = finished.finished_at
    end
  end

  describe "finish/3 -- run-end economics (T48.7, ADR-0058 decision 1)" do
    test "persists tokens/USD/dispatch-count and goal shape alongside the terminal status" do
      attrs = run_attrs()
      assert {:ok, _} = RunRegistry.start(attrs)

      economics = %{
        budget_tokens: 4200,
        budget_cached_input_tokens: 1500,
        budget_cost_usd: 0.0837,
        dispatch_count: 3,
        context_tier: 2,
        predicate_count: 5,
        predicate_kind_histogram: %{"custom_script" => 3, "http_probe" => 2}
      }

      assert {:ok, finished} = RunRegistry.finish(attrs.run_id, "converged", economics)

      assert finished.status == "converged"
      assert finished.budget_tokens == 4200
      assert finished.budget_cached_input_tokens == 1500
      assert finished.budget_cost_usd == 0.0837
      assert finished.dispatch_count == 3
      assert finished.context_tier == 2
      assert finished.predicate_count == 5
      assert finished.predicate_kind_histogram == %{"custom_script" => 3, "http_probe" => 2}
      # This economics map omits the T48.4 cause keys entirely (no cause was
      # classified this run) -- stays nil, not a zero-filled placeholder.
      assert finished.outcome_cause_class == nil
      assert finished.outcome_cause_detail == nil
    end

    test "a run whose harness reported no usage persists NULL for tokens and cost, not 0" do
      attrs = run_attrs()
      assert {:ok, _} = RunRegistry.start(attrs)

      # The caller (Kazi.Runtime) omits the token/cost keys entirely when the
      # loop's usage envelope was empty all run -- honest-unknown (ADR-0046),
      # never a zero-filled economics map.
      economics = %{
        dispatch_count: 1,
        context_tier: 1,
        predicate_count: 1,
        predicate_kind_histogram: %{"custom_script" => 1}
      }

      assert {:ok, finished} = RunRegistry.finish(attrs.run_id, "over_budget", economics)

      assert finished.budget_tokens == nil
      assert finished.budget_cached_input_tokens == nil
      assert finished.budget_cost_usd == nil
      assert finished.dispatch_count == 1
    end

    test "defaults to %{} -- byte-identical to the pre-T48.7 two-arg call" do
      attrs = run_attrs()
      assert {:ok, _} = RunRegistry.start(attrs)

      assert {:ok, finished} = RunRegistry.finish(attrs.run_id, "stopped")

      assert finished.status == "stopped"
      assert finished.budget_tokens == nil
      assert finished.dispatch_count == 0
      assert finished.predicate_kind_histogram == %{}
    end

    test "finish/3 on a %Run{} struct dispatches through the run_id clause" do
      attrs = run_attrs()
      assert {:ok, run} = RunRegistry.start(attrs)

      assert {:ok, finished} = RunRegistry.finish(run, "converged", %{dispatch_count: 2})
      assert finished.dispatch_count == 2
    end

    test "a pre-T48.7 row (no economics ever written) reads back NULL/default new columns" do
      # Simulates a row from before this migration: only the columns
      # `RunRegistry.start/1` writes are populated; the new economics columns
      # were never touched by any `finish/3` call.
      attrs = run_attrs()
      assert {:ok, run} = RunRegistry.start(attrs)

      reloaded = Repo.get_by!(Run, run_id: attrs.run_id)

      assert reloaded.budget_tokens == nil
      assert reloaded.budget_cached_input_tokens == nil
      assert reloaded.budget_cost_usd == nil
      assert reloaded.outcome_cause_class == nil
      assert reloaded.outcome_cause_detail == nil
      assert reloaded.context_tier == nil
      assert reloaded.predicate_count == nil
      assert reloaded.predicate_kind_histogram == %{}
      assert reloaded.dispatch_count == 0
      assert run.status == "running"
    end
  end

  describe "finish/3 -- honest terminal cause class (T48.4, ADR-0058 decision 4)" do
    test "persists the cause class + detail alongside the terminal status" do
      attrs = run_attrs()
      assert {:ok, _} = RunRegistry.start(attrs)

      economics = %{
        outcome_cause_class: "error_wedged",
        outcome_cause_detail: %{
          "ids" => ["live_route"],
          "reasons" => %{"live_route" => "missing_url"},
          "exhausted" => nil
        }
      }

      assert {:ok, finished} = RunRegistry.finish(attrs.run_id, "stuck", economics)

      assert finished.status == "stuck"
      assert finished.outcome_cause_class == "error_wedged"

      assert finished.outcome_cause_detail == %{
               "ids" => ["live_route"],
               "reasons" => %{"live_route" => "missing_url"},
               "exhausted" => nil
             }
    end

    test "a budget_exhausted cause persists the exhausted dimension with no reasons" do
      attrs = run_attrs()
      assert {:ok, _} = RunRegistry.start(attrs)

      economics = %{
        outcome_cause_class: "budget_exhausted",
        outcome_cause_detail: %{
          "ids" => ["code"],
          "reasons" => %{},
          "exhausted" => "max_iterations"
        }
      }

      assert {:ok, finished} = RunRegistry.finish(attrs.run_id, "over_budget", economics)

      assert finished.outcome_cause_class == "budget_exhausted"
      assert finished.outcome_cause_detail["exhausted"] == "max_iterations"
    end

    test "a run with no cause classified persists NULL for both columns, not a zero-filled object" do
      attrs = run_attrs()
      assert {:ok, _} = RunRegistry.start(attrs)

      assert {:ok, finished} = RunRegistry.finish(attrs.run_id, "converged", %{dispatch_count: 1})

      assert finished.outcome_cause_class == nil
      assert finished.outcome_cause_detail == nil
    end
  end

  describe "stale?/2 and list_stale/1" do
    test "a running row with an old heartbeat is stale" do
      attrs = run_attrs()
      assert {:ok, run} = RunRegistry.start(attrs)

      stale_heartbeat = DateTime.add(DateTime.utc_now(), -200, :second)

      run
      |> Run.changeset(%{"heartbeat_at" => stale_heartbeat})
      |> Repo.update!()

      reloaded = Repo.get_by!(Run, run_id: attrs.run_id)

      assert RunRegistry.stale?(reloaded, 90)
      assert reloaded.run_id in Enum.map(RunRegistry.list_stale(90), & &1.run_id)
    end

    test "a fresh heartbeat is not stale" do
      assert {:ok, run} = RunRegistry.start(run_attrs())
      refute RunRegistry.stale?(run, 90)
    end

    test "a terminal run is never stale, even with an old heartbeat" do
      attrs = run_attrs()
      assert {:ok, _run} = RunRegistry.start(attrs)
      assert {:ok, finished} = RunRegistry.finish(attrs.run_id, "converged")

      stale_heartbeat = DateTime.add(DateTime.utc_now(), -200, :second)

      finished
      |> Run.changeset(%{"heartbeat_at" => stale_heartbeat})
      |> Repo.update!()

      reloaded = Repo.get_by!(Run, run_id: attrs.run_id)

      refute RunRegistry.stale?(reloaded, 90)
    end
  end

  describe "list/0" do
    test "returns registered runs, most recently started first" do
      older = run_attrs()
      assert {:ok, _} = RunRegistry.start(older)

      newer = run_attrs()

      newer_row =
        %Run{}
        |> Run.changeset(
          Map.merge(newer, %{
            started_at: DateTime.add(DateTime.utc_now(), 10, :second),
            heartbeat_at: DateTime.utc_now()
          })
        )
        |> Repo.insert!()

      [first | _] = RunRegistry.list()
      assert first.run_id == newer_row.run_id
    end
  end

  describe "session identity" do
    test "start/1 records the operator-assigned session_name" do
      attrs = run_attrs() |> Map.put(:session_name, "starmap-pass-3")

      assert {:ok, run} = RunRegistry.start(attrs)
      assert run.session_name == "starmap-pass-3"
    end

    test "record_harness_session/2 sets, keeps idempotent, and supersedes the id" do
      {:ok, run} = RunRegistry.start(run_attrs())

      assert {:ok, updated} = RunRegistry.record_harness_session(run.run_id, "sess-1")
      assert updated.harness_session_id == "sess-1"

      # Idempotent: rewriting the same id is a no-op read.
      assert {:ok, same} = RunRegistry.record_harness_session(run.run_id, "sess-1")
      assert same.harness_session_id == "sess-1"

      # A rotated session records the NEWEST (resumable) id.
      assert {:ok, rotated} = RunRegistry.record_harness_session(run.run_id, "sess-2")
      assert rotated.harness_session_id == "sess-2"
    end

    test "record_harness_session/2 on an unregistered run is :not_found" do
      assert {:error, :not_found} =
               RunRegistry.record_harness_session("never-started", "sess-1")
    end
  end

  describe "harness pid identity (issue #857)" do
    test "record_harness_pid/2 sets, keeps idempotent, and supersedes the pid" do
      {:ok, run} = RunRegistry.start(run_attrs())

      assert {:ok, updated} = RunRegistry.record_harness_pid(run.run_id, "1234")
      assert updated.harness_child_pid == "1234"

      # Idempotent: rewriting the same pid is a no-op read.
      assert {:ok, same} = RunRegistry.record_harness_pid(run.run_id, "1234")
      assert same.harness_child_pid == "1234"

      # A re-dispatched run's newer pid supersedes the prior one.
      assert {:ok, redispatched} = RunRegistry.record_harness_pid(run.run_id, "5678")
      assert redispatched.harness_child_pid == "5678"
    end

    test "record_harness_pid/2 on an unregistered run is :not_found" do
      assert {:error, :not_found} = RunRegistry.record_harness_pid("never-started", "1234")
    end
  end

  describe "list_by_goal_ref/2" do
    test "lists only OTHER runs of the same goal_ref, most recently started first" do
      target_goal = "goal-#{System.unique_integer([:positive])}"

      {:ok, this_run} = RunRegistry.start(run_attrs(%{goal_ref: target_goal}))
      {:ok, other_goal_run} = RunRegistry.start(run_attrs(%{goal_ref: "goal-different"}))

      older = run_attrs(%{goal_ref: target_goal})
      assert {:ok, older_run} = RunRegistry.start(older)

      newer_row =
        %Run{}
        |> Run.changeset(
          Map.merge(run_attrs(%{goal_ref: target_goal}), %{
            started_at: DateTime.add(DateTime.utc_now(), 10, :second),
            heartbeat_at: DateTime.utc_now()
          })
        )
        |> Repo.insert!()

      results = RunRegistry.list_by_goal_ref(target_goal, this_run.run_id)
      result_ids = Enum.map(results, & &1.run_id)

      assert result_ids == [newer_row.run_id, older_run.run_id]
      refute this_run.run_id in result_ids
      refute other_goal_run.run_id in result_ids
    end
  end
end
