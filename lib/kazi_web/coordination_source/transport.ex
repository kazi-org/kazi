defmodule KaziWeb.CoordinationSource.Transport do
  @moduledoc """
  The default `KaziWeb.CoordinationSource`: aggregates the live presence/lease map
  from the coordination transport (T3.6c, ADR-0011 §3).

  Builds a `%Snapshot{}` by asking `Kazi.Coordination.Presence.snapshot/1` for the
  current presence + work-intent and `peek`ing each intended resource on
  `Kazi.Coordination.Lease` for its active holder. The intents tell us which
  resource keys are in play; the lease peek tells us who actually holds each — so
  the lease map is the live owner per contended resource. Everything goes through
  the existing coordination seams (transport module + injected clock), so this
  reads the same substrate the reconciler coordinates on without coupling the web
  layer to NATS specifics or to the loop/harness (ADR-0011 §2).

  Configure the transport/lease backend and clock via application env
  (`:coordination_opts`); the defaults match the in-memory doubles so this is
  inert until a real NATS transport is wired in. The view only ever calls
  `snapshot/0` and `topic/0`.
  """

  @behaviour KaziWeb.CoordinationSource

  alias Kazi.Coordination.{Lease, Presence}
  alias KaziWeb.CoordinationSource

  @topic "coordination:lease_map"

  @impl CoordinationSource
  def topic, do: @topic

  @impl CoordinationSource
  def snapshot do
    opts = coordination_opts()
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

  defp coordination_opts do
    Application.get_env(:kazi, :coordination_opts, [])
  end
end
