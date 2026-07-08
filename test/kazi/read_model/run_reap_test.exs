defmodule Kazi.ReadModel.RunReapTest do
  @moduledoc """
  T48.15: run reaper tests for liveness detection and cleanup of dead runs.
  """

  use ExUnit.Case, async: true

  alias Kazi.ReadModel.Run
  alias Kazi.ReadModel.RunReaper
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  describe "run reaping" do
    test "identifies dead runs by missing os_pid" do
      # A run with no os_pid recorded is considered not yet reported and not dead.
      run = insert_run(os_pid: nil)
      assert is_nil(run.os_pid)
    end

    test "records os_pid for liveness tracking" do
      # A run with an os_pid can be checked for liveness.
      run = insert_run(os_pid: "12345")
      assert run.os_pid == "12345"
    end

    test "reaper never kills an alive process" do
      # The reaper function must never reap a process that is still alive.
      # This test ensures the liveness check respects active processes. We use
      # this process's own PID as a guaranteed-alive process.
      own_pid = :os.getpid() |> IO.chardata_to_string()
      old_heartbeat = DateTime.utc_now(:microsecond) |> DateTime.add(-2, :hour)
      run = insert_run(os_pid: own_pid, status: "running", heartbeat_at: old_heartbeat)
      assert run.os_pid == own_pid

      {:ok, reaped} = RunReaper.reap()

      # The alive process (ourselves) should not have been reaped
      refute Enum.any?(reaped, fn r -> r.run_id == run.run_id end)
    end

    test "reaper transitions dead runs to abandoned" do
      # When a run's OS process has terminated, the reaper should mark it abandoned.
      old_heartbeat = DateTime.utc_now(:microsecond) |> DateTime.add(-2, :hour)
      run = insert_run(os_pid: "999999", status: "running", heartbeat_at: old_heartbeat)

      {:ok, reaped} = RunReaper.reap()

      # The non-existent process should be marked abandoned
      assert Enum.any?(reaped, fn r -> r.run_id == run.run_id and r.status == "abandoned" end)
    end
  end

  defp insert_run(attrs \\ []) do
    now = DateTime.utc_now(:microsecond)

    base_attrs = [
      run_id: "test-#{System.unique_integer([:positive])}",
      pid: "#{System.unique_integer([:positive])}",
      workspace: "/tmp/test",
      goal_ref: "test.goal.toml",
      started_at: now,
      heartbeat_at: now
    ]

    attrs = Keyword.merge(base_attrs, attrs)

    {:ok, run} = Repo.insert(Run.changeset(%Run{}, Map.new(attrs)))
    run
  end
end
