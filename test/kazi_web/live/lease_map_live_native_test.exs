defmodule KaziWeb.LeaseMapLiveNativeTest do
  @moduledoc """
  Acceptance for the dashboard-lease-map fix: `/leases` RENDERS (no 500) on a
  single-node, NATS-free (native) run through the default
  `KaziWeb.CoordinationSource.Native` source.

  Before the fix the view defaulted to the NATS `Transport` source, whose
  `snapshot/0` raises when no `:bus` is configured (the native default) — so
  `/leases` 500'd. The native source reads the readable `Kazi.Coordination.LeaseTable`
  instead: it renders the empty state with no leases held and the live lease map
  when leases are present, never touching NATS.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.Coordination.Lease
  alias Kazi.Coordination.LeaseTable

  setup do
    # Drive the view through the DEFAULT native source (clear any test override),
    # pointed at an isolated lease table — exactly the NATS-free path.
    name = :"native_live_table_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {LeaseTable, :start_link, [[name: name]]}})

    prev_source = Application.get_env(:kazi, :lease_map_source)
    prev_table = Application.get_env(:kazi, :native_lease_table)
    Application.delete_env(:kazi, :lease_map_source)
    Application.put_env(:kazi, :native_lease_table, name)

    on_exit(fn ->
      if prev_source,
        do: Application.put_env(:kazi, :lease_map_source, prev_source),
        else: Application.delete_env(:kazi, :lease_map_source)

      if prev_table,
        do: Application.put_env(:kazi, :native_lease_table, prev_table),
        else: Application.delete_env(:kazi, :native_lease_table)
    end)

    %{table: name}
  end

  test "renders the empty state on a native run with no leases (no 500)", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/leases")

    assert html =~ ~s(id="lease-map-empty")
    assert html =~ "No active leases"
    assert html =~ ~s(id="presence-empty")
  end

  test "renders the live native lease map when leases are held", %{conn: conn, table: name} do
    :ok =
      LeaseTable.record(
        %Lease{key: "blast:lib/a.ex", holder: "kazi-part-1", revision: 1, expires_at_ms: 30_000},
        name
      )

    {:ok, _view, html} = live(conn, ~p"/leases")

    assert html =~ ~s(id="lease-map-table")
    assert html =~ ~s(id="lease-blast:lib/a.ex")
    assert html =~ ~s(data-holder="kazi-part-1")
  end
end
