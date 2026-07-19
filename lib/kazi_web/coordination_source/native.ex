defmodule KaziWeb.CoordinationSource.Native do
  @moduledoc """
  The **non-NATS** `KaziWeb.CoordinationSource`: the lease map for a single-node,
  NATS-free (native) parallel run (the dashboard-lease-map blocker fix).

  `KaziWeb.CoordinationSource.Transport` reads the daemon's bus roster (or, when
  `:coordination_opts` is configured, aggregates over the coordination
  transport). The native scheduler announces neither: it coordinates partitions
  on per-run in-memory leases, recorded into the globally-readable
  `Kazi.Coordination.LeaseTable`.

  This source reads that table directly. It is the dashboard's **no-daemon
  fallback** (`KaziWeb.CoordinationSource.select/0` defaults to it whenever no
  kazi daemon control socket probes alive — T55.3, ADR-0073 §4), so `/leases`
  renders out of the box on a native run:

    * `snapshot/0` projects the `LeaseTable`'s active leases into a render-ready
      `%Snapshot{}` — presence/intent are empty (a native run announces neither),
      the lease map is the live native leases. When the table is not running (or
      holds nothing) it returns the EMPTY snapshot rather than raising, so the view
      renders the empty state instead of crashing.
    * `topic/0` is the coordination topic the view subscribes to for live pushes.

  When a kazi daemon is up, `KaziWeb.CoordinationSource.select/0` picks the
  transport-backed source automatically; an explicit `:lease_map_source` config
  still overrides the choice either way (ADR-0011 §3).
  """

  @behaviour KaziWeb.CoordinationSource

  alias Kazi.Coordination.LeaseTable
  alias KaziWeb.CoordinationSource

  @topic "coordination:lease_map"

  @impl CoordinationSource
  def topic, do: @topic

  @impl CoordinationSource
  def snapshot do
    # Native runs announce no presence/intent over a bus; the lease map is the
    # active native leases recorded in the readable LeaseTable. Absent table ⇒ [].
    CoordinationSource.build([], [], LeaseTable.list(table()))
  end

  # The readable lease registry to project. Defaults to the application singleton
  # (`Kazi.Coordination.LeaseTable`); overridable via the `:native_lease_table`
  # application env so a test can point the source at an isolated instance.
  defp table, do: Application.get_env(:kazi, :native_lease_table, LeaseTable)
end
