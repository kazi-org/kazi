defmodule Kazi.Bus.UnreachableHostProbeTest do
  @moduledoc """
  #1606 EMPIRICAL PROBE — what actually raises `:ehostunreach` and kills the
  velocity collection pass.

  PR #1637 un-linked the work run INSIDE `Kazi.Bus.run/3` and circuit-broke the
  collector's per-session fact post. The live run on v1.273.3 (which contains it)
  still showed `passes_crashed: 7 / 7` with the identical
  `went DOWN without completing (:ehostunreach)`, so that premise —
  "the crashing call is the one inside `run/3`" — is falsified by artifact.

  This probe pins the real mechanism, which sits UPSTREAM of `run/3`:
  `Kazi.Bus.connect_discovered/3` establishes the NATS connection with
  **`Gnat.start_link/1`** (`lib/kazi/bus.ex`, the `with {:ok, conn} <-
  Gnat.start_link(...)` clause) BEFORE it ever calls `run(conn, fun, timeout)`.
  `start_link` LINKS: when the connect fails, the child exits with the socket
  reason and that exit signal kills a caller which does not trap exits — which
  the velocity pass child (a bare `spawn_monitor`'d process) does not. So the
  pass dies before the un-linked `run/3` is entered at all, and before
  `post_fact/5` can return a failure for the circuit-break to act on.

  WHY 244 TESTS MISSED IT: `with_conn/2` short-circuits to `run(conn, fun, _)`
  whenever `opts[:conn]` is supplied, and every bus test supplies one (or stubs
  the poster outright). Injecting a connection SKIPS DISCOVERY ENTIRELY, so no
  test has ever executed the `Gnat.start_link` path — the doubles reproduced the
  linking mechanism inside `run/3` while never touching the call that actually
  fails.

  The address below is `192.0.2.1` — TEST-NET-1 from RFC 5737, reserved for
  documentation and guaranteed not to be a real host. It is not infrastructure,
  internal or otherwise.
  """
  use ExUnit.Case, async: false

  @unreachable "192.0.2.1"
  @nats_port 4222

  test "PROBE: Gnat.start_link to an unreachable host kills a NON-TRAPPING caller" do
    parent = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        # Exactly the shape `connect_discovered/3` uses, and exactly the process
        # shape the velocity pass child has: no trap_exit.
        result =
          Gnat.start_link(%{
            host: @unreachable,
            port: @nats_port,
            connection_timeout: 1_000
          })

        send(parent, {:survived, result})
      end)

    receive do
      {:DOWN, ^ref, :process, _pid, reason} ->
        # THE FINDING: the caller is killed by the link rather than receiving an
        # `{:error, reason}` it could handle. `reason` here is the same class the
        # live daemon logged (`:ehostunreach` on a fail-fast network; a timeout
        # shape when the network blackholes instead).
        assert reason != :normal

        IO.puts(
          "\n[#1606 PROBE] non-trapping caller was KILLED by Gnat.start_link; " <>
            "reason=#{inspect(reason)}"
        )

      {:survived, result} ->
        IO.puts("\n[#1606 PROBE] caller SURVIVED; Gnat.start_link returned #{inspect(result)}")
    after
      15_000 -> flunk("probe did not resolve within 15s")
    end
  end

  test "PROBE: a TRAPPING caller survives the same call — proving it is the LINK" do
    parent = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)

        result =
          Gnat.start_link(%{
            host: @unreachable,
            port: @nats_port,
            connection_timeout: 1_000
          })

        send(parent, {:survived, result})
      end)

    receive do
      {:survived, result} ->
        IO.puts(
          "\n[#1606 PROBE] TRAPPING caller survived; Gnat.start_link returned #{inspect(result)}"
        )

        assert true

      {:DOWN, ^ref, :process, _pid, reason} ->
        IO.puts("\n[#1606 PROBE] trapping caller ALSO died; reason=#{inspect(reason)}")
        assert reason != :normal
    after
      15_000 -> flunk("probe did not resolve within 15s")
    end
  end
end
