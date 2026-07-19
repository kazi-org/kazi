defmodule Kazi.Bus.DaemonSocketUnresponsiveTest do
  @moduledoc """
  T66.6 (#1579): a bus call must distinguish "no daemon" (no socket file) from
  "socket present but not accepting" (a stale/deaf socket, or a daemon
  alive-but-wedged out of file descriptors). Folding both into `:no_daemon` told
  operators to `kazi daemon start` when a daemon was already there — the wrong fix.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Bus

  @moduletag :tmp_dir

  describe "with_discovered_conn error classification" do
    test "a MISSING socket file is :no_daemon", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "absent.sock")
      refute File.exists?(missing)
      assert {:error, :no_daemon} = Bus.who(sock_path: missing)
    end

    test "a PRESENT-but-not-accepting socket is :daemon_socket_unresponsive", %{tmp_dir: tmp_dir} do
      # A plain file at the socket path: it exists, but nothing is listening, so a
      # connect is refused — Probe classifies it :dead, the alive-but-deaf case.
      dead = Path.join(tmp_dir, "daemon.sock")
      File.write!(dead, "")
      assert File.exists?(dead)
      assert {:error, :daemon_socket_unresponsive} = Bus.who(sock_path: dead)
    end
  end

  describe "CLI rendering (both paths)" do
    setup %{tmp_dir: tmp_dir} do
      prev = System.get_env("KAZI_STATE_DIR")
      System.put_env("KAZI_STATE_DIR", tmp_dir)

      on_exit(fn ->
        if prev,
          do: System.put_env("KAZI_STATE_DIR", prev),
          else: System.delete_env("KAZI_STATE_DIR")
      end)

      :ok
    end

    test "no socket → 'no daemon running'", %{tmp_dir: _tmp_dir} do
      out = capture_io(:stderr, fn -> Kazi.CLI.run(["bus", "who"], []) end)
      assert out =~ "no daemon running"
    end

    test "present-but-deaf socket → a DISTINCT message naming the state + kickstart remedy",
         %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "daemon"))
      File.write!(Path.join([tmp_dir, "daemon", "daemon.sock"]), "")

      out = capture_io(:stderr, fn -> Kazi.CLI.run(["bus", "who"], []) end)

      assert out =~ "not accepting connections"
      refute out =~ "no daemon running"
      assert out =~ "launchctl kickstart -k"
    end
  end
end
