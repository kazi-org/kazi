defmodule Kazi.Daemon.LifecycleTest do
  @moduledoc """
  T51.1 (ADR-0067 decision point 1): the daemon skeleton's lifecycle contract
  — process supervision + the Unix-socket control plane, with NO NATS/bus
  wired yet (that's T51.2+). This test starts the supervision tree IN-TEST
  (`Kazi.Daemon.start/1`), never the released binary, against tmp-scoped
  socket/pidfile paths passed explicitly through `opts` — never the real
  `~/.kazi/daemon/` a developer's machine might already be using.

  `async: false`: real OS sockets and pidfiles are shared, mutable resources
  (not an Ecto sandbox transaction), so tests run serially to avoid flakiness
  from overlapping accept loops / file writes.
  """
  use ExUnit.Case, async: false

  alias Kazi.Daemon
  alias Kazi.Daemon.Probe

  # Short, /tmp-rooted paths -- AF_UNIX socket paths have a small OS-level
  # length cap (~104 bytes on macOS); a nested `System.tmp_dir!()` path (often
  # under /var/folders/... on macOS) can blow that budget, so this deliberately
  # does NOT use `System.tmp_dir!()`.
  defp tmp_paths do
    id = System.unique_integer([:positive])
    {"/tmp/kazi_daemon_test_#{id}.sock", "/tmp/kazi_daemon_test_#{id}.pid"}
  end

  defp unique_name(label), do: :"#{label}_#{System.unique_integer([:positive])}"

  defp daemon_opts(sock_path, pid_path) do
    [
      sock_path: sock_path,
      pid_path: pid_path,
      name: unique_name(:daemon_sup),
      listener_name: unique_name(:daemon_listener)
    ]
  end

  defp expected_vsn do
    case Application.spec(:kazi, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  # Registers the daemon tree under ExUnit's OWN supervisor (the same pattern
  # `Kazi.Coordination.LeaseTableTest` uses) rather than linking it directly
  # to this (ephemeral) test process. `Kazi.Daemon.start/1` is itself an MFA
  # returning `{:ok, pid} | {:error, reason}`, so it slots straight into a
  # raw child spec. This sidesteps a real race: a daemon started directly in
  # the test process makes the test process its proc_lib "parent" -- when the
  # test process exits, the daemon tree tears itself down via that parent-exit
  # link BEFORE `on_exit` runs, so a manual `on_exit`-driven `Supervisor.stop`
  # call can collide with that already-in-flight shutdown.
  defp start_daemon!(sock_path, pid_path) do
    id = unique_name(:daemon)
    start_supervised!(%{id: id, start: {Daemon, :start, [daemon_opts(sock_path, pid_path)]}})
  end

  # ===========================================================================
  # (1) start the tree, connect, ping -- vsn matches Application.spec, uptime
  # present.
  # ===========================================================================

  test "start, connect, ping round-trips the version handshake" do
    {sock_path, pid_path} = tmp_paths()
    start_daemon!(sock_path, pid_path)

    assert File.exists?(sock_path)
    assert File.exists?(pid_path)
    assert File.read!(pid_path) == :os.getpid() |> to_string()

    assert {:ok, resp} = Probe.ping(sock_path)
    assert resp["ok"] == true
    assert resp["vsn"] == expected_vsn()
    assert is_integer(resp["pid"])
    assert is_integer(resp["uptime_s"])
    assert resp["uptime_s"] >= 0
  end

  test "an unknown op replies with a clean error, not a crash" do
    {sock_path, pid_path} = tmp_paths()
    start_daemon!(sock_path, pid_path)

    assert {:ok, resp} = Probe.request(sock_path, %{"op" => "not_a_real_op"})
    assert resp == %{"ok" => false, "error" => "unknown_op"}
  end

  # ===========================================================================
  # (2) shutdown op -- tree terminates, socket + pidfile gone.
  # ===========================================================================

  test "the shutdown op terminates the whole tree and removes socket + pidfile" do
    {sock_path, pid_path} = tmp_paths()
    assert {:ok, sup_pid} = Daemon.start(daemon_opts(sock_path, pid_path))
    ref = Process.monitor(sup_pid)

    assert File.exists?(sock_path)
    assert File.exists?(pid_path)

    assert {:ok, %{"ok" => true}} = Probe.request(sock_path, %{"op" => "shutdown"})

    assert_receive {:DOWN, ^ref, :process, ^sup_pid, _reason}, 2000
    refute File.exists?(sock_path)
    refute File.exists?(pid_path)
  end

  # ===========================================================================
  # (3) status-style connect against a missing socket path errors distinctly
  # from a stale one.
  # ===========================================================================

  test "probing a missing socket path reports :missing, distinct from a stale one" do
    {sock_path, _pid_path} = tmp_paths()

    refute File.exists?(sock_path)
    assert Probe.probe(sock_path) == :missing
    assert {:error, _reason} = Probe.ping(sock_path)
  end

  # ===========================================================================
  # (4) a stale socket file (create the file, no listener) is detected as dead
  # (connect refused) -- the probe helper reports it, and `start/1` (the path
  # `kazi daemon start` calls) cleans it up rather than refusing.
  # ===========================================================================

  test "a stale socket file is detected as dead and start/1 replaces it" do
    {sock_path, pid_path} = tmp_paths()
    File.write!(sock_path, "")

    assert Probe.probe(sock_path) == :dead

    assert Probe.probe(sock_path) !=
             Probe.probe(
               "/tmp/kazi_daemon_test_missing_#{System.unique_integer([:positive])}.sock"
             )

    start_daemon!(sock_path, pid_path)

    assert Probe.probe(sock_path) == :alive
    assert {:ok, %{"ok" => true}} = Probe.ping(sock_path)
  end

  # ===========================================================================
  # (5) double-start against a live socket refuses.
  # ===========================================================================

  test "starting a second daemon against a live socket refuses, naming the vsn" do
    {sock_path, pid_path} = tmp_paths()
    start_daemon!(sock_path, pid_path)

    assert {:error, {:already_running, vsn}} = Daemon.start(daemon_opts(sock_path, pid_path))
    assert vsn == expected_vsn()
  end
end
