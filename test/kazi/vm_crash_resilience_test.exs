defmodule Kazi.VmCrashResilienceTest do
  @moduledoc """
  Pins the two behaviors issue #856 asks for:

    1. `erl_crash.dump` never lands in the user's workspace CWD — the CLI boot
       path (`Kazi.Application.start/2`) points `ERL_CRASH_DUMP` at a path
       under kazi's own state dir before any run starts.
    2. When the installed release changes underneath a running VM, kazi
       reports one clear diagnosis line instead of a misleading
       harness-profile stack trace plus Logger formatter-crash spam. This is a
       module-load-failure CLASSIFIER unit test, not a live crash: it asserts
       `Kazi.SwapDiagnosis` correctly distinguishes a swap from an ordinary
       exception, using an injected `:modified_modules` seam rather than
       actually corrupting a `.beam` file on disk.

  `Kazi.Application.start/2` already ran once (as part of `mix test` booting
  the `:kazi` app), so `ERL_CRASH_DUMP` is asserted against the value that boot
  set, exactly as every other entry point (escript, `mix kazi.run`, the release
  `eval` path, the Burrito binary) would see it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{CrashDump, SwapDiagnosis}

  describe "crash-dump path (predicate crash_dump_in_state_dir)" do
    test "ERL_CRASH_DUMP is set to a path under kazi's own crash-dump dir" do
      assert System.get_env("ERL_CRASH_DUMP") == CrashDump.path()
    end

    test "the crash-dump dir is NOT the current working directory" do
      refute CrashDump.dir() == File.cwd!()
      assert Path.basename(CrashDump.dir()) == "crash"
    end

    test "the configured crash-dump dir exists on disk" do
      assert File.dir?(CrashDump.dir())
    end

    test "path/0 is erl_crash.dump under dir/0" do
      assert CrashDump.path() == Path.join(CrashDump.dir(), "erl_crash.dump")
    end

    test "configure!/0 leaves an operator's own ERL_CRASH_DUMP override untouched" do
      System.put_env("ERL_CRASH_DUMP", "/tmp/operator-chosen.dump")

      try do
        assert CrashDump.configure!() == :ok
        assert System.get_env("ERL_CRASH_DUMP") == "/tmp/operator-chosen.dump"
      after
        System.put_env("ERL_CRASH_DUMP", CrashDump.path())
      end
    end
  end

  describe "release-swap classifier (predicate swap_diagnosis)" do
    test "release_swapped?/1 is false with no modified modules" do
      refute SwapDiagnosis.release_swapped?(modified_modules: [])
    end

    test "release_swapped?/1 is true when the on-disk code has drifted from what's loaded" do
      assert SwapDiagnosis.release_swapped?(modified_modules: [Kazi.Harness.Profiles.Claude])
    end

    test "release_swapped?/0 (no injection) reflects the real, unmodified test VM" do
      refute SwapDiagnosis.release_swapped?()
    end

    test "classify/2 names the swap when modules have drifted" do
      error = %RuntimeError{message: "put_usage/2 blew up"}

      assert SwapDiagnosis.classify(error, modified_modules: [:io_lib_pretty]) ==
               {:release_swap, SwapDiagnosis.message()}
    end

    test "classify/2 is :unclassified for an ordinary error with no drift" do
      error = %RuntimeError{message: "just a bug"}

      assert SwapDiagnosis.classify(error, modified_modules: []) == :unclassified
    end

    test "message/0 names the cause plainly" do
      assert SwapDiagnosis.message() =~ "installed release changed under a running VM"
    end
  end

  describe "guard/2 (the shared CLI entry-point wrapper)" do
    test "prints the one-line diagnosis and returns exit code 1 on a swap, instead of raising" do
      output =
        capture_io(:stderr, fn ->
          result =
            SwapDiagnosis.guard(
              fn -> raise "put_usage/2 blew up on a stale module" end,
              modified_modules: [:io_lib_pretty]
            )

          send(self(), {:result, result})
        end)

      assert_received {:result, 1}
      assert output =~ "installed release changed under a running VM"
    end

    test "re-raises an ordinary exception unchanged when there is no drift" do
      assert_raise RuntimeError, "just a bug", fn ->
        SwapDiagnosis.guard(fn -> raise "just a bug" end, modified_modules: [])
      end
    end

    test "returns the wrapped function's own result when it doesn't raise" do
      assert SwapDiagnosis.guard(fn -> 0 end) == 0
    end
  end
end
