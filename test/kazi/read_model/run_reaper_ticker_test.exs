defmodule Kazi.ReadModel.RunReaperTickerTest do
  @moduledoc """
  T48.15: the ticker that actually invokes `RunReaper.reap/0` on a schedule.

  `RunReaper.reap/0` was correct and unit-tested from the start, but nothing
  ever called it in the running application -- every zombie row sat in the
  read-model forever. This test pins that the ticker (a) starts and schedules
  a check, and (b) reaping a dead run's row actually happens once a tick
  fires, using a real GenServer message (not a real multi-minute wait).
  """

  use ExUnit.Case, async: false

  alias Kazi.ReadModel.{Run, RunReaperTicker}
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "a tick reaps a stale run with a dead os_pid" do
    old_heartbeat = DateTime.utc_now(:microsecond) |> DateTime.add(-2, :hour)
    run = insert_run(os_pid: "999998", status: "running", heartbeat_at: old_heartbeat)

    pid = running_ticker!()
    send(pid, :tick)
    # Let the GenServer process the message before we assert on its effect.
    :sys.get_state(pid)

    reloaded = Repo.get_by(Run, run_id: run.run_id)
    assert reloaded.status == "abandoned"
  end

  test "a tick never reaps a run with a live os_pid" do
    own_pid = :os.getpid() |> IO.chardata_to_string()
    old_heartbeat = DateTime.utc_now(:microsecond) |> DateTime.add(-2, :hour)
    run = insert_run(os_pid: own_pid, status: "running", heartbeat_at: old_heartbeat)

    pid = running_ticker!()
    send(pid, :tick)
    :sys.get_state(pid)

    reloaded = Repo.get_by(Run, run_id: run.run_id)
    assert reloaded.status == "running"
  end

  # The application supervision tree already starts one RunReaperTicker under
  # its registered name (T48.15); a test-local start_link would collide
  # ({:already_started, _}). Drive the real running instance instead.
  defp running_ticker! do
    pid = Process.whereis(RunReaperTicker)
    assert is_pid(pid), "expected RunReaperTicker to already be running (application-supervised)"
    pid
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
