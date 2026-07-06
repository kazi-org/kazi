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

  plus fleet-wide counts by state. With no roadmap DAG configured
  (`KaziWeb.Starmap.GoalSource`, the default), every run is its own
  "single-goal group" with no declared order — this flat list IS that
  fallback, not a separate mode.

  ## Wave bands (T46.5 remainder)

  When a roadmap ref IS configured (`KaziWeb.Starmap.GoalSource.goal/0`
  returns a `Kazi.Goal.t()` — the ADR-0056 roadmap DAG, one group per
  goal-level dependency), the starmap ADDITIONALLY renders that goal's
  `needs`-DAG in topological wave bands, reusing
  `Kazi.Goal.DepGraph.frontiers/1` — the SAME computation `kazi apply
  --explain` prints, so the bands can never disagree with the schedule a
  `kazi apply --parallel` run would actually take. Each band node's display
  state extends the four above with:

    * `:claimed`  — declared, every `needs` dep converged (the LIVE
      frontier — eligible to dispatch right now), but no run has registered
      for it yet.
    * `:pending`  — declared but still waiting on an unconverged dep (a
      later wave), or a dependent transitively behind a `:stuck`/
      `:over_budget` group (poisoned, folded into `:pending` for the fleet
      glance — see `Kazi.Scheduler.DagSnapshot`'s finer `:blocked`).

  ## Attention queue (T46.6)

  The rail alongside the fleet list: `Kazi.Attention.Queue.build/2` ranks
  what needs the operator across every registered run — stuck (the same
  `Kazi.Loop.StuckDetector` a live loop uses), budget (>=85% of the run's
  declared `max_iterations` consumed), flake suspicion (a predicate whose
  status has flipped more than once), and regression-recovered (a past
  green→red flip whose predicate is back to `:pass`) — from the SAME
  persisted per-iteration history the drill-in heatmap (T46.7) reads. Each
  entry deep-links to that goal's `/goals/:id/drillin`. An empty fleet
  renders no rail (nothing needs attention because nothing is running).

  Pure read projection (ADR-0011 §2): it never mutates a run, a goal, or a
  lease. `mount/3` reads `RunRegistry.list/0` directly; a connected mount also
  polls on a short interval so a status/heartbeat change is visible without a
  manual refresh (projection-only — no PubSub coupling to the loop is
  required for this slice).
  """
  use KaziWeb, :live_view

  alias Kazi.Attention.Queue, as: AttentionQueue
  alias Kazi.Goal
  alias Kazi.Goal.DepGraph
  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Scheduler.DagSnapshot
  alias KaziWeb.Starmap.GoalSource

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
     |> assign_runs()
     |> assign_bands()
     |> assign_attention_queue()}
  end

  @impl true
  def handle_info(:tick, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_ms)

    {:noreply, socket |> assign_runs() |> assign_bands() |> assign_attention_queue()}
  end

  defp assign_runs(socket) do
    nodes = RunRegistry.list() |> Enum.map(&to_node/1)
    counts = Enum.frequencies_by(nodes, & &1.state)

    socket
    |> assign(:nodes, nodes)
    |> assign(:counts, counts)
  end

  # T46.6: the attention-queue rail, ranked from the same run registry the
  # fleet list above renders.
  defp assign_attention_queue(socket) do
    assign(socket, :attention_queue, AttentionQueue.build(RunRegistry.list()))
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

  # ---------------------------------------------------------------------------
  # Wave bands (T46.5 remainder): the roadmap goal's `needs`-DAG laid out as
  # topological frontiers, each group's display state resolved from the LATEST
  # registered run for its `goal_ref` (or `:claimed`/`:pending` when none has
  # started yet). `bands` is `[]` when no roadmap is configured — the flat list
  # above is the whole view, as documented in the moduledoc.
  # ---------------------------------------------------------------------------

  defp assign_bands(socket) do
    case GoalSource.goal() do
      %Goal{} = goal -> assign(socket, :bands, build_bands(goal))
      _none -> assign(socket, :bands, [])
    end
  end

  defp build_bands(%Goal{} = goal) do
    latest_run_by_ref = latest_run_by_goal_ref()

    dep_states =
      Map.new(goal.groups, fn %Goal.Group{id: id} ->
        {id, dep_state(Map.get(latest_run_by_ref, id))}
      end)

    dag_nodes_by_id =
      goal |> DagSnapshot.from(dep_states) |> Map.fetch!(:nodes) |> Map.new(&{&1.id, &1})

    goal
    |> DepGraph.frontiers()
    |> Enum.with_index()
    |> Enum.map(fn {ids, index} ->
      %{
        frontier: index,
        nodes: Enum.map(ids, &band_node(&1, dag_nodes_by_id, latest_run_by_ref))
      }
    end)
  end

  defp latest_run_by_goal_ref do
    # `RunRegistry.list/0` is already ordered `desc: started_at`, so the FIRST
    # run seen per `goal_ref` is the latest one — the one whose state should
    # win when a group has been retried under the same ref.
    RunRegistry.list()
    |> Enum.reduce(%{}, fn run, acc -> Map.put_new(acc, run.goal_ref, run) end)
  end

  # The group's raw `Kazi.Goal.DepGraph` convergence state, from its LATEST
  # registered run — absent → `:pending` (declared, unobserved: the correct
  # DepGraph default for a group nothing has dispatched yet).
  defp dep_state(nil), do: :pending
  defp dep_state(%Run{status: "converged"}), do: :converged

  defp dep_state(%Run{status: status}) when status in ["stuck", "over_budget", "error"],
    do: :stuck

  defp dep_state(%Run{status: "running"}), do: :running
  defp dep_state(%Run{}), do: :pending

  defp band_node(id, dag_nodes_by_id, latest_run_by_ref) do
    dag_node = Map.fetch!(dag_nodes_by_id, id)
    run = Map.get(latest_run_by_ref, id)

    %{
      id: id,
      name: dag_node.name,
      state: band_state(dag_node.state, run),
      run_id: run && run.run_id,
      harness: run && run.harness,
      model: run && run.model
    }
  end

  # Maps a `Kazi.Scheduler.DagSnapshot` display state onto the starmap's
  # fleet-glance vocabulary: `:converged`/`:stuck`/`:over_budget` fold onto
  # the run-registry states already in play (`:landed`/`:stuck`); `:ready`
  # (DepGraph's "eligible right now, undispatched") is the starmap's
  # `:claimed`; `:blocked` (a dependent poisoned by a stuck ancestor) folds
  # into `:pending` — still waiting, from the fleet operator's glance.
  # `:running` needs the ACTUAL run to resolve heartbeat staleness, which
  # `DagSnapshot` (a pure function of the convergence-state map) cannot see.
  defp band_state(:converged, _run), do: :landed
  defp band_state(:stuck, _run), do: :stuck
  defp band_state(:over_budget, _run), do: :stuck
  defp band_state(:ready, _run), do: :claimed
  defp band_state(:blocked, _run), do: :pending
  defp band_state(:pending, _run), do: :pending

  defp band_state(:running, run) do
    if run && RunRegistry.stale?(run), do: :stale, else: :converging
  end

  defp signal_label(:stuck), do: "stuck"
  defp signal_label(:budget), do: "budget"
  defp signal_label(:flake_suspicion), do: "flake suspicion"
  defp signal_label(:regression_recovered), do: "regression recovered"

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

      <section :if={@bands != []} id="starmap-wavebands" data-frontiers={length(@bands)}>
        <h2>Wave bands</h2>
        <div
          :for={band <- @bands}
          id={"starmap-band-#{band.frontier}"}
          data-frontier={band.frontier}
          class="starmap-band"
        >
          <h3>Wave {band.frontier}</h3>
          <ol class="starmap-nodes">
            <li
              :for={node <- band.nodes}
              id={"starmap-band-node-#{node.id}"}
              data-node-id={node.id}
              data-frontier={band.frontier}
              data-state={node.state}
              class={"starmap-node starmap-state-#{node.state}"}
            >
              <span class="starmap-node-goal">{node.name}</span>
              <span class="starmap-node-state" data-state={node.state}>{node.state}</span>
              <span :if={node.harness} class="starmap-node-tag">
                {node.harness}<span :if={node.model}>/{node.model}</span>
              </span>
            </li>
          </ol>
        </div>
      </section>

      <aside :if={@attention_queue != []} id="attention-queue" data-count={length(@attention_queue)}>
        <h2>Attention queue</h2>
        <ol class="attention-queue-list">
          <li
            :for={item <- @attention_queue}
            id={"attention-item-#{item.goal_ref}-#{item.signal}"}
            data-goal-ref={item.goal_ref}
            data-signal={item.signal}
            data-predicate-id={item.predicate_id}
            class={"attention-item attention-signal-#{item.signal}"}
          >
            <span class="attention-signal-label" data-signal={item.signal}>
              {signal_label(item.signal)}
            </span>
            <span class="attention-goal">{item.goal_ref}</span>
            <span :if={item.predicate_id} class="attention-predicate">
              {item.predicate_id}
            </span>
            <.link navigate={~p"/goals/#{item.goal_ref}/drillin"} class="attention-drillin-link">
              drill in
            </.link>
          </li>
        </ol>
      </aside>

      <p :if={@nodes != [] and @attention_queue == []} id="attention-queue-empty" class="empty-state">
        Nothing needs attention right now.
      </p>

      <style>
        .starmap-counts { list-style: none; display: flex; gap: 1rem; padding: 0; margin: 1rem 0; }
        .starmap-nodes { list-style: none; display: flex; flex-wrap: wrap; gap: .75rem; padding: 0; }
        .starmap-node { padding: .6rem .8rem; border-radius: .4rem; border: 1px solid rgba(0,0,0,.2); min-width: 9rem; }
        .attention-queue-list { list-style: none; display: flex; flex-direction: column; gap: .5rem; padding: 0; }
        .attention-item { display: flex; align-items: center; gap: .6rem; padding: .5rem .7rem; border-radius: .4rem; border: 1px solid rgba(0,0,0,.2); }
        .attention-signal-stuck { background: #ffd9d9; }
        .attention-signal-budget { background: #ffe0c2; }
        .attention-signal-flake_suspicion { background: #fff3b0; }
        .attention-signal-regression_recovered { background: #eee; }
        .starmap-state-landed { background: #d8f5d8; }
        .starmap-state-converging { background: #d6e4ff; }
        .starmap-state-stale { background: #ffe0c2; }
        .starmap-state-stuck { background: #ffd9d9; }
        .starmap-state-claimed { background: #fff3b0; }
        .starmap-state-pending { background: #eee; }
        .starmap-band { margin-bottom: 1rem; }
      </style>
    </main>
    """
  end
end
