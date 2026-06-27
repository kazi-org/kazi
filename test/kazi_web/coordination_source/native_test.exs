defmodule KaziWeb.CoordinationSource.NativeTest do
  @moduledoc """
  The non-NATS coordination source (the dashboard-lease-map fix): it projects the
  readable `Kazi.Coordination.LeaseTable` into a render-ready snapshot WITHOUT a
  NATS bus, so `/leases` renders on a single-node native run. Asserts the empty
  case (no table / no leases) and the populated projection against an isolated
  table instance pointed to via the `:native_lease_table` env.
  """
  use ExUnit.Case, async: false

  alias Kazi.Coordination.Lease
  alias Kazi.Coordination.LeaseTable
  alias KaziWeb.CoordinationSource.Native
  alias KaziWeb.CoordinationSource.Snapshot

  setup do
    name = :"native_src_table_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {LeaseTable, :start_link, [[name: name]]}})

    prev = Application.get_env(:kazi, :native_lease_table)
    Application.put_env(:kazi, :native_lease_table, name)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:kazi, :native_lease_table, prev),
        else: Application.delete_env(:kazi, :native_lease_table)
    end)

    %{table: name}
  end

  defp lease(key, holder),
    do: %Lease{key: key, holder: holder, revision: 1, expires_at_ms: 30_000}

  test "snapshot is the empty state when no native leases are held (no raise)" do
    assert %Snapshot{present: [], intents: [], leases: []} = Native.snapshot()
  end

  test "projects the table's active leases into the render-ready, sorted lease map", %{
    table: name
  } do
    :ok = LeaseTable.record(lease("blast:lib/b.ex", "agent-2"), name)
    :ok = LeaseTable.record(lease("blast:lib/a.ex", "agent-1"), name)

    assert %Snapshot{present: [], intents: [], leases: leases} = Native.snapshot()

    # Sorted by key, projected to {key, holder, expires_at_ms}.
    assert Enum.map(leases, & &1.key) == ["blast:lib/a.ex", "blast:lib/b.ex"]
    assert Enum.map(leases, & &1.holder) == ["agent-1", "agent-2"]

    # A released lease drops out of the next snapshot.
    :ok = LeaseTable.forget("blast:lib/a.ex", name)
    assert %Snapshot{leases: [%{key: "blast:lib/b.ex"}]} = Native.snapshot()
  end
end
