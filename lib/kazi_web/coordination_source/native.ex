defmodule KaziWeb.CoordinationSource.Native do
  @moduledoc """
  The **non-NATS** `KaziWeb.CoordinationSource`: the lease map for a single-node,
  NATS-free (native) parallel run (the dashboard-lease-map blocker fix).

  The default `KaziWeb.CoordinationSource.Transport` aggregates presence + leases
  over the coordination transport — but the in-memory transport demands a running
  `:bus` handle, so on a native run (no `:coordination_opts`, no NATS) its
  `snapshot/0` raises and `/leases` 500s. The native scheduler does not announce
  presence on a bus at all; it coordinates partitions on per-run in-memory leases,
  recorded into the globally-readable `Kazi.Coordination.LeaseTable`.

  This source reads that table directly. It is the dashboard's **default** source,
  so `/leases` renders out of the box on a native run:

    * `snapshot/0` projects the `LeaseTable`'s active leases into a render-ready
      `%Snapshot{}` — presence/intent are empty (a native run announces neither),
      the lease map is the live native leases. When the table is not running (or
      holds nothing) it returns the EMPTY snapshot rather than raising, so the view
      renders the empty state instead of crashing.
    * `topic/0` is the coordination topic the view subscribes to for live pushes.

  When NATS is wired (multi-node, Slice 3+), set `:lease_map_source` to
  `KaziWeb.CoordinationSource.Transport` in config to read the transport instead.
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
