defmodule Kazi.Harness.ChildLifetimeTest do
  @moduledoc """
  Tier 2 — real subprocess boundary (issue #857). Pins the load-bearing
  guarantee that a dispatched harness subprocess cannot outlive its
  controller, including an ABNORMAL controller exit (an uncatchable
  `SIGKILL`/crash gives the controller no chance to run any cleanup code
  itself — the #856 path this issue follows on from).

  A real BEAM `kill -9` would end the test process too, so the "controller" is
  a SYNTHETIC OS process (a real `sh -c 'sleep ...'` spawned via `Port.open/2`)
  whose pid is threaded in as `CliAdapter`'s `:supervise_parent_pid` override —
  exactly the seam `Kazi.Harness.ChildSupervisor.wrap/3` exposes for this. The
  dispatch itself still goes through the REAL production path
  (`CliAdapter.run/3` -> `ChildSupervisor.wrap/3` -> a real wrapped `sh`
  subprocess), so this proves the actual shipped mechanism, not a mock of it.
  """
  use ExUnit.Case, async: true

  alias Kazi.Harness.CliAdapter

  # A stub "harness": writes its own OS pid to a file the instant it starts (so
  # the test can recover it), then sleeps far longer than any test needs —
  # standing in for a long-running agent turn.
  @stub_harness """
  #!/bin/sh
  echo "$$" > "$1"
  sleep 30
  """

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "kazi-child-lifetime-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    stub_path =
      Path.join(System.tmp_dir!(), "kazi-stub-harness-#{System.unique_integer([:positive])}.sh")

    File.write!(stub_path, @stub_harness)
    File.chmod!(stub_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm(stub_path)
    end)

    {:ok, workspace: workspace, stub_path: stub_path}
  end

  # A liveness check independent of the production module under test, so the
  # assertion doesn't just re-check `ChildSupervisor`'s own `alive?/1` against
  # itself.
  defp os_alive?(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  test "a dispatched harness subprocess is killed when the controller dies", %{
    workspace: workspace,
    stub_path: stub_path
  } do
    stub_pid_file = Path.join(workspace, "stub.pid")

    # The synthetic "controller": a real, independently-killable OS process
    # standing in for a `kazi apply` process that is about to crash mid-dispatch.
    controller_port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        args: ["-c", "sleep 30"]
      ])

    {:os_pid, controller_pid} = Port.info(controller_port, :os_pid)

    # Dispatch the long-running stub harness through the REAL CliAdapter path,
    # supervised against the SYNTHETIC controller (not this test's own BEAM
    # process) and a fast poll interval so the test doesn't wait a full
    # production poll cycle.
    profile = %Kazi.Harness.Profile{
      id: :stub,
      command: stub_path,
      build_args: fn _prompt, _opts -> [stub_pid_file] end,
      parse: fn _output -> %{} end
    }

    dispatch_task =
      Task.async(fn ->
        CliAdapter.run("go", workspace,
          profile: profile,
          supervise_parent_pid: controller_pid,
          supervise_poll_ms: 100
        )
      end)

    # Wait for the stub to actually start and report its own pid.
    stub_pid =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        case File.read(stub_pid_file) do
          {:ok, contents} when contents != "" ->
            {:halt, String.trim(contents)}

          _ ->
            Process.sleep(20)
            {:cont, nil}
        end
      end)

    refute is_nil(stub_pid), "the stub harness never reported its pid — dispatch never started"
    assert os_alive?(stub_pid), "the stub harness should be running before the controller dies"

    # Kill the controller the way a crash would: uncatchable, no cleanup chance.
    # The port closes itself as soon as it sees the OS process's exit status —
    # sometimes before this explicit close runs — so an already-closed port is
    # expected, not an error.
    System.cmd("kill", ["-9", to_string(controller_pid)])

    try do
      Port.close(controller_port)
    rescue
      ArgumentError -> :ok
    end

    # The wrapped dispatch's own `wait` only unblocks once its child has
    # actually been reaped, so awaiting it (rather than a fixed sleep) is both
    # the deterministic and the fast-under-load way to know the watchdog
    # noticed the dead controller and killed the harness — no flake margin to
    # tune, no race with system load.
    assert {:ok, %{exit: exit_status}} = Task.await(dispatch_task, 5_000)
    assert exit_status != 0

    refute os_alive?(stub_pid),
           "the harness subprocess outlived its dead controller — orphaned writer (issue #857)"
  end
end
