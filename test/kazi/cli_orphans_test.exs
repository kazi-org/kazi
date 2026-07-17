defmodule Kazi.CLIOrphansTest do
  @moduledoc """
  T54.5 (issue #1073/#857): `kazi orphans` lists every run whose recorded
  `harness_child_pid` is STILL alive -- a dispatch that outlived its controller
  -- and `--reap` actually kills them. Drives the real `Kazi.CLI.run/2` entry
  point against REAL, independently-controlled OS processes so the liveness and
  kill boundaries are the genuine `kill`/`ps` ones, not mocks.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Harness.ChildSupervisor
  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # A real, independently-alive OS process standing in for an orphaned harness
  # child. `sh -c "sleep N"` execs into sleep, so the returned os_pid IS the
  # sleep -- killing it reaps the process the test seeds.
  defp spawn_orphan(seconds \\ 30) do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        args: ["-c", "sleep #{seconds}"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    pid = to_string(os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", pid], stderr_to_stdout: true) end)
    pid
  end

  defp seed_run(run_id, goal_ref, harness_pid) do
    {:ok, _} =
      RunRegistry.start(%{
        run_id: run_id,
        pid: "#PID<0.1.0>",
        workspace: "/tmp/#{run_id}",
        goal_ref: goal_ref,
        started_at: DateTime.utc_now(),
        heartbeat_at: DateTime.utc_now()
      })

    if harness_pid, do: {:ok, _} = RunRegistry.record_harness_pid(run_id, harness_pid)
    :ok
  end

  defp wait_dead(pid, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    cond do
      not ChildSupervisor.alive?(pid) -> :dead
      System.monotonic_time(:millisecond) > deadline -> :still_alive
      true -> Process.sleep(50) && wait_dead(pid, deadline)
    end
  end

  test "lists ONLY runs whose harness child is still alive" do
    alive_pid = spawn_orphan()
    seed_run("orphan-alive", "goal-a", alive_pid)
    seed_run("orphan-dead", "goal-b", "999999999")
    seed_run("orphan-none", "goal-c", nil)

    out = capture_io(fn -> assert Kazi.CLI.run(["orphans"], []) == 0 end)

    assert out =~ "orphan-alive"
    assert out =~ alive_pid
    refute out =~ "orphan-dead"
    refute out =~ "orphan-none"
  end

  test "reports the clean empty message when nothing is orphaned" do
    seed_run("orphan-dead-only", "goal-d", "999999999")

    out = capture_io(fn -> assert Kazi.CLI.run(["orphans"], []) == 0 end)

    assert out =~ "no orphaned harness processes"
  end

  test "--json carries the versioned orphans envelope" do
    alive_pid = spawn_orphan()
    seed_run("orphan-json", "goal-json", alive_pid)
    seed_run("orphan-json-dead", "goal-json2", "999999999")

    out = capture_io(fn -> assert Kazi.CLI.run(["orphans", "--json"], []) == 0 end)

    decoded = Jason.decode!(String.trim(out))
    assert decoded["kind"] == "orphans"
    assert decoded["reaped"] == false
    assert decoded["count"] == 1
    assert [orphan] = decoded["orphans"]
    assert orphan["run_id"] == "orphan-json"
    assert orphan["harness_child_pid"] == alive_pid
    assert is_integer(decoded["schema_version"])
  end

  test "--reap actually kills the orphaned process" do
    alive_pid = spawn_orphan()
    seed_run("orphan-reap", "goal-reap", alive_pid)

    assert ChildSupervisor.alive?(alive_pid), "the orphan must be alive before reaping"

    out = capture_io(fn -> assert Kazi.CLI.run(["orphans", "--reap"], []) == 0 end)

    assert out =~ "reaped"
    assert out =~ "orphan-reap"
    assert wait_dead(alive_pid) == :dead, "the orphan must be dead after --reap"
  end

  test "--reap --json reports the reap outcome per orphan" do
    alive_pid = spawn_orphan()
    seed_run("orphan-reap-json", "goal-reap-json", alive_pid)

    out = capture_io(fn -> assert Kazi.CLI.run(["orphans", "--reap", "--json"], []) == 0 end)

    decoded = Jason.decode!(String.trim(out))
    assert decoded["reaped"] == true
    assert [orphan] = decoded["orphans"]
    assert orphan["reap_outcome"] == "ok"
    assert wait_dead(alive_pid) == :dead
  end
end
