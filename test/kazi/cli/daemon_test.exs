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
    test "`daemon start`/`stop`/`status` parse to the daemon command" do
      assert {:daemon, "start", [], _opts} = Kazi.CLI.parse(["daemon", "start"])
      assert {:daemon, "stop", [], _opts} = Kazi.CLI.parse(["daemon", "stop"])
      assert {:daemon, "status", [], _opts} = Kazi.CLI.parse(["daemon", "status"])
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

  defp expected_vsn do
    case Application.spec(:kazi, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
