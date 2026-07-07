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

  ## Edges, sessions, and the slide-over panel (docs/dashboard-design.md)

  With a roadmap configured, the goal's declared `needs` edges also draw as
  connector lines between the placed nodes (cyan-highlighted when either
  endpoint is converging/stuck). Converging, stuck, and claimed nodes carry
  session tags (`S1`, `S2`, ...) mirrored into the rail's SESSIONS section
  (red chip for a stuck session). Clicking a SESSIONS row filters the
  constellation to that session's goal (everything else dims); clicking the
  same row again — or the session ending — clears the filter. The FLEET
  tiles (RUNNING / LANDED / STUCK) filter the same way by state; the two
  filters are mutually exclusive (setting one clears the other). Clicking any
  canvas node — or an attention
  entry — opens the right slide-over drill-in panel: identity chips,
  iteration/budget burn, the predicate-vector DNA strip, the convergence
  heatmap, and a transcript tail, with a "FULL ANALYST VIEW" link to the
  full drill-in page. All of it reads the same projections the full-page
  views read; nothing is fabricated.

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
  alias Kazi.ReadModel.{Iteration, Run, RunRegistry}
  alias Kazi.Scheduler.DagSnapshot
  alias Kazi.Sink.Events
  alias Kazi.Sink.Transcript
  alias KaziWeb.Starmap.GoalSource

  # Poll interval for picking up registry changes (T46.5 acc: "a verdict change
  # is reflected on refresh without restart"). A LiveView test never waits this
  # long — it triggers the same `handle_info(:tick, ...)` message directly.
  @poll_ms 2_000

  # Bound on how many of the newest fleet-wide events the bottom river ticker
  # carries — a glance, not the full feed (`KaziWeb.EventRiverLive` is that).
  @river_window 12

  # The mockup's base canvas height. A band taller than it GROWS the canvas
  # (the viewBox height stretches at @row_pitch per node) and the canvas
  # scrolls vertically inside its shell — nodes never wrap into extra
  # sub-columns, keeping the mockup's one-column-per-band composition and
  # leaving straight sight-lines for the `needs` edges.
  @canvas_min_height 742
  @row_pitch 96

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_ms)

    {:ok,
     socket
     |> assign(:page_title, "kazi · starmap")
     |> assign(:selected_id, nil)
     |> assign(:session_filter, nil)
     |> assign(:state_filter, nil)
     |> assign(:mtab, "map")
     |> assign_runs()
     |> assign_bands()
     |> assign_attention_queue()
     |> assign_canvas()
     |> validate_session_filter()
     |> assign_panel()
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
     |> validate_session_filter()
     |> assign_panel()
     |> assign_river()}
  end

  # Slide-over drill-in panel (docs/dashboard-design.md "Slide-over drill-in
  # panel"): click a canvas node (or an attention entry) to peek that goal's
  # predicate vector, convergence heatmap, and transcript tail without leaving
  # the starmap; the panel refreshes on the same poll tick the canvas does.
  @impl true
  def handle_event("select_node", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_id, id) |> assign_panel()}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, socket |> assign(:selected_id, nil) |> assign_panel()}
  end

  # Session filter: clicking a SESSIONS rail row dims the constellation to
  # that session's goal; clicking the same row again clears the filter. The
  # filter is pinned to the node id (not just the positional S-tag, which can
  # drift to a different goal as states change between ticks). Mutually
  # exclusive with the fleet-tile state filter — setting one clears the other,
  # so the canvas never composes two dimming rules.
  def handle_event("toggle_session_filter", %{"id" => id, "tag" => tag}, socket) do
    filter =
      case socket.assigns.session_filter do
        %{id: ^id} -> nil
        _other -> %{id: id, tag: tag}
      end

    {:noreply, socket |> assign(:session_filter, filter) |> assign(:state_filter, nil)}
  end

  # Fleet-tile state filter: clicking RUNNING / LANDED / STUCK dims every
  # node whose state the tile doesn't count; clicking the active tile again
  # clears it. The state sets mirror the tile counts exactly.
  def handle_event("toggle_state_filter", %{"key" => key}, socket) do
    filter =
      case socket.assigns.state_filter do
        %{key: ^key} -> nil
        _other -> %{key: key, states: tile_states(key)}
      end

    {:noreply, socket |> assign(:state_filter, filter) |> assign(:session_filter, nil)}
  end

  # Mobile bottom-tab bar (docs/dashboard-design.md "Mobile layout"): below
  # the breakpoint the rail's sections become tab panes keyed off `data-mtab`
  # on the shell. The active tab is a server assign so the poll-tick DOM
  # patches preserve it; desktop CSS never reads the attribute.
  def handle_event("set_mtab", %{"tab" => tab}, socket)
      when tab in ~w(map needs sessions more) do
    {:noreply, assign(socket, :mtab, tab)}
  end

  def handle_event("set_mtab", _params, socket), do: {:noreply, socket}

  defp tile_states("running"), do: [:converging]
  defp tile_states("landed"), do: [:landed]
  defp tile_states("stuck"), do: [:stuck]
  defp tile_states(_unknown), do: []

  # A canvas at the base height letterboxes into the viewport exactly as
  # before; only a GROWN canvas (a dense band) switches to natural-height
  # rendering, which is what makes the shell scroll.
  defp canvas_class(height) when height > @canvas_min_height, do: "starmap-canvas tall"
  defp canvas_class(_height), do: "starmap-canvas"

  # A filter whose session ended (the node landed, or its tag was reassigned
  # on a state change) clears itself rather than dimming the whole canvas
  # against a node that no longer carries it.
  defp validate_session_filter(%{assigns: %{session_filter: nil}} = socket), do: socket

  defp validate_session_filter(%{assigns: %{session_filter: %{id: id, tag: tag}}} = socket) do
    if Enum.any?(socket.assigns.canvas_nodes, &(&1.id == id and &1.session_tag == tag)) do
      socket
    else
      assign(socket, :session_filter, nil)
    end
  end

  # One dimming rule at a time (the toggles clear each other): a session
  # filter keeps its node lit; a state filter keeps its tile's states lit.
  # Edges stay lit while either endpoint survives the filter.
  defp dimmed_node?(%{id: id}, _state_filter, node), do: node.id != id

  defp dimmed_node?(nil, %{states: states}, node), do: node.state not in states
  defp dimmed_node?(nil, nil, _node), do: false

  defp dimmed_edge?(%{id: id}, _state_filter, edge),
    do: edge.from != id and edge.to != id

  defp dimmed_edge?(nil, %{states: states}, edge),
    do: edge.from_state not in states and edge.to_state not in states

  defp dimmed_edge?(nil, nil, _edge), do: false

  # The canvas cap (docs/dashboard-design.md "Canvas composition" overflow
  # rule): one node per GOAL (its latest run), newest ~48 on the canvas, the
  # rest a single "+N older" pointer to /goals. Counts stay fleet-wide. The
  # single-column scroll layout carries density the old wrap couldn't, so the
  # cap is a DOM-size bound, not a layout one.
  @canvas_node_cap 48

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
      sublabel: sublabel(state, run),
      session_name: run.session_name,
      workspace: run.workspace
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
      %Goal{} = goal ->
        socket
        |> assign(:bands, build_bands(goal))
        |> assign(:needs_edges, needs_edges(goal))

      _none ->
        socket
        |> assign(:bands, [])
        |> assign(:needs_edges, [])
    end
  end

  # The roadmap goal's declared `needs` edges (docs/dashboard-design.md:
  # "`needs` edges draw as 1.5px lines between group nodes") — dep -> group,
  # the same edges `DepGraph.frontiers/1` topologically sorts. `[]` without a
  # roadmap: the flat fleet fallback declares no order, so drawing lines there
  # would fabricate structure the registry doesn't know.
  defp needs_edges(%Goal{groups: groups}) do
    Enum.flat_map(groups, fn %Goal.Group{id: id, needs: needs} ->
      Enum.map(needs, &%{from: &1, to: id})
    end)
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
      model: run && run.model,
      session_name: run && run.session_name,
      workspace: run && run.workspace
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

    tallest_band = rows_per_band |> Map.values() |> Enum.max(fn -> 0 end)
    canvas_height = max(@canvas_min_height, tallest_band * @row_pitch + 120)

    canvas_nodes =
      Enum.map(placed, fn {frontier, row, node} ->
        band_center = frontier * band_width + band_width / 2
        rows = Map.fetch!(rows_per_band, frontier)

        # One column per band (the mockup's composition): even vertical
        # spread over the full canvas height, with a gentle alternating x
        # offset so the constellation reads organic — never a rigid grid,
        # never a second sub-column. Deterministic (resume-safety).
        cy = canvas_height * (row + 1) / (rows + 1)
        cx = band_center + if(rem(row, 2) == 0, do: -32, else: 32)

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
    |> assign(:canvas_height, canvas_height)
    |> assign(:canvas_edges, canvas_edges(socket.assigns.needs_edges, canvas_nodes))
    |> assign(:canvas_wave_labels, wave_labels)
  end

  # Resolves the roadmap's `needs` edges onto the placed nodes' coordinates.
  # An edge is "active" (cyan per the spec) when either endpoint is live —
  # converging or stuck — so the operator's eye follows the working path.
  # Edges whose endpoint fell off the canvas (the overflow cap) are dropped.
  defp canvas_edges(needs_edges, canvas_nodes) do
    by_id = Map.new(canvas_nodes, &{&1.id, &1})

    Enum.flat_map(needs_edges, fn %{from: from, to: to} ->
      case {by_id[from], by_id[to]} do
        {%{} = a, %{} = b} ->
          [
            %{
              from: from,
              to: to,
              from_state: a.state,
              to_state: b.state,
              x1: a.cx,
              y1: a.cy,
              x2: b.cx,
              y2: b.cy,
              active: a.state in [:converging, :stuck] or b.state in [:converging, :stuck]
            }
          ]

        _missing_endpoint ->
          []
      end
    end)
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
      sublabel: Map.get(node, :sublabel) || default_sublabel(node.state),
      session_name: Map.get(node, :session_name),
      workspace: Map.get(node, :workspace)
    }
  end

  # The SESSIONS row's identity: the operator-assigned name when the run has
  # one, else the harness. The workspace basename rides alongside as the
  # tiebreaker for several sessions driving the same repo.
  defp session_label(node), do: node.session_name || node.harness || "agent"

  defp workspace_base(%{workspace: workspace}) when is_binary(workspace),
    do: Path.basename(workspace)

  defp workspace_base(_node), do: nil

  # Roadmap band nodes carry no run row; their status line is the state name
  # the mockup uses ("CLAIMED · NEXT", "PENDING · NEEDS deps").
  defp default_sublabel(:claimed), do: "CLAIMED · NEXT"
  defp default_sublabel(:pending), do: "PENDING"
  defp default_sublabel(state), do: state |> to_string() |> String.upcase()

  # Session tags (`S1`, `S2`, ...): assigned in canvas order to every node a
  # session is (or was) attached to — dispatched-and-running (`:converging`),
  # wedged (`:stuck` — the mockup's S2, whose rail chip renders red), or
  # eligible-right-now (`:claimed`, the goal the next session picks up).
  # Landed/pending/stale nodes carry no tag, so the SESSIONS rail section
  # lists exactly the sessions the operator can still act on.
  defp build_session_tags(placed) do
    placed
    |> Enum.filter(fn {_frontier, _row, node} ->
      node.state in [:converging, :stuck, :claimed]
    end)
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

  # ---------------------------------------------------------------------------
  # Slide-over drill-in panel (docs/dashboard-design.md "Slide-over drill-in
  # panel"): the selected goal's identity chips, iteration/budget burn,
  # predicate-vector DNA strip, convergence heatmap, and transcript tail —
  # the SAME read paths the full-page views use (`Kazi.ReadModel`'s iteration
  # history like DrillinHeatmapLive, `Kazi.Sink.Transcript` like
  # TranscriptPeekLive), windowed for a peek. Pure read projection.
  # ---------------------------------------------------------------------------

  # How many trailing transcript events the panel tail shows; the full-page
  # transcript peek remains the unbounded view.
  @panel_tail_window 12

  defp assign_panel(%{assigns: %{selected_id: nil}} = socket) do
    assign(socket, :panel, nil)
  end

  defp assign_panel(%{assigns: %{selected_id: id}} = socket) do
    # A canvas node's id is a run_id in the flat fallback and a roadmap group
    # id (== the goal_ref runs register under) in wave-band mode; an attention
    # entry always selects by goal_ref. Resolve either to the goal's latest
    # registered run (`RunRegistry.list/0` is newest-first).
    run = Enum.find(RunRegistry.list(), &(&1.run_id == id or &1.goal_ref == id))
    goal_ref = if run, do: run.goal_ref, else: id

    node =
      Enum.find(socket.assigns.canvas_nodes, &(&1.id == id)) ||
        Enum.find(socket.assigns.canvas_nodes, &(&1.label == goal_ref))

    iterations = drillin_source().list_iterations(goal_ref)

    assign(socket, :panel, %{
      goal_ref: goal_ref,
      node_id: node && node.id,
      state: (node && node.state) || (run && state(run)) || :pending,
      sublabel: node && node.sublabel,
      run: run,
      iterations: iterations,
      transcript: transcript_tail(run)
    })
  end

  # The same injectable read-model seam DrillinHeatmapLive uses (ADR-0011 §3),
  # so a test can drive the panel from a fixture history.
  defp drillin_source do
    Application.get_env(:kazi, :drillin_source, Kazi.ReadModel)
  end

  defp transcript_tail(%Run{transcript_sink_path: path}) when is_binary(path) do
    path |> Transcript.read() |> Enum.take(-@panel_tail_window)
  end

  defp transcript_tail(_run_or_nil), do: []

  defp tail_label(%Run{status: "running"} = run) do
    if RunRegistry.stale?(run) do
      "post-mortem · run ended without terminal status"
    else
      "live"
    end
  end

  defp tail_label(_run_or_nil), do: "post-mortem"

  defp panel_iter([]), do: nil
  defp panel_iter(iterations), do: List.last(iterations).iteration_index

  # Burn fraction of the run's declared iteration budget — the honest budget
  # the registry actually knows (`max_iterations`, T46.6); nil hides the bar.
  defp burn_pct(%{run: %Run{max_iterations: max}, iterations: iterations})
       when is_integer(max) and max > 0 do
    case panel_iter(iterations) do
      nil -> nil
      iter -> min(round((iter + 1) / max * 100), 100)
    end
  end

  defp burn_pct(_panel), do: nil

  defp burn_class(pct) when pct >= 85, do: "burn-hot"
  defp burn_class(pct) when pct >= 70, do: "burn-warn"
  defp burn_class(_pct), do: "burn-ok"

  # T48.4 (ADR-0058 decision 4, UC-064): the honest terminal cause line for a
  # FINISHED run — read straight off the read-model row (`Run.outcome_cause_class`
  # / `Run.outcome_cause_detail`, T48.7/T48.4), since a finished run's process is
  # gone and the loop's in-process `t:Kazi.Loop.result/0` no longer exists. `nil`
  # when no cause was classified (a clean converge, or a stop that is exactly
  # what its status already says — see `Kazi.Loop.CauseClass`), which hides the
  # line entirely.
  defp cause_line(%Run{outcome_cause_class: nil}), do: nil

  defp cause_line(%Run{outcome_cause_class: class, outcome_cause_detail: detail}) do
    "cause: #{class}#{cause_detail_suffix(detail)}"
  end

  defp cause_line(_run), do: nil

  defp cause_detail_suffix(%{"reasons" => reasons})
       when is_map(reasons) and map_size(reasons) > 0 do
    text =
      reasons
      |> Enum.sort_by(fn {id, _reason} -> id end)
      |> Enum.map_join(", ", fn {id, reason} -> "#{id}: #{reason}" end)

    " (#{text})"
  end

  defp cause_detail_suffix(%{"exhausted" => exhausted}) when is_binary(exhausted),
    do: " (#{exhausted})"

  defp cause_detail_suffix(%{"ids" => [_ | _] = ids}), do: " (#{Enum.join(ids, ", ")})"
  defp cause_detail_suffix(_detail), do: ""

  # The DNA strip: the LATEST iteration's predicate vector as stably-ordered
  # squares — the same presentation DrillinHeatmapLive's strip uses.
  defp panel_squares([]), do: []

  defp panel_squares(iterations) do
    iterations
    |> List.last()
    |> Kazi.ReadModel.to_predicate_vector()
    |> Map.fetch!(:results)
    |> Enum.sort_by(fn {pid, _result} -> pid end)
    |> Enum.map(fn {pid, result} -> %{id: pid, status: result.status} end)
  end

  # Heatmap rows: the union of predicate ids across the goal's history, so a
  # predicate introduced mid-run still gets a row (not-evaluated before it
  # existed) — mirrors DrillinHeatmapLive.
  defp panel_predicate_ids(iterations) do
    iterations
    |> Enum.flat_map(fn %Iteration{predicate_vector: vector} -> Map.keys(vector) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp panel_cell_status(predicate_id, %Iteration{predicate_vector: vector}) do
    case Map.get(vector, predicate_id) do
      %{"status" => status} -> status
      nil -> "not_evaluated"
    end
  end

  defp panel_regression_flip?(predicate_id, %Iteration{regressions: regressions} = iteration) do
    Enum.any?(regressions, fn flag ->
      flag["predicate_id"] == predicate_id && flag["red_iteration"] == iteration.iteration_index
    end)
  end

  defp panel_tool_event?(%{"type" => type}) when is_binary(type),
    do: String.starts_with?(type, "tool")

  defp panel_tool_event?(_event), do: false

  defp panel_text_line(%{"type" => "text", "text" => text}), do: text
  defp panel_text_line(event), do: inspect(event)

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
    <main id="starmap" class="shell" data-mtab={@mtab}>
      <aside id="starmap-rail" class="rail">
        <div class="wordmark display-heading">
          KAZI <span class="cyn">STARMAP</span>
          <span id="starmap-live-badge" class="live-badge">
            <span class="live-dot"></span>LIVE
          </span>
        </div>

        <div id="starmap-fleet-tiles" class="fleet-tiles">
          <div class="section-label">FLEET</div>
          <div
            :for={
              {key, state, cls, label} <- [
                {"running", :converging, "nd-conv", "RUNNING"},
                {"landed", :landed, "nd-landed", "LANDED"},
                {"stuck", :stuck, "nd-stuck", "STUCK"}
              ]
            }
            class={"fleet-tile" <>
              if(@state_filter && @state_filter.key == key, do: " active", else: "")}
            data-tile={key}
            phx-click="toggle_state_filter"
            phx-value-key={key}
          >
            <span class={"fleet-tile-value #{cls}"}>{Map.get(@counts, state, 0)}</span>
            <span class="fleet-tile-label">{label}</span>
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
                phx-click="select_node"
                phx-value-id={item.goal_ref}
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
            class={"session-row" <>
              if(@session_filter && @session_filter.id == node.id, do: " active", else: "")}
            data-session={node.session_tag}
            phx-click="toggle_session_filter"
            phx-value-id={node.id}
            phx-value-tag={node.session_tag}
          >
            <span class={"session-id" <> if(node.state == :stuck, do: " red", else: "")}>
              {node.session_tag}
            </span>
            <span class="session-text">
              {session_label(node)} · driving
              <b>{node.label}</b><span
                :if={workspace_base(node)}
                class="session-ws"
              > · {workspace_base(node)}</span>
            </span>
          </div>
        </div>

        <p
          :if={not Enum.any?(@canvas_nodes, & &1.session_tag)}
          id="starmap-sessions-empty"
          class="empty-state msessions-empty"
        >
          No active sessions.
        </p>

        <nav id="starmap-nav" class="rail-nav" aria-label="dashboard views">
          <div class="section-label">VIEWS</div>
          <.link navigate={~p"/goals"}>goal board</.link>
          <.link navigate={~p"/dag"}>dependency dag</.link>
          <.link navigate={~p"/leases"}>lease map</.link>
          <.link navigate={~p"/events"}>event river</.link>
        </nav>

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

        <div :if={@canvas_nodes != []} class="canvas-scroll">
          <svg
            id="starmap-canvas"
            class={canvas_class(@canvas_height)}
            viewBox={"0 0 1160 #{@canvas_height}"}
            data-canvas-height={@canvas_height}
            role="img"
            aria-label="wave-band constellation canvas"
            data-frontiers={length(@canvas_wave_labels)}
            data-session-filter={@session_filter && @session_filter.tag}
            data-fleet-filter={@state_filter && @state_filter.key}
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
                height={@canvas_height}
              />
              <line
                :if={wl.frontier > 0}
                class="band-sep"
                x1={wl.rect_x}
                y1="0"
                x2={wl.rect_x}
                y2={@canvas_height}
              />
              <text class="wlabel section-label" text-anchor="middle" x={wl.x} y="30">
                {wl.title}
              </text>
            </g>

            <g :if={@canvas_edges != []} id="starmap-edges">
              <line
                :for={edge <- @canvas_edges}
                class={"edge" <>
                if(edge.active, do: " edge-active", else: "") <>
                if(dimmed_edge?(@session_filter, @state_filter, edge), do: " dimmed", else: "")}
                data-from={edge.from}
                data-to={edge.to}
                x1={edge.x1}
                y1={edge.y1}
                x2={edge.x2}
                y2={edge.y2}
              />
            </g>

            <g
              :for={node <- @canvas_nodes}
              id={"canvas-node-group-#{node.id}"}
              class={"canvas-node-group" <>
              if(dimmed_node?(@session_filter, @state_filter, node), do: " dimmed", else: "")}
              data-node-id={node.id}
              data-frontier={node.frontier}
              data-state={node.state}
              phx-click="select_node"
              phx-value-id={node.id}
            >
              <title :if={node.harness}>{node.harness}{if node.model, do: " / #{node.model}"}</title>
              <circle
                :if={@panel && @panel.node_id == node.id}
                class="selring"
                cx={node.cx}
                cy={node.cy}
                r="19"
              />
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
        </div>

        <.link
          :if={@older_count > 0}
          id="starmap-older"
          navigate={~p"/goals"}
          class="older-link"
        >
          +{@older_count} older
        </.link>
      </div>

      <aside
        :if={@panel}
        id="starmap-panel"
        class="slide-over"
        data-goal-ref={@panel.goal_ref}
        data-state={@panel.state}
      >
        <button
          type="button"
          id="starmap-panel-close"
          class="panel-close"
          phx-click="close_panel"
          aria-label="close panel"
        >
          ×
        </button>

        <h2 class="panel-title display-heading">{@panel.goal_ref}</h2>

        <div class="panel-chips">
          <span :if={@panel.run && @panel.run.session_name} class="chip chip-session">
            {@panel.run.session_name}
          </span>
          <span :if={@panel.run} class="chip">{@panel.run.workspace}</span>
          <span :if={@panel.run && @panel.run.harness} class="chip">
            {@panel.run.harness}{if @panel.run.model, do: " · #{@panel.run.model}"}
          </span>
          <span class={"chip state-pill pill-#{@panel.state}"}>
            {@panel.sublabel || @panel.state |> to_string() |> String.upcase()}
          </span>
        </div>

        <div
          :if={@panel.run && @panel.run.harness == "claude" && @panel.run.harness_session_id}
          id="starmap-panel-resume"
          class="panel-resume"
        >
          <span class="section-label">RESUME SESSION</span>
          <code>claude -r {@panel.run.harness_session_id}</code>
        </div>

        <div :if={panel_iter(@panel.iterations)} id="starmap-panel-iter" class="panel-iter">
          ITER {panel_iter(@panel.iterations)}
          <span :if={@panel.run && @panel.run.max_iterations} class="panel-budget">
            · budget {@panel.run.max_iterations} iterations
          </span>
        </div>

        <div :if={burn_pct(@panel)} class="burn-bar">
          <div
            class={"burn-fill #{burn_class(burn_pct(@panel))}"}
            style={"width: #{burn_pct(@panel)}%"}
          >
          </div>
        </div>

        <div :if={@panel.run && cause_line(@panel.run)} id="starmap-panel-cause" class="panel-cause">
          {cause_line(@panel.run)}
        </div>

        <div :if={@panel.iterations != []} id="starmap-panel-dna" class="panel-section">
          <div class="section-label">PREDICATE VECTOR</div>
          <div class="dna-squares">
            <span
              :for={square <- panel_squares(@panel.iterations)}
              class={"dna-square status-#{square.status}"}
              data-predicate-id={square.id}
              data-status={square.status}
              title={square.id}
            ></span>
          </div>
        </div>

        <div :if={@panel.iterations != []} id="starmap-panel-heatmap" class="panel-section">
          <div class="section-label">CONVERGENCE · PREDICATES × ITERATIONS</div>
          <div
            :for={predicate_id <- panel_predicate_ids(@panel.iterations)}
            class="hm-row"
            data-predicate-id={predicate_id}
          >
            <span class="hm-label">{predicate_id}</span>
            <span class="hm-cells">
              <span
                :for={iteration <- @panel.iterations}
                class={"hm-cell status-#{panel_cell_status(predicate_id, iteration)}" <>
                  if(panel_regression_flip?(predicate_id, iteration),
                    do: " regression-flip",
                    else: ""
                  )}
                data-status={panel_cell_status(predicate_id, iteration)}
              ></span>
            </span>
          </div>
        </div>

        <div id="starmap-panel-transcript" class="panel-section">
          <div class="section-label">TRANSCRIPT TAIL · {tail_label(@panel.run)}</div>
          <div class="panel-transcript">
            <p :if={@panel.transcript == []} class="empty-state">No transcript events.</p>
            <div :for={event <- @panel.transcript} class="panel-event">
              <span :if={panel_tool_event?(event)} class="panel-pill">
                <span class="marker">▸</span> {event["name"] || event["type"]}
              </span>
              <p :if={!panel_tool_event?(event)} class="panel-line">
                {panel_text_line(event)}
              </p>
            </div>
          </div>
        </div>

        <.link
          navigate={~p"/goals/#{@panel.goal_ref}/drillin"}
          id="starmap-panel-analyst"
          class="analyst-btn"
        >
          FULL ANALYST VIEW →
        </.link>
      </aside>

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

      <nav id="starmap-tabbar" class="mtabbar" aria-label="starmap sections">
        <button
          :for={
            {tab, glyph, label} <- [
              {"map", "✦", "MAP"},
              {"needs", "◉", "NEEDS YOU"},
              {"sessions", "⌁", "SESSIONS"},
              {"more", "☰", "MORE"}
            ]
          }
          type="button"
          id={"starmap-mtab-#{tab}"}
          class={"mtab" <> if(@mtab == tab, do: " on", else: "")}
          phx-click="set_mtab"
          phx-value-tab={tab}
        >
          <span class="mtab-glyph" aria-hidden="true">{glyph}</span>{label}
          <span :if={tab == "needs" && @attention_queue != []} class="mtab-badge">
            {length(@attention_queue)}
          </span>
        </button>
      </nav>

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
        .canvas-scroll { overflow-y: auto; max-height: calc(100vh - 9.5rem); margin-top: 1rem; scrollbar-width: thin; scrollbar-color: #16233A transparent; }
        .starmap-canvas { width: 100%; height: calc(100vh - 9.5rem); display: block; }
        .starmap-canvas.tall { height: auto; }
        .starmap-canvas .nd-landed { fill: var(--grn); }
        .starmap-canvas .nd-conv { fill: #0A1526; stroke: var(--cyn); stroke-width: 2; }
        .starmap-canvas .nd-stuck { fill: #160D14; stroke: var(--red); stroke-width: 2; }
        .starmap-canvas .nd-claimed { fill: #0B1424; stroke: var(--cyn); stroke-width: 1.5; stroke-dasharray: 4 4; opacity: .85; }
        .starmap-canvas .nd-pending { fill: #0D1626; stroke: #223350; stroke-width: 1.5; }
        .starmap-canvas .nd-stale { fill: #141118; stroke: var(--amb); stroke-width: 1.5; stroke-dasharray: 2 4; }
        .starmap-canvas .ring { fill: none; stroke: var(--cyn); stroke-width: 1.5; transform-box: fill-box; transform-origin: center; }
        .starmap-canvas .ring.redr { stroke: var(--red); }
        .starmap-canvas .edge { stroke: #152840; stroke-width: 1.5; }
        .starmap-canvas .edge-active { stroke: rgba(86,204,242,.5); }
        .starmap-canvas .canvas-node-group { cursor: pointer; }
        .starmap-canvas .canvas-node-group.dimmed { opacity: .12; }
        .starmap-canvas .edge.dimmed { opacity: .12; }
        .starmap-canvas .selring { fill: none; stroke: #EAF6FF; stroke-width: 1; stroke-dasharray: 3 5; transform-box: fill-box; transform-origin: center; }
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
        .rail-sessions .session-row { display: flex; align-items: center; gap: .6rem; padding: .4rem 0; border-bottom: 1px solid rgba(22,35,58,.6); font-size: 10px; color: var(--dim, #46587A); cursor: pointer; }
        .rail-sessions .session-row:last-child { border-bottom: none; }
        .rail-sessions .session-row:hover { color: var(--txt, #BFD2EA); }
        .rail-sessions .session-row.active { background: rgba(86,204,242,.07); box-shadow: inset 2px 0 0 var(--cyn, #56CCF2); padding-left: .4rem; }
        .rail-sessions .session-row.active .session-id { background: rgba(86,204,242,.18); }
        .rail-sessions .session-id { color: var(--cyn, #56CCF2); border: 1px solid rgba(86,204,242,.4); border-radius: 3px; padding: 1px 6px; font-weight: 700; flex: 0 0 auto; }
        .rail-sessions .session-id.red { color: var(--red, #FF5C6C); border-color: rgba(255,92,108,.5); }
        .rail-sessions .session-text { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .rail-sessions .session-text b { color: var(--txt, #BFD2EA); }
        .rail-sessions .session-ws { color: #34456B; }
        .fleet-tiles { display: flex; gap: .6rem; flex-wrap: wrap; align-items: stretch; }
        .fleet-tiles .section-label { flex-basis: 100%; }
        .fleet-tile { flex: 1; display: flex; flex-direction: column; align-items: center; gap: .25rem; border: 1px solid var(--line, #16233A); border-radius: 4px; background: rgba(11,20,36,.6); padding: .6rem .4rem; cursor: pointer; }
        .fleet-tile:hover { border-color: #2A3D5F; }
        .fleet-tile.active { border-color: rgba(86,204,242,.6); background: rgba(86,204,242,.08); }
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

        .slide-over { position: fixed; top: 0; right: 0; bottom: 38px; width: 470px; max-width: 92vw; background: rgba(9,15,28,.97); border-left: 1px solid rgba(86,204,242,.25); box-shadow: -24px 0 60px rgba(0,0,0,.55); padding: 1.2rem 1.4rem; overflow-y: auto; z-index: 20; display: flex; flex-direction: column; gap: 1rem; }
        .panel-close { position: absolute; top: .8rem; right: .9rem; background: transparent; border: 1px solid var(--line); color: var(--dim); border-radius: 3px; width: 22px; height: 22px; cursor: pointer; font-family: inherit; }
        .panel-close:hover { color: var(--txt); border-color: var(--dim); }
        .panel-title { font-size: 21px; margin: 0; padding-right: 2rem; overflow-wrap: anywhere; }
        .panel-chips { display: flex; gap: .4rem; flex-wrap: wrap; }
        .chip { border: 1px solid var(--line); border-radius: 3px; padding: 2px 8px; font-size: 10px; color: var(--dim); }
        .chip-session { color: var(--cyn); border-color: rgba(86,204,242,.4); font-weight: 700; }
        .panel-resume { display: flex; flex-direction: column; gap: .3rem; }
        .panel-resume code { border: 1px solid var(--line); border-radius: 4px; padding: .4rem .6rem; font-size: 10px; color: var(--txt); overflow-wrap: anywhere; user-select: all; }
        .state-pill.pill-converging, .state-pill.pill-claimed { color: var(--cyn); border-color: rgba(86,204,242,.4); }
        .state-pill.pill-stuck { color: var(--red); border-color: rgba(255,92,108,.5); }
        .state-pill.pill-landed { color: var(--grn); border-color: rgba(46,230,168,.4); }
        .state-pill.pill-stale { color: var(--amb); border-color: rgba(255,180,84,.4); }
        .panel-iter { font-size: 11px; letter-spacing: .12em; color: var(--txt); }
        .panel-iter .panel-budget { color: var(--dim); }
        .burn-bar { height: 4px; background: #101B30; border-radius: 2px; overflow: hidden; }
        .burn-fill { height: 100%; }
        .burn-ok { background: var(--cyn); }
        .burn-warn { background: var(--amb); }
        .burn-hot { background: var(--red); }
        .panel-cause { font-size: 10px; color: var(--amb); border: 1px solid rgba(255,180,84,.3); border-radius: 4px; padding: .35rem .5rem; overflow-wrap: anywhere; }
        .panel-section { display: flex; flex-direction: column; gap: .45rem; }
        .dna-squares { display: flex; gap: 3px; flex-wrap: wrap; }
        .dna-square { width: 15px; height: 15px; border-radius: 2px; background: #152134; display: inline-block; }
        .dna-square.status-pass { background: var(--grn); box-shadow: 0 0 6px rgba(46,230,168,.5); }
        .dna-square.status-fail { background: var(--red); box-shadow: 0 0 6px rgba(255,92,108,.5); }
        .dna-square.status-error { background: var(--red); }
        .hm-row { display: flex; align-items: center; gap: 6px; }
        .hm-label { flex: 0 0 110px; font-size: 9px; color: var(--dim); text-align: right; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .hm-cells { display: flex; gap: 2px; flex-wrap: wrap; }
        .hm-cell { width: 15px; height: 13px; border-radius: 2px; background: #101B30; display: inline-block; }
        .hm-cell.status-pass { background: var(--grn); }
        .hm-cell.status-fail, .hm-cell.status-error { background: var(--red); }
        .hm-cell.regression-flip { outline: 1px solid var(--amb); }
        .panel-transcript { border: 1px solid var(--line); border-radius: 4px; padding: .7rem .8rem; display: flex; flex-direction: column; gap: .5rem; max-height: 30vh; overflow-y: auto; }
        .panel-line { font-size: 11px; color: var(--txt); margin: 0; overflow-wrap: anywhere; }
        .panel-pill { display: inline-flex; gap: .4rem; align-items: center; border: 1px solid var(--line); border-radius: 999px; padding: .15rem .7rem; font-size: 10px; color: var(--txt); width: max-content; max-width: 100%; }
        .panel-pill .marker { color: var(--cyn); }
        .analyst-btn { margin-top: auto; border: 1px solid rgba(86,204,242,.5); color: var(--cyn); text-align: center; padding: .55rem; border-radius: 4px; text-decoration: none; letter-spacing: .15em; font-size: 11px; }
        .analyst-btn:hover { background: rgba(86,204,242,.08); }

        .rail-nav { margin-top: auto; display: flex; flex-direction: column; gap: .35rem; }
        .rail-nav + .legend { margin-top: 0; }
        .rail-nav a { color: var(--dim); text-decoration: none; font-size: 11px; }
        .rail-nav a:hover { color: var(--cyn); }
        .mtabbar { display: none; }
        .msessions-empty { display: none; }

        /* Mobile (docs/dashboard-design.md "Mobile layout"): below the
           breakpoint the shell becomes a full-height column and the rail's
           sections become tab panes -- MAP / NEEDS YOU / SESSIONS / MORE --
           selected by the data-mtab attribute the set_mtab event drives.
           Desktop above the breakpoint is untouched. */
        @media (max-width: 820px) {
          .shell { flex-direction: column; flex-wrap: nowrap; height: 100vh; height: 100dvh; min-height: 0; overflow: hidden; }
          .rail { width: 100%; flex: 0 0 auto; border-right: none; border-bottom: 1px solid var(--line); padding: .75rem .9rem; gap: .8rem; min-height: 0; }
          .fleet-tiles, .rail-attention, .rail-sessions, .rail-nav, .legend, .msessions-empty { display: none; }
          .canvas-shell { display: none; }

          .shell[data-mtab="map"] .fleet-tiles { display: flex; flex-wrap: nowrap; overflow-x: auto; }
          .shell[data-mtab="map"] .fleet-tiles .section-label { display: none; }
          .shell[data-mtab="map"] .fleet-tile { min-width: 72px; min-height: 44px; }
          .shell[data-mtab="map"] .canvas-shell { display: flex; flex-direction: column; flex: 1; min-height: 0; padding: .4rem .75rem 0; }
          .shell[data-mtab="map"] .canvas-scroll { flex: 1; max-height: none; overflow-x: auto; margin-top: .25rem; }
          .shell[data-mtab="map"] .starmap-canvas { min-width: 880px; height: 100%; }
          .shell[data-mtab="map"] .starmap-canvas.tall { height: auto; }
          .shell[data-mtab="map"] .canvas-node-label { font-size: 15px; }
          .shell[data-mtab="map"] .canvas-node-sublabel { font-size: 11px; }
          .shell[data-mtab="map"] .wlabel { font-size: 12px; }
          .shell[data-mtab="map"] .older-link { bottom: .5rem; right: .9rem; }

          .shell[data-mtab="needs"] .rail,
          .shell[data-mtab="sessions"] .rail,
          .shell[data-mtab="more"] .rail { flex: 1; overflow-y: auto; }
          .shell[data-mtab="needs"] .rail-attention { display: block; }
          .shell[data-mtab="needs"] .attention-queue-list { max-height: none; }
          .shell[data-mtab="needs"] .attention-item { padding: .7rem 0; font-size: 12px; }
          .shell[data-mtab="sessions"] .rail-sessions { display: block; }
          .shell[data-mtab="sessions"] .session-row { padding: .7rem 0; font-size: 11px; }
          .shell[data-mtab="sessions"] .msessions-empty { display: block; }
          .shell[data-mtab="more"] .rail-nav { display: flex; margin-top: 0; gap: 0; }
          .shell[data-mtab="more"] .rail-nav a { padding: .8rem 0; border-bottom: 1px solid rgba(22,35,58,.7); color: var(--txt); font-size: 12px; }
          .shell[data-mtab="more"] .legend { display: flex; margin-top: .8rem; }

          .event-river { flex: 0 0 auto; }

          .mtabbar { display: flex; flex: 0 0 auto; border-top: 1px solid var(--line); background: rgba(10,17,32,.97); padding-bottom: env(safe-area-inset-bottom); }
          .mtab { position: relative; flex: 1; display: flex; flex-direction: column; align-items: center; gap: 3px; padding: .55rem 0 .7rem; min-height: 48px; background: none; border: none; color: var(--dim); font-family: inherit; font-size: 9px; letter-spacing: .14em; cursor: pointer; }
          .mtab-glyph { font-size: 15px; line-height: 1; }
          .mtab.on { color: var(--cyn); }
          .mtab.on::before { content: ""; position: absolute; top: -1px; left: 22%; right: 22%; height: 2px; background: var(--cyn); }
          .mtab-badge { position: absolute; top: 4px; right: 16%; min-width: 15px; height: 15px; border-radius: 8px; background: var(--red); color: #fff; font-size: 9px; font-weight: 700; display: flex; align-items: center; justify-content: center; padding: 0 4px; }

          .slide-over { top: 24%; left: 0; right: 0; bottom: 0; width: 100%; max-width: none; background: #090F1C; border-left: none; border-top: 1px solid rgba(86,204,242,.3); border-radius: 14px 14px 0 0; box-shadow: 0 -18px 50px rgba(0,0,0,.6); }
        }
      </style>
    </main>
    """
  end
end
