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
  alias Kazi.Sink.Events
  alias KaziWeb.Starmap.GoalSource

  # Poll interval for picking up registry changes (T46.5 acc: "a verdict change
  # is reflected on refresh without restart"). A LiveView test never waits this
  # long — it triggers the same `handle_info(:tick, ...)` message directly.
  @poll_ms 2_000

  # Bound on how many of the newest fleet-wide events the bottom river ticker
  # carries — a glance, not the full feed (`KaziWeb.EventRiverLive` is that).
  @river_window 12

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_ms)

    {:ok,
     socket
     |> assign(:page_title, "kazi · starmap")
     |> assign_runs()
     |> assign_bands()
     |> assign_attention_queue()
     |> assign_canvas()
     |> assign_river()}
  end

  @impl true
  def handle_info(:tick, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_ms)

    {:noreply,
     socket
     |> assign_runs()
     |> assign_bands()
     |> assign_attention_queue()
     |> assign_canvas()
     |> assign_river()}
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

  # ---------------------------------------------------------------------------
  # Visual canvas (ADR-0057/docs/dashboard-design.md): the SAME nodes as the
  # data-attribute lists above (wave bands when a roadmap is configured,
  # otherwise the flat fleet list folded into a single synthetic frontier),
  # laid out as an SVG wave-band DAG with per-state node classes (the "node
  # state zoo") and session tags on the active (`:converging`/`:claimed`)
  # nodes. Purely a rendering of state already computed by `assign_bands/1`
  # and `assign_runs/1` — no new read.
  # ---------------------------------------------------------------------------

  @frontier_width 220
  @node_row_height 90

  defp assign_canvas(socket) do
    canvas_bands =
      cond do
        socket.assigns.bands != [] -> socket.assigns.bands
        socket.assigns.nodes != [] -> [%{frontier: 0, nodes: socket.assigns.nodes}]
        true -> []
      end

    placed =
      Enum.flat_map(canvas_bands, fn band ->
        band.nodes
        |> Enum.with_index()
        |> Enum.map(fn {node, row} -> {band.frontier, row, normalize_canvas_node(node)} end)
      end)

    session_tags = build_session_tags(placed)

    canvas_nodes =
      Enum.map(placed, fn {frontier, row, node} ->
        Map.merge(node, %{
          frontier: frontier,
          cx: 60 + frontier * @frontier_width,
          cy: 70 + row * @node_row_height,
          session_tag: Map.get(session_tags, node.id)
        })
      end)

    wave_labels =
      Enum.map(canvas_bands, fn band ->
        %{frontier: band.frontier, x: 60 + band.frontier * @frontier_width}
      end)

    socket
    |> assign(:canvas_nodes, canvas_nodes)
    |> assign(:canvas_wave_labels, wave_labels)
  end

  # Normalizes a flat fleet node (`run_id`/`goal_ref`) or a band node
  # (`id`/`name`) onto the same shape the canvas draws from.
  defp normalize_canvas_node(node) do
    %{
      id: Map.get(node, :id) || Map.get(node, :run_id),
      label: Map.get(node, :name) || Map.get(node, :goal_ref),
      state: node.state,
      harness: node.harness,
      model: node.model
    }
  end

  # Session tags (`S1`, `S2`, ...): assigned in canvas order to every node
  # whose state is "active" per the spec's zoo — dispatched-and-running
  # (`:converging`) or eligible-right-now (`:claimed`).
  defp build_session_tags(placed) do
    placed
    |> Enum.filter(fn {_frontier, _row, node} -> node.state in [:converging, :claimed] end)
    |> Enum.with_index(1)
    |> Map.new(fn {{_frontier, _row, node}, n} -> {node.id, "S#{n}"} end)
  end

  # The node-state zoo class (docs/dashboard-design.md): the six states this
  # view can render map onto the spec's `nd-*` SVG/CSS classes.
  defp nd_class(:landed), do: "nd-landed"
  defp nd_class(:converging), do: "nd-conv"
  defp nd_class(:stuck), do: "nd-stuck"
  defp nd_class(:claimed), do: "nd-claimed"
  defp nd_class(:pending), do: "nd-pending"
  defp nd_class(:stale), do: "nd-stale"

  # T47.1's fleet-wide event feed (`Kazi.Sink.Events`), reused here as a
  # small, bounded ticker for the bottom event-river bar — the SAME source
  # `KaziWeb.EventRiverLive` reads, just windowed tighter for a glance.
  defp assign_river(socket) do
    assign(socket, :river_entries, river_entries())
  end

  defp river_entries do
    RunRegistry.list()
    |> Enum.flat_map(&run_river_events/1)
    |> Enum.sort_by(& &1.observed_at, {:desc, DateTime})
    |> Enum.take(@river_window)
    |> Enum.map(&river_label/1)
  end

  defp run_river_events(%Run{events_sink_path: nil}), do: []

  defp run_river_events(%Run{} = run) do
    run.events_sink_path
    |> Events.read()
    |> Enum.map(&river_entry(&1, run))
  end

  defp river_entry(event, run) do
    %{
      goal_ref: event["goal_ref"] || run.goal_ref,
      type: event["type"] || "event",
      observed_at: parse_river_time(event["observed_at"])
    }
  end

  defp parse_river_time(nil), do: DateTime.from_unix!(0)

  defp parse_river_time(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> DateTime.from_unix!(0)
    end
  end

  defp river_label(%{goal_ref: goal_ref, type: type, observed_at: observed_at}) do
    "[#{Calendar.strftime(observed_at, "%H:%M:%S")}] #{goal_ref} · #{type}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="starmap" class="shell">
      <aside id="starmap-rail" class="rail">
        <div class="wordmark display-heading">
          KAZI <span class="cyn">STARMAP</span>
          <span id="starmap-live-badge" class="live-badge">
            <span class="live-dot"></span>LIVE
          </span>
        </div>

        <div id="starmap-fleet-tiles" class="fleet-tiles">
          <div class="section-label">FLEET</div>
          <div class="fleet-tile" data-tile="running">
            <span class="fleet-tile-value nd-conv">{Map.get(@counts, :converging, 0)}</span>
            <span class="fleet-tile-label">RUNNING</span>
          </div>
          <div class="fleet-tile" data-tile="landed">
            <span class="fleet-tile-value nd-landed">{Map.get(@counts, :landed, 0)}</span>
            <span class="fleet-tile-label">LANDED</span>
          </div>
          <div class="fleet-tile" data-tile="stuck">
            <span class="fleet-tile-value nd-stuck">{Map.get(@counts, :stuck, 0)}</span>
            <span class="fleet-tile-label">STUCK</span>
          </div>
        </div>

        <div id="starmap-rail-attention" class="rail-attention">
          <div class="section-label">NEEDS YOU</div>

          <aside
            :if={@attention_queue != []}
            id="attention-queue"
            data-count={length(@attention_queue)}
          >
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

          <p
            :if={@nodes != [] and @attention_queue == []}
            id="attention-queue-empty"
            class="empty-state"
          >
            Nothing needs attention right now.
          </p>
        </div>

        <ul id="starmap-legend" class="legend">
          <li class="section-label">LEGEND</li>
          <li class="legend-item" data-state="landed">
            <span class="legend-dot nd-landed"></span>landed
          </li>
          <li class="legend-item" data-state="converging">
            <span class="legend-dot nd-conv"></span>converging
          </li>
          <li class="legend-item" data-state="stuck">
            <span class="legend-dot nd-stuck"></span>stuck
          </li>
          <li class="legend-item" data-state="claimed">
            <span class="legend-dot nd-claimed"></span>claimed
          </li>
          <li class="legend-item" data-state="pending">
            <span class="legend-dot nd-pending"></span>pending
          </li>
          <li class="legend-item" data-state="stale">
            <span class="legend-dot nd-stale"></span>stale
          </li>
        </ul>
      </aside>

      <div class="canvas-shell">
        <div class="starfield sweep" aria-hidden="true"></div>

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
            class={"starmap-node starmap-state-#{node.state} #{nd_class(node.state)}"}
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
                class={"starmap-node starmap-state-#{node.state} #{nd_class(node.state)}"}
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

        <svg
          :if={@canvas_nodes != []}
          id="starmap-canvas"
          class="starmap-canvas"
          viewBox="0 0 1160 742"
          role="img"
          aria-label="wave-band DAG canvas"
        >
          <text
            :for={wl <- @canvas_wave_labels}
            class="wave-label section-label"
            x={wl.x}
            y="24"
          >
            WAVE {wl.frontier}
          </text>

          <g
            :for={node <- @canvas_nodes}
            class="canvas-node-group"
            data-node-id={node.id}
            data-state={node.state}
          >
            <circle
              :if={node.state in [:converging, :stuck]}
              class={"ring" <> if(node.state == :stuck, do: " redr", else: "")}
              cx={node.cx}
              cy={node.cy}
              r="14"
            />
            <circle
              id={"canvas-node-#{node.id}"}
              class={"canvas-node #{nd_class(node.state)}"}
              data-state={node.state}
              cx={node.cx}
              cy={node.cy}
              r={if node.state == :pending, do: "10", else: "13"}
            />
            <text class="canvas-node-label" x={node.cx} y={node.cy + 26}>{node.label}</text>
            <text
              :if={node.session_tag}
              class="stag"
              data-session-tag={node.session_tag}
              x={node.cx + 18}
              y={node.cy - 16}
            >
              {node.session_tag}
            </text>
          </g>
        </svg>
      </div>

      <div id="starmap-event-river" class="event-river">
        <span class="event-river-label section-label">EVENT RIVER</span>

        <div :if={@river_entries != []} class="ticker">
          <div class="ticker-track">
            <span :for={entry <- @river_entries} class="ticker-entry">{entry}</span>
            <span :for={entry <- @river_entries} class="ticker-entry" aria-hidden="true">
              {entry}
            </span>
          </div>
        </div>

        <p :if={@river_entries == []} id="starmap-event-river-empty" class="empty-state">
          No events yet.
        </p>
      </div>

      <style>
        .shell { display: flex; min-height: 100vh; flex-wrap: wrap; }

        .rail { width: 280px; flex: 0 0 280px; background: var(--rail); border-right: 1px solid var(--line); padding: 1rem; display: flex; flex-direction: column; gap: 1.1rem; }
        .wordmark { font-size: 16px; letter-spacing: .2em; }
        .wordmark .cyn { color: var(--cyn); }
        .live-badge { display: inline-flex; align-items: center; gap: .3rem; color: var(--grn); font-size: 10px; margin-left: .6rem; }
        .live-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--grn); box-shadow: 0 0 6px var(--grn); display: inline-block; }

        .fleet-tiles { display: flex; align-items: center; gap: .8rem; flex-wrap: wrap; }
        .fleet-tile { display: flex; flex-direction: column; align-items: center; }
        .fleet-tile-value { font-size: 20px; font-weight: 700; }
        .fleet-tile-value.nd-conv { color: var(--cyn); }
        .fleet-tile-value.nd-landed { color: var(--grn); }
        .fleet-tile-value.nd-stuck { color: var(--red); }
        .fleet-tile-label { font-size: 9px; letter-spacing: .2em; color: var(--dim); }

        .legend { list-style: none; padding: 0; margin-top: auto; display: flex; flex-direction: column; gap: .35rem; }
        .legend-item { display: flex; align-items: center; gap: .4rem; color: var(--dim); }
        .legend-dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
        .legend-dot.nd-landed { background: var(--grn); }
        .legend-dot.nd-conv { background: #0A1526; border: 2px solid var(--cyn); }
        .legend-dot.nd-stuck { background: #160D14; border: 2px solid var(--red); }
        .legend-dot.nd-claimed { background: #0B1424; border: 1.5px dashed var(--cyn); }
        .legend-dot.nd-pending { background: #0D1626; border: 1.5px solid #223350; }
        .legend-dot.nd-stale { background: #141118; border: 1.5px dotted var(--amb); }

        .canvas-shell { position: relative; flex: 1; min-width: 0; padding: 1rem 1.5rem 3.5rem; }
        .starfield { position: absolute; inset: 0; background-image: radial-gradient(rgba(191,210,234,.25) 1px, transparent 1px); background-size: 48px 48px; opacity: .2; pointer-events: none; }
        .starmap-canvas { width: 100%; height: auto; margin-top: 1rem; }
        .starmap-canvas .nd-landed { fill: var(--grn); }
        .starmap-canvas .nd-conv { fill: #0A1526; stroke: var(--cyn); stroke-width: 2; }
        .starmap-canvas .nd-stuck { fill: #160D14; stroke: var(--red); stroke-width: 2; }
        .starmap-canvas .nd-claimed { fill: #0B1424; stroke: var(--cyn); stroke-width: 1.5; stroke-dasharray: 4 4; opacity: .85; }
        .starmap-canvas .nd-pending { fill: #0D1626; stroke: #223350; stroke-width: 1.5; }
        .starmap-canvas .nd-stale { fill: #141118; stroke: var(--amb); stroke-width: 1.5; stroke-dasharray: 2 4; }
        .starmap-canvas .ring { fill: none; stroke: var(--cyn); stroke-width: 1.5; }
        .starmap-canvas .ring.redr { stroke: var(--red); }
        .starmap-canvas .wave-label { fill: #3D4F6E; letter-spacing: .32em; }
        .starmap-canvas .canvas-node-label { fill: #D7E4F4; font-size: 12px; font-weight: 700; text-anchor: middle; }
        .starmap-canvas .stag { fill: var(--cyn); font-size: 10px; font-weight: 700; }

        .event-river { flex: 0 0 100%; height: 38px; background: rgba(10,17,32,.92); border-top: 1px solid var(--line); display: flex; align-items: center; gap: 1rem; padding: 0 1rem; overflow: hidden; }
        .event-river-label { flex: 0 0 auto; }
        .ticker { flex: 1; overflow: hidden; }
        .ticker-track { display: flex; gap: 2rem; white-space: nowrap; width: max-content; }
        .ticker-entry { color: var(--dim); }

        .starmap-counts { list-style: none; display: flex; gap: 1rem; padding: 0; margin: 1rem 0; }
        .starmap-nodes { list-style: none; display: flex; flex-wrap: wrap; gap: .75rem; padding: 0; }
        .starmap-node { padding: .6rem .8rem; border-radius: .4rem; border: 1px solid var(--line, #16233A); min-width: 9rem; background: #0D1626; color: var(--txt, #BFD2EA); }
        .attention-queue-list { list-style: none; display: flex; flex-direction: column; gap: .5rem; padding: 0; }
        .attention-item { display: flex; align-items: center; gap: .6rem; padding: .5rem .7rem; border-radius: .4rem; border: 1px solid var(--line, #16233A); background: #0B1424; }
        .attention-signal-stuck { background: rgba(255,92,108,.12); border-color: var(--red, #FF5C6C); }
        .attention-signal-budget { background: rgba(255,180,84,.12); border-color: var(--amb, #FFB454); }
        .attention-signal-flake_suspicion { background: rgba(255,180,84,.08); border-color: rgba(255,180,84,.5); }
        .attention-signal-regression_recovered { background: #101A2A; }
        .starmap-state-landed { background: #0B1F18; border-color: var(--grn, #2EE6A8); box-shadow: 0 0 7px rgba(46,230,168,.35); }
        .starmap-state-converging { background: #0A1526; border-color: var(--cyn, #56CCF2); box-shadow: 0 0 7px rgba(86,204,242,.3); }
        .starmap-state-stale { background: #141118; border-color: var(--amb, #FFB454); border-style: dotted; }
        .starmap-state-stuck { background: #160D14; border-color: var(--red, #FF5C6C); box-shadow: 0 0 8px rgba(255,92,108,.35); }
        .starmap-state-claimed { background: #0B1424; border-color: var(--cyn, #56CCF2); border-style: dashed; }
        .starmap-state-pending { background: #0D1626; border-color: #223350; }
        .starmap-band { margin-bottom: 1rem; }
      </style>
    </main>
    """
  end
end
