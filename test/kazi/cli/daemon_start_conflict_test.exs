defmodule Kazi.CLI.DaemonStartConflictTest do
  @moduledoc """
  T66.6 (#1579): when an old-version daemon still holds the socket and a newer
  `kazi` binary starts, the conflict error must name BOTH versions and the
  force-restart remedy — not a bare "already running" that leaves the operator
  guessing the stale process must be killed first.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.TestSupport.FakeDaemonSocket

  setup do
    # Short /tmp-rooted state dir: AF_UNIX socket paths cap at ~104 bytes.
    state_dir = "/tmp/kazi_t66_conflict_#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.join(state_dir, "daemon"))

    prev = System.get_env("KAZI_STATE_DIR")
    System.put_env("KAZI_STATE_DIR", state_dir)

    on_exit(fn ->
      if prev,
        do: System.put_env("KAZI_STATE_DIR", prev),
        else: System.delete_env("KAZI_STATE_DIR")

      File.rm_rf(state_dir)
    end)

    {:ok, state_dir: state_dir}
  end

  test "daemon start against an OLDER daemon names both versions + the kickstart remedy",
       %{state_dir: state_dir} do
    sock = Path.join([state_dir, "daemon", "daemon.sock"])
    # A live daemon on the socket reporting an OLD version.
    FakeDaemonSocket.start!(%{"ok" => true, "vsn" => "1.221.0"}, sock)

    this_vsn = to_string(Application.spec(:kazi, :vsn))

    # `--nats-host` puts start in connect mode, skipping the nats-server binary
    # resolution, so the probe (which finds the live older daemon) is what
    # decides the outcome — hermetic, no real nats-server.
    out =
      capture_io(:stderr, fn ->
        Kazi.CLI.run(["daemon", "start", "--nats-host", "127.0.0.1"], [])
      end)

    # Both versions named: the running daemon's and this binary's.
    assert out =~ "1.221.0"
    assert out =~ this_vsn
    # The remedy, not a bare bind conflict.
    assert out =~ "kazi daemon restart" or out =~ "launchctl kickstart -k"
    # Not the old, uninformative single-version message.
    refute out == "daemon already running (vsn 1.221.0)"
  end
end
