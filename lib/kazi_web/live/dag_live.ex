defmodule KaziWeb.DagLive do
  @moduledoc """
  The live dependency-DAG dashboard — the "wave" view (T23.7, UC-038, ADR-0011 /
  ADR-0028).

  Renders a goal's `needs`-DAG as it runs: one node per group, color-labelled by
  its live state (**running / ready / blocked / converged**, plus
  pending/stuck/over-budget), the `needs` **edges** between them, and each
  group's **convergence** (how many of its `needs` deps have converged). It is a
  pure READ projection: it asks a `KaziWeb.DagSource` for a render-ready
  `%Kazi.Scheduler.DagSnapshot{}` and subscribes to that source's topic for live
  pushes — it NEVER calls into `Kazi.Scheduler`, `Kazi.Loop`, or `Kazi.Harness.*`
  (ADR-0011 §2). There are no action controls; the view cannot mutate a run.

  The source is injectable (ADR-0011 §3): it defaults to `KaziWeb.DagSource`
  (which serves the last snapshot the scheduler broadcast, via
  `KaziWeb.DagSource.Cache`) but can be overridden via the `:dag_source`
  application env so a LiveView test drives the DAG from a fixture source with no
  scheduler. As the `Kazi.Scheduler.DepScheduler` drives a real run it broadcasts
  a fresh snapshot on each transition; the subscribed view re-renders, so groups
  visibly move ready → running → converged (and blocked sub-DAGs surface) live.

  When no run is active the view renders a clear "no active run" empty state — it
  never fabricates sample nodes.
  """
  use KaziWeb, :live_view

  alias Kazi.Scheduler.DagSnapshot

  @impl true
  def mount(_params, _session, socket) do
    source = source()

    # Live updates: subscribe to the source's topic on the connected mount only
    # (the static render has no socket to push to). A `{:dag_updated, snapshot}`
    # broadcast carries the fresh DAG, which we render directly.
    if connected?(socket), do: Phoenix.PubSub.subscribe(Kazi.PubSub, source.topic())

    {:ok,
     socket
     |> assign(:page_title, "kazi · dependency DAG")
     |> assign(:source, source)
     |> assign(:snapshot, source.snapshot())}
  end

  @impl true
  def handle_info({:dag_updated, %DagSnapshot{} = snapshot}, socket) do
    # A fresh DAG frame landed (a group started / converged / blocked): replace
    # and let LiveView push the minimal diff.
    {:noreply, assign(socket, :snapshot, snapshot)}
  end

  # The injectable DAG source seam (ADR-0011 §3): override in test config to feed
  # the view a fixture source; defaults to the live snapshot cache.
  defp source do
    Application.get_env(:kazi, :dag_source, KaziWeb.DagSource)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="dag">
      <h1>kazi dependency DAG</h1>
      <p>
        Read-only projection of the dependency-graph scheduler (ADR-0011).
        Live-updating: groups move ready → running → converged as the run progresses.
      </p>

      <section :if={@snapshot.nodes != []} id="dag-run" data-goal-ref={@snapshot.goal_ref}>
        <ul id="dag-legend" class="dag-legend">
          <li
            :for={s <- ~w(ready running converged blocked pending stuck over_budget)}
            class={"dag-state-#{s}"}
          >
            {legend_label(s)}
          </li>
        </ul>

        <ol id="dag-nodes" class="dag-nodes">
          <li
            :for={node <- @snapshot.nodes}
            id={"dag-node-#{node.id}"}
            data-group={node.id}
            data-state={node.state}
            class={"dag-node dag-state-#{node.state}"}
          >
            <span class="dag-node-name">{node.name}</span>
            <span class="dag-node-state" data-state={node.state}>{state_label(node.state)}</span>
            <span :if={node.state == :blocked and node.blocked_by} class="dag-node-blocker">
              blocked by {node.blocked_by}
            </span>
            <span
              class="dag-node-convergence"
              data-converged={node.needs_converged}
              data-total={node.needs_total}
            >
              deps {node.needs_converged}/{node.needs_total} converged
            </span>
          </li>
        </ol>

        <section id="dag-edges">
          <h2>Dependencies (needs)</h2>
          <ul :if={@snapshot.edges != []} class="dag-edges">
            <li
              :for={edge <- @snapshot.edges}
              id={"dag-edge-#{edge.from}-#{edge.to}"}
              data-from={edge.from}
              data-to={edge.to}
              class="dag-edge"
            >
              <span class="dag-edge-from">{edge.from}</span>
              <span class="dag-edge-arrow">→</span>
              <span class="dag-edge-to">{edge.to}</span>
            </li>
          </ul>
          <p :if={@snapshot.edges == []} id="dag-edges-empty" class="empty-state">
            No dependency edges — every group is independent (fully parallel).
          </p>
        </section>
      </section>

      <p :if={@snapshot.nodes == []} id="dag-empty" class="empty-state">
        No active run. Start a multi-group goal with `needs` edges and the DAG will appear here, live.
      </p>

      <style>
        .dag-legend, .dag-nodes, .dag-edges { list-style: none; padding: 0; }
        .dag-legend { display: flex; flex-wrap: wrap; gap: .5rem; margin: 1rem 0; }
        .dag-legend li { padding: .15rem .5rem; border-radius: .25rem; font-size: .8rem; }
        .dag-nodes { display: flex; flex-wrap: wrap; gap: .75rem; margin: 1rem 0; }
        .dag-node { padding: .6rem .8rem; border-radius: .4rem; border: 1px solid var(--line, #16233A); min-width: 9rem; display: flex; flex-direction: column; gap: .2rem; background: #0D1626; color: var(--txt, #BFD2EA); }
        .dag-node-name { font-weight: 600; }
        .dag-node-state { font-size: .75rem; text-transform: uppercase; letter-spacing: .03em; }
        .dag-node-convergence { font-size: .75rem; opacity: .8; }
        .dag-node-blocker { font-size: .75rem; color: var(--red, #FF5C6C); }
        .dag-edges { display: flex; flex-direction: column; gap: .2rem; }
        .dag-edge { font-family: monospace; font-size: .85rem; }
        .dag-edge-arrow { opacity: .6; }
        .dag-state-ready { background: #0B1424; border-color: var(--cyn, #56CCF2); border-style: dashed; }
        .dag-state-running { background: #0A1526; border-color: var(--cyn, #56CCF2); box-shadow: 0 0 7px rgba(86,204,242,.3); }
        .dag-state-converged { background: #0B1F18; border-color: var(--grn, #2EE6A8); box-shadow: 0 0 7px rgba(46,230,168,.35); }
        .dag-state-blocked { background: #160D14; border-color: var(--red, #FF5C6C); }
        .dag-state-pending { background: #0D1626; border-color: #223350; }
        .dag-state-stuck { background: #141118; border-color: var(--amb, #FFB454); }
        .dag-state-over_budget { background: #141118; border-color: var(--amb, #FFB454); border-style: dotted; }
      </style>
    </main>
    """
  end

  defp state_label(:over_budget), do: "over budget"
  defp state_label(state), do: Atom.to_string(state)

  defp legend_label("over_budget"), do: "over budget"
  defp legend_label(state), do: state
end
