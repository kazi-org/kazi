defmodule KaziWeb.LeaseMapLiveTest do
  @moduledoc """
  LiveView test for the presence + lease map (T3.6c, UC-018).

  Drives the view from an injected `KaziWeb.CoordinationFixtureSource` (no NATS,
  no transport) and asserts: injected presence/intent/lease fixtures render as a
  presence list + lease map; a simulated lease *release* — a fresh snapshot pushed
  on the source topic with the lease dropped — removes it from the rendered map;
  and an empty snapshot renders the empty states. Hermetic: the fixture IS the
  snapshot.
  """
  use KaziWeb.ConnCase, async: false

  alias KaziWeb.CoordinationFixtureSource, as: Fixture
  alias KaziWeb.CoordinationSource

  setup do
    # Point the view at the in-memory fixture source for this test, restoring the
    # default afterwards so other tests are unaffected.
    prev = Application.get_env(:kazi, :lease_map_source)
    Application.put_env(:kazi, :lease_map_source, Fixture)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:kazi, :lease_map_source, prev),
        else: Application.delete_env(:kazi, :lease_map_source)
    end)

    :ok
  end

  defp start_fixture(snapshot) do
    start_supervised!({Fixture, snapshot: snapshot})
    :ok
  end

  defp populated_snapshot do
    CoordinationSource.build(
      [
        %{instance: "kazi-1", announced_at_ms: 1_000},
        %{instance: "kazi-2", announced_at_ms: 1_100}
      ],
      [
        %{instance: "kazi-1", resource: "lib/auth", announced_at_ms: 1_000},
        %{instance: "kazi-2", resource: "lib/billing", announced_at_ms: 1_100}
      ],
      [
        %Kazi.Coordination.Lease{
          key: "lib/auth",
          holder: "kazi-1",
          revision: 1,
          expires_at_ms: 31_000
        },
        %Kazi.Coordination.Lease{
          key: "lib/billing",
          holder: "kazi-2",
          revision: 1,
          expires_at_ms: 31_100
        }
      ]
    )
  end

  test "renders the empty state when nothing is present and no leases are held", %{conn: conn} do
    start_fixture(Fixture.empty_snapshot())

    {:ok, _view, html} = live(conn, ~p"/leases")

    assert html =~ ~s(id="presence-empty")
    assert html =~ "No instances present"
    assert html =~ ~s(id="lease-map-empty")
    assert html =~ "No active leases"
    refute html =~ ~s(id="presence-list")
    refute html =~ ~s(id="lease-map-table")
  end

  test "renders injected presence/intent + the active lease map", %{conn: conn} do
    start_fixture(populated_snapshot())

    {:ok, _view, html} = live(conn, ~p"/leases")

    # Presence list with both instances + their announced intent.
    assert html =~ ~s(id="presence-list")
    assert html =~ ~s(id="presence-kazi-1")
    assert html =~ ~s(id="presence-kazi-2")
    assert html =~ ~s(data-intent="lib/auth")
    assert html =~ ~s(data-intent="lib/billing")

    # Lease map: each contended resource → its holder.
    assert html =~ ~s(id="lease-map-table")
    assert html =~ ~s(id="lease-lib/auth")
    assert html =~ ~s(data-holder="kazi-1")
    assert html =~ ~s(id="lease-lib/billing")
    assert html =~ ~s(data-holder="kazi-2")
  end

  test "a simulated lease release updates the rendered map live", %{conn: conn} do
    start_fixture(populated_snapshot())

    {:ok, view, _html} = live(conn, ~p"/leases")

    assert render(view) =~ ~s(id="lease-lib/billing")

    # Simulate releasing the billing lease and kazi-2 leaving: push a fresh
    # snapshot with only kazi-1 present and only its lease held. The subscribed
    # view re-renders from the broadcast.
    released =
      CoordinationSource.build(
        [%{instance: "kazi-1", announced_at_ms: 1_000}],
        [%{instance: "kazi-1", resource: "lib/auth", announced_at_ms: 1_000}],
        [
          %Kazi.Coordination.Lease{
            key: "lib/auth",
            holder: "kazi-1",
            revision: 1,
            expires_at_ms: 31_000
          }
        ]
      )

    :ok = Fixture.put_snapshot(released)

    html = render(view)
    assert html =~ ~s(id="lease-lib/auth")
    refute html =~ ~s(id="lease-lib/billing")
    refute html =~ ~s(id="presence-kazi-2")
  end
end
