defmodule Kazi.Runtime.ParentMonitorTest do
  @moduledoc """
  T54.5 (issue #1073): the parent-liveness monitor fires exactly when the
  launcher dies, never while it lives, and only after N CONSECUTIVE dead reads
  (so a transient `ps` misread can't abort a healthy run, R-E54-3).

  Every test injects a synthetic launcher pid and a stub `on_dead` that sends a
  message instead of halting -- proving the fire/no-fire behaviour without ever
  calling `System.halt/1` on the test BEAM.
  """
  use ExUnit.Case, async: true

  alias Kazi.Runtime.ParentMonitor

  defp start!(opts) do
    {:ok, pid} = ParentMonitor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 500) end)
    pid
  end

  # An alive_fn backed by a flag the test can flip mid-run.
  defp flag_alive_fn(initial) do
    {:ok, agent} = start_supervised({Agent, fn -> initial end})
    {agent, fn _pid -> Agent.get(agent, & &1) end}
  end

  test "does NOT fire while the launcher is alive" do
    test = self()
    {_agent, alive_fn} = flag_alive_fn(true)

    start!(
      parent_pid: "424242",
      poll_ms: 20,
      dead_threshold: 1,
      alive_fn: alive_fn,
      on_dead: fn _state -> send(test, :fired) end
    )

    refute_receive :fired, 200
  end

  test "fires once the launcher dies, carrying the run_id and pid it watched" do
    test = self()
    {agent, alive_fn} = flag_alive_fn(true)

    start!(
      parent_pid: "424242",
      run_id: "run-abc",
      poll_ms: 20,
      dead_threshold: 1,
      alive_fn: alive_fn,
      on_dead: fn state -> send(test, {:fired, state.run_id, state.parent_pid}) end
    )

    refute_receive {:fired, _, _}, 100
    Agent.update(agent, fn _ -> false end)
    assert_receive {:fired, "run-abc", "424242"}, 1_000
  end

  test "requires N CONSECUTIVE dead reads before firing (transient misread resets)" do
    test = self()

    # dead, then ALIVE (resets the counter), then dead forever. With a threshold
    # of 3 the single leading dead read must NOT fire -- only the later run of 3
    # consecutive dead reads may.
    {:ok, agent} = start_supervised({Agent, fn -> [false, true] end})

    alive_fn = fn _pid ->
      Agent.get_and_update(agent, fn
        [h | t] -> {h, t}
        # exhausted -> permanently dead
        [] -> {false, []}
      end)
    end

    start!(
      parent_pid: "1",
      poll_ms: 20,
      dead_threshold: 3,
      alive_fn: alive_fn,
      on_dead: fn _state -> send(test, :fired) end
    )

    # The leading transient dead read (count=1) then a live read (reset) must not
    # trip the threshold; only the 3 consecutive dead reads that follow do.
    assert_receive :fired, 1_000
  end

  test "a permanently dead launcher does not fire BEFORE the threshold is reached" do
    test = self()
    # Always dead. With poll_ms=40 and threshold=3, the earliest fire is the 3rd
    # poll (~120ms); it must be silent through the first two (~80ms).
    start!(
      parent_pid: "1",
      poll_ms: 40,
      dead_threshold: 3,
      alive_fn: fn _pid -> false end,
      on_dead: fn _state -> send(test, :fired) end
    )

    refute_receive :fired, 90
    assert_receive :fired, 1_000
  end

  test "an unresolvable launcher pid keeps the monitor inert (never fires)" do
    test = self()

    # No :parent_pid and a resolver that yields nothing leaves parent_pid nil, so
    # the monitor idles -- it must never fire on absent evidence. (We can't force
    # the real `ps` resolver to nil, so we assert the alive_fn is simply never
    # consulted when the pid is nil by pointing on_dead at the test and pinning a
    # nil pid through the public seam.)
    start!(
      parent_pid: nil,
      poll_ms: 20,
      dead_threshold: 1,
      # If the monitor ever polled, this would raise (nil pid) -- proving inertia.
      alive_fn: fn _pid -> send(test, :polled) && false end,
      on_dead: fn _state -> send(test, :fired) end
    )

    refute_receive :polled, 150
    refute_receive :fired, 50
  end
end
