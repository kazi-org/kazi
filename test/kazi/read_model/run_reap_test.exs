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

    test "reaper transitions a stale run with NO os_pid to abandoned (T60.2 #1155)" do
      # The primary ghost-row cause: a `running` row that crashed before it ever
      # recorded an os_pid (or predates the field). Liveness is unverifiable, so
      # once the row is stale it must be finalized rather than sit forever. The
      # original T48.15 reaper filtered these rows out entirely.
      old_heartbeat = DateTime.utc_now(:microsecond) |> DateTime.add(-2, :hour)
      run = insert_run(os_pid: nil, status: "running", heartbeat_at: old_heartbeat)

      {:ok, reaped} = RunReaper.reap()

      assert Enum.any?(reaped, fn r -> r.run_id == run.run_id and r.status == "abandoned" end)
      assert Repo.get_by(Run, run_id: run.run_id).status == "abandoned"
    end

    test "time backstop reaps a stale run whose os_pid reads alive (recycled pid)" do
      # A recycled os_pid probes as alive even though the original run is long
      # dead — no liveness check can catch this. The time backstop abandons any
      # stale `running` row past `abandon_after_seconds` regardless of the probe.
      # Use this live process's own pid + a small bound to force the path.
      own_pid = :os.getpid() |> IO.chardata_to_string()
      old_heartbeat = DateTime.utc_now(:microsecond) |> DateTime.add(-2, :hour)
      run = insert_run(os_pid: own_pid, status: "running", heartbeat_at: old_heartbeat)

      {:ok, reaped} = RunReaper.reap(abandon_after_seconds: 60)

      assert Enum.any?(reaped, fn r -> r.run_id == run.run_id and r.status == "abandoned" end)
    end

    test "a fresh-heartbeat running row is never reaped" do
      # Regression pin: a legitimately-running row (fresh heartbeat) must never
      # be touched, whether or not it has recorded an os_pid.
      run_no_pid = insert_run(os_pid: nil, status: "running")
      run_with_pid = insert_run(os_pid: "999997", status: "running")

      {:ok, reaped} = RunReaper.reap(abandon_after_seconds: 60)

      refute Enum.any?(reaped, fn r -> r.run_id == run_no_pid.run_id end)
      refute Enum.any?(reaped, fn r -> r.run_id == run_with_pid.run_id end)
      assert Repo.get_by(Run, run_id: run_no_pid.run_id).status == "running"
    end

    test "after one reap, no `running` row remains older than the bound (#1155)" do
      # Mirrors the operator fixture-db check: a mix of ghost shapes plus one
      # legitimately-live run. After a single reap sweep, every stale `running`
      # ghost is finalized and only the fresh live row stays `running`.
      import Ecto.Query

      stale = DateTime.utc_now(:microsecond) |> DateTime.add(-9, :day)

      _ghost_no_pid = insert_run(os_pid: nil, status: "running", heartbeat_at: stale)
      _ghost_dead_pid = insert_run(os_pid: "999996", status: "running", heartbeat_at: stale)
      own_pid = :os.getpid() |> IO.chardata_to_string()
      _ghost_recycled = insert_run(os_pid: own_pid, status: "running", heartbeat_at: stale)
      live = insert_run(os_pid: own_pid, status: "running")

      {:ok, _reaped} = RunReaper.reap(abandon_after_seconds: 60)

      # No `running` row older than the stale bound survives.
      bound = DateTime.utc_now(:microsecond) |> DateTime.add(-90, :second)

      stragglers =
        Repo.all(from(r in Run, where: r.status == "running" and r.heartbeat_at < ^bound))

      assert stragglers == []
      assert Repo.get_by(Run, run_id: live.run_id).status == "running"
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
