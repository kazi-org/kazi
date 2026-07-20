defmodule Kazi.Daemon.VelocityTickerBootTest do
  @moduledoc """
  #1606 (tick-never-fires): the live release binary showed `velocity collector:
  enabled` with `passes_killed: 0` and `last_run_at: null` after three tick
  windows — the pass never ran, and nothing said why. These tests pin the
  BOOT-PATH arming (which every pre-existing ticker test bypassed by injecting a
  short `interval_ms` seam) and the tick-lifecycle counters that make a
  silently-non-advancing collector diagnosable from status alone.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kazi.Daemon.VelocityTicker

  setup do
    prev = Application.get_env(:kazi, :velocity_collector, [])

    on_exit(fn ->
      Application.put_env(:kazi, :velocity_collector, prev)
      System.delete_env("KAZI_VELOCITY_INTERVAL_S")
      System.delete_env("KAZI_VELOCITY_COLLECTOR")
    end)

    state_dir =
      Path.join(System.tmp_dir!(), "kazi-velboot-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(state_dir) end)
    {:ok, prev: prev, state_dir: state_dir}
  end

  test "the PRODUCTION arming path (no interval_ms seam; interval from app-env) fires a tick",
       %{prev: prev, state_dir: state_dir} do
    # Exactly the daemon-supervisor shape: the ticker is started with ONLY a name
    # (+ test seams for the collector), and the interval must come from config —
    # the path no pre-existing test exercised (they all pass interval_ms).
    Application.put_env(:kazi, :velocity_collector, Keyword.put(prev, :interval_s, 1))
    test_pid = self()

    {:ok, pid} =
      start_supervised(
        {VelocityTicker,
         name: :velboot_config_interval,
         state_dir: state_dir,
         collect_fun: fn _opts ->
           send(test_pid, :tick_fired)
           {:ok, []}
         end}
      )

    assert_receive :tick_fired, 5_000
    # `passes_completed` is adopted asynchronously when the ticker handles the
    # child's `:pass_done`, so wait for it rather than racing the round-trip.
    wait_until(fn -> VelocityTicker.status(pid).passes_completed >= 1 end)
    status = VelocityTicker.status(pid)
    # The armed interval is surfaced (1s), and the tick was counted.
    assert status.interval_ms == 1_000
    assert status.ticks_fired >= 1
    assert status.passes_completed >= 1
  end

  test "KAZI_VELOCITY_INTERVAL_S is read at init and overrides app-env (#1571 pattern)",
       %{prev: prev, state_dir: state_dir} do
    Application.put_env(:kazi, :velocity_collector, Keyword.put(prev, :interval_s, 999))
    System.put_env("KAZI_VELOCITY_INTERVAL_S", "1")

    {:ok, pid} =
      start_supervised(
        {VelocityTicker,
         name: :velboot_env_interval, state_dir: state_dir, collect_fun: fn _ -> {:ok, []} end}
      )

    # The env override (1s) wins over the app-env 999s.
    assert VelocityTicker.status(pid).interval_ms == 1_000
  end

  test "a pass that crashes below its guards increments passes_crashed and logs (was silent)",
       %{state_dir: state_dir} do
    test_pid = self()

    # The collect_fun kills its OWN (child) process untrappably — run_tick's
    # rescue/catch cannot stop a :kill, so the pass goes DOWN without completing
    # and without a deadline kill: the exact silent path that made a crashing pass
    # look identical to "no run yet" / "no tick" (passes_killed stays 0).
    crashing = fn _opts ->
      send(test_pid, :about_to_crash)
      Process.exit(self(), :kill)
    end

    log =
      capture_log(fn ->
        {:ok, pid} =
          start_supervised(
            {VelocityTicker,
             name: :velboot_crash,
             interval_ms: 20,
             collect_timeout_ms: 60_000,
             state_dir: state_dir,
             collect_fun: crashing}
          )

        assert_receive :about_to_crash, 5_000
        wait_until(fn -> VelocityTicker.status(pid).passes_crashed >= 1 end)
        status = VelocityTicker.status(pid)
        assert status.ticks_fired >= 1
        assert status.passes_crashed >= 1
        assert status.passes_killed == 0
        assert Process.alive?(pid)
      end)

    assert log =~ "went DOWN without completing"
    assert log =~ "crashed below its guards"
  end

  defp wait_until(fun, attempts \\ 500)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
