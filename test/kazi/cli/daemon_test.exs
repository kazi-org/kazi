defmodule Kazi.CLI.DaemonTest do
  @moduledoc """
  T51.1 (ADR-0067 decision point 1): the `kazi daemon start|stop|status` verb
  at the CLI boundary -- argv parsing plus the real `status`/`stop` entry
  points against a tmp-scoped `KAZI_STATE_DIR` (never a developer's real
  `~/.kazi/daemon/`). Mirrors `Kazi.CLI.DashboardTest`'s two-tier shape.

  `async: false`: mutates the process-global `KAZI_STATE_DIR` env var and
  talks to a real OS socket.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Daemon
  alias Kazi.TestSupport.NatsPrereq

  # ===========================================================================
  # Tier 1 -- the argv boundary
  # ===========================================================================

  describe "parse/1 -- the daemon verb" do
    test "`daemon start`/`stop`/`status`/`restart`/`reregister` parse to the daemon command" do
      assert {:daemon, "start", [], _opts} = Kazi.CLI.parse(["daemon", "start"])
      assert {:daemon, "stop", [], _opts} = Kazi.CLI.parse(["daemon", "stop"])
      assert {:daemon, "status", [], _opts} = Kazi.CLI.parse(["daemon", "status"])
      assert {:daemon, "restart", [], _opts} = Kazi.CLI.parse(["daemon", "restart"])
      # #1484/ADR-0083: re-pins a stale launchd LWCR against the current binary.
      assert {:daemon, "reregister", [], _opts} = Kazi.CLI.parse(["daemon", "reregister"])
    end

    test "--json is threaded through" do
      assert {:daemon, "status", [], opts} = Kazi.CLI.parse(["daemon", "status", "--json"])
      assert opts[:json] == true
    end

    test "an unknown subcommand is a clear usage error" do
      assert {:error, message} = Kazi.CLI.parse(["daemon", "nope"])
      assert message =~ "unknown daemon subcommand"
    end

    test "no subcommand is a clear usage error" do
      assert {:error, message} = Kazi.CLI.parse(["daemon"])
      assert message =~ "requires a <subcommand>"
    end

    test "an unexpected positional argument is a usage error" do
      assert {:error, message} = Kazi.CLI.parse(["daemon", "status", "extra"])
      assert message =~ "unexpected argument"
    end
  end

  describe "help --json" do
    test "the daemon command is listed in the generated command surface" do
      json_output = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"], []) == 0 end)

      decoded = Jason.decode!(json_output)
      names = Enum.map(decoded["commands"], & &1["name"])
      assert "daemon" in names
    end
  end

  # ===========================================================================
  # Tier 2 -- the real `kazi daemon status|stop` entry points
  # ===========================================================================

  describe "kazi daemon status|stop -- no daemon running" do
    setup do
      state_dir =
        Path.join(System.tmp_dir!(), "kazi_cli_daemon_test_#{System.unique_integer([:positive])}")

      previous = System.get_env("KAZI_STATE_DIR")
      System.put_env("KAZI_STATE_DIR", state_dir)

      on_exit(fn ->
        if previous,
          do: System.put_env("KAZI_STATE_DIR", previous),
          else: System.delete_env("KAZI_STATE_DIR")
      end)

      :ok
    end

    test "status against a missing socket reports a clear error and exits 1" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["daemon", "status"], []) == 1
        end)

      assert output =~ "no daemon running"
    end

    test "stop against a missing socket reports a clear error and exits 1" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["daemon", "stop"], []) == 1
        end)

      assert output =~ "no daemon running"
    end

    test "status --json against a missing socket emits a JSON error envelope" do
      output =
        capture_io(fn ->
          assert Kazi.CLI.run(["daemon", "status", "--json"], []) == 1
        end)

      decoded = Jason.decode!(output)
      assert decoded["error"] =~ "no daemon running"
    end

    test "restart against a missing socket errors clearly and exits 1 (T52.4)" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["daemon", "restart"], []) == 1
        end)

      assert output =~ "no daemon running to restart"
    end
  end

  describe "kazi daemon status -- a live daemon" do
    setup do
      NatsPrereq.ensure!()

      state_dir =
        Path.join(
          System.tmp_dir!(),
          "kazi_cli_daemon_live_test_#{System.unique_integer([:positive])}"
        )

      previous = System.get_env("KAZI_STATE_DIR")
      System.put_env("KAZI_STATE_DIR", state_dir)

      on_exit(fn ->
        if previous,
          do: System.put_env("KAZI_STATE_DIR", previous),
          else: System.delete_env("KAZI_STATE_DIR")
      end)

      # Start the daemon at the SAME paths `Kazi.Daemon.Supervisor` resolves
      # to given the KAZI_STATE_DIR just set, so the CLI's real (unopinionated)
      # path resolution reaches our test daemon.
      sock_path = Kazi.Daemon.Supervisor.default_sock_path()
      pid_path = Kazi.Daemon.Supervisor.default_pid_path()
      id = System.unique_integer([:positive])

      start_supervised!(%{
        id: :"cli_daemon_#{id}",
        start:
          {Daemon, :start,
           [
             [
               sock_path: sock_path,
               pid_path: pid_path,
               name: :"cli_daemon_sup_#{id}",
               listener_name: :"cli_daemon_listener_#{id}"
             ]
           ]}
      })

      :ok
    end

    test "reports the version handshake under --json" do
      output = capture_io(fn -> assert Kazi.CLI.run(["daemon", "status", "--json"], []) == 0 end)

      decoded = Jason.decode!(output)
      assert decoded["ok"] == true
      assert decoded["vsn"] == expected_vsn()
      assert is_integer(decoded["pid"])
    end

    test "reports the version handshake human-readably" do
      output = capture_io(fn -> assert Kazi.CLI.run(["daemon", "status"], []) == 0 end)

      assert output =~ "running"
      assert output =~ expected_vsn()
    end

    test "stop shuts the daemon down cleanly" do
      output = capture_io(fn -> assert Kazi.CLI.run(["daemon", "stop"], []) == 0 end)
      assert output =~ "stopped"

      # A second stop now reports the down state, never a crash. Depending on
      # whether the socket file lost its race with the listener's own cleanup,
      # the CLI reports either "no daemon running (no socket at ...)" or
      # "daemon was not running (stale socket ... cleaned up)" -- both are the
      # down state, so accept either racy phrasing instead of pinning one.
      output2 = capture_io(:stderr, fn -> assert Kazi.CLI.run(["daemon", "stop"], []) == 1 end)
      assert output2 =~ "no daemon running" or output2 =~ "was not running"
    end
  end

  describe "kazi daemon restart -- a live daemon (T52.4)" do
    setup do
      NatsPrereq.ensure!()

      state_dir =
        Path.join(
          System.tmp_dir!(),
          "kazi_cli_daemon_restart_test_#{System.unique_integer([:positive])}"
        )

      previous = System.get_env("KAZI_STATE_DIR")
      System.put_env("KAZI_STATE_DIR", state_dir)

      on_exit(fn ->
        # Best-effort teardown of whatever daemon is holding the socket at the
        # end (the fresh one `restart` stood up), then restore the env.
        sock_path = Kazi.Daemon.Supervisor.default_sock_path()
        Kazi.Daemon.Probe.request(sock_path, %{"op" => "shutdown"})

        if previous,
          do: System.put_env("KAZI_STATE_DIR", previous),
          else: System.delete_env("KAZI_STATE_DIR")
      end)

      sock_path = Kazi.Daemon.Supervisor.default_sock_path()
      pid_path = Kazi.Daemon.Supervisor.default_pid_path()
      id = System.unique_integer([:positive])

      # The INITIAL daemon, at the same paths the CLI resolves. Explicit isolated
      # nats port + store so this test never touches a real machine bus.
      {:ok, old_sup} =
        Daemon.start(
          sock_path: sock_path,
          pid_path: pid_path,
          name: :"restart_old_sup_#{id}",
          listener_name: :"restart_old_listener_#{id}",
          store_dir: Path.join(state_dir, "js_old"),
          port: 30_000 + rem(id, 20_000)
        )

      %{sock_path: sock_path, old_sup: old_sup, port2: 30_000 + rem(id + 1, 20_000)}
    end

    test "restart stops the running daemon and stands up a fresh one on the same socket", %{
      sock_path: sock_path,
      old_sup: old_sup,
      port2: port2
    } do
      assert Process.alive?(old_sup)
      assert Kazi.Daemon.Probe.probe(sock_path) == :alive

      # Inject a non-blocking wait so the foreground `start` inside `restart`
      # returns instead of parking the test on the running daemon.
      output =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["daemon", "restart", "--nats-port", Integer.to_string(port2)],
                   daemon_wait: fn _pid -> :ok end
                 ) == 0
        end)

      assert output =~ "listening"

      # The OLD tree is gone and a fresh daemon answers on the re-bound socket.
      refute Process.alive?(old_sup)
      assert Kazi.Daemon.Probe.probe(sock_path) == :alive
      assert {:ok, %{"ok" => true}} = Kazi.Daemon.Probe.ping(sock_path)
    end
  end

  defp expected_vsn do
    case Application.spec(:kazi, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
