# The BEAM role in the T54.5 (#1073) signal-propagation test. Run under
# `mix run --no-start`. Plays the released binary: it arms the REAL
# `Kazi.Runtime.ParentMonitor` against a launcher pid, and runs a REAL
# `Kazi.Harness.ChildSupervisor`-wrapped child that spawns a grandchild.
#
# When the launcher dies, ParentMonitor `System.halt/1`s this BEAM; halting
# closes the wrapped child's dispatch port, and the wrapper watchdog (whose
# parent is THIS BEAM) reaps the child's whole process group -- child AND
# grandchild. The orchestrating shell asserts exactly that.

launcher = System.fetch_env!("LAUNCHER_PID")
child_pidfile = System.fetch_env!("CHILD_PIDFILE")
gc_pidfile = System.fetch_env!("GC_PIDFILE")

# A wrapped child that backgrounds a grandchild (recording its pid) then waits,
# so the reap must walk the whole process group to kill everything.
{cmd, args} =
  Kazi.Harness.ChildSupervisor.wrap(
    "sh",
    ["-c", "sleep 300 & echo $! > #{gc_pidfile}; wait"],
    parent_pid: System.pid(),
    poll_ms: 200,
    pid_file: child_pidfile
  )

Task.start(fn -> System.cmd(cmd, args, stderr_to_stdout: true) end)

# The REAL monitor with the production on_dead (record is a no-op without a
# run_id; the halt is the point). One dead read is enough for this test.
{:ok, _} =
  Kazi.Runtime.ParentMonitor.start_link(
    parent_pid: launcher,
    poll_ms: 200,
    dead_threshold: 1
  )

# Idle until ParentMonitor halts this BEAM on the launcher's death.
Process.sleep(:infinity)
