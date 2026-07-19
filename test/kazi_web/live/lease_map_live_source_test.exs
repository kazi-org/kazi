defmodule KaziWeb.LeaseMapLiveSourceTest do
  @moduledoc """
  T55.3 (ADR-0073 §4, UC-068): `/leases` renders the live bus, not an empty rail.

  Acceptance pinned here:

    * with a stubbed transport snapshot the presence rail renders roster rows —
      session, machine, last-seen;
    * with no daemon the view falls back to the Native source and renders
      today's output unchanged (no crash, no 500);
    * the source choice is observable (the `data-source` attribute carries the
      selected module), not hardcoded — including the daemon-up default flipping
      to the transport-backed source.

  Hermetic: the "daemon" is a bare Unix-socket listener
  (`Kazi.TestSupport.FakeDaemonSocket`); the roster snapshot is the in-memory
  fixture source. No real daemon, no NATS.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.TestSupport.FakeDaemonSocket
  alias KaziWeb.CoordinationFixtureSource, as: Fixture
  alias KaziWeb.CoordinationSource

  setup do
    prev_source = Application.get_env(:kazi, :lease_map_source)
    prev_sock = Application.get_env(:kazi, :lease_map_daemon_sock)
    prev_table = Application.get_env(:kazi, :native_lease_table)
    prev_refresh = Application.get_env(:kazi, :lease_map_refresh_ms)
    Application.delete_env(:kazi, :lease_map_source)

    on_exit(fn ->
      restore(:lease_map_source, prev_source)
      restore(:lease_map_daemon_sock, prev_sock)
      restore(:native_lease_table, prev_table)
      restore(:lease_map_refresh_ms, prev_refresh)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:kazi, key)
  defp restore(key, value), do: Application.put_env(:kazi, key, value)

  defp isolated_table do
    name = :"t553_live_table_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {Kazi.Coordination.LeaseTable, :start_link, [[name: name]]}
    })

    Application.put_env(:kazi, :native_lease_table, name)
    name
  end

  test "a stubbed transport snapshot renders roster rows: session, machine, last-seen",
       %{conn: conn} do
    Application.put_env(:kazi, :lease_map_source, Fixture)

    roster =
      CoordinationSource.build(
        [
          %{
            instance: "session-a",
            announced_at_ms: 1_752_600_000_000,
            machine: "machine-1",
            last_seen: "12s ago"
          },
          %{
            instance: "session-b",
            announced_at_ms: 1_752_600_010_000,
            machine: "machine-2",
            last_seen: "3m ago"
          }
        ],
        [],
        []
      )

    start_supervised!({Fixture, snapshot: roster})

    {:ok, _view, html} = live(conn, ~p"/leases")

    assert html =~ ~s(id="presence-list")
    assert html =~ ~s(id="presence-session-a")
    assert html =~ ~s(data-machine="machine-1")
    assert html =~ ~s(data-last-seen="12s ago")
    assert html =~ ~s(id="presence-session-b")
    assert html =~ ~s(data-machine="machine-2")
    assert html =~ ~s(data-last-seen="3m ago")
    refute html =~ "No instances present"
  end

  test "with a live daemon socket the selected source is Transport, observable in the markup",
       %{conn: conn} do
    isolated_table()
    sock = FakeDaemonSocket.start!(%{"ok" => true})
    Application.put_env(:kazi, :lease_map_daemon_sock, sock)

    {:ok, _view, html} = live(conn, ~p"/leases")

    assert html =~ ~s(data-source="KaziWeb.CoordinationSource.Transport")
    # The fake daemon carries no NATS, so the roster degrades to the honest
    # empty state — rendered, not raised.
    assert html =~ ~s(id="presence-empty")
  end

  test "with no daemon the view falls back to Native and renders today's output unchanged",
       %{conn: conn} do
    table = isolated_table()

    :ok =
      Kazi.Coordination.LeaseTable.record(
        %Kazi.Coordination.Lease{
          key: "blast:lib/a.ex",
          holder: "kazi-part-1",
          revision: 1,
          expires_at_ms: 30_000
        },
        table
      )

    # config/test.exs points the daemon-sock seam at a never-existing path.
    {:ok, _view, html} = live(conn, ~p"/leases")

    assert html =~ ~s(data-source="KaziWeb.CoordinationSource.Native")
    assert html =~ ~s(id="presence-empty")
    assert html =~ "No instances present"
    assert html =~ ~s(id="lease-map-table")
    assert html =~ ~s(data-holder="kazi-part-1")
  end

  test "a connected view re-reads its source on the refresh tick", %{conn: conn} do
    table = isolated_table()
    Application.put_env(:kazi, :lease_map_refresh_ms, 25)

    {:ok, view, html} = live(conn, ~p"/leases")
    assert html =~ ~s(id="lease-map-empty")

    :ok =
      Kazi.Coordination.LeaseTable.record(
        %Kazi.Coordination.Lease{
          key: "blast:lib/b.ex",
          holder: "kazi-part-2",
          revision: 1,
          expires_at_ms: 30_000
        },
        table
      )

    Kazi.TestSupport.Eventually.eventually(fn ->
      assert render(view) =~ ~s(id="lease-blast:lib/b.ex")
    end)
  end
end
