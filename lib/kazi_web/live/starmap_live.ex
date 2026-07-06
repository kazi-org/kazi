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

  # The canvas cap (docs/dashboard-design.md "Canvas composition" overflow
  # rule): one node per GOAL (its latest run), newest ~24 on the canvas, the
  # rest a single "+N older" pointer to /goals. Counts stay fleet-wide.
  @canvas_node_cap 24

  defp assign_runs(socket) do
    all_nodes = RunRegistry.list() |> Enum.map(&to_node/1)
    counts = Enum.frequencies_by(all_nodes, & &1.state)

    deduped =
      all_nodes
      |> Enum.group_by(& &1.goal_ref)
      |> Enum.map(fn {_ref, runs} -> Enum.max_by(runs, & &1.heartbeat_at, DateTime) end)
      |> Enum.sort_by(& &1.heartbeat_at, {:desc, DateTime})

    {shown, older} = Enum.split(deduped, @canvas_node_cap)

    socket
    |> assign(:nodes, shown)
    |> assign(:older_count, length(older) + (length(all_nodes) - length(deduped)))
    |> assign(:counts, counts)
  end

  # T46.6: the attention-queue rail, ranked from the same run registry the
  # fleet list above renders.
  defp assign_attention_queue(socket) do
    queue =
      RunRegistry.list()
      |> AttentionQueue.build()
      # One rail entry per goal+signal: repeated runs of the same goal say
      # nothing new to the operator; ranking already put the hottest first.
      |> Enum.uniq_by(&{&1.goal_ref, &1.signal})

    assign(socket, :attention_queue, queue)
  end

  defp to_node(%Run{} = run) do
    state = state(run)

    %{
      run_id: run.run_id,
      goal_ref: run.goal_ref,
      harness: run.harness,
      model: run.model,
      heartbeat_at: run.heartbeat_at,
      state: state,
      sublabel: sublabel(state, run)
    }
  end

  # The mockup's per-node status line ("LANDED · v1.68.0", "STUCK · ITER 9",
  # "STALE · NO HEARTBEAT 4m"): rendered from what the registry row actually
  # knows — state plus heartbeat recency; never fabricated detail.
  defp sublabel(:landed, run), do: "LANDED · #{ago(run.heartbeat_at)}"
  defp sublabel(:converging, _run), do: "CONVERGING · LIVE"

  defp sublabel(:stuck, run),
    do: "#{String.upcase(run.status || "stuck")} · #{ago(run.heartbeat_at)}"

  defp sublabel(:stale, run), do: "STALE · NO HEARTBEAT #{ago(run.heartbeat_at)}"
  defp sublabel(_state, _run), do: nil

  defp ago(nil), do: "?"

  defp ago(%DateTime{} = t) do
    s = DateTime.diff(DateTime.utc_now(), t, :second)

    cond do
      s < 90 -> "#{s}s"
      s < 5400 -> "#{div(s, 60)}m"
      s < 172_800 -> "#{div(s, 3600)}h"
      true -> "#{div(s, 86_400)}d"
    end
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
  # Visual canvas (ADR-0057/docs/dashboard-design.md "Canvas composition",
  # NORMATIVE): the ONE rendering of the fleet — `@bands` when a roadmap is
  # configured, otherwise the flat fleet list folded into a single synthetic
  # frontier — as an SVG wave-band constellation with per-state node classes
  # (the "node state zoo") and session tags on the active
  # (`:converging`/`:claimed`) nodes. There is no separate chip/pill list:
  # `assign_bands/1` and `assign_runs/1` compute state, this is purely its
  # rendering.
  # ---------------------------------------------------------------------------

  @canvas_width 1160
  @canvas_height 742

  defp assign_canvas(socket) do
    canvas_bands =
      cond do
        socket.assigns.bands != [] -> socket.assigns.bands
        socket.assigns.nodes != [] -> state_bands(socket.assigns.nodes)
        true -> []
      end

    band_count = max(length(canvas_bands), 1)
    band_width = @canvas_width / band_count

    placed =
      Enum.flat_map(canvas_bands, fn band ->
        band.nodes
        |> Enum.with_index()
        |> Enum.map(fn {node, row} -> {band.frontier, row, normalize_canvas_node(node)} end)
      end)

    session_tags = build_session_tags(placed)

    rows_per_band =
      placed
      |> Enum.group_by(fn {frontier, _row, _node} -> frontier end)
      |> Map.new(fn {frontier, entries} -> {frontier, length(entries)} end)

    canvas_nodes =
      Enum.map(placed, fn {frontier, row, node} ->
        band_center = frontier * band_width + band_width / 2
        rows = Map.fetch!(rows_per_band, frontier)

        # Vertical spread with a gentle alternating x offset so the
        # constellation reads organic (the mockup's scatter), never a rigid
        # grid. Dense bands (> 7 nodes) split into two sub-columns so labels
        # keep the mockup's breathing room. Deterministic — no randomness
        # (resume-safety).
        {cx, cy} =
          if rows > 7 do
            col = rem(row, 2)
            col_rows = div(rows + 1 - col, 2)
            col_row = div(row, 2)
            cy = @canvas_height * (col_row + 1) / (col_rows + 1) + col * 34
            cx = band_center + if(col == 0, do: -band_width / 4, else: band_width / 4)
            {cx, cy}
          else
            cy = @canvas_height * (row + 1) / (rows + 1)
            cx = band_center + if(rem(row, 2) == 0, do: -32, else: 32)
            {cx, cy}
          end

        Map.merge(node, %{
          frontier: frontier,
          cx: Float.round(cx * 1.0, 1),
          cy: Float.round(cy * 1.0, 1),
          session_tag: Map.get(session_tags, node.id)
        })
      end)

    wave_labels =
      Enum.map(canvas_bands, fn band ->
        %{
          frontier: band.frontier,
          title: band_title(band),
          x: Float.round(band.frontier * band_width + band_width / 2, 1),
          rect_x: Float.round(band.frontier * band_width * 1.0, 1),
          rect_width: Float.round(band_width * 1.0, 1)
        }
      end)

    socket
    |> assign(:canvas_nodes, canvas_nodes)
    |> assign(:canvas_wave_labels, wave_labels)
  end

  # No roadmap configured: derive the wave bands from run state
  # (docs/dashboard-design.md "Canvas composition"): LANDED, then ACTIVE
  # (converging/claimed), then FRONTIER (stuck/stale — where the operator's
  # attention is), then HORIZON (anything pending). Empty bands are dropped
  # and frontiers renumbered so the canvas divides among populated bands.
  defp state_bands(nodes) do
    order = [
      {"LANDED", [:landed]},
      {"ACTIVE", [:converging, :claimed]},
      {"FRONTIER", [:stuck, :stale]},
      {"HORIZON", [:pending]}
    ]

    order
    |> Enum.map(fn {name, states} ->
      %{name: name, nodes: Enum.filter(nodes, &(&1.state in states))}
    end)
    |> Enum.reject(&(&1.nodes == []))
    |> Enum.with_index()
    |> Enum.map(fn {band, i} -> %{frontier: i, name: band.name, nodes: band.nodes} end)
  end

  # "WAVE N · LANDED" per the mockup: state-derived bands carry their name;
  # roadmap bands derive it from the dominant node state within the band.
  defp band_title(%{frontier: frontier} = band) do
    name =
      Map.get(band, :name) ||
        cond do
          Enum.any?(band.nodes, &(&1.state in [:converging, :stuck])) -> "ACTIVE"
          Enum.all?(band.nodes, &(&1.state == :landed)) -> "LANDED"
          Enum.any?(band.nodes, &(&1.state == :claimed)) -> "FRONTIER"
          true -> "HORIZON"
        end

    "WAVE #{frontier + 1} · #{name}"
  end

  # Normalizes a flat fleet node (`run_id`/`goal_ref`) or a band node
  # (`id`/`name`) onto the same shape the canvas draws from.
  defp normalize_canvas_node(node) do
    %{
      id: Map.get(node, :id) || Map.get(node, :run_id),
      label: Map.get(node, :name) || Map.get(node, :goal_ref),
      state: node.state,
      harness: node.harness,
      model: node.model,
      sublabel: Map.get(node, :sublabel) || default_sublabel(node.state)
    }
  end

  # Roadmap band nodes carry no run row; their status line is the state name
  # the mockup uses ("CLAIMED · NEXT", "PENDING · NEEDS deps").
  defp default_sublabel(:claimed), do: "CLAIMED · NEXT"
  defp default_sublabel(:pending), do: "PENDING"
  defp default_sublabel(state), do: state |> to_string() |> String.upcase()

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

        <div
          :if={Enum.any?(@canvas_nodes, & &1.session_tag)}
          id="starmap-sessions"
          class="rail-sessions"
        >
          <div class="section-label">SESSIONS</div>
          <div
            :for={node <- Enum.filter(@canvas_nodes, & &1.session_tag)}
            class="session-row"
            data-session={node.session_tag}
          >
            <span class={"session-id" <> if(node.state == :stuck, do: " red", else: "")}>
              {node.session_tag}
            </span>
            <span class="session-text">
              {node.harness || "agent"} · driving <b>{node.label}</b>
            </span>
          </div>
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

        <p :if={@nodes == []} id="starmap-empty" class="empty-state">
          No runs registered yet. Start a `kazi apply` and it will appear here.
        </p>

        <svg
          :if={@canvas_nodes != []}
          id="starmap-canvas"
          class="starmap-canvas"
          viewBox="0 0 1160 742"
          role="img"
          aria-label="wave-band constellation canvas"
          data-frontiers={length(@canvas_wave_labels)}
        >
          <g
            :for={wl <- @canvas_wave_labels}
            id={"starmap-band-#{wl.frontier}"}
            data-frontier={wl.frontier}
            class="band-group"
          >
            <rect
              class={"band " <> if(rem(wl.frontier, 2) == 0, do: "band-a", else: "band-b")}
              x={wl.rect_x}
              y="0"
              width={wl.rect_width}
              height="742"
            />
            <line
              :if={wl.frontier > 0}
              class="band-sep"
              x1={wl.rect_x}
              y1="0"
              x2={wl.rect_x}
              y2="742"
            />
            <text class="wlabel section-label" text-anchor="middle" x={wl.x} y="30">
              {wl.title}
            </text>
          </g>

          <g
            :for={node <- @canvas_nodes}
            id={"canvas-node-group-#{node.id}"}
            class="canvas-node-group"
            data-node-id={node.id}
            data-frontier={node.frontier}
            data-state={node.state}
          >
            <title :if={node.harness}>{node.harness}{if node.model, do: " / #{node.model}"}</title>
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
            <text class="canvas-node-label" x={node.cx} y={node.cy + 28}>{node.label}</text>
            <text
              :if={node.sublabel}
              class={"canvas-node-sublabel nsub-#{node.state}"}
              x={node.cx}
              y={node.cy + 42}
            >
              {node.sublabel}
            </text>
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

        <.link
          :if={@older_count > 0}
          id="starmap-older"
          navigate={~p"/goals"}
          class="older-link"
        >
          +{@older_count} older
        </.link>
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
        .starmap-canvas { width: 100%; height: calc(100vh - 9.5rem); margin-top: 1rem; display: block; }
        .starmap-canvas .nd-landed { fill: var(--grn); }
        .starmap-canvas .nd-conv { fill: #0A1526; stroke: var(--cyn); stroke-width: 2; }
        .starmap-canvas .nd-stuck { fill: #160D14; stroke: var(--red); stroke-width: 2; }
        .starmap-canvas .nd-claimed { fill: #0B1424; stroke: var(--cyn); stroke-width: 1.5; stroke-dasharray: 4 4; opacity: .85; }
        .starmap-canvas .nd-pending { fill: #0D1626; stroke: #223350; stroke-width: 1.5; }
        .starmap-canvas .nd-stale { fill: #141118; stroke: var(--amb); stroke-width: 1.5; stroke-dasharray: 2 4; }
        .starmap-canvas .ring { fill: none; stroke: var(--cyn); stroke-width: 1.5; transform-box: fill-box; transform-origin: center; }
        .starmap-canvas .ring.redr { stroke: var(--red); }
        .starmap-canvas .band-a { fill: rgba(86,204,242,.028); }
        .starmap-canvas .band-b { fill: transparent; }
        .starmap-canvas .band-sep { stroke: rgba(22,35,58,.8); stroke-width: 1; stroke-dasharray: 2 6; }
        .starmap-canvas .wlabel { fill: #3D4F6E; letter-spacing: .32em; }
        .starmap-canvas .canvas-node-label { fill: #D7E4F4; font-size: 12px; font-weight: 700; text-anchor: middle; }
        .starmap-canvas .stag { fill: var(--cyn); font-size: 10px; font-weight: 700; }

        .event-river { flex: 0 0 100%; height: 38px; background: rgba(10,17,32,.92); border-top: 1px solid var(--line); display: flex; align-items: center; gap: 1rem; padding: 0 1rem; overflow: hidden; }
        .event-river-label { flex: 0 0 auto; }
        .ticker { flex: 1; overflow: hidden; }
        .ticker-track { display: flex; gap: 2rem; white-space: nowrap; width: max-content; }
        .ticker-entry { color: var(--dim); }

        .attention-queue-list { list-style: none; display: flex; flex-direction: column; padding: 0; margin: 0; max-height: 30vh; overflow-y: auto; }
        .attention-item { display: flex; align-items: baseline; gap: .45rem; padding: .45rem 0; border: none; background: transparent; border-bottom: 1px solid rgba(22,35,58,.6); font-size: 11px; line-height: 1.5; }
        .attention-item:last-child { border-bottom: none; }
        .attention-item::before { content: ""; flex: 0 0 auto; width: 7px; height: 7px; border-radius: 50%; align-self: center; }
        .attention-signal-stuck::before { background: var(--red, #FF5C6C); box-shadow: 0 0 8px var(--red, #FF5C6C); }
        .attention-signal-budget::before { background: var(--amb, #FFB454); box-shadow: 0 0 8px var(--amb, #FFB454); }
        .attention-signal-flake_suspicion::before { background: rgba(255,180,84,.7); }
        .attention-signal-regression_recovered::before { background: #46587A; }
        .attention-goal { color: var(--txt, #BFD2EA); font-weight: 700; }
        .attention-signal-label, .attention-predicate { color: var(--dim, #46587A); }
        .attention-drillin-link { color: var(--cyn, #56CCF2); text-decoration: none; font-size: 10px; margin-left: auto; flex: 0 0 auto; }
        .attention-drillin-link:hover { text-decoration: underline; }
        .rail-sessions .session-row { display: flex; align-items: center; gap: .6rem; padding: .4rem 0; border-bottom: 1px solid rgba(22,35,58,.6); font-size: 10px; color: var(--dim, #46587A); }
        .rail-sessions .session-row:last-child { border-bottom: none; }
        .rail-sessions .session-id { color: var(--cyn, #56CCF2); border: 1px solid rgba(86,204,242,.4); border-radius: 3px; padding: 1px 6px; font-weight: 700; flex: 0 0 auto; }
        .rail-sessions .session-id.red { color: var(--red, #FF5C6C); border-color: rgba(255,92,108,.5); }
        .rail-sessions .session-text { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .rail-sessions .session-text b { color: var(--txt, #BFD2EA); }
        .fleet-tiles { display: flex; gap: .6rem; flex-wrap: wrap; align-items: stretch; }
        .fleet-tiles .section-label { flex-basis: 100%; }
        .fleet-tile { flex: 1; display: flex; flex-direction: column; align-items: center; gap: .25rem; border: 1px solid var(--line, #16233A); border-radius: 4px; background: rgba(11,20,36,.6); padding: .6rem .4rem; }
        .fleet-tile-value { font-size: 20px; font-weight: 700; line-height: 1; }
        .fleet-tile-label { font-size: 8px; letter-spacing: .18em; color: var(--dim, #46587A); }
        .older-link { position: absolute; right: 1.2rem; bottom: 3.4rem; color: var(--dim, #46587A); font-size: 10px; letter-spacing: .2em; text-decoration: none; }
        .older-link:hover { color: var(--cyn, #56CCF2); }
        .starmap-canvas .canvas-node-sublabel { font-size: 8px; letter-spacing: .22em; text-anchor: middle; }
        .starmap-canvas .nsub-landed { fill: var(--grn, #2EE6A8); }
        .starmap-canvas .nsub-converging { fill: var(--cyn, #56CCF2); }
        .starmap-canvas .nsub-claimed { fill: var(--cyn, #56CCF2); }
        .starmap-canvas .nsub-stuck { fill: var(--red, #FF5C6C); }
        .starmap-canvas .nsub-stale { fill: var(--amb, #FFB454); }
        .starmap-canvas .nsub-pending { fill: #3D4F6E; }
      </style>
    </main>
    """
  end
end
