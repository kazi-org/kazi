defmodule Kazi.CLI.DaemonReregisterTest do
  @moduledoc """
  #1484 (ADR-0083), defect 1: `kazi daemon reregister` re-pins a launchd job's
  Lightweight Code Requirement against the CURRENT binary -- the remedy after
  an in-place upgrade leaves the job spawning against stale bytes (launchd
  refuses with `last exit code = 78: EX_CONFIG`, its own code, never kazi's).

  Every real `launchctl`/`id` call is stubbed via `inject_opts` (`:launchd_os`,
  `:reregister_runner`, `:uid_fn`) so this suite exercises every branch
  hermetically, on any OS, WITHOUT touching a real launchd job -- required
  since this behavior is macOS-only and CI runs Linux.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "macOS-only guard" do
    test "on a non-darwin OS, reregister is a documented no-op (exit 0)" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["daemon", "reregister"], launchd_os: :other) == 0
        end)

      assert out =~ "no-op"
      assert out =~ "macOS"
    end

    test "the no-op is reported under --json too" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["daemon", "reregister", "--json"], launchd_os: :other) == 0
        end)

      decoded = Jason.decode!(String.trim(out))
      assert decoded["ok"] == true
      assert decoded["skipped"] == true
    end
  end

  describe "on darwin: no plist installed" do
    test "errors clearly instead of trying to register nothing" do
      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["daemon", "reregister"],
                   launchd_os: :darwin,
                   uid_fn: fn -> {:ok, "501"} end
                 ) == 1
        end)

      assert out =~ "no LaunchAgent plist installed"
    end
  end

  describe "on darwin: uid resolution failure" do
    test "errors clearly when the uid cannot be determined" do
      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["daemon", "reregister"],
                   launchd_os: :darwin,
                   uid_fn: fn -> {:error, "id -u exited 1"} end
                 ) == 1
        end)

      assert out =~ "could not determine the current uid"
    end
  end

  describe "on darwin: the bootout+bootstrap sequence" do
    test "bootout is allowed to fail; bootstrap succeeding is a full success" do
      calls = :ets.new(:reregister_calls, [:public])

      runner = fn cmd, args, _opts ->
        :ets.insert(calls, {:erlang.unique_integer([:monotonic]), {cmd, args}})

        case args do
          ["bootout" | _] -> {"Could not find service", 1}
          ["bootstrap" | _] -> {"", 0}
        end
      end

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["daemon", "reregister"],
                   launchd_os: :darwin,
                   uid_fn: fn -> {:ok, "501"} end,
                   reregister_runner: runner,
                   skip_plist_check: true
                 ) == 0
        end)

      assert out =~ "re-registered"
      assert out =~ "run.kazi.bushost"

      calls_in_order =
        :ets.tab2list(calls) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

      assert [{"launchctl", ["bootout" | _]}, {"launchctl", ["bootstrap" | _]}] = calls_in_order
    end

    test "a failing bootstrap is a loud, exit-1 error naming the launchctl output" do
      runner = fn _cmd, args, _opts ->
        case args do
          ["bootout" | _] -> {"", 0}
          ["bootstrap" | _] -> {"Bootstrap failed: 5: Input/output error", 5}
        end
      end

      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["daemon", "reregister"],
                   launchd_os: :darwin,
                   uid_fn: fn -> {:ok, "501"} end,
                   reregister_runner: runner,
                   skip_plist_check: true
                 ) == 1
        end)

      assert out =~ "re-registration failed"
      assert out =~ "exited 5"
      assert out =~ "Input/output error"
    end

    test "--json reports both steps' cmd/output/status" do
      runner = fn _cmd, _args, _opts -> {"", 0} end

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["daemon", "reregister", "--json"],
                   launchd_os: :darwin,
                   uid_fn: fn -> {:ok, "501"} end,
                   reregister_runner: runner,
                   skip_plist_check: true
                 ) == 0
        end)

      decoded = Jason.decode!(String.trim(out))
      assert decoded["ok"] == true
      assert length(decoded["steps"]) == 2
      assert Enum.all?(decoded["steps"], &(&1["status"] == 0))
    end
  end
end
