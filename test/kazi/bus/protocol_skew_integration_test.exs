defmodule Kazi.Bus.ProtocolSkewIntegrationTest do
  @moduledoc """
  T58.2 (#1227): the injected version-skew fixture the task's acceptance
  criteria asks for -- a fake daemon (`Kazi.TestSupport.FakeDaemonSocket`)
  answering `ping` WITHOUT a `bus_vsn` field, exactly as a real pre-T58.2
  daemon binary would (it was compiled before this handshake existed).

  Before this fix: `tell`/`join`/`who` (writes) publish direct-to-NATS and
  never touch this reply at all, so they would proceed straight past this
  fake daemon to a `Gnat.start_link` that then fails for its OWN reasons
  (no real NATS running) -- the skewed-daemon case was invisible. `read`
  (via the control socket) would instead reach a REAL daemon's `unknown_op`
  catch-all -- an opaque error with no version information.

  After this fix: BOTH paths are caught at the identical seam (`ping`'s
  reply, before either a write's `Gnat.start_link` or a read's `read`
  request is attempted), and BOTH surface the same clear
  `{:daemon_protocol_skew, daemon_vsn}` error -- no more asymmetry.

  `async: false`: binds a real OS Unix-domain socket.
  """
  use ExUnit.Case, async: false

  alias Kazi.Bus
  alias Kazi.TestSupport.FakeDaemonSocket

  # Shaped exactly like a real pre-T58.2 daemon's ping reply: every OTHER
  # field a write path needs (nats_port, so `with_discovered_conn/3`'s guard
  # passes and the skew check is what actually stops it) is present; only
  # `bus_vsn` -- introduced by this task -- is absent.
  @old_daemon_pong %{
    "ok" => true,
    "vsn" => "1.150.0",
    "uptime_s" => 5,
    "pid" => 4242,
    "nats_port" => 4222
  }

  setup do
    sock_path = FakeDaemonSocket.start!(@old_daemon_pong)
    %{sock_path: sock_path}
  end

  test "a write (tell) against a skewed daemon fails loud with :daemon_protocol_skew, never reaching NATS",
       %{sock_path: sock_path} do
    assert {:error, {:daemon_protocol_skew, "1.150.0"}} =
             Bus.tell("someone", "hello", sock_path: sock_path)
  end

  test "a write (join) against a skewed daemon fails loud with :daemon_protocol_skew", %{
    sock_path: sock_path
  } do
    assert {:error, {:daemon_protocol_skew, "1.150.0"}} =
             Bus.join("some-team", sock_path: sock_path)
  end

  test "the assembled read against a skewed daemon fails loud with :daemon_protocol_skew, never sending the read op",
       %{sock_path: sock_path} do
    assert {:error, {:daemon_protocol_skew, "1.150.0"}} =
             Bus.read_digest(sock_path: sock_path)
  end

  test "read and write are now SYMMETRIC under skew -- both refuse, neither silently succeeds nor gives an opaque unknown_op",
       %{sock_path: sock_path} do
    write_result = Bus.tell("someone", "hello", sock_path: sock_path)
    read_result = Bus.read_digest(sock_path: sock_path)

    assert {:error, {:daemon_protocol_skew, _}} = write_result
    assert {:error, {:daemon_protocol_skew, _}} = read_result
    assert write_result == read_result
  end

  test "the read op is never issued when the daemon is skewed -- read_request/1's op never reaches the fake socket's second recv",
       %{sock_path: sock_path} do
    # FakeDaemonSocket answers ping AND (if sent) a second "read" request with
    # the SAME fixed line, then closes. If the skew check did not short-circuit
    # before the read, `read_assembled/1` would still see `%{"ok" => true}`
    # with no "digest" key and treat it as a malformed-but-ok reply rather than
    # the skew error -- so asserting the exact error, not just "an error",
    # pins that the short-circuit fired.
    assert Bus.read_digest(sock_path: sock_path) ==
             {:error, {:daemon_protocol_skew, "1.150.0"}}
  end
end
