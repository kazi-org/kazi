defmodule Kazi.CLI.DaemonSchemaVsnTest do
  @moduledoc """
  T52.2 (ADR-0068): `kazi daemon status --json` surfaces the daemon's `schema_vsn`
  handshake field. Driven by a fake control socket (`Kazi.TestSupport.FakeDaemonSocket`)
  bound at the CLI's resolved `default_sock_path/0` — no real daemon, no NATS, no
  DB — so this pins the CLI's pass-through of the field, not the daemon's read.

  `async: false`: mutates the process-global `KAZI_STATE_DIR` and binds a real OS
  socket.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.TestSupport.FakeDaemonSocket

  setup do
    # A short, /tmp-rooted state dir: AF_UNIX socket paths cap at ~104 bytes on
    # macOS, and default_sock_path/0 nests `<state>/daemon/daemon.sock`.
    state_dir = "/tmp/kazi_t52_2_#{System.unique_integer([:positive])}"
    previous = System.get_env("KAZI_STATE_DIR")
    System.put_env("KAZI_STATE_DIR", state_dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("KAZI_STATE_DIR", previous),
        else: System.delete_env("KAZI_STATE_DIR")

      File.rm_rf(state_dir)
    end)

    reply = %{
      "ok" => true,
      "vsn" => "dev",
      "uptime_s" => 5,
      "pid" => 4242,
      "schema_vsn" => 20_260_709_210_000
    }

    FakeDaemonSocket.start!(reply, Kazi.Daemon.Supervisor.default_sock_path())
    :ok
  end

  test "daemon status --json shows schema_vsn" do
    output = capture_io(fn -> assert Kazi.CLI.run(["daemon", "status", "--json"], []) == 0 end)

    decoded = Jason.decode!(output)
    assert decoded["schema_vsn"] == 20_260_709_210_000
    assert decoded["vsn"] == "dev"
  end

  test "daemon status (human) names the schema_vsn" do
    output = capture_io(fn -> assert Kazi.CLI.run(["daemon", "status"], []) == 0 end)

    assert output =~ "running"
    assert output =~ "schema_vsn 20260709210000"
  end
end
