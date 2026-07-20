defmodule Kazi.TestSupport.BusPeer do
  @moduledoc """
  Stub daemon control sockets that drive `Kazi.Bus`'s REAL discovery path
  (#1649), promoted here from `Kazi.Bus.RemotePeerDiscoveryTest` (#1644) so
  every bus suite can reach it.

  ## Why this exists

  `Kazi.Bus.with_conn/2` short-circuits to `run(conn, fun, _)` whenever
  `opts[:conn]` is supplied, and every bus test supplied one. So the discovery
  path — `Probe.probe` → `Probe.ping` → `check_protocol_skew` →
  `Gnat.start_link` → `run` — had never been executed by the suite: the most
  failure-prone part of the transport was unreachable BY CONSTRUCTION. A green
  suite over a path the tests cannot enter is not weak evidence, it is none.

  Handing a test one of these socket paths as `sock_path:` (and NO `conn:`)
  forces the real discovery path: the stub answers `ping` with a well-formed
  pong naming a NATS peer, and the bus then genuinely tries to connect to it.

  ## The two peer states

  Discovery can meet two failure modes, which produced the two distinct #1606
  symptoms. They are NOT interchangeable and each is pinned separately:

    * `blackhole/0` — packets are dropped; the connect BLOCKS until a bound
      fires. Uses `192.0.2.1` (TEST-NET-1, RFC 5737), reserved for
      documentation and guaranteed not to route to a real host, so this
      reproduces anywhere and depends on nobody's network.
    * `refusing/0` — the connect is actively REFUSED, fast. This one cannot be
      built from TEST-NET: a reserved address has no listener to refuse, so it
      drops (measured: TEST-NET-1 blocks to the timeout; loopback on a closed
      port refuses in ~90ms). It therefore points at `127.0.0.1` on a port that
      was bound and released, which is deterministic, needs no network at all,
      and leaks nothing.

  Both are local-only and name no real host.
  """

  # TEST-NET-1 (RFC 5737): reserved for documentation, never routed.
  @blackhole_host "192.0.2.1"
  @blackhole_port 4222

  @doc """
  A daemon whose NATS peer BLACKHOLES: the connect blocks until the caller's
  bound fires. Returns the control-socket path to pass as `sock_path:`.
  """
  @spec blackhole() :: Path.t()
  def blackhole do
    daemon(@blackhole_host, @blackhole_port)
  end

  @doc """
  A daemon whose NATS peer REFUSES immediately (loopback, closed port). Returns
  the control-socket path to pass as `sock_path:`.
  """
  @spec refusing() :: Path.t()
  def refusing do
    daemon("127.0.0.1", closed_port())
  end

  @doc """
  A daemon control socket answering `ping` with a well-formed pong that names
  `host`/`port` as the NATS peer — enough for discovery to pass the protocol-skew
  check and genuinely attempt the connection.
  """
  @spec daemon(String.t(), pos_integer()) :: Path.t()
  def daemon(host, port) when is_binary(host) and is_integer(port) do
    Kazi.TestSupport.FakeDaemonSocket.start!(%{
      "ok" => true,
      "bus_vsn" => Kazi.Bus.ProtocolSkew.required_bus_vsn(),
      "nats_port" => port,
      "nats_host" => host
    })
  end

  @doc """
  A TCP port that was bound and immediately released — connecting to it is
  refused rather than dropped. Deterministic and network-free.
  """
  @spec closed_port() :: pos_integer()
  def closed_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end
end
