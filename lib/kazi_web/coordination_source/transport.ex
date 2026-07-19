defmodule KaziWeb.CoordinationSource.Transport do
  @moduledoc """
  The daemon/transport-backed `KaziWeb.CoordinationSource` (T3.6c, T55.3;
  ADR-0011 §3, ADR-0073 §4).

  `KaziWeb.CoordinationSource.select/0` defaults the dashboard to this source
  whenever a kazi daemon is reachable, so `/leases` renders the LIVE bus roster
  instead of the native source's structurally-empty presence. `snapshot/0` has
  two paths:

    * **No `:coordination_opts` configured (the daemon default, T55.3).**
      Presence is the session roster in the daemon's `kazi_sessions` KV bucket —
      the same rows `kazi bus who` lists. Discovery mirrors the bus client:
      probe the control socket (`Kazi.Daemon.Probe`), take `nats_port`/host/token
      from the ping handshake, open a short-lived `Gnat` connection, and READ the
      bucket's contents. Entries older than the session TTL are hidden (the same
      client-side freshness rule `Kazi.Bus.who/1` applies), and each live row
      carries `machine` + a render-ready `last_seen` label. Leases are the
      globally-readable `Kazi.Coordination.LeaseTable` (same table, same
      `:native_lease_table` override as the native source), so a same-node native
      run keeps its lease map when a daemon happens to be up. Any failure — no
      daemon, a hung socket, a handshake without a NATS port, a missing bucket —
      degrades to that section rendering empty; this source NEVER raises
      (the L-0021 invariant: a web read seam must not 500 the dashboard).

    * **`:coordination_opts` configured (the original transport aggregation).**
      Builds the snapshot by asking `Kazi.Coordination.Presence.snapshot/1` for
      presence + work-intent over the configured coordination transport and
      `peek`ing each intended resource on `Kazi.Coordination.Lease` for its
      active holder — unchanged from T3.6c.

  Read-only by contract (ADR-0011, reaffirmed by ADR-0073 §4): this source
  observes the bus and never writes to it — unlike `Kazi.Bus.who/1` it does NOT
  upsert the caller's presence before reading, because the dashboard is an
  observer, not a session. The view only ever calls `snapshot/0` and `topic/0`.
  """

  @behaviour KaziWeb.CoordinationSource

  alias Gnat.Jetstream.API.KV
  alias Kazi.Bus.Provision
  alias Kazi.Coordination.{Lease, LeaseTable, Presence}
  alias Kazi.Daemon.Probe
  alias KaziWeb.CoordinationSource

  @topic "coordination:lease_map"

  @impl CoordinationSource
  def topic, do: @topic

  @impl CoordinationSource
  def snapshot do
    case Application.get_env(:kazi, :coordination_opts) do
      nil -> daemon_snapshot()
      opts -> transport_snapshot(opts)
    end
  end

  # ---------------------------------------------------------------------------
  # The daemon default (T55.3): roster from the daemon KV, leases from the
  # readable LeaseTable. Every failure degrades to an empty section — never a
  # raise, so /leases cannot 500 whatever state the daemon is in.
  # ---------------------------------------------------------------------------

  defp daemon_snapshot do
    CoordinationSource.build(bus_roster(), [], LeaseTable.list(lease_table()))
  end

  # The same readable lease registry (and test override) the native source
  # projects, so flipping the default source never hides a native run's leases.
  defp lease_table, do: Application.get_env(:kazi, :native_lease_table, LeaseTable)

  # The live session roster from the daemon's `kazi_sessions` KV bucket,
  # discovered exactly like a bus client (probe -> ping handshake -> Gnat) but
  # read-only: no presence upsert, no post, no consumer. Returns `[]` on any
  # failure.
  defp bus_roster do
    sock_path = CoordinationSource.daemon_sock_path()

    with :alive <- Probe.probe(sock_path),
         {:ok, %{"nats_port" => port} = pong} when is_integer(port) <- Probe.ping(sock_path),
         {:ok, conn} <- Gnat.start_link(Kazi.Bus.discovered_connect_opts(pong, port)) do
      try do
        roster_entries(conn)
      after
        if Process.alive?(conn), do: Gnat.stop(conn)
      end
    else
      _no_daemon -> []
    end
  rescue
    _error -> []
  catch
    :exit, _reason -> []
  end

  defp roster_entries(conn) do
    case KV.contents(conn, Provision.sessions_bucket()) do
      {:ok, contents} ->
        now = DateTime.utc_now()
        ttl_s = div(Provision.session_ttl_ns(), 1_000_000_000)

        contents
        |> Enum.flat_map(fn {_key, value} -> decode_session(value, now) end)
        |> Enum.filter(&(&1.age_s <= ttl_s))
        |> Enum.map(&presence_entry/1)

      {:error, _reason} ->
        []
    end
  end

  # One KV value -> a decoded roster row, or [] when the entry is unreadable or
  # carries no parseable heartbeat (freshness is then undecidable, so the row is
  # hidden — mirroring `Kazi.Bus.who/1`, which hides rows without a valid age).
  defp decode_session(value, now) do
    with {:ok, %{"session" => session, "ts" => ts} = entry} when is_binary(session) <-
           Jason.decode(value),
         {:ok, seen_at, _offset} <- DateTime.from_iso8601(ts) do
      [
        %{
          session: session,
          machine: entry["machine"],
          seen_at: seen_at,
          age_s: max(DateTime.diff(now, seen_at, :second), 0)
        }
      ]
    else
      _unreadable -> []
    end
  end

  defp presence_entry(row) do
    entry = %{
      instance: row.session,
      announced_at_ms: DateTime.to_unix(row.seen_at, :millisecond),
      last_seen: format_age(row.age_s)
    }

    if is_binary(row.machine), do: Map.put(entry, :machine, row.machine), else: entry
  end

  defp format_age(s) when s < 60, do: "#{s}s ago"
  defp format_age(s), do: "#{div(s, 60)}m ago"

  # ---------------------------------------------------------------------------
  # The configured coordination-transport aggregation (T3.6c, unchanged).
  # ---------------------------------------------------------------------------

  defp transport_snapshot(opts) do
    lease_backend = Keyword.get(opts, :lease_backend, Kazi.Coordination.Lease.Memory)

    {:ok, %Presence.Snapshot{present: present, intents: intents}} = Presence.snapshot(opts)

    leases =
      intents
      |> Enum.map(& &1.resource)
      |> Enum.uniq()
      |> Enum.flat_map(fn key ->
        case lease_backend.peek(key, opts) do
          {:ok, %Lease{} = lease} -> [lease]
          :free -> []
        end
      end)

    CoordinationSource.build(present, intents, leases)
  end
end
