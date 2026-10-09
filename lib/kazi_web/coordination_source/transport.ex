defmodule KaziWeb.CoordinationSource.Transport do
  @behaviour KaziWeb.CoordinationSource

  alias Kazi.Coordination.{Lease, LeaseTable, Presence}
  alias KaziWeb.CoordinationSource

  @topic "coordination:lease_map"

  @impl CoordinationSource
  def topic, do: @topic

  @impl CoordinationSource
  def snapshot do
    case Application.get_env(:kazi, :coordination_opts) do
      nil -> native_snapshot()
      opts -> transport_snapshot(opts)
    end
  end

  # With no configured transport, retain the native lease projection.
  defp native_snapshot do
    CoordinationSource.build([], [], LeaseTable.list(lease_table()))
  end

  # The same readable lease registry (and test override) the native source
  # projects, so flipping the default source never hides a native run's leases.
  defp lease_table, do: Application.get_env(:kazi, :native_lease_table, LeaseTable)

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
