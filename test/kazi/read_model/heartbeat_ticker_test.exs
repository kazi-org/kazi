defmodule Kazi.ReadModel.HeartbeatTickerTest do
  @moduledoc """
  Tier 2 — real SQLite boundary. Exercises the heartbeat ticker that maintains
  liveness signals for active runs in the registry. The ticker is responsible
  for updating the heartbeat_at timestamp on periodic intervals to signal that
  a run is still alive.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kazi.ReadModel.{HeartbeatTicker, Run, RunRegistry}
  alias Kazi.Repo

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

  describe "heartbeat updates" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    end

    test "a run's heartbeat timestamp advances on successive registry operations" do
      attrs = run_attrs()

      {:ok, run1} = RunRegistry.start(attrs)
      first_heartbeat = run1.heartbeat_at

      # Simulate a small delay to ensure timestamp difference
      Process.sleep(10)

      # Update the run (simulating a heartbeat from within the loop)
      {:ok, run2} = RunRegistry.heartbeat(run1.run_id)

      assert run2.heartbeat_at > first_heartbeat
    end

    test "a stale run with no terminal status is detected" do
      attrs = run_attrs()
      {:ok, run} = RunRegistry.start(attrs)

      # Manually update heartbeat_at to simulate staleness
      {:ok, _} =
        run
        |> Run.changeset(%{heartbeat_at: DateTime.add(DateTime.utc_now(), -3600)})
        |> Repo.update()

      # A stale run should be queryable as stale (stale_after 1800 seconds = 30 minutes)
      stale_runs = RunRegistry.list_stale(1800)
      assert Enum.any?(stale_runs, &(&1.run_id == run.run_id))
    end

    test "a completed run is not classified as stale" do
      attrs = run_attrs()
      {:ok, run} = RunRegistry.start(attrs)

      # Manually finish the run
      {:ok, finished_run} =
        run
        |> Run.changeset(%{status: "passed", finished_at: DateTime.utc_now()})
        |> Repo.update()

      # A run with a terminal status is never stale, even with an old heartbeat
      {:ok, _} =
        finished_run
        |> Run.changeset(%{heartbeat_at: DateTime.add(DateTime.utc_now(), -3600)})
        |> Repo.update()

      stale_runs = RunRegistry.list_stale(1800)
      assert not Enum.any?(stale_runs, &(&1.run_id == run.run_id))
    end
  end

  describe "read-model degrade (issue #1511)" do
    # No sandbox checkout here: in manual mode a Repo call without an owned
    # connection raises, which Guard converts to the `{:error,
    # :read_model_unavailable}` degrade tuple -- the exact state that used to
    # crash the ticker's handle_info/2 with a CaseClauseError.

    test "a tick against an unavailable read-model skips the beat and keeps the ticker alive" do
      # Sanity: the read-model really is degraded (no owned connection).
      assert {:error, :read_model_unavailable} = RunRegistry.heartbeat("run-degraded")

      # On pre-fix code this raises CaseClauseError; the fix returns :noreply.
      assert {:noreply, "run-degraded"} =
               HeartbeatTicker.handle_info(:tick, "run-degraded")

      # The ticker re-armed via Process.send_after (30s delay), so no :tick is
      # delivered synchronously -- proving it survived rather than tearing down.
      refute_received :tick
    end

    test "the degrade is logged at most once across many ticks" do
      log =
        capture_log(fn ->
          # Prime the same process dictionary the ticker uses, then drive
          # several ticks; only the first should emit a degrade line.
          Enum.reduce(1..5, "run-degraded", fn _i, run_id ->
            {:noreply, ^run_id} = HeartbeatTicker.handle_info(:tick, run_id)
            run_id
          end)
        end)

      occurrences =
        log
        |> String.split("read-model unavailable for run")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1,
             "expected the degrade to be logged exactly once, got #{occurrences}:\n#{log}"
    end
  end
end
