defmodule Kazi.ReadModel.HeartbeatTickerTest do
  @moduledoc """
  Tier 2 — real SQLite boundary. Exercises the heartbeat ticker that maintains
  liveness signals for active runs in the registry. The ticker is responsible
  for updating the heartbeat_at timestamp on periodic intervals to signal that
  a run is still alive.
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

  describe "heartbeat updates" do
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
end
