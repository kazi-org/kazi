defmodule Kazi.Velocity.CollectorBusIsolationTest do
  @moduledoc """
  #1606: the velocity collection pass died silently every tick on the live
  release binary. The tick-lifecycle counters localized it to the pass itself:

      ticks_fired: 5, passes_completed: 1, passes_crashed: 3, passes_killed: 0
      velocity pass went DOWN without completing (:ehostunreach)

  Root cause: the collector's BEST-EFFORT bus `fact` post reaches an unreachable
  NATS host, and `Kazi.Bus.run/3` ran the call in a `Task.async` — which LINKS.
  A linked task exiting `:ehostunreach` kills a caller that does not trap exits
  (the pass child is a bare `spawn_monitor`'d process) via an exit SIGNAL, which
  the collector's own try/rescue/catch cannot intercept.

  The SAME unreachable host produces a second, different-looking failure when the
  network blackholes instead of failing fast: the call blocks to `Bus.run/3`'s
  15s bound once PER SESSION, so the pass overruns its tick interval —
  "velocity pass still running after 10000ms; skipping this tick" — while
  `passes_killed` stays 0 because it never reaches the 120s kill deadline.

  These tests pin BOTH modes, since fixing only the crash would let the stall
  come back wearing a different hat.
  """
  use ExUnit.Case, async: false

  alias Kazi.Velocity.SessionCollector

  @fixtures Path.expand("../../support/fixtures/velocity", __DIR__)

  setup do
    state_dir =
      Path.join(System.tmp_dir!(), "kazi-busiso-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(state_dir) end)
    {:ok, state_dir: state_dir}
  end

  describe "crash mode — an exiting bus post must not take the pass down" do
    test "a poster whose linked worker exits does NOT kill the collecting process",
         %{state_dir: state_dir} do
      # Reproduces the live path exactly: the poster routes through
      # `Kazi.Bus.run/3` (as `Kazi.Bus.post/3` -> `with_conn/2` does) and the
      # underlying call exits `:ehostunreach`, as a NATS connect to an
      # unreachable host did. Pre-fix `run/3` used `Task.async`, whose LINK
      # propagated that exit and killed this pass outright — uncatchable by the
      # collector's own try/rescue/catch, so the pass vanished with no result.
      exiting_poster = fn _kind, _text, _opts ->
        Kazi.Bus.run(:fake_conn, fn _conn -> exit(:ehostunreach) end, 2_000)
      end

      parent = self()

      {_pid, ref} =
        spawn_monitor(fn ->
          collected =
            SessionCollector.collect(
              dir: @fixtures,
              state_dir: state_dir,
              machine: "test-host",
              write: fn _wire -> :ok end,
              poster: exiting_poster
            )

          send(parent, {:collected, length(collected)})
        end)

      # The pass must COMPLETE and report its sessions, not go DOWN.
      assert_receive {:collected, n}, 5_000
      assert n == 2

      # And it exits NORMALLY — pre-fix it went DOWN with :ehostunreach, which is
      # exactly what the live counters recorded as `passes_crashed`.
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
    end
  end

  describe "stall mode — a hanging bus must cost the pass ONE bound, not N" do
    test "the fact post is circuit-broken for the rest of the pass after one failure",
         %{state_dir: state_dir} do
      # A blackholed host makes each post block to `Bus.run/3`'s bound. The
      # collector must stop paying that per session: the FIRST failure disables
      # the fact for the remainder of the pass. The fixture has 2 sessions, so
      # pre-fix this cost 2 x the bound; now it costs 1.
      counter = :counters.new(1, [])

      slow_failing_poster = fn _kind, _text, _opts ->
        :counters.add(counter, 1, 1)
        Process.sleep(300)
        # What `Kazi.Bus` degrades to when the bus is unreachable/timed out.
        {:error, :bus_unavailable}
      end

      collected =
        SessionCollector.collect(
          dir: @fixtures,
          state_dir: state_dir,
          machine: "test-host",
          write: fn _wire -> :ok end,
          poster: slow_failing_poster
        )

      # Both sessions still collected and WRITTEN (the read-model ship is the
      # essential one and is never skipped) ...
      assert length(collected) == 2
      # ... but the unreachable bus was attempted exactly ONCE.
      assert :counters.get(counter, 1) == 1
    end

    test "a HEALTHY bus is still posted for every session (no false circuit-break)",
         %{state_dir: state_dir} do
      counter = :counters.new(1, [])

      ok_poster = fn _kind, _text, _opts ->
        :counters.add(counter, 1, 1)
        :ok
      end

      collected =
        SessionCollector.collect(
          dir: @fixtures,
          state_dir: state_dir,
          machine: "test-host",
          write: fn _wire -> :ok end,
          poster: ok_poster
        )

      assert length(collected) == 2
      assert :counters.get(counter, 1) == 2
    end
  end

  describe "Kazi.Bus.run/3 — the central guarantee" do
    test "a crashing bus call degrades instead of killing a non-trapping caller" do
      parent = self()

      {_pid, ref} =
        spawn_monitor(fn ->
          # Deliberately NOT trapping exits — the shape every bare pass child has.
          result = Kazi.Bus.run(:fake_conn, fn _conn -> exit(:ehostunreach) end, 2_000)
          send(parent, {:result, result})
        end)

      assert_receive {:result, {:error, :bus_unavailable}}, 5_000
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
    end

    test "a hanging bus call is bounded and degrades" do
      assert Kazi.Bus.run(:fake_conn, fn _conn -> Process.sleep(:infinity) end, 200) ==
               {:error, :bus_unavailable}
    end
  end
end
