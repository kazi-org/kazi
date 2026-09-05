defmodule Kazi.Runtime.ParentMonitorDetachTest do
  @moduledoc """
  T70.4 (issue #1699): `kazi apply --parallel`, launched via `nohup ... &
  disown` (or `setsid`) so it deliberately reparents off its invoking shell,
  used to get reaped within seconds as "launcher process 1 is gone" before
  any dispatch happened -- indistinguishable, by pid alone, from the launcher
  actually dying (issue #1073, the case this monitor exists to catch).

  The fix lives in `Kazi.Harness.ChildSupervisor.alive?/1` (ParentMonitor's
  DEFAULT `:alive_fn`): `kill -0 1` fails EPERM ("Operation not permitted" --
  the process exists, owned by root) rather than ESRCH ("No such process" --
  genuinely gone), and `alive?/1` now treats EPERM as proof of life. Every
  test in `parent_monitor_test.exs` injects a synthetic `:alive_fn`, so none
  of them exercise this seam -- these tests deliberately do NOT override
  `:alive_fn`, driving REAL OS processes (a genuine `nohup ... & disown`
  detach, and a genuinely-killed process) through the real default so the
  distinction is proven against actual `kill`/`ps` semantics, not a stub.
  """
  use ExUnit.Case, async: false

  alias Kazi.Harness.ChildSupervisor
  alias Kazi.Runtime.ParentMonitor

  defp start!(opts) do
    {:ok, pid} = ParentMonitor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 500) end)
    pid
  end

  # A plain, live child process owned by the SAME user as the test -- the
  # "real launcher" stand-in for the genuinely-dead scenario. Mirrors
  # cli_orphans_test.exs's spawn_orphan/1: a Port with :exit_status so the
  # BEAM reaps it promptly once killed (no lingering zombie masking the
  # ESRCH transition).
  defp spawn_real_child(seconds \\ 30) do
    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        :exit_status,
        args: ["-c", "sleep #{seconds}"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    pid = to_string(os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", pid], stderr_to_stdout: true) end)
    pid
  end

  # Spawns a real OS process backgrounded via `nohup ... & disown` inside a
  # shell that exits immediately after -- the exact `nohup kazi apply &
  # disown` detach pattern from #1699. `System.cmd` blocks only on the OUTER
  # shell, which backgrounds the long-lived process, disowns it, and exits
  # right away -- orphaning the backgrounded process to init within moments,
  # exactly like an interactive terminal closing right after backgrounding.
  #
  # Returns the value `resolve_launcher_pid/0` would ACTUALLY compute for a
  # process in this exact state -- `ps -o ppid=` of the detached process --
  # confirmed by real `ps`, never assumed. `resolve_launcher_pid/0` itself
  # is hardcoded to `System.pid()` (the CALLING BEAM), so it cannot be driven
  # by an external process from inside `mix test`; feeding its real-world
  # output through the same `:parent_pid` injection seam every other test in
  # this suite uses is the closest a single-BEAM test can get to genuine. The
  # spawned process's OWN pid is not what a real ParentMonitor would watch
  # here -- it is always alive regardless of the fix, since it is a live,
  # same-user process throughout; watching that would be a vacuous test that
  # passes identically before and after the fix (caught in review: an
  # earlier draft of this test did exactly that).
  defp spawn_detached_orphan(seconds \\ 30) do
    pid_file =
      Path.join(System.tmp_dir!(), "kazi-detach-test-#{System.unique_integer([:positive])}")

    {_out, 0} =
      System.cmd("bash", [
        "-c",
        "nohup bash -c 'echo $$ > #{pid_file}; exec sleep #{seconds}' " <>
          ">/dev/null 2>&1 & disown; exit 0"
      ])

    pid = wait_for_pidfile(pid_file)
    on_exit(fn -> System.cmd("kill", ["-9", pid], stderr_to_stdout: true) end)

    wait_for_reparent_to_init!(pid)
  end

  defp wait_for_pidfile(pid_file, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    case File.read(pid_file) do
      {:ok, content} when byte_size(content) > 0 ->
        File.rm(pid_file)
        String.trim(content)

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk(
            "nohup+disown child never wrote its pidfile within 2s -- environment issue, " <>
              "not the #1699 fix under test"
          )
        else
          Process.sleep(20)
          wait_for_pidfile(pid_file, deadline)
        end
    end
  end

  # Polls the REAL `ps -o ppid=` of `pid` -- the exact command
  # `resolve_launcher_pid/0` runs -- until it reads "1" (genuinely
  # reparented to init), and returns that resolved value. A test-environment
  # quirk (no reparent within the deadline) fails loudly instead of quietly
  # passing without exercising the genuine #1699 scenario.
  defp wait_for_reparent_to_init!(pid, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    case System.cmd("ps", ["-o", "ppid=", "-p", pid], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "1" ->
            "1"

          _other ->
            if System.monotonic_time(:millisecond) > deadline do
              flunk(
                "nohup+disown child (pid #{pid}) never reparented to init (ppid=1) within 2s " <>
                  "-- cannot exercise the #1699 scenario in this environment"
              )
            else
              Process.sleep(20)
              wait_for_reparent_to_init!(pid, deadline)
            end
        end

      _ ->
        flunk("could not read ppid for pid #{pid}")
    end
  end

  test "a launcher reparented via nohup+disown survives as an intentional detach, not a reap" do
    test = self()
    # The pid resolve_launcher_pid/0 would ACTUALLY compute here: "1" --
    # confirmed by real ps against a real nohup+disown-detached process, not
    # assumed (see spawn_detached_orphan/1's moduledoc-style comment).
    launcher_pid = spawn_detached_orphan()

    # No :alive_fn override -- production default (ChildSupervisor.alive?/1),
    # the exact seam the #1699 fix lives in.
    start!(
      parent_pid: launcher_pid,
      poll_ms: 50,
      dead_threshold: 3,
      on_dead: fn _state -> send(test, :fired) end
    )

    refute_receive :fired, 1_000
  end

  test "a genuinely killed launcher still triggers the reap (no #1073 regression)" do
    test = self()
    pid = spawn_real_child()

    assert ChildSupervisor.alive?(pid), "the launcher stand-in must be alive before killing it"

    start!(
      parent_pid: pid,
      poll_ms: 50,
      dead_threshold: 3,
      on_dead: fn _state -> send(test, :fired) end
    )

    refute_receive :fired, 100
    System.cmd("kill", ["-9", pid], stderr_to_stdout: true)
    assert_receive :fired, 3_000
  end
end
