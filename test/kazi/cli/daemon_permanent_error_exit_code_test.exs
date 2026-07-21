defmodule Kazi.CLI.DaemonPermanentErrorExitCodeTest do
  @moduledoc """
  #1484 (ADR-0083), defect 2: launchd's `KeepAlive` respawned `kazi daemon
  start` 33,035 times against a PERMANENTLY failing precondition (a stale
  daemon holding the socket) -- a condition no amount of respawning fixes.

  The shipped plist now uses `KeepAlive: {SuccessfulExit: false}`, which only
  restarts a NON-zero exit. This suite pins the CLI half of that fix: the
  `{:error, {:already_running, _vsn}}` path exits **0** (not 1) exactly when
  the process is running UNDER a supervisor (`KAZI_SUPERVISOR`, set by the
  shipped templates) -- so the message is unchanged, only the exit code
  differs, and only under supervision. An unsupervised, hand-run invocation
  is untouched: still exit 1, as every existing script/test expects.

  `inject_opts[:supervisor_env]` is the test seam for
  `Kazi.Daemon.LaunchAgent.supervised?/1` -- no real env var is mutated, so
  this is safe under `async: false` alongside every other daemon-socket test.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.TestSupport.FakeDaemonSocket

  setup do
    state_dir = "/tmp/kazi_t1484_permerr_#{System.unique_integer([:positive])}"
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

  test "unsupervised (no KAZI_SUPERVISOR): already-running still exits 1, message unchanged",
       %{state_dir: state_dir} do
    sock = Path.join([state_dir, "daemon", "daemon.sock"])
    FakeDaemonSocket.start!(%{"ok" => true, "vsn" => "1.221.0"}, sock)

    out =
      capture_io(:stderr, fn ->
        assert Kazi.CLI.run(["daemon", "start", "--nats-host", "127.0.0.1"],
                 supervisor_env: %{}
               ) == 1
      end)

    assert out =~ "daemon already running"
  end

  test "supervised (KAZI_SUPERVISOR=launchd): already-running exits 0, SAME message",
       %{state_dir: state_dir} do
    sock = Path.join([state_dir, "daemon", "daemon.sock"])
    FakeDaemonSocket.start!(%{"ok" => true, "vsn" => "1.221.0"}, sock)

    out =
      capture_io(:stderr, fn ->
        assert Kazi.CLI.run(["daemon", "start", "--nats-host", "127.0.0.1"],
                 supervisor_env: %{"KAZI_SUPERVISOR" => "launchd"}
               ) == 0
      end)

    assert out =~ "daemon already running"
  end

  test "supervised (KAZI_SUPERVISOR=systemd): already-running also exits 0", %{
    state_dir: state_dir
  } do
    sock = Path.join([state_dir, "daemon", "daemon.sock"])
    FakeDaemonSocket.start!(%{"ok" => true, "vsn" => "1.221.0"}, sock)

    out =
      capture_io(:stderr, fn ->
        assert Kazi.CLI.run(["daemon", "start", "--nats-host", "127.0.0.1"],
                 supervisor_env: %{"KAZI_SUPERVISOR" => "systemd"}
               ) == 0
      end)

    assert out =~ "daemon already running"
  end

  test "an unrecognized KAZI_SUPERVISOR value is never treated as supervised (exit 1)", %{
    state_dir: state_dir
  } do
    sock = Path.join([state_dir, "daemon", "daemon.sock"])
    FakeDaemonSocket.start!(%{"ok" => true, "vsn" => "1.221.0"}, sock)

    capture_io(:stderr, fn ->
      assert Kazi.CLI.run(["daemon", "start", "--nats-host", "127.0.0.1"],
               supervisor_env: %{"KAZI_SUPERVISOR" => "bogus"}
             ) == 1
    end)
  end

  test "--json envelope is unchanged; only the exit code differs", %{state_dir: state_dir} do
    sock = Path.join([state_dir, "daemon", "daemon.sock"])
    FakeDaemonSocket.start!(%{"ok" => true, "vsn" => "1.221.0"}, sock)

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(["daemon", "start", "--nats-host", "127.0.0.1", "--json"],
                 supervisor_env: %{"KAZI_SUPERVISOR" => "launchd"}
               ) == 0
      end)

    decoded = Jason.decode!(String.trim(out))
    assert decoded["error"] =~ "daemon already running"
  end
end
