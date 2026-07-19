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

  The source is injectable (ADR-0011 §3) and chosen by
  `KaziWeb.CoordinationSource.select/0` (T55.3, ADR-0073 §4): an explicit
  `:lease_map_source` config override always wins (a LiveView/Playwright test
  points it at a fixture source with no NATS); otherwise the view defaults to
  `KaziWeb.CoordinationSource.Transport` when a kazi daemon is reachable — so
  the presence rail renders the LIVE bus roster (session, machine, last-seen) —
  and falls back to `KaziWeb.CoordinationSource.Native` (the NATS-free source
  that reads the live per-run leases from `Kazi.Coordination.LeaseTable`) when
  no daemon runs, rendering exactly as a single-node native run always has.
  The selected source is observable in the markup (`data-source` on the main
  element). A fresh snapshot pushed on the source topic — e.g. one with a
  released lease dropped — re-renders the map live, and a connected view also
  re-reads its source on a slow poll so roster churn (a session appearing on or
  aging off the bus) shows up without a manual reload.

  When nothing is present and no leases are held the view renders a clear empty
  state.
  """
  use KaziWeb, :live_view

  alias KaziWeb.CoordinationSource
  alias KaziWeb.CoordinationSource.Snapshot

  @impl true
  def mount(_params, _session, socket) do
    source = CoordinationSource.select()

    # Live updates: subscribe to the source's topic on the connected mount only
    # (the static render has no socket to push to). A broadcast carries the fresh
    # snapshot, which we render directly. The refresh tick re-reads the source on
    # a slow poll — the bus roster has no push channel into this node.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kazi.PubSub, source.topic())
      Process.send_after(self(), :refresh, refresh_ms())
    end

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

  @impl true
  def handle_info(:refresh, socket) do
    # Re-SELECT the source each tick so a daemon that starts (or stops) after
    # mount flips the default live. Both selectable production sources share one
    # topic string, and an explicit :lease_map_source override never changes, so
    # the mount-time subscription stays valid across a flip.
    source = CoordinationSource.select()
    Process.send_after(self(), :refresh, refresh_ms())

    {:noreply,
     socket
     |> assign(:source, source)
     |> assign(:snapshot, source.snapshot())}
  end

  # The roster poll interval. Overridable via :lease_map_refresh_ms so a test can
  # observe a refresh without waiting out the production cadence.
  defp refresh_ms, do: Application.get_env(:kazi, :lease_map_refresh_ms, 15_000)

  @impl true
  def render(assigns) do
    ~H"""
    <main id="lease-map" data-source={inspect(@source)}>
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
            <span :if={entry[:machine]} class="machine" data-machine={entry[:machine]}>
              {entry[:machine]}
            </span>
            <span :if={entry[:last_seen]} class="last-seen" data-last-seen={entry[:last_seen]}>
              {entry[:last_seen]}
            </span>
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
