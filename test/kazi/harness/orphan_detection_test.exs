defmodule Kazi.Harness.OrphanDetectionTest do
  @moduledoc """
  Tier 2 — the end-to-end proof for issue #857's second ask: on startup, warn
  if a PRIOR run of the same `goal_ref` recorded a harness subprocess pid that
  is still alive (a probable orphan — its controller likely crashed without
  reaping it, #856). Drives a real `kazi apply` through `Kazi.CLI.run/2` (the
  same entry point every real user hits), seeding a prior `runs` row first —
  against a REAL, independently-controlled OS process standing in for the
  orphaned harness child, so the liveness check exercises the genuine
  `kill -0` boundary, not a mock of it.
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Repo

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "a fresh apply warns (stderr + its own events sink) when a prior run's harness pid is still alive",
       %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    sinks_dir = Path.join(tmp_dir, "sinks")
    goal_ref = "orphan-detection-fixture-alive"

    goal_file = write_goal_file(tmp_dir, work, goal_ref)
    harness_stub = write_harness_stub(tmp_dir)

    # A real, independently-alive OS process standing in for a prior run's
    # orphaned harness child — its controller crashed without reaping it.
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        args: ["-c", "sleep 30"]
      ])

    {:os_pid, orphan_pid} = Port.info(port, :os_pid)
    # `on_exit/1` runs in a separate process from the port's owner, so it
    # closes the underlying OS process directly rather than via `Port.close/1`
    # (which requires being called by the owning process).
    on_exit(fn -> System.cmd("kill", ["-9", to_string(orphan_pid)], stderr_to_stdout: true) end)

    prior_attrs = %{
      run_id: "prior-run-alive",
      pid: "#PID<0.1.0>",
      workspace: work,
      goal_ref: goal_ref,
      started_at: DateTime.utc_now(),
      heartbeat_at: DateTime.utc_now()
    }

    assert {:ok, _} = RunRegistry.start(prior_attrs)
    assert {:ok, _} = RunRegistry.record_harness_pid("prior-run-alive", to_string(orphan_pid))
    # A crashed controller stops heartbeating: backdate the prior row so it
    # models the REAL orphan shape (stale heartbeat, live harness child). The
    # duplicate-run guard correctly refuses a FRESH-heartbeat prior run before
    # the orphan check would even fire -- that refusal has its own test
    # (runtime_duplicate_run_test.exs); this one needs the stale shape.
    backdate_heartbeat("prior-run-alive")

    stderr =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", work],
            adapter_opts: [command: harness_stub],
            sinks_dir: sinks_dir,
            reobserve_interval_ms: 5,
            await_timeout: 15_000
          )
        end)
      end)

    assert stderr =~ "orphan"
    assert stderr =~ "prior-run-alive"
    assert stderr =~ to_string(orphan_pid)

    fresh_run = Repo.get_by!(Run, goal_ref: goal_ref, status: "converged")
    assert fresh_run.events_sink_path
    assert File.exists?(fresh_run.events_sink_path)

    events =
      fresh_run.events_sink_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(events, fn event ->
             event["type"] == "orphan_warning" and
               event["prior_run_id"] == "prior-run-alive" and
               event["harness_pid"] == to_string(orphan_pid)
           end)
  end

  test "a fresh apply does NOT warn when a prior run's recorded harness pid is dead",
       %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    sinks_dir = Path.join(tmp_dir, "sinks")
    goal_ref = "orphan-detection-fixture-dead"

    goal_file = write_goal_file(tmp_dir, work, goal_ref)
    harness_stub = write_harness_stub(tmp_dir)

    # Well beyond any real pid on this machine — never alive.
    dead_pid = "999999999"

    prior_attrs = %{
      run_id: "prior-run-dead",
      pid: "#PID<0.1.0>",
      workspace: work,
      goal_ref: goal_ref,
      started_at: DateTime.utc_now(),
      heartbeat_at: DateTime.utc_now()
    }

    assert {:ok, _} = RunRegistry.start(prior_attrs)
    assert {:ok, _} = RunRegistry.record_harness_pid("prior-run-dead", dead_pid)
    # Same stale-heartbeat shape as the alive-orphan test above: a crashed
    # controller stops heartbeating, and a fresh heartbeat would (correctly)
    # trip the duplicate-run guard before this test's subject even runs.
    backdate_heartbeat("prior-run-dead")

    stderr =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", work],
            adapter_opts: [command: harness_stub],
            sinks_dir: sinks_dir,
            reobserve_interval_ms: 5,
            await_timeout: 15_000
          )
        end)
      end)

    refute stderr =~ "orphan"

    fresh_run = Repo.get_by!(Run, goal_ref: goal_ref, status: "converged")
    assert fresh_run.events_sink_path
    assert File.exists?(fresh_run.events_sink_path)

    events =
      fresh_run.events_sink_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    refute Enum.any?(events, &(&1["type"] == "orphan_warning"))
  end

  # Model the real orphan shape: the crashed controller stopped heartbeating,
  # so the prior row's heartbeat is STALE (which keeps it out of the
  # duplicate-run guard's way) while its recorded harness child may live on.
  # `RunRegistry.start/1` force-stamps heartbeat_at to now, so backdate after.
  defp backdate_heartbeat(run_id) do
    stale = DateTime.utc_now(:microsecond) |> DateTime.add(-2, :hour)
    run = Repo.get_by!(Run, run_id: run_id)
    {:ok, _} = run |> Run.changeset(%{"heartbeat_at" => stale}) |> Repo.update()
  end

  defp write_goal_file(tmp_dir, work, goal_ref) do
    path = Path.join(tmp_dir, "goal-#{goal_ref}.toml")

    File.write!(path, """
    id = "#{goal_ref}"
    name = "issue #857 orphan-detection fixture"

    [scope]
    workspace = "#{work}"

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp write_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end
