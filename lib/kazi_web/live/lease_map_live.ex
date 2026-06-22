defmodule KaziWeb.LeaseMapLive do
  @moduledoc """
  The operator presence + lease map (T3.6c, UC-018, ADR-0011).

  Renders the live coordination substrate: which kazi instances are **present**,
  the per-resource **work-intent** they've announced (`Kazi.Coordination.Presence`,
  T3.1c), and the **active leases** — the resource → holder map that arbitrates
  parallel work (`Kazi.Coordination.Lease`, T3.1a). It is a pure READ projection:
  it asks a `KaziWeb.CoordinationSource` for a snapshot and subscribes to that
  source's topic for live pushes — it NEVER calls into `Kazi.Loop` or
  `Kazi.Harness.*`, and it never touches NATS directly (ADR-0011 §2).

  The source is injectable (ADR-0011 §3): it defaults to
  `KaziWeb.CoordinationSource.Transport` (aggregates over the coordination
  transport) but can be overridden via the `:lease_map_source` application env so a
  LiveView/Playwright test drives the map from a fixture source with no NATS. A
  fresh snapshot pushed on the source topic — e.g. one with a released lease
  dropped — re-renders the map live.

  When nothing is present and no leases are held the view renders a clear empty
  state.
  """
  use KaziWeb, :live_view

  alias KaziWeb.CoordinationSource.Snapshot

  @impl true
  def mount(_params, _session, socket) do
    source = source()

    # Live updates: subscribe to the source's topic on the connected mount only
    # (the static render has no socket to push to). A broadcast carries the fresh
    # snapshot, which we render directly.
    if connected?(socket), do: Phoenix.PubSub.subscribe(Kazi.PubSub, source.topic())

    {:ok,
     socket
     |> assign(:page_title, "kazi · lease map")
     |> assign(:source, source)
     |> assign(:snapshot, source.snapshot())}
  end

  @impl true
  def handle_info({:coordination_updated, %Snapshot{} = snapshot}, socket) do
    # A fresh snapshot landed (e.g. a lease released): replace and let LiveView push
    # the minimal diff.
    {:noreply, assign(socket, :snapshot, snapshot)}
  end

  # The injectable coordination seam (ADR-0011 §3): override in test config to feed
  # the map a fixture source; defaults to the transport aggregator.
  defp source do
    Application.get_env(:kazi, :lease_map_source, KaziWeb.CoordinationSource.Transport)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="lease-map">
      <h1>kazi lease map</h1>
      <p>Read-only projection of coordination presence + leases (ADR-0011). Live-updating.</p>

      <section id="presence">
        <h2>Presence</h2>
        <ul :if={@snapshot.present != []} id="presence-list">
          <li
            :for={entry <- @snapshot.present}
            id={"presence-#{entry.instance}"}
            data-instance={entry.instance}
            class="presence-entry"
          >
            <span class="instance">{entry.instance}</span>
            <span
              :if={intent_for(@snapshot, entry.instance)}
              class="intent"
              data-intent={intent_for(@snapshot, entry.instance)}
            >
              → {intent_for(@snapshot, entry.instance)}
            </span>
          </li>
        </ul>
        <p :if={@snapshot.present == []} id="presence-empty" class="empty-state">
          No instances present.
        </p>
      </section>

      <section id="leases">
        <h2>Active leases</h2>
        <table :if={@snapshot.leases != []} id="lease-map-table">
          <thead>
            <tr>
              <th>Resource</th>
              <th>Holder</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={lease <- @snapshot.leases}
              id={"lease-#{lease.key}"}
              data-key={lease.key}
              class="lease-entry"
            >
              <td class="lease-key">{lease.key}</td>
              <td class="lease-holder" data-holder={lease.holder}>{lease.holder}</td>
            </tr>
          </tbody>
        </table>
        <p :if={@snapshot.leases == []} id="lease-map-empty" class="empty-state">
          No active leases.
        </p>
      </section>
    </main>
    """
  end

  # The resource an instance has announced intent on, if any — rendered next to its
  # presence entry. Intents are unique per {instance, resource}; we show the first
  # for a present instance (an instance typically announces intent on one resource
  # at a time).
  defp intent_for(%Snapshot{intents: intents}, instance) do
    case Enum.find(intents, &(&1.instance == instance)) do
      %{resource: resource} -> resource
      nil -> nil
    end
  end
end
