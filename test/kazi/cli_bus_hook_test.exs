defmodule Kazi.CLIBusHookTest do
  @moduledoc """
  T55.2 (UC-068, ADR-0071 decision 2) + T55.9: the `kazi bus hook <event>` CLI
  contract -- the harness hook entry point `install-hooks` registers.

  The contract holds no matter what the payload does (T55.9 fills it): ALWAYS
  exit 0, and with NO daemon running print NOTHING and return immediately, so a
  missing daemon can neither error nor hang a session's turn. These tests pin
  the no-daemon path via a tmp-scoped `KAZI_STATE_DIR` (like `bus_test.exs`) so
  a developer's real daemon can never make them flap; the live payload against a
  real daemon is `Kazi.Bus.HookPayloadTest`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # A tmp state dir points the default control socket at a path with no daemon,
  # so `bus hook` takes its silent no-daemon path regardless of the environment.
  setup do
    state_dir =
      Path.join(System.tmp_dir!(), "kazi-hook-cli-#{System.unique_integer([:positive])}")

    previous = System.get_env("KAZI_STATE_DIR")
    System.put_env("KAZI_STATE_DIR", state_dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("KAZI_STATE_DIR", previous),
        else: System.delete_env("KAZI_STATE_DIR")

      File.rm_rf(state_dir)
    end)

    :ok
  end

  # The command's OWN stderr lines, identified by the CLI's `error:` convention —
  # so a foreign `[warning] …` / `kazi: … deprecated` line captured off the shared
  # :standard_error device by a concurrent test is excluded (T59.5, #1025/#1186).
  defp own_stderr_lines(err) do
    err
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "error:"))
  end

  describe "parse/1 — bus hook" do
    test "`bus hook <event>` parses as a bus verb" do
      assert {:bus, "hook", ["turn"], _opts} = Kazi.CLI.parse(["bus", "hook", "turn"])

      assert {:bus, "hook", ["session-start"], _opts} =
               Kazi.CLI.parse(["bus", "hook", "session-start"])
    end

    test "`bus hook --help` routes to the per-verb help" do
      assert {:bus_help, "hook"} = Kazi.CLI.parse(["bus", "hook", "--help"])
    end
  end

  describe "run/2 — bus hook is silent exit 0 (no daemon needed, no hang)" do
    test "`bus hook session-start` exits 0 and prints nothing" do
      {out, err} =
        with_io(:stderr, fn ->
          capture_io(fn -> assert Kazi.CLI.run(["bus", "hook", "session-start"]) == 0 end)
        end)

      assert out == ""
      # Isolation (T59.5, #1025/#1186): assert on THIS command's own stderr, not
      # the whole global :standard_error device. `with_io(:stderr, …)` swaps that
      # device process-WIDE, so any concurrent async test logging during the window
      # (a Logger `[warning] …` line, a `kazi: provider … deprecated` notice) lands
      # in `err` and reddened `err == ""` under full-suite load. The bus-hook
      # command's ONLY stderr shape is the CLI's `error:` convention (it is silent
      # otherwise), so asserting it emitted no `error:` line proves its silence and
      # is immune to foreign noise the shared device picks up.
      assert own_stderr_lines(err) == []
    end

    test "`bus hook turn` exits 0 and prints nothing" do
      {out, err} =
        with_io(:stderr, fn ->
          capture_io(fn -> assert Kazi.CLI.run(["bus", "hook", "turn"]) == 0 end)
        end)

      assert out == ""
      # Isolation (T59.5, #1025/#1186): assert on THIS command's own stderr, not
      # the whole global :standard_error device. `with_io(:stderr, …)` swaps that
      # device process-WIDE, so any concurrent async test logging during the window
      # (a Logger `[warning] …` line, a `kazi: provider … deprecated` notice) lands
      # in `err` and reddened `err == ""` under full-suite load. The bus-hook
      # command's ONLY stderr shape is the CLI's `error:` convention (it is silent
      # otherwise), so asserting it emitted no `error:` line proves its silence and
      # is immune to foreign noise the shared device picks up.
      assert own_stderr_lines(err) == []
    end

    test "an unknown event is STILL a silent exit 0 (a hook must never break a session)" do
      {out, err} =
        with_io(:stderr, fn ->
          capture_io(fn -> assert Kazi.CLI.run(["bus", "hook", "frobnicate"]) == 0 end)
        end)

      assert out == ""
      # Isolation (T59.5, #1025/#1186): assert on THIS command's own stderr, not
      # the whole global :standard_error device. `with_io(:stderr, …)` swaps that
      # device process-WIDE, so any concurrent async test logging during the window
      # (a Logger `[warning] …` line, a `kazi: provider … deprecated` notice) lands
      # in `err` and reddened `err == ""` under full-suite load. The bus-hook
      # command's ONLY stderr shape is the CLI's `error:` convention (it is silent
      # otherwise), so asserting it emitted no `error:` line proves its silence and
      # is immune to foreign noise the shared device picks up.
      assert own_stderr_lines(err) == []
    end

    test "a missing event is a silent exit 0 too" do
      {out, err} =
        with_io(:stderr, fn ->
          capture_io(fn -> assert Kazi.CLI.run(["bus", "hook"]) == 0 end)
        end)

      assert out == ""
      # Isolation (T59.5, #1025/#1186): assert on THIS command's own stderr, not
      # the whole global :standard_error device. `with_io(:stderr, …)` swaps that
      # device process-WIDE, so any concurrent async test logging during the window
      # (a Logger `[warning] …` line, a `kazi: provider … deprecated` notice) lands
      # in `err` and reddened `err == ""` under full-suite load. The bus-hook
      # command's ONLY stderr shape is the CLI's `error:` convention (it is silent
      # otherwise), so asserting it emitted no `error:` line proves its silence and
      # is immune to foreign noise the shared device picks up.
      assert own_stderr_lines(err) == []
    end

    test "returns fast -- no daemon connect, no hanging (bounded wall-clock)" do
      {elapsed_us, :ok} =
        :timer.tc(fn ->
          capture_io(fn -> assert Kazi.CLI.run(["bus", "hook", "turn"]) == 0 end)
          :ok
        end)

      # The skeleton never opens a socket; even a generous bound (1s) is far
      # above what a no-op run/2 takes and far below any connect timeout.
      assert elapsed_us < 1_000_000
    end
  end

  describe "bus hook --help documents the events" do
    test "names both events and the always-exit-0 contract" do
      out = capture_io(fn -> assert Kazi.CLI.run(["bus", "hook", "--help"]) == 0 end)

      assert out =~ "kazi bus hook <event>"
      assert out =~ "session-start"
      assert out =~ "turn"
      assert out =~ "exits 0"
      assert out =~ "install-hooks"
    end
  end
end
