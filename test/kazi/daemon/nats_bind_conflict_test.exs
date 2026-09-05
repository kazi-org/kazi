defmodule Kazi.Daemon.NatsBindConflictTest do
  @moduledoc """
  T69.5 (#1684): `Kazi.Daemon.Nats` used to treat EVERY nats-server exit as
  fatal, with no distinction between "the configured port is squatted by an
  unrelated/orphaned process" (recoverable, self-diagnosable) and any other
  exit -- a live incident had an orphaned nats-server (ppid 1, #1719's exact
  symptom) crash-loop the daemon for 10+ hours with only a generic
  "nats-server exited" line.

  Three real scenarios, one per disposition that matters for the acceptance
  bar:

  * a FOREIGN process (not nats-server at all) holding the port -- left alone,
    logged distinctly, still fatal; repeated cycles trip `restart_loop`.
  * a genuine ORPHAN (nats-server, our store dir, ppid 1) holding the port --
    reaped, and the daemon self-heals without ever going fatal.
  * an exit with NO holder at all (something else genuinely killed
    nats-server) -- unchanged, exactly as fatal as before, no bind-conflict
    text.

  The orphan case injects `opts[:os_probe]`'s `:ppid` fact only -- genuine
  ppid-1 reparenting is impractical to fabricate reliably across OSes/sandboxes
  in a test, so this exercises the REAL `lsof`/`ps` lookups, the REAL kill, and
  the REAL respawn against a REAL decoy `nats-server` process, faking only the
  one fact that would otherwise require actually orphaning a process.

  `async: false`: these tests bind real TCP ports and spawn/kill real OS
  processes.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kazi.Daemon.Nats
  alias Kazi.TestSupport.NatsPrereq

  # Generous: a real nats-server's JetStream startup runs BEFORE it attempts
  # its network bind (~0.5-1s observed on this machine), so a full
  # fail-then-reap-then-respawn cycle can take several seconds end to end.
  @spawn_timeout_ms 8_000
  @poll_ms 50

  setup_all do
    NatsPrereq.ensure!()
    :ok
  end

  setup do
    # A GenServer's fatal `{:stop, ...}` delivers an `:EXIT` to this (linked,
    # via `start_link/1`) test process -- trap it so the test process survives
    # and can assert on the reason.
    Process.flag(:trap_exit, true)
    :ok
  end

  test "a foreign (non-nats-server) process holding the port is left alone, logs distinctly, and stays fatal" do
    id = System.unique_integer([:positive])
    port = 54_000 + rem(id, 6_000)
    store_dir = "/tmp/kazi_bind_conflict_foreign_#{id}"
    name = :"nats_bind_conflict_foreign_#{id}"

    # `:inet6` + `ipv6_v6only: false`: nats-server binds a dual-stack `::`
    # socket by default (confirmed via `lsof`: its LISTEN entry shows `IPv6`
    # even for `-p <port>` with no explicit bind address), so a plain
    # IPv4-only `:gen_tcp.listen` does NOT actually conflict with it on this
    # OS -- both bind successfully, no exit ever happens. Matching the real
    # address family is what makes this decoy a genuine occupant.
    {:ok, listen_socket} =
      :gen_tcp.listen(port, [:inet6, :binary, active: false, ipv6_v6only: false])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)
    on_exit(fn -> File.rm_rf(store_dir) end)

    beam_os_pid = :os.getpid() |> to_string() |> String.to_integer()

    log =
      capture_log(fn ->
        for _ <- 1..3 do
          {:ok, pid} = Nats.start_link(name: name, port: port, store_dir: store_dir)
          assert_receive {:EXIT, ^pid, {:nats_server_exited, _status}}, @spawn_timeout_ms
        end
      end)

    assert log =~ "nats bind conflict: port #{port} held by pid #{beam_os_pid}"
    assert log =~ "an unrelated process; leaving it alone"
    refute log =~ "orphaned"

    health = Nats.health(name)
    assert health.bind_conflict.disposition == :foreign
    assert health.bind_conflict.holder_pid == beam_os_pid
    # Three cycles at the default threshold (3) trips the restart-loop flag --
    # exactly the observability #1684 asks `kazi daemon status` to surface.
    assert health.restart_loop == true
    assert health.exits_in_window >= 3
  end

  test "an orphaned nats-server (ppid 1) matching our store dir is reaped and the daemon self-heals" do
    id = System.unique_integer([:positive])
    port = 53_000 + rem(id, 6_000)
    store_dir = "/tmp/kazi_bind_conflict_orphan_#{id}"
    name = :"nats_bind_conflict_orphan_#{id}"

    decoy_pid = spawn_decoy_nats!(port, store_dir)
    on_exit(fn -> kill!(decoy_pid) end)
    on_exit(fn -> File.rm_rf(store_dir) end)

    assert wait_listening?(port, 2_000), "decoy nats-server never bound port #{port}"

    log =
      capture_log(fn ->
        {:ok, pid} =
          Nats.start_link(
            name: name,
            port: port,
            store_dir: store_dir,
            os_probe: %{ppid: fn _pid -> 1 end}
          )

        # Our own supervised nats-server's OWN bind attempt (JetStream startup
        # runs before the network listener binds, ~0.5-1s observed) only fails
        # some time after `start_link/1` returns -- the reap+respawn cycle is
        # fully async from here. Wait for the ACTUAL recovery signal (the decoy
        # dying) rather than `wait_ready/2`, which would otherwise report
        # success near-instantly by talking to the still-alive DECOY.
        assert dies_within?(decoy_pid, @spawn_timeout_ms),
               "decoy nats-server #{decoy_pid} was never reaped"

        # Recovery, not a crash loop: the GenServer never received a fatal
        # `:stop`, and `wait_ready/2` now succeeds against the RESPAWNED
        # server (the only thing left listening, the decoy being dead).
        refute_received {:EXIT, ^pid, _reason}
        assert Process.alive?(pid)
        assert Nats.wait_ready(port, @spawn_timeout_ms) == :ok

        GenServer.stop(pid)
      end)

    assert log =~
             "nats bind conflict: port #{port} held by pid #{decoy_pid} (nats-server), not ours"

    assert log =~ "orphaned (ppid 1, matching store dir); reaping and retrying"

    health = Nats.health(name)
    assert health.bind_conflict.disposition == :orphan
    assert health.bind_conflict.holder_pid == decoy_pid
  end

  test "a nats-server exit for a genuinely unrelated reason (no port holder at all) stays exactly as fatal as before" do
    id = System.unique_integer([:positive])
    port = 55_000 + rem(id, 6_000)
    store_dir = "/tmp/kazi_bind_conflict_plain_#{id}"
    name = :"nats_bind_conflict_plain_#{id}"
    on_exit(fn -> File.rm_rf(store_dir) end)

    {:ok, pid} = Nats.start_link(name: name, port: port, store_dir: store_dir)
    assert Nats.wait_ready(port, @spawn_timeout_ms) == :ok

    shim_os_pid = :sys.get_state(pid).os_pid
    nats_os_pid = await_nats_pid!(shim_os_pid)
    on_exit(fn -> kill!(nats_os_pid) end)

    log =
      capture_log(fn ->
        # Something else entirely kills the real nats-server (not us, not a
        # squatter -- the port is genuinely free once this returns).
        System.cmd("kill", ["-9", to_string(nats_os_pid)], stderr_to_stdout: true)
        assert_receive {:EXIT, ^pid, {:nats_server_exited, _status}}, @spawn_timeout_ms
      end)

    assert log =~ "kazi daemon: nats-server exited (status"
    refute log =~ "nats bind conflict"

    assert Nats.health(name).bind_conflict == nil
  end

  # -- decoy nats-server (a REAL, bare -- no shim -- OS process left running
  # after the spawning port is closed, exactly the pre-#1719 orphaning shape) -

  defp spawn_decoy_nats!(port, store_dir) do
    bin = System.find_executable("nats-server")
    File.mkdir_p!(store_dir)

    port_ref =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        args: ["-js", "-p", to_string(port), "-sd", store_dir]
      ])

    {:os_pid, os_pid} = Port.info(port_ref, :os_pid)
    # Deliberately NOT the #1719 shim: closing the port here does not kill the
    # OS process (the exact pre-#1719 gap), leaving a genuine standalone
    # nats-server for `os_probe.ppid` to be asked about.
    Port.close(port_ref)
    os_pid
  end

  defp wait_listening?(port, timeout_ms) do
    do_wait_listening?(port, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp do_wait_listening?(port, deadline) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 200) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(@poll_ms)
          do_wait_listening?(port, deadline)
        end
    end
  end

  # Resolves the REAL nats-server pid from the shim's os_pid (mirrors
  # `Kazi.Daemon.NatsOrphanTest`'s helper of the same shape).
  defp await_nats_pid!(shim_os_pid, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @spawn_timeout_ms

    cond do
      comm(shim_os_pid) == "nats-server" ->
        shim_os_pid

      os_pid = nats_child(shim_os_pid) ->
        os_pid

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("no nats-server found at or under shim os_pid #{shim_os_pid}")

      true ->
        Process.sleep(@poll_ms)
        await_nats_pid!(shim_os_pid, deadline)
    end
  end

  defp nats_child(shim_os_pid) do
    case System.cmd("pgrep", ["-P", to_string(shim_os_pid)], stderr_to_stdout: true) do
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
    do_dies_within?(os_pid, System.monotonic_time(:millisecond) + timeout_ms)
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

  defp kill!(os_pid) do
    System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
  end
end
