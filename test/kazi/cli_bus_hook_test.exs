defmodule Kazi.CLIBusHookTest do
  @moduledoc """
  T55.2 (UC-068, ADR-0071 decision 2): the `kazi bus hook <event>` skeleton --
  the harness hook entry point `install-hooks` registers.

  The skeleton's contract IS the hook contract (not a stub): ALWAYS exit 0,
  print NOTHING, return immediately -- it never connects to the daemon, so a
  missing daemon can neither error nor hang a session's turn. T55.9 fills the
  payload behind the same contract.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

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
      assert err == ""
    end

    test "`bus hook turn` exits 0 and prints nothing" do
      {out, err} =
        with_io(:stderr, fn ->
          capture_io(fn -> assert Kazi.CLI.run(["bus", "hook", "turn"]) == 0 end)
        end)

      assert out == ""
      assert err == ""
    end

    test "an unknown event is STILL a silent exit 0 (a hook must never break a session)" do
      {out, err} =
        with_io(:stderr, fn ->
          capture_io(fn -> assert Kazi.CLI.run(["bus", "hook", "frobnicate"]) == 0 end)
        end)

      assert out == ""
      assert err == ""
    end

    test "a missing event is a silent exit 0 too" do
      {out, err} =
        with_io(:stderr, fn ->
          capture_io(fn -> assert Kazi.CLI.run(["bus", "hook"]) == 0 end)
        end)

      assert out == ""
      assert err == ""
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
