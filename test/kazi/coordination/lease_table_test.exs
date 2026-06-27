defmodule Kazi.Coordination.LeaseTableTest do
  @moduledoc """
  The readable native-lease registry (the dashboard-lease-map fix): the NATS-free
  lease map source reads the active per-run leases the scheduler records here, so
  `/leases` renders on a single-node run instead of crashing on the NATS transport.

  Asserts record/forget/list against an isolated named instance and the best-effort
  no-op contract when the table is not running (so the lease lifecycle never
  depends on it and a headless run never crashes recording).
  """
  use ExUnit.Case, async: true

  alias Kazi.Coordination.Lease
  alias Kazi.Coordination.LeaseTable

  defp lease(key, holder),
    do: %Lease{key: key, holder: holder, revision: 1, expires_at_ms: 30_000}

  test "records, lists, and forgets held leases on a named instance" do
    name = :"lease_table_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {LeaseTable, :start_link, [[name: name]]}})

    assert LeaseTable.list(name) == []

    :ok = LeaseTable.record(lease("blast:lib/a.ex", "agent-1"), name)
    :ok = LeaseTable.record(lease("blast:lib/b.ex", "agent-2"), name)

    keys = name |> LeaseTable.list() |> Enum.map(& &1.key) |> Enum.sort()
    assert keys == ["blast:lib/a.ex", "blast:lib/b.ex"]

    :ok = LeaseTable.forget("blast:lib/a.ex", name)
    assert name |> LeaseTable.list() |> Enum.map(& &1.key) == ["blast:lib/b.ex"]
  end

  test "re-recording the same key replaces the holder (one entry per resource)" do
    name = :"lease_table_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {LeaseTable, :start_link, [[name: name]]}})

    :ok = LeaseTable.record(lease("blast:lib/a.ex", "agent-1"), name)
    :ok = LeaseTable.record(lease("blast:lib/a.ex", "agent-2"), name)

    assert [%Lease{key: "blast:lib/a.ex", holder: "agent-2"}] = LeaseTable.list(name)
  end

  test "writes/reads are best-effort no-ops when the table is not running" do
    absent = :"lease_table_absent_#{System.unique_integer([:positive])}"

    # No process registered under `absent` — every op is safe and inert.
    assert LeaseTable.list(absent) == []
    assert LeaseTable.record(lease("k", "h"), absent) == :ok
    assert LeaseTable.forget("k", absent) == :ok
    assert LeaseTable.list(absent) == []
  end
end
