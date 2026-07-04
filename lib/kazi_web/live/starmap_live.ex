defmodule KaziWeb.StarmapLive do
  @moduledoc """
  The fleet home view — the **starmap** (T46.5, UC-061, ADR-0057).

  A read-only projection of the run registry (`Kazi.ReadModel.RunRegistry`):
  one node per registered `kazi apply` process, resolved to a display state —

    * `:landed`     — the run's terminal status is `"converged"` (ADR-0055: a
      converged goal that has landed).
    * `:stuck`      — a terminal non-converging status (`"stuck"` /
      `"over_budget"` / `"error"`).
    * `:stale`      — no terminal status and the heartbeat is stale
      (`RunRegistry.stale?/2`) — a crashed or hung process.
    * `:converging` — no terminal status and heartbeating normally.

  plus fleet-wide counts by state. This is the walking-skeleton slice of the
  full starmap (E46/ADR-0057): the wave-band goal-DAG layout, the roadmap
  spine, and the attention queue are later tasks (T46.5's fuller scope,
  T46.6) — this view already gives the operator the fleet at a glance from
  data the registry persists today.

  Pure read projection (ADR-0011 §2): it never mutates a run, a goal, or a
  lease. `mount/3` reads `RunRegistry.list/0` directly; a connected mount also
  polls on a short interval so a status/heartbeat change is visible without a
  manual refresh (projection-only — no PubSub coupling to the loop is
  required for this slice).
  """
  use KaziWeb, :live_view

  alias Kazi.ReadModel.{Run, RunRegistry}

  # Poll interval for picking up registry changes (T46.5 acc: "a verdict change
  # is reflected on refresh without restart"). A LiveView test never waits this
  # long — it triggers the same `handle_info(:tick, ...)` message directly.
  @poll_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_ms)

    {:ok,
     socket
     |> assign(:page_title, "kazi · starmap")
     |> assign_runs()}
  end

  @impl true
  def handle_info(:tick, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_ms)
    {:noreply, assign_runs(socket)}
  end

  defp assign_runs(socket) do
    nodes = RunRegistry.list() |> Enum.map(&to_node/1)
    counts = Enum.frequencies_by(nodes, & &1.state)

    socket
    |> assign(:nodes, nodes)
    |> assign(:counts, counts)
  end

  defp to_node(%Run{} = run) do
    %{
      run_id: run.run_id,
      goal_ref: run.goal_ref,
      harness: run.harness,
      model: run.model,
      state: state(run)
    }
  end

  defp state(%Run{status: "converged"}), do: :landed
  defp state(%Run{status: status}) when status in ["stuck", "over_budget", "error"], do: :stuck

  defp state(%Run{status: "running"} = run) do
    if RunRegistry.stale?(run), do: :stale, else: :converging
  end

  defp state(%Run{}), do: :converging

  @impl true
  def render(assigns) do
    ~H"""
    <main id="starmap">
      <h1>kazi starmap</h1>
      <p>
        Read-only fleet view (ADR-0011 / ADR-0057): every registered `kazi apply` run
        on this machine, at a glance.
      </p>

      <ul id="starmap-counts" class="starmap-counts">
        <li
          :for={s <- ~w(landed converging stale stuck)a}
          data-state={s}
          data-count={Map.get(@counts, s, 0)}
        >
          {s}: {Map.get(@counts, s, 0)}
        </li>
      </ul>

      <ol :if={@nodes != []} id="starmap-nodes" class="starmap-nodes">
        <li
          :for={node <- @nodes}
          id={"starmap-node-#{node.run_id}"}
          data-run-id={node.run_id}
          data-goal-ref={node.goal_ref}
          data-state={node.state}
          class={"starmap-node starmap-state-#{node.state}"}
        >
          <span class="starmap-node-goal">{node.goal_ref}</span>
          <span class="starmap-node-state" data-state={node.state}>{node.state}</span>
          <span :if={node.harness} class="starmap-node-tag">
            {node.harness}<span :if={node.model}>/{node.model}</span>
          </span>
        </li>
      </ol>

      <p :if={@nodes == []} id="starmap-empty" class="empty-state">
        No runs registered yet. Start a `kazi apply` and it will appear here.
      </p>

      <style>
        .starmap-counts { list-style: none; display: flex; gap: 1rem; padding: 0; margin: 1rem 0; }
        .starmap-nodes { list-style: none; display: flex; flex-wrap: wrap; gap: .75rem; padding: 0; }
        .starmap-node { padding: .6rem .8rem; border-radius: .4rem; border: 1px solid rgba(0,0,0,.2); min-width: 9rem; }
        .starmap-state-landed { background: #d8f5d8; }
        .starmap-state-converging { background: #d6e4ff; }
        .starmap-state-stale { background: #ffe0c2; }
        .starmap-state-stuck { background: #ffd9d9; }
      </style>
    </main>
    """
  end
end
