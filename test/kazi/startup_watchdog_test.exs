defmodule Kazi.StartupWatchdogTest do
  @moduledoc """
  T59.3 (issue #1255): the CLI-startup watchdog fires on a hung startup and dumps
  where the main process is blocked, without a full release build. Verified at the
  function level — a deliberately-blocking fun stands in for the hung dispatch.
  """
  use ExUnit.Case, async: true

  alias Kazi.StartupWatchdog

  # Capture the watchdog's stderr dump into a StringIO so the assertions can read
  # exactly what an operator would see, without touching the process's real stderr.
  defp capture_device do
    {:ok, dev} = StringIO.open("")
    dev
  end

  defp device_contents(dev) do
    {_in, out} = StringIO.contents(dev)
    out
  end

  describe "with_watchdog/2 — a hung startup" do
    test "dumps where the main process is blocked after the deadline (dump-and-continue default)" do
      dev = capture_device()
      test = self()

      # Run the watchdog around a fun that blocks forever, in a separate process so
      # the test itself is not the one that hangs. `halt?: false` (the default) means
      # the watchdog only dumps — it must not halt the VM under test.
      blocked =
        spawn(fn ->
          send(test, {:running, self()})

          StartupWatchdog.with_watchdog(
            fn -> Process.sleep(:infinity) end,
            deadline_ms: 20,
            halt?: false,
            device: dev
          )
        end)

      assert_receive {:running, ^blocked}, 500
      # Give the 20ms deadline time to fire and the dump to land.
      Process.sleep(150)

      out = device_contents(dev)
      assert out =~ "kazi startup-watchdog: CLI startup exceeded 20ms"
      assert out =~ "issue #1255"
      # It names WHERE the main process is blocked (the whole point of the
      # diagnostic) — including the exact stack frame it is stuck on.
      assert out =~ "where startup is blocked"
      assert out =~ "Process.sleep"
      assert out =~ "main process"
      assert out =~ "run_queue_lengths="
      assert out =~ "idle-scheduler receive-block"
      assert out =~ "open ports"

      Process.exit(blocked, :kill)
    end
  end

  describe "with_watchdog/2 — a healthy startup" do
    test "returns the fun's value and emits NO dump when it completes before the deadline" do
      dev = capture_device()

      result =
        StartupWatchdog.with_watchdog(
          fn -> 0 end,
          deadline_ms: 5_000,
          device: dev
        )

      assert result == 0
      # No timeout fired, so nothing was written.
      assert device_contents(dev) == ""
    end

    test "a non-zero exit code passes through unchanged" do
      assert StartupWatchdog.with_watchdog(fn -> 3 end, deadline_ms: 5_000) == 3
    end
  end

  describe "with_watchdog/2 — disabled" do
    test "deadline_ms 0 is a pure pass-through (no watcher, no dump)" do
      dev = capture_device()
      assert StartupWatchdog.with_watchdog(fn -> :done end, deadline_ms: 0, device: dev) == :done
      assert device_contents(dev) == ""
    end
  end
end
