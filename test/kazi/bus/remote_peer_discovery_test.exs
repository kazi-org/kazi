defmodule Kazi.Bus.RemotePeerDiscoveryTest do
  @moduledoc """
  #1606 regression: a bus call whose REMOTE peer is unreachable must degrade to
  `{:error, :bus_unavailable}` for every caller — including one that does not
  trap exits — instead of killing it.

  ## Why this test did not exist, and why that mattered

  `Kazi.Bus.with_conn/2` short-circuits straight to `run(conn, fun, _)` whenever
  `opts[:conn]` is supplied. Every bus test supplies one (or stubs the poster
  outright), so **no test had ever executed the discovery path** — `Probe.ping`
  → `check_protocol_skew` → `Gnat.start_link` → `run`. Discovery and connection
  establishment, the most failure-prone part of the transport, were unreachable
  from the suite by construction.

  That is why 244 tests passed while the live behaviour was unchanged: they
  exercised the linking mechanism inside `run/3` faithfully and never touched
  the call that actually fails. This test closes that specific hole by driving
  real discovery against a stub control socket — no injected `opts[:conn]`.

  ## The failure it reproduces

  `connect_discovered/3` establishes the connection with `Gnat.start_link/1`
  BEFORE calling `run/3`. `start_link` links, so when the peer is unreachable
  the connection process exits and that signal kills a caller which does not
  trap exits — which the velocity collection pass (a bare `spawn_monitor`'d
  child) does not. The pass died every tick with `:ehostunreach`, upstream of
  the un-linked `run/3`, which is why PR #1637 did not change the live counters.

  The peer address is `192.0.2.1` — TEST-NET-1 from RFC 5737, reserved for
  documentation and guaranteed not to route to a real host. It models a remote
  bus peer without depending on (or naming) anyone's network.
  """
  use ExUnit.Case, async: false

  alias Kazi.Bus

  # A remote bus peer that cannot be reached. Depending on the network this
  # either refuses fast (`:ehostunreach`, as the live daemon saw) or drops
  # (`:timeout`); both are the same defect and this test accepts either.
  @unreachable_peer "192.0.2.1"

  defp remote_peer_daemon do
    Kazi.TestSupport.FakeDaemonSocket.start!(%{
      "ok" => true,
      "bus_vsn" => Kazi.Bus.ProtocolSkew.required_bus_vsn(),
      "nats_port" => 4222,
      "nats_host" => @unreachable_peer
    })
  end

  test "a non-trapping caller SURVIVES a bus post to an unreachable remote peer" do
    sock_path = remote_peer_daemon()
    parent = self()

    # The velocity pass shape: a bare spawn_monitor'd process, no trap_exit.
    {_pid, ref} =
      spawn_monitor(fn ->
        result =
          Bus.post("fact", ~s({"probe":true}),
            sock_path: sock_path,
            topic: "session:probe",
            call_timeout_ms: 2_000
          )

        send(parent, {:returned, result})
      end)

    receive do
      {:returned, result} ->
        # The contract `Kazi.Bus` documents: degrade, never take the caller down.
        assert match?({:error, _}, result),
               "expected a degraded {:error, _}, got #{inspect(result)}"

        assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:DOWN, ^ref, :process, _pid, reason} ->
        flunk("""
        REGRESSION (#1606): the caller was KILLED instead of degrading.

          exit reason: #{inspect(reason)}

        A bus call must never take down a caller that does not trap exits. The
        connection is established with Gnat.start_link/1 in connect_discovered/3,
        which LINKS it to the caller, so an unreachable peer kills it outright —
        upstream of run/3's bound, which is why un-linking run/3 alone did not
        fix the live failure.
        """)
    after
      20_000 -> flunk("neither a result nor a DOWN within 20s")
    end
  end

  test "the same call from a TRAPPING caller already degrades — isolating the link as the variable" do
    sock_path = remote_peer_daemon()
    parent = self()

    {_pid, _ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)

        result =
          Bus.post("fact", ~s({"probe":true}),
            sock_path: sock_path,
            topic: "session:probe",
            call_timeout_ms: 2_000
          )

        send(parent, {:returned, result})
      end)

    assert_receive {:returned, result}, 20_000
    assert match?({:error, _}, result), "expected a degraded {:error, _}, got #{inspect(result)}"
  end
end
