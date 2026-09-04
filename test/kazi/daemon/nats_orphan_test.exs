defmodule Kazi.Daemon.NatsOrphanTest do
  @moduledoc """
  Issue #1719: a signalled BEAM must not leave its supervised nats-server behind.

  `Kazi.Daemon.Nats` used to spawn nats-server as a bare port program. A port's
  OS process has no death pact with the BEAM, and the daemon tree runs from the
  CLI process rather than under `Kazi.Application`, so `launchctl kickstart -k`
  (or any `kill`) halted the VM without running `terminate/2` and orphaned a
  nats-server still holding the TCP port -- after which the next daemon could
  never bind and logged `nats-server exited (status 1)` every ~30s forever.

  `Process.exit(pid, :kill)` is the in-test stand-in for that: it is the ONE
  teardown no `terminate/2` can intercept, so an assertion that the server dies
  anyway can only be satisfied by the out-of-BEAM mechanism (the port-pipe shim),
  never by an in-BEAM handler.

  `async: false`: these tests bind real TCP ports and spawn real OS processes.
  """
  use ExUnit.Case, async: false

  alias Kazi.Daemon.Nats
  alias Kazi.TestSupport.NatsPrereq

  @spawn_timeout_ms 5_000
  @death_timeout_ms 3_000
  @poll_ms 50

  setup_all do
    NatsPrereq.ensure!()
    :ok
  end

  setup do
    # A brutal kill of a LINKED GenServer would take the test process with it.
    Process.flag(:trap_exit, true)
    :ok
  end

  test "a brutal-killed Nats server leaves no orphaned nats-server holding the port" do
    {pid, port_os_pid, nats_pid} = start_nats!()

    assert alive?(nats_pid)

    Process.exit(pid, :kill)
    assert_receive {:EXIT, ^pid, :killed}, 1_000

    assert dies_within?(nats_pid, @death_timeout_ms),
           "nats-server pid #{nats_pid} survived a brutal kill of its owner and still " <>
             "holds its TCP port (#1719)"

    refute alive?(port_os_pid)
  end

  test "a graceful stop still reaps nats-server before terminate/2 returns" do
    {pid, port_os_pid, nats_pid} = start_nats!()

    :ok = GenServer.stop(pid)

    # `terminate/2` signals the SHIM, and the shim only exits once it has reaped
    # nats-server -- so by the time `GenServer.stop/1` returns the TCP port is
    # genuinely free, exactly as it was before the shim existed.
    refute alive?(nats_pid)
    refute alive?(port_os_pid)
  end

  # Starts a supervised nats-server on an isolated port + JetStream store and
  # returns `{genserver_pid, port_os_pid, nats_os_pid}`.
  defp start_nats! do
    id = System.unique_integer([:positive])
    port = 51_000 + rem(id, 9_000)
    store_dir = "/tmp/kazi_nats_orphan_test_#{id}"

    {:ok, pid} = Nats.start_link(name: :"nats_orphan_#{id}", port: port, store_dir: store_dir)

    port_os_pid = :sys.get_state(pid).os_pid
    nats_pid = await_nats_pid!(port_os_pid)

    on_exit(fn ->
      # Best effort: whichever of the two survived a failed assertion.
      System.cmd("kill", ["-9", to_string(nats_pid), to_string(port_os_pid)],
        stderr_to_stdout: true
      )

      File.rm_rf(store_dir)
    end)

    assert Nats.wait_ready(port, @spawn_timeout_ms) == :ok
    {pid, port_os_pid, nats_pid}
  end

  # Resolves the REAL nats-server pid from the port's os_pid, without assuming
  # which of the two shapes produced it: it is either the port program itself
  # (the pre-#1719 bare spawn) or a child of the shim. Resolving both ways keeps
  # the assertions above about BEHAVIOUR -- "the server dies with its owner" --
  # rather than about the spawn's internal shape, so they stay meaningful red
  # against the old code instead of failing early on a missing child.
  defp await_nats_pid!(port_os_pid, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @spawn_timeout_ms

    cond do
      comm(port_os_pid) == "nats-server" ->
        port_os_pid

      os_pid = nats_child(port_os_pid) ->
        os_pid

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("no nats-server found at or under port os_pid #{port_os_pid}")

      true ->
        Process.sleep(@poll_ms)
        await_nats_pid!(port_os_pid, deadline)
    end
  end

  # The shim's children are nats-server and the shim's own stdin reader (a `sh`
  # subshell whose ARGV repeats the whole script, nats-server's path included).
  # Match on the executable name (`ps -o comm=`), never the command line, so the
  # reader is never mistaken for the server.
  defp nats_child(port_os_pid) do
    case System.cmd("pgrep", ["-P", to_string(port_os_pid)], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.find(&(comm(&1) == "nats-server"))
        |> to_os_pid()

      _no_children ->
        nil
    end
  end

  defp to_os_pid(nil), do: nil
  defp to_os_pid(str), do: String.to_integer(str)

  defp comm(os_pid) do
    case System.cmd("ps", ["-p", to_string(os_pid), "-o", "comm="], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> Path.basename()
      _gone -> ""
    end
  end

  defp alive?(os_pid) do
    match?({_out, 0}, System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true))
  end

  defp dies_within?(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_dies_within?(os_pid, deadline)
  end

  defp do_dies_within?(os_pid, deadline) do
    cond do
      not alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        do_dies_within?(os_pid, deadline)
    end
  end
end
