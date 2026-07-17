defmodule KaziWeb.CoordinationSource.TransportTest do
  @moduledoc """
  T55.3 (ADR-0073 §4): the transport-backed source never raises and stays a
  strict superset of the native projection.

  Pre-T55.3, `Transport.snapshot/0` with no `:coordination_opts` raised inside
  the in-memory transport ("requires a :bus handle") and 500'd `/leases` — the
  L-0021 landmine. Now the no-config path is the daemon default: roster from the
  daemon KV (empty here — no daemon), leases from the same readable
  `Kazi.Coordination.LeaseTable` the native source projects, so flipping the
  dashboard default can never hide a same-node native run's leases. The
  configured `:coordination_opts` path (the original T3.6c aggregation) is
  pinned unchanged.
  """
  use ExUnit.Case, async: false

  alias Kazi.Coordination.Lease
  alias Kazi.Coordination.LeaseTable
  alias KaziWeb.CoordinationSource.{Snapshot, Transport}

  setup do
    prev_opts = Application.get_env(:kazi, :coordination_opts)
    prev_table = Application.get_env(:kazi, :native_lease_table)
    prev_sock = Application.get_env(:kazi, :lease_map_daemon_sock)
    Application.delete_env(:kazi, :coordination_opts)

    on_exit(fn ->
      restore(:coordination_opts, prev_opts)
      restore(:native_lease_table, prev_table)
      restore(:lease_map_daemon_sock, prev_sock)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:kazi, key)
  defp restore(key, value), do: Application.put_env(:kazi, key, value)

  defp isolated_table do
    name = :"t553_transport_table_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {LeaseTable, :start_link, [[name: name]]}})
    Application.put_env(:kazi, :native_lease_table, name)
    name
  end

  test "no :coordination_opts + no daemon: empty roster, native leases, NO raise (L-0021)" do
    table = isolated_table()

    :ok =
      LeaseTable.record(
        %Lease{key: "blast:lib/a.ex", holder: "kazi-part-1", revision: 1, expires_at_ms: 30_000},
        table
      )

    # config/test.exs points :lease_map_daemon_sock at a never-existing path.
    assert %Snapshot{present: [], intents: [], leases: leases} = Transport.snapshot()
    assert [%{key: "blast:lib/a.ex", holder: "kazi-part-1"}] = leases
  end

  test "no :coordination_opts + a daemon whose handshake lacks a nats_port degrades to empty" do
    isolated_table()
    sock = Kazi.TestSupport.FakeDaemonSocket.start!(%{"ok" => true})
    Application.put_env(:kazi, :lease_map_daemon_sock, sock)

    # Probe says :alive, ping answers, but there is no NATS to read — the
    # roster section degrades to empty rather than raising or hanging.
    assert %Snapshot{present: [], intents: [], leases: []} = Transport.snapshot()
  end

  test "configured :coordination_opts keep the original transport aggregation" do
    {:ok, bus} = Kazi.Coordination.Transport.Memory.start_link()
    {:ok, store} = Kazi.Coordination.Lease.Memory.start_link()

    opts = [
      transport: Kazi.Coordination.Transport.Memory,
      bus: bus,
      lease_backend: Kazi.Coordination.Lease.Memory,
      store: store,
      now_ms: 1_000
    ]

    :ok = Kazi.Coordination.Presence.announce_presence("kazi-1", opts)
    :ok = Kazi.Coordination.Presence.announce_intent("kazi-1", "lib/auth", opts)
    {:ok, _lease} = Kazi.Coordination.Lease.Memory.acquire("lib/auth", "kazi-1", 30_000, opts)

    Application.put_env(:kazi, :coordination_opts, opts)

    assert %Snapshot{
             present: [%{instance: "kazi-1"}],
             intents: [%{instance: "kazi-1", resource: "lib/auth"}],
             leases: [%{key: "lib/auth", holder: "kazi-1"}]
           } = Transport.snapshot()
  end
end
