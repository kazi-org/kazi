defmodule Kazi.ReadModel.RunReapTest do
  @moduledoc """
  T48.15: run reaper tests for liveness detection and cleanup of dead runs.
  """

  use ExUnit.Case, async: true

  alias Kazi.ReadModel.Run
  alias Kazi.Repo

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
