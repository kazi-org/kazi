defmodule KaziWeb.MissionControlLive do
  @moduledoc """
  The fleet home view — **Mission Control** (UC-061, ADR-0070, superseding the
  ADR-0057 starmap home view).

  A read-only projection of the run registry (`Kazi.ReadModel.RunRegistry`) laid
  out as an ops-center card grid rather than a spatial constellation: a topbar
  fleet-count strip, a **NEEDS ATTENTION** row (the ranked attention queue,
  `Kazi.Attention.Queue`), a **FLEET** grid of one card per goal, a **PLANNED**
  section of approved-but-undispatched proposals (T60.4, #1160 — the queue's
  unstarted/todo goals, per-machine by construction since proposals are not
  bus-synced), and a bottom
  **EVENT RIVER** ticker. It renders state; it never mutates a run, a goal, or a
  lease (ADR-0011 §2 reaffirmed at fleet scope) — the only interactions are the
  navigation deep-links into the full drill-in / board / lease / event pages.

  Each goal resolves to a display state the same way the starmap did:

    * `:landed`     — terminal status `"converged"` (ADR-0055).
    * `:stuck`      — a terminal non-converging status (`"stuck"` / `"error"`;
      `"over_budget"` is split out into its own fleet count but still renders as
      a `c-bad` card).
    * `:stale`      — no terminal status and a stale heartbeat
      (`RunRegistry.stale?/1`) — a crashed or hung process.
    * `:converging` — no terminal status and heartbeating normally.

  ## Roadmap wave grouping (ADR-0070, preserving T47.2)

  When a roadmap goal-file is configured (`KaziWeb.Starmap.GoalSource.goal/0`
  returns a `Kazi.Goal.t()` — the ADR-0056 roadmap DAG, driven by `kazi
  dashboard --roadmap`), the FLEET grid GROUPS into labeled wave sections, one
  per topological frontier from `Kazi.Goal.DepGraph.frontiers/1` — the SAME
  computation `kazi apply --explain` prints, so the waves can never disagree
  with the schedule a `--parallel` run would take. This is the starmap's
  wave-band value rendered in the card idiom instead of a constellation: a
  declared group with a registered run shows its live card; a group nothing has
  dispatched yet shows a lighter placeholder card in state:

    * `:claimed`  — every `needs` dep converged (the LIVE frontier, eligible to
      dispatch now).
    * `:pending`  — still waiting on an unconverged dep (a later wave), or
      poisoned behind a stuck ancestor (`DagSnapshot`'s `:blocked`, folded here).

  With no roadmap configured (the default) the fleet is a single flat grid,
  newest goal first — the fallback, not a separate mode.

  ## Per-card telemetry (ADR-0070)

  Beyond the registry row, each run-backed card renders the goal's convergence
  at a glance from the SAME persisted per-iteration history the drill-in heatmap
  (T46.7) reads (`Kazi.ReadModel.list_iterations/1`):

    * **predicate DNA** — the latest iteration's predicate vector as squares
      (pass green / fail-or-error red / not-evaluated dark).
    * **sparkline** — passing-predicate count across the iteration history.
    * **burn bar** — the honest budget the registry knows: iteration progress
      against the run's declared `max_iterations`. kazi has no token *cap*, so —
      unlike the originating mock's "k / k tokens" — the bar reads iterations;
      harness-reported tokens (`Run.budget_tokens`) ride alongside as text when
      present (`docs/dashboard-design.md`, "The burn bar").

  ## Scope + polling

  Flat-mode cards, chips, and attention alerts honor a CURRENT/CLOSED **scope
  toggle** (`set_session_scope`, default CURRENT): CURRENT shows runs whose
  driving agent session is still alive (or — for rows a pre-session-pid binary
  registered — still actively converging); CLOSED shows dead history —
  converged, stuck, and crashed/stale runs whose session has ended, so a crash is
  reviewable here rather than only on `/goals`. Roadmap-mode wave state ignores
  the scope: it resolves from the LATEST run per group across the whole registry
  (the roadmap is the durable plan, so a group converged by a since-closed
  session must still read landed). `mount/3` reads the registry directly; a
  connected mount also polls on a short interval so a status or heartbeat change
  is visible without a manual refresh (projection-only — no PubSub coupling to
  the loop). Pure read projection (ADR-0011 §2).
  """
  use KaziWeb, :live_view

  alias Kazi.Attention.Queue, as: AttentionQueue
  alias Kazi.Goal
  alias Kazi.Goal.DepGraph
  alias Kazi.Loop.CauseClass
  alias Kazi.ReadModel
  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Scheduler.DagSnapshot
  alias Kazi.SessionLiveness
  alias Kazi.Sink.Events
  alias KaziWeb.Starmap.GoalSource
  alias KaziWeb.CoordinationSource
  alias KaziWeb.CoordinationSource.Snapshot

  # Poll interval for picking up registry changes ("a verdict change is
  # reflected on refresh without restart"). A LiveView test never waits this
  # long — it sends the same `handle_info(:tick, ...)` message directly.
  @poll_ms 2_000

  # Newest fleet-wide events the bottom river ticker carries — a glance, not the
  # full feed (`KaziWeb.EventRiverLive` is that).
  @river_window 12

  # Flat mode only: one card per goal (its latest run); the newest this many
  # render on the grid, the rest fold into a single "+N more" pointer to /goals.
  # A DOM-size bound. Roadmap mode is bounded by the goal-file's declared groups.
  @card_cap 24

  # Squares beyond this per card fold into a "+N" marker so a goal with a very
  # large predicate set can't stretch a card's DNA strip past its row.
  @dna_cap 24

  # PLANNED section (T60.4, #1160): approved proposals no run has picked up
  # yet render as light todo cards; beyond this many, a "+N more" line points
  # at `kazi list-proposed`. Same DOM-size rationale as @card_cap.
  @planned_cap 12

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, @poll_ms)
      # T51.5 (ADR-0073 §4): subscribe to the coordination source's topic so a
      # fresh bus roster pushes into the SESSIONS rail live. Both production
      # sources share one topic and an explicit override never changes, so the
      # mount-time subscription stays valid across a daemon starting/stopping.
      Phoenix.PubSub.subscribe(Kazi.PubSub, CoordinationSource.select().topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "kazi · mission control")
     |> assign(:session_scope, :current)
     |> assign(:state_filter, nil)
     |> assign(:repo_filter, nil)
     |> assign(:time_window, nil)
     |> assign(:debug?, false)
     |> assign_fleet()
     |> assign_presence()}
  end

  # Operator/debug mode split (ADR-0078, T63.7): the mode is a URL query param —
  # `?debug=1` reveals the expert surfaces (DAG/lease-map/event-river), its
  # absence is the calmer default operator view. Canonical in the URL so the
  # first server-rendered DOM is already correct (no flash, testable); each
  # param change mirrors the active mode to the browser's localStorage via the
  # `McDebug` hook so the choice sticks per browser across bare `/` visits.
  @impl true
  def handle_params(params, _uri, socket) do
    debug? = params["debug"] in ["1", "true"]
    socket = assign(socket, :debug?, debug?)

    socket =
      if connected?(socket),
        do: push_event(socket, "mc-store-debug", %{on: debug?}),
        else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_ms)
    {:noreply, socket |> assign_fleet() |> assign_presence()}
  end

  # T51.5: a fresh coordination snapshot pushed on the source topic (e.g. a
  # session appearing on or aging off the bus) re-renders the SESSIONS rail live.
  @impl true
  def handle_info({:coordination_updated, %Snapshot{} = snapshot}, socket) do
    {:noreply, assign(socket, :presence, snapshot.present)}
  end

  # CURRENT/CLOSED scope toggle: CURRENT (the default) shows runs whose driving
  # agent session is still alive; CLOSED shows dead history — converged, stuck,
  # and crashed/stale runs whose session has ended. A crashed run (status
  # `running`, heartbeat long stale, session gone) is closed history the operator
  # can still review here rather than only on `/goals`. Roadmap mode ignores the
  # scope (wave state is the durable plan, resolved across all runs).
  @impl true
  def handle_event("set_session_scope", %{"scope" => scope}, socket) do
    scope = if scope == "closed", do: :closed, else: :current
    {:noreply, socket |> assign(:session_scope, scope) |> assign_fleet()}
  end

  # Topbar chip click: filter the flat grid to that state; clicking the same
  # chip again clears the filter back to the full fleet.
  @impl true
  def handle_event("toggle_state_filter", %{"state" => raw}, socket) do
    clicked = parse_state_filter(raw)
    next = if socket.assigns.state_filter == clicked, do: nil, else: clicked
    {:noreply, socket |> assign(:state_filter, next) |> assign_fleet()}
  end

  # Repo dropdown (project = "org/repo", default all) + time-window dropdown
  # (last N duration by last-active, default all time).
  @impl true
  def handle_event("set_filters", params, socket) do
    repo =
      case params["repo"] do
        r when is_binary(r) and r != "" -> r
        _all -> nil
      end

    {:noreply,
     socket
     |> assign(:repo_filter, repo)
     |> assign(:time_window, parse_time_window(params["window"]))
     |> assign_fleet()}
  end

  # The `McDebug` hook fires this on connect when localStorage holds a debug
  # preference but the URL is silent on the mode (a bare `/` visit) — restore it
  # by patching the canonical param in (ADR-0078, T63.7).
  @impl true
  def handle_event("mc-restore-debug", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/?debug=1")}
  end

  # ---------------------------------------------------------------------------
  # Projection: the whole view is derived from the registry + the per-goal
  # read-model history on each poll tick. No handle_event — Mission Control is a
  # glance; every drill-in is a navigation into a full-page view.
  # ---------------------------------------------------------------------------

  defp assign_fleet(socket) do
    scope = socket.assigns[:session_scope] || :current
    all_runs = RunRegistry.list()
    live_map = liveness_source().alive_map(Enum.map(all_runs, & &1.session_os_pid))
    {current, closed} = Enum.split_with(all_runs, &session_current?(&1, live_map))
    scoped = if scope == :closed, do: closed, else: current

    socket
    |> assign(:scope_counts, %{current: length(current), closed: length(closed)})
    |> assign(:repos, all_runs |> Enum.map(&project_label/1) |> Enum.uniq() |> Enum.sort())
    |> assign_grid(all_runs, scoped)
    |> assign(:clock, utc_clock())
    |> assign(:alerts, alerts(scoped))
    |> assign_planned(all_runs)
    |> assign(:river_entries, river_entries(all_runs))
  end

  # T60.4 (#1160): the PLANNED bucket — approved proposals no run has picked up
  # yet, i.e. the queue's unstarted/todo goals. A read-only projection over the
  # proposed-goals store (ADR-0011); a proposal leaves PLANNED the moment ANY
  # run registers its goal_id (dispatched work is the fleet grid's job,
  # whatever its state). Proposals are machine-local (not bus-synced), so this
  # bucket is per-machine by construction. Best-effort like every other
  # read-model touch here: an unavailable store renders an empty section,
  # never a 500.
  defp assign_planned(socket, all_runs) do
    planned = planned_proposals(all_runs)
    {shown, more} = Enum.split(planned, @planned_cap)

    socket
    |> assign(:planned, shown)
    |> assign(:planned_more, length(more))
  end

  defp planned_proposals(all_runs) do
    dispatched = MapSet.new(all_runs, & &1.goal_ref)

    ReadModel.list_proposed_goals(status: "approved")
    |> Enum.reject(&MapSet.member?(dispatched, &1.goal_id))
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # T51.5 (ADR-0073 §4): the SESSIONS rail's live bus presence, read from the
  # SAME injectable `KaziWeb.CoordinationSource` the `/leases` map uses --
  # Transport when a daemon is reachable (the live bus roster: session, machine,
  # last-seen), Native otherwise (empty, never a crash -- L-0021). Re-selected
  # each tick so a daemon starting or stopping flips the rail live. A source that
  # cannot answer degrades to an empty rail, never a 500.
  defp assign_presence(socket) do
    source = CoordinationSource.select()

    present =
      try do
        source.snapshot().present
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    socket
    |> assign(:coord_source, source)
    |> assign(:presence, present)
  end

  # Roadmap configured -> wave-grouped cards (resolved across ALL runs, since the
  # roadmap is the durable plan); otherwise the flat grid over the SCOPED run set
  # (current or closed per the toggle). Both funnel into the same `fleet_card`
  # component; the fleet chips count run-backed cards either way.
  defp assign_grid(socket, all_runs, scoped) do
    case GoalSource.goal() do
      %Goal{} = goal ->
        waves = build_waves(goal, all_runs)
        cards = Enum.flat_map(waves, & &1.cards)
        run_cards = Enum.filter(cards, & &1.run?)

        socket
        |> assign(:roadmap?, true)
        |> assign(:waves, waves)
        |> assign(:cards, [])
        |> assign(:card_groups, [])
        |> assign(:multi_project?, false)
        |> assign(:older_count, 0)
        |> assign(:instance_count, length(cards))
        |> assign(:filters_hide_runs?, false)
        |> assign(:counts, fleet_counts(run_cards))

      _none ->
        deduped =
          scoped
          |> Enum.group_by(& &1.goal_ref)
          |> Enum.map(fn {_ref, runs} -> Enum.max_by(runs, & &1.heartbeat_at, DateTime) end)
          |> Enum.sort_by(& &1.heartbeat_at, {:desc, DateTime})

        filtered =
          deduped
          |> filter_repo(socket.assigns.repo_filter)
          |> filter_window(socket.assigns.time_window)

        {shown, older} = Enum.split(filtered, @card_cap)
        remote = remote_cards(all_runs)
        cards = Enum.map(shown, &card_from_run/1) ++ remote
        visible = state_filtered(cards, socket.assigns.state_filter)
        groups = group_cards_by_project(visible)

        socket
        |> assign(:roadmap?, false)
        |> assign(:waves, [])
        |> assign(:cards, visible)
        |> assign(:card_groups, groups)
        |> assign(:multi_project?, length(groups) > 1)
        |> assign(:older_count, length(older))
        |> assign(:instance_count, length(filtered) + length(remote))
        |> assign(:filters_hide_runs?, deduped != [] and remote == [] and visible == [])
        |> assign(:counts, fleet_counts(cards))
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-machine fleet visibility (T60.1, #1154 clause 3): a run in flight on
  # ANOTHER machine is invisible to `RunRegistry.list/0` (per-machine SQLite,
  # ADR-0057) -- render it as a distinct card sourced from the bus board's
  # last-value-per-topic `run:<short-id>` facts (T51.5's `Kazi.Runtime.BusMirror`)
  # instead. Read-only, best-effort (ADR-0011 §2 / ADR-0067 point 1's mirror
  # invariant mirrored here): an unreachable daemon degrades to zero remote
  # cards, never an error -- the local fleet grid renders exactly as before.
  # ---------------------------------------------------------------------------

  defp remote_cards(all_runs) do
    local_refs = all_runs |> Enum.map(& &1.goal_ref) |> MapSet.new()

    remote_run_facts()
    |> Enum.map(&parse_remote_fact/1)
    |> Enum.filter(& &1)
    |> Enum.reject(&MapSet.member?(local_refs, &1.goal_ref))
    |> Enum.uniq_by(& &1.goal_ref)
    |> Enum.map(&remote_card/1)
  end

  # Injectable (ADR-0011 §3, mirroring `liveness_source/0`/`CoordinationSource`):
  # defaults to the real bus board, overridable in test config so a LiveView
  # test can seed a fixture fact list with no daemon. The fetcher call itself
  # (default OR injected) is wrapped in try/rescue/catch -- an unreachable
  # daemon or a raising fixture degrades to zero remote cards, never a crashed
  # render (same contract `assign_presence/1` already gives the SESSIONS rail).
  defp remote_run_facts do
    fetch = Application.get_env(:kazi, :remote_run_facts_fetcher, &default_remote_run_facts/0)

    try do
      fetch.()
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp default_remote_run_facts do
    case Kazi.Bus.board(claims: false) do
      {:ok, %{"facts" => facts}} -> facts
      _other -> []
    end
  end

  @remote_started_re ~r/^started (?<goal_ref>\S+)$/
  @remote_terminal_re ~r/^(?<verb>converged|over_budget|stuck|stopped|error) (?<goal_ref>\S+)(?: \(.*\))?$/
  @remote_terminated_re ~r/^terminated (?<goal_ref>\S+) \(.*\)$/
  @remote_iter_re ~r/^iter \d+: .+ (?<goal_ref>\S+)$/

  # A fact from OUR OWN machine is not "remote" -- `Kazi.Bus.hostname/0` is the
  # SAME value every posted fact's `machine` header carries, reused rather than
  # a second hostname check.
  defp parse_remote_fact(%{"topic" => "run:" <> _short, "machine" => machine, "text" => text})
       when is_binary(machine) and is_binary(text) do
    if machine != Kazi.Bus.hostname() do
      case remote_fact_state(text) do
        {goal_ref, state} -> %{goal_ref: goal_ref, state: state, machine: machine}
        nil -> nil
      end
    end
  end

  defp parse_remote_fact(_other), do: nil

  defp remote_fact_state(text) do
    cond do
      m = Regex.named_captures(@remote_started_re, text) ->
        {m["goal_ref"], :converging}

      m = Regex.named_captures(@remote_iter_re, text) ->
        {m["goal_ref"], :converging}

      m = Regex.named_captures(@remote_terminal_re, text) ->
        {m["goal_ref"], remote_verdict_state(m["verb"])}

      m = Regex.named_captures(@remote_terminated_re, text) ->
        {m["goal_ref"], :stuck}

      true ->
        nil
    end
  end

  defp remote_verdict_state("converged"), do: :landed
  defp remote_verdict_state(_stuck_over_budget_stopped_error), do: :stuck

  defp remote_card(%{goal_ref: goal_ref, state: state, machine: machine}) do
    %{
      run?: false,
      remote?: true,
      goal_ref: goal_ref,
      name: goal_ref,
      state: state,
      over_budget?: false,
      state_label: state_label(state, false),
      card_cls: "card " <> card_variant(state) <> " remote",
      pill_cls: "stpill " <> pill_variant(state),
      harness: nil,
      ws: nil,
      project: nil,
      age: nil,
      last_active: nil,
      rel: nil,
      iter: "—",
      preds: [],
      dna_overflow: 0,
      budget_label: nil,
      burn_cls: nil,
      burn_w: nil,
      spark: "",
      sub: "remote · #{machine}",
      machine: machine
    }
  end

  # ---------------------------------------------------------------------------
  # Filters (flat mode): state (topbar chip toggle), repo ("org/repo" dropdown),
  # and time window (last-active within the last N seconds). Chip counts are
  # computed AFTER the repo/time filters but BEFORE the state filter, so the
  # numbers on the chips always describe the set the chips slice.
  # ---------------------------------------------------------------------------

  defp parse_state_filter("running"), do: :running
  defp parse_state_filter("converged"), do: :converged
  defp parse_state_filter("stuck"), do: :stuck
  defp parse_state_filter("over_budget"), do: :over_budget
  defp parse_state_filter(_other), do: nil

  @time_windows [
    {"1h", 3_600},
    {"6h", 6 * 3_600},
    {"24h", 24 * 3_600},
    {"7d", 7 * 86_400},
    {"30d", 30 * 86_400}
  ]

  defp parse_time_window(raw) do
    case List.keyfind(@time_windows, raw, 0) do
      {_label, seconds} -> seconds
      nil -> nil
    end
  end

  defp time_window_label(nil), do: nil

  defp time_window_label(seconds) do
    case List.keyfind(@time_windows, seconds, 1) do
      {label, _seconds} -> label
      nil -> nil
    end
  end

  defp filter_repo(runs, nil), do: runs
  defp filter_repo(runs, repo), do: Enum.filter(runs, &(project_label(&1) == repo))

  defp filter_window(runs, nil), do: runs

  defp filter_window(runs, seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -seconds, :second)

    Enum.filter(runs, fn run ->
      last = run.heartbeat_at || run.started_at
      is_struct(last, DateTime) and DateTime.compare(last, cutoff) != :lt
    end)
  end

  # Direction B (T63.6): the flat grid groups by project ("org/repo") under ruled
  # headers. Groups preserve the cards' heartbeat-desc order and appear in order
  # of first appearance, so the newest run's project leads. A card with no
  # project (a remote card) folds under a stable "—" bucket. The caller drops the
  # per-group header when there is only one group (a single-project fleet needs
  # no redundant header).
  defp group_cards_by_project(cards) do
    cards
    |> Enum.group_by(&(&1.project || "—"))
    |> Enum.sort_by(fn {project, _group_cards} ->
      {Enum.find_index(cards, &((&1.project || "—") == project)), project}
    end)
    |> Enum.map(fn {project, group_cards} -> %{project: project, cards: group_cards} end)
  end

  defp state_filtered(cards, nil), do: cards

  defp state_filtered(cards, filter), do: Enum.filter(cards, &card_matches_state?(&1, filter))

  # The same slicing the chip counts use: OVER-BUDGET is split out of STUCK.
  defp card_matches_state?(card, :running), do: card.state == :converging
  defp card_matches_state?(card, :converged), do: card.state == :landed
  defp card_matches_state?(card, :over_budget), do: card.over_budget?

  defp card_matches_state?(card, :stuck),
    do: card.state in [:stuck, :stale] and not card.over_budget?

  # Injectable liveness seam (ADR-0011 §3): production probes `ps` via
  # `Kazi.SessionLiveness`; tests configure the deterministic stub so no test
  # shells out.
  defp liveness_source do
    Application.get_env(:kazi, :session_liveness_source, SessionLiveness)
  end

  # A run is CURRENT when its recorded agent-session pid is alive. Rows without a
  # recorded session pid (an older binary, or a run launched outside any agent
  # session) fall back to run liveness: still-converging counts as current.
  defp session_current?(%Run{session_os_pid: pid} = run, live_map) do
    case pid do
      p when is_binary(p) and p != "" -> Map.get(live_map, p, false)
      _unrecorded -> state(run) == :converging
    end
  end

  # ---------------------------------------------------------------------------
  # Roadmap wave grouping — the goal's `needs`-DAG laid out as topological
  # frontiers, each group's display state resolved from its LATEST registered
  # run (or `:claimed`/`:pending` when none has started). Reuses the SAME
  # `DepGraph.frontiers/1` + `DagSnapshot` the starmap and `--explain` use.
  # ---------------------------------------------------------------------------

  defp build_waves(%Goal{} = goal, all_runs) do
    latest_run_by_ref = latest_run_by_goal_ref(all_runs)

    dep_states =
      Map.new(goal.groups, fn %Goal.Group{id: id} ->
        {id, dep_state(Map.get(latest_run_by_ref, id))}
      end)

    dag_nodes_by_id =
      goal |> DagSnapshot.from(dep_states) |> Map.fetch!(:nodes) |> Map.new(&{&1.id, &1})

    goal
    |> DepGraph.frontiers()
    |> Enum.with_index()
    |> Enum.map(fn {ids, frontier} ->
      cards = Enum.map(ids, &wave_card(&1, dag_nodes_by_id, latest_run_by_ref))
      %{frontier: frontier, label: wave_label(frontier, cards), cards: cards}
    end)
  end

  # `RunRegistry.list/0` is ordered `desc: started_at`, so the FIRST run seen per
  # `goal_ref` is the latest — the one whose state wins when a group was retried.
  defp latest_run_by_goal_ref(all_runs) do
    Enum.reduce(all_runs, %{}, fn run, acc -> Map.put_new(acc, run.goal_ref, run) end)
  end

  defp dep_state(nil), do: :pending
  defp dep_state(%Run{status: "converged"}), do: :converged

  defp dep_state(%Run{status: status}) when status in ["stuck", "over_budget", "error"],
    do: :stuck

  defp dep_state(%Run{status: "running"}), do: :running
  defp dep_state(%Run{}), do: :pending

  defp wave_card(id, dag_nodes_by_id, latest_run_by_ref) do
    dag_node = Map.fetch!(dag_nodes_by_id, id)
    state = band_state(dag_node.state, Map.get(latest_run_by_ref, id))

    case Map.get(latest_run_by_ref, id) do
      %Run{} = run when state in [:landed, :converging, :stuck, :stale] ->
        card_from_run(run, name: dag_node.name, state: state)

      _no_run_or_frontier ->
        placeholder_card(id, dag_node.name, state)
    end
  end

  # Maps a `DagSnapshot` display state onto Mission Control's card vocabulary:
  # converged/stuck/over_budget fold onto the run-registry states; `:ready`
  # (eligible-now, undispatched) is `:claimed`; `:blocked` (poisoned by a stuck
  # ancestor) folds into `:pending`. `:running` needs the actual run to resolve
  # heartbeat staleness, which the pure `DagSnapshot` cannot see.
  defp band_state(:converged, _run), do: :landed
  defp band_state(:stuck, _run), do: :stuck
  defp band_state(:over_budget, _run), do: :stuck
  defp band_state(:ready, _run), do: :claimed
  defp band_state(:blocked, _run), do: :pending
  defp band_state(:pending, _run), do: :pending

  defp band_state(:running, run),
    do: if(run && RunRegistry.stale?(run), do: :stale, else: :converging)

  # Wave header (docs/dashboard-design.md "Roadmap waves"): "WAVE N · <summary>"
  # from the wave's card states, mirroring the starmap's band titles.
  defp wave_label(frontier, cards) do
    summary =
      cond do
        Enum.any?(cards, &(&1.state in [:converging, :stuck, :stale])) -> "ACTIVE"
        cards != [] and Enum.all?(cards, &(&1.state == :landed)) -> "LANDED"
        Enum.any?(cards, &(&1.state == :claimed)) -> "FRONTIER"
        true -> "HORIZON"
      end

    "WAVE #{frontier + 1} · #{summary}"
  end

  # ---------------------------------------------------------------------------
  # Cards
  # ---------------------------------------------------------------------------

  defp card_from_run(%Run{} = run, opts \\ []) do
    iterations = ReadModel.list_iterations(run.goal_ref)
    state = Keyword.get(opts, :state) || state(run)
    over_budget? = run.status == "over_budget"

    %{
      run?: true,
      goal_ref: run.goal_ref,
      name: Keyword.get(opts, :name) || run.goal_name || run.goal_ref,
      state: state,
      over_budget?: over_budget?,
      state_label: state_label(state, over_budget?),
      card_cls: "card " <> card_variant(state),
      pill_cls: "stpill " <> pill_variant(state),
      harness: harness_label(run),
      ws: workspace_base(run),
      project: project_label(run),
      age: rel_time(run.started_at),
      last_active: rel_time(run.heartbeat_at),
      rel: rel_time(run.heartbeat_at) || rel_time(run.started_at),
      iter: iter_label(iterations),
      preds: dna_squares(iterations),
      dna_overflow: dna_overflow(iterations),
      budget_label: budget_label(run, iterations),
      burn_cls: burn_class(burn_pct(run, iterations)),
      burn_w: "width: #{burn_pct(run, iterations) || 0}%",
      spark: spark_points(iterations),
      sub: nil
    }
  end

  # A declared roadmap group nothing has dispatched yet: no run row, so no DNA /
  # burn / spark — just its name, its frontier state, and an honest one-line
  # note. Not a link (there is no drill-in history to peek).
  defp placeholder_card(id, name, state) do
    %{
      run?: false,
      goal_ref: id,
      name: name || id,
      state: state,
      over_budget?: false,
      state_label: state_label(state, false),
      card_cls: "card " <> card_variant(state),
      pill_cls: "stpill " <> pill_variant(state),
      harness: nil,
      ws: nil,
      project: nil,
      age: nil,
      last_active: nil,
      rel: nil,
      iter: "—",
      preds: [],
      dna_overflow: 0,
      budget_label: nil,
      burn_cls: nil,
      burn_w: nil,
      spark: "",
      sub: placeholder_sub(state)
    }
  end

  defp placeholder_sub(:claimed), do: "eligible now · no run dispatched yet"
  defp placeholder_sub(_pending), do: "waiting on upstream goals"

  defp state(%Run{status: "converged"}), do: :landed
  defp state(%Run{status: status}) when status in ["stuck", "over_budget", "error"], do: :stuck

  defp state(%Run{status: "running"} = run) do
    if RunRegistry.stale?(run), do: :stale, else: :converging
  end

  defp state(%Run{}), do: :converging

  defp state_label(:converging, _ob), do: "RUNNING"
  defp state_label(:landed, _ob), do: "CONVERGED"
  defp state_label(:stale, _ob), do: "STALE"
  defp state_label(:claimed, _ob), do: "CLAIMED"
  defp state_label(:pending, _ob), do: "PENDING"
  defp state_label(:stuck, true), do: "OVER-BUDGET"
  defp state_label(:stuck, false), do: "STUCK"

  # Card frame + status pill classes (docs/dashboard-design.md "Fleet cards"):
  # running a quiet cyan frame, converged a green glow, stuck a red alarm glow,
  # stale an amber warn frame, claimed a dashed frontier frame, pending dim.
  defp card_variant(:landed), do: "c-ok"
  defp card_variant(:stuck), do: "c-bad"
  defp card_variant(:stale), do: "c-warn"
  defp card_variant(:claimed), do: "c-claimed"
  defp card_variant(:pending), do: "c-pending"
  defp card_variant(_running), do: "c-run"

  defp pill_variant(:landed), do: "st-ok"
  defp pill_variant(:stuck), do: "st-bad"
  defp pill_variant(:stale), do: "st-warn"
  defp pill_variant(:claimed), do: "st-claimed"
  defp pill_variant(:pending), do: "st-pending"
  defp pill_variant(_running), do: "st-run"

  defp harness_label(%Run{harness: nil}), do: "agent"
  defp harness_label(%Run{harness: h, model: nil}), do: h
  defp harness_label(%Run{harness: h, model: m}), do: "#{h} · #{m}"

  defp workspace_base(%Run{workspace: ws}) when is_binary(ws) and ws != "", do: Path.basename(ws)
  defp workspace_base(_run), do: nil

  # Project = "org/repo" resolved from the workspace's git `origin` remote,
  # cached per workspace in the LiveView process (the poll tick re-derives the
  # whole projection every 2s; the remote never changes mid-run). A workspace
  # that is gone or has no remote (ephemeral worktree already reaped, plain
  # directory) falls back to the last two path segments — still a stable,
  # honest grouping key for the repo dropdown.
  defp project_label(%Run{workspace: ws}) when is_binary(ws) and ws != "" do
    case Process.get({:mc_project, ws}) do
      nil ->
        label = derive_project(ws)
        Process.put({:mc_project, ws}, label)
        label

      cached ->
        cached
    end
  end

  defp project_label(_run), do: "unknown"

  defp derive_project(ws) do
    with true <- File.dir?(ws),
         {url, 0} <-
           System.cmd("git", ["-C", ws, "remote", "get-url", "origin"], stderr_to_stdout: true),
         {:ok, label} <- parse_remote(String.trim(url)) do
      label
    else
      _fallback -> ws |> Path.split() |> Enum.take(-2) |> Path.join()
    end
  rescue
    _e -> ws |> Path.split() |> Enum.take(-2) |> Path.join()
  end

  # "git@github.com:org/repo.git" | "https://github.com/org/repo(.git)" -> "org/repo"
  defp parse_remote(url) do
    case Regex.run(~r{[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$}, url) do
      [_, org, repo] -> {:ok, "#{org}/#{repo}"}
      _no_match -> :error
    end
  end

  # Compact relative time for the card's AGE / ACTIVE line: "42s", "5m", "3h", "2d".
  defp rel_time(nil), do: nil

  defp rel_time(%DateTime{} = dt) do
    s = max(DateTime.diff(DateTime.utc_now(), dt), 0)

    cond do
      s < 60 -> "#{s}s"
      s < 3_600 -> "#{div(s, 60)}m"
      s < 86_400 -> "#{div(s, 3_600)}h"
      true -> "#{div(s, 86_400)}d"
    end
  end

  defp iter_label([]), do: "—"
  defp iter_label(iterations), do: "#{List.last(iterations).iteration_index}"

  # The DNA strip: the latest iteration's predicate vector as stably-ordered
  # squares — pass green (dg), fail/error red (dr), anything else dark (dx) —
  # capped at @dna_cap so a large predicate set folds rather than overflows.
  defp dna_squares([]), do: []

  defp dna_squares(iterations) do
    iterations
    |> latest_results()
    |> Enum.take(@dna_cap)
    |> Enum.map(fn {_pid, result} -> %{cls: "dna " <> dna_class(result.status)} end)
  end

  defp dna_overflow([]), do: 0
  defp dna_overflow(iterations), do: max(length(latest_results(iterations)) - @dna_cap, 0)

  defp latest_results(iterations) do
    iterations
    |> List.last()
    |> ReadModel.to_predicate_vector()
    |> Map.fetch!(:results)
    |> Enum.sort_by(fn {pid, _result} -> pid end)
  end

  defp dna_class(:pass), do: "dg"
  defp dna_class(status) when status in [:fail, :error], do: "dr"
  defp dna_class(_other), do: "dx"

  # Sparkline: passing-predicate count across the iteration history, normalized
  # into the 64x18 viewBox (matching the originating mock's polyline math). One
  # iteration renders a single flat point; none renders nothing.
  defp spark_points([]), do: ""

  defp spark_points(iterations) do
    vals =
      Enum.map(iterations, fn iteration ->
        iteration
        |> ReadModel.to_predicate_vector()
        |> Map.fetch!(:results)
        |> Enum.count(fn {_pid, result} -> result.status == :pass end)
      end)

    max = Enum.max([1 | vals])
    step = if length(vals) > 1, do: 64 / (length(vals) - 1), else: 64.0

    vals
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {v, i} ->
      "#{Float.round(i * step, 1)},#{Float.round(16 - v / max * 13, 1)}"
    end)
  end

  # The burn bar reads the run's declared iteration budget (`max_iterations`) —
  # the honest budget the registry knows; nil hides the fill. Same green/amber/
  # red thresholds the drill-in panel used.
  defp burn_pct(%Run{max_iterations: max}, iterations) when is_integer(max) and max > 0 do
    case iterations do
      [] -> nil
      _ -> min(round((List.last(iterations).iteration_index + 1) / max * 100), 100)
    end
  end

  defp burn_pct(_run, _iterations), do: nil

  defp burn_class(pct) when is_integer(pct) and pct >= 85, do: "burnfill b-hot"
  defp burn_class(pct) when is_integer(pct) and pct >= 65, do: "burnfill b-warn"
  defp burn_class(_pct), do: "burnfill b-ok"

  # Label above the burn bar: iteration progress against the budget, with
  # harness-reported tokens riding alongside when present (never fabricated —
  # kazi has no token cap, so tokens are reported-used, not a fraction).
  defp budget_label(%Run{max_iterations: max} = run, iterations) do
    iter_part =
      case {iterations, max} do
        {[], m} when is_integer(m) ->
          "iter 0 / #{m}"

        {[], _} ->
          "no iterations yet"

        {its, m} when is_integer(m) and m > 0 ->
          "iter #{List.last(its).iteration_index + 1} / #{m}"

        {its, _} ->
          "iter #{List.last(its).iteration_index + 1}"
      end

    case run.budget_tokens do
      n when is_integer(n) and n > 0 -> "#{iter_part} · #{format_tokens(n)} tok"
      _ -> iter_part
    end
  end

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp format_tokens(n), do: "#{n}"

  # Fleet counts, over the run-backed cards so the chips sum to real instances:
  # running, converged, over-budget (split out), and stuck (stuck+stale, minus
  # the over-budget already counted). Placeholder (claimed/pending) cards carry
  # no run, so they never enter the counts.
  defp fleet_counts(cards) do
    %{
      running: Enum.count(cards, &(&1.state == :converging)),
      converged: Enum.count(cards, &(&1.state == :landed)),
      over_budget: Enum.count(cards, & &1.over_budget?),
      stuck: Enum.count(cards, &(&1.state in [:stuck, :stale] and not &1.over_budget?))
    }
  end

  # ---------------------------------------------------------------------------
  # NEEDS ATTENTION alerts — the ranked attention queue, one entry per
  # goal+signal, mapped to a severity chip + an honest one-line detail.
  # ---------------------------------------------------------------------------

  defp alerts(runs) do
    runs
    |> AttentionQueue.build()
    |> Enum.uniq_by(&{&1.goal_ref, &1.signal})
    |> Enum.map(&to_alert/1)
  end

  defp to_alert(%{signal: signal, goal_ref: goal_ref, predicate_id: predicate_id} = item) do
    %{
      goal_ref: goal_ref,
      signal: signal,
      sev: alert_severity(signal),
      cls: "alert " <> alert_variant(signal),
      title: goal_ref,
      detail: alert_detail(signal, predicate_id, item.detail)
    }
  end

  defp alert_severity(:cause), do: "NEEDS YOU"
  defp alert_severity(:stuck), do: "STUCK"
  defp alert_severity(:budget), do: "BUDGET"
  defp alert_severity(:flake_suspicion), do: "FLAKE"
  defp alert_severity(:regression_recovered), do: "REGRESS"

  # A cause (needs-a-human) or a stuck predicate is a red alarm; budget / flake /
  # regression are amber warnings.
  defp alert_variant(signal) when signal in [:cause, :stuck], do: "al-bad"
  defp alert_variant(_signal), do: "al-warn"

  defp alert_detail(:cause, _predicate_id, %{cause_class: class, cause_detail: detail}),
    do: CauseClass.format(class, detail)

  defp alert_detail(:stuck, predicate_id, _detail) when is_binary(predicate_id),
    do: "predicate #{predicate_id} red for consecutive iterations"

  defp alert_detail(:stuck, _predicate_id, _detail), do: "stuck detector fired"

  defp alert_detail(:budget, _predicate_id, _detail), do: "iteration budget ≥85% consumed"

  defp alert_detail(:flake_suspicion, predicate_id, _detail) when is_binary(predicate_id),
    do: "predicate #{predicate_id} status flip-flopping"

  defp alert_detail(:flake_suspicion, _predicate_id, _detail), do: "a predicate is flip-flopping"

  defp alert_detail(:regression_recovered, predicate_id, _detail) when is_binary(predicate_id),
    do: "predicate #{predicate_id} recovered green → red → green"

  defp alert_detail(:regression_recovered, _predicate_id, _detail),
    do: "a past regression has recovered"

  # ---------------------------------------------------------------------------
  # Event river — the newest fleet-wide events (`Kazi.Sink.Events`), the SAME
  # source `KaziWeb.EventRiverLive` reads, windowed tight for a glance ticker.
  # ---------------------------------------------------------------------------

  defp river_entries(runs) do
    runs
    |> Enum.flat_map(&run_river_events/1)
    |> Enum.sort_by(& &1.observed_at, {:desc, DateTime})
    |> Enum.take(@river_window)
    |> Enum.map(&river_label/1)
  end

  defp run_river_events(%Run{events_sink_path: nil}), do: []

  defp run_river_events(%Run{} = run) do
    run.events_sink_path
    |> Events.read()
    |> Enum.map(fn event ->
      %{
        goal_ref: event["goal_ref"] || run.goal_ref,
        type: event["type"] || "event",
        observed_at: parse_river_time(event["observed_at"])
      }
    end)
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

  defp utc_clock, do: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")

  defp scope_word(:closed), do: "CLOSED"
  defp scope_word(_current), do: "LIVE"

  # Scope-aware empty state: an empty CURRENT grid with closed history points the
  # operator at the CLOSED toggle rather than falsely implying nothing ever ran.
  defp empty_message(:current, %{closed: closed}) when closed > 0,
    do: "No live runs right now — #{closed} closed. Switch to CLOSED, or open the goal board."

  defp empty_message(:closed, _counts), do: "No closed runs."

  defp empty_message(_scope, _counts),
    do: "No runs registered yet. Start a `kazi apply` and it will appear here."

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <main id="mission-control" class="shell">
      <div class="inner">
        <header class="topbar">
          <div class="wordmark display-heading">KAZI<span class="wm2">FLEET</span></div>

          <div class="clockwrap">
            <%!-- Operator/debug mode toggle (ADR-0078, T63.7). The McDebug hook
            mirrors the active mode to localStorage and restores it on a bare
            `/` visit; the links are the canonical URL-param switch. --%>
            <div
              id="mc-mode"
              class="segmented modetoggle"
              data-mode={if @debug?, do: "debug", else: "operator"}
              phx-hook="McDebug"
            >
              <.link
                patch={~p"/"}
                class={"seg" <> if(not @debug?, do: " on", else: "")}
                data-mode-option="operator"
              >
                OPERATOR
              </.link>
              <.link
                patch={~p"/?debug=1"}
                class={"seg" <> if(@debug?, do: " on", else: "")}
                data-mode-option="debug"
              >
                DEBUG
              </.link>
            </div>
            <span class="live"><span class="livedot"></span>LIVE</span>
            <span id="mc-clock" class="clock">{@clock} UTC</span>
          </div>
        </header>

        <section :if={@alerts != []} id="mc-attention">
          <div class="seclabel section-label">NEEDS ATTENTION</div>
          <div id="mc-attention-affordance" class="attnaffordance">
            stuck, over-budget, or awaiting operator — live runs only
          </div>
          <div class="attnrow">
            <.link
              :for={a <- @alerts}
              id={"mc-alert-#{a.goal_ref}-#{a.signal}"}
              navigate={~p"/goals/#{a.goal_ref}/drillin"}
              class={a.cls}
              data-signal={a.signal}
              data-goal-ref={a.goal_ref}
            >
              <div class="asev">{a.sev}</div>
              <div class="abody">
                <div class="atitle">{a.title}</div>
                <div class="adetail" title={a.detail}>{a.detail}</div>
              </div>
              <span class="peek">PEEK →</span>
            </.link>
          </div>
        </section>

        <section id="mc-fleet">
          <div :if={@roadmap?} class="seclabel section-label">
            ROADMAP · {@instance_count} GOALS · {length(@waves)} WAVES
          </div>
          <div :if={not @roadmap?} class="fleethead">
            <span class="seclabel section-label">
              FLEET · {@instance_count} {scope_word(@session_scope)}
            </span>

            <div class="fleetcontrols">
              <div id="mc-fleet-chips" class="segmented" data-state-filter={@state_filter}>
                <button
                  :for={
                    {key, dot, count, label} <- [
                      {:running, "dg", @counts.running, "RUNNING"},
                      {:converged, "dgg", @counts.converged, "CONVERGED"},
                      {:stuck, "dr", @counts.stuck, "STUCK"},
                      {:over_budget, "da", @counts.over_budget, "OVER-BUDGET"}
                    ]
                  }
                  type="button"
                  class={"seg" <> if(@state_filter == key, do: " on", else: "")}
                  data-count={key}
                  phx-click="toggle_state_filter"
                  phx-value-state={key}
                >
                  <span class={"dot " <> dot}></span>{count} {label}
                </button>
              </div>

              <div id="mc-scope" class="segmented scopetoggle" data-scope={@session_scope}>
                <button
                  :for={
                    {scope, label, count} <- [
                      {:current, "CURRENT", @scope_counts.current},
                      {:closed, "CLOSED", @scope_counts.closed}
                    ]
                  }
                  type="button"
                  class={"seg" <> if(@session_scope == scope, do: " on", else: "")}
                  data-scope-option={scope}
                  phx-click="set_session_scope"
                  phx-value-scope={scope}
                >
                  {label} · {count}
                </button>
              </div>

              <form id="mc-filters" class="filterrow" phx-change="set_filters">
                <select name="repo" class="filtersel" data-filter="repo">
                  <option value="" selected={is_nil(@repo_filter)}>ALL REPOS</option>
                  <option :for={repo <- @repos} value={repo} selected={@repo_filter == repo}>
                    {repo}
                  </option>
                </select>
                <select name="window" class="filtersel" data-filter="window">
                  <option value="" selected={is_nil(@time_window)}>ALL TIME</option>
                  <option
                    :for={label <- ["1h", "6h", "24h", "7d", "30d"]}
                    value={label}
                    selected={time_window_label(@time_window) == label}
                  >
                    LAST {label}
                  </option>
                </select>
                <span id="mc-filters-busy" class="mc-busy-indicator" aria-hidden="true"></span>
              </form>
            </div>
          </div>

          <p
            :if={not @roadmap? and @cards == [] and @filters_hide_runs?}
            id="mission-control-filtered-empty"
            class="empty-state"
          >
            No runs match the current filters — clear the chip / repo / time filters to see the fleet.
          </p>

          <p
            :if={not @roadmap? and @cards == [] and not @filters_hide_runs?}
            id="mission-control-empty"
            class="empty-state"
          >
            {empty_message(@session_scope, @scope_counts)}
          </p>

          <%!-- Direction B (T63.6): the flat grid groups by project under ruled
          headers. A single-project fleet drops the header (it would be
          redundant) and renders one bare grid. --%>
          <div :if={not @roadmap? and @card_groups != []} id="mc-fleet-groups">
            <div
              :for={group <- @card_groups}
              class="projgroup"
              data-project-group={group.project}
            >
              <div
                :if={@multi_project?}
                class="projgroup-head section-label"
                data-project-group-head={group.project}
              >
                {group.project}
              </div>
              <div class="grid">
                <.fleet_card :for={g <- group.cards} card={g} />
              </div>
            </div>
          </div>

          <div :for={wave <- @waves} class="wave" data-frontier={wave.frontier}>
            <div class="wavehead section-label">{wave.label}</div>
            <div class="grid">
              <.fleet_card :for={g <- wave.cards} card={g} />
            </div>
          </div>

          <.link :if={@older_count > 0} id="mc-older" navigate={~p"/goals"} class="older-link">
            +{@older_count} more on the goal board →
          </.link>
        </section>

        <section :if={@planned != []} id="mc-planned">
          <div class="seclabel section-label">
            PLANNED · {length(@planned) + @planned_more} APPROVED, NOT DISPATCHED
          </div>
          <div class="grid">
            <div
              :for={p <- @planned}
              id={"mc-planned-#{p.proposal_ref}"}
              class="card c-todo"
              data-proposal-ref={p.proposal_ref}
            >
              <div class="cardtop">
                <div class="gname">{p.goal_id}</div>
                <div class="stpill st-todo">TODO</div>
              </div>
              <div class="csub">{p.proposal_ref}</div>
              <div :if={p.roadmap_ref} class="csub">{p.roadmap_ref}</div>
            </div>
          </div>
          <p :if={@planned_more > 0} id="mc-planned-more" class="older-link">
            +{@planned_more} more approved — `kazi list-proposed`
          </p>
        </section>
      </div>

      <%!-- Expert surfaces (ADR-0078, T63.7): only present in DEBUG mode. The
      debug nav links the three full expert pages; the SESSIONS rail (lease
      presence) and the EVENT RIVER footer render inline below it. In operator
      mode none of this is in the DOM. --%>
      <nav :if={@debug?} id="mc-debug-nav" class="debugnav">
        <span class="seclabel section-label">DEBUG · EXPERT SURFACES</span>
        <.link id="mc-debug-dag" navigate={~p"/dag"} class="debuglink">DAG</.link>
        <.link id="mc-debug-leases" navigate={~p"/leases"} class="debuglink">LEASE MAP</.link>
        <.link id="mc-debug-events" navigate={~p"/events"} class="debuglink">EVENT RIVER</.link>
      </nav>

      <section :if={@debug?} id="mc-sessions" data-source={inspect(@coord_source)}>
        <div class="seclabel section-label">SESSIONS</div>
        <ul :if={@presence != []} id="mc-sessions-list" class="sessions">
          <li
            :for={entry <- @presence}
            id={"presence-#{entry.instance}"}
            data-instance={entry.instance}
            class="session-row"
          >
            <span class="instance">{entry.instance}</span>
            <span :if={entry[:machine]} class="machine" data-machine={entry[:machine]}>
              {entry[:machine]}
            </span>
            <span :if={entry[:last_seen]} class="last-seen" data-last-seen={entry[:last_seen]}>
              {entry[:last_seen]}
            </span>
          </li>
        </ul>
        <p :if={@presence == []} id="mc-sessions-empty" class="empty-state">
          No sessions present.
        </p>
      </section>

      <footer :if={@debug?} id="mc-event-river" class="river">
        <div class="riverin">
          <div class="riverlabel section-label">EVENT RIVER</div>
          <div :if={@river_entries != []} class="tickerwrap">
            <div class="ticker">
              <span :for={entry <- @river_entries} class="tk">{entry}</span>
              <span :for={entry <- @river_entries} class="tk" aria-hidden="true">{entry}</span>
            </div>
          </div>
          <p :if={@river_entries == []} id="mission-control-river-empty" class="empty-state">
            No events yet.
          </p>
        </div>
      </footer>

      <style>
        .shell { min-height: 100vh; display: flex; flex-direction: column;
          background: radial-gradient(1200px 500px at 50% -200px, rgba(83,214,255,.05), transparent 70%), var(--bg); }
        .inner { width: 100%; max-width: 1440px; margin: 0 auto; padding: 0 28px; box-sizing: border-box; flex: 1; display: flex; flex-direction: column; }

        .topbar { display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 16px 0; border-bottom: 1px solid var(--line); flex-wrap: wrap; }
        .wordmark { font-size: 18px; letter-spacing: .22em; color: #EAF3FC; }
        .wordmark .wm2 { color: var(--cyn); margin-left: 8px; font-weight: 500; }
        .dot { width: 7px; height: 7px; border-radius: 50%; }
        .dot.dg { background: var(--cyn); box-shadow: 0 0 8px var(--cyn); }
        .dot.dgg { background: var(--grn); box-shadow: 0 0 8px var(--grn); }
        .dot.dr { background: var(--red); box-shadow: 0 0 8px var(--red); }
        .dot.da { background: var(--amb); box-shadow: 0 0 8px var(--amb); }
        .clockwrap { display: flex; align-items: center; gap: 16px; }
        .live { display: flex; align-items: center; gap: 7px; color: var(--grn); font-size: 11px; letter-spacing: .2em; }
        .livedot { width: 8px; height: 8px; border-radius: 50%; background: var(--grn); box-shadow: 0 0 10px var(--grn); }
        .clock { font-size: 14px; color: #EAF3FC; font-weight: 500; letter-spacing: .1em; min-width: 116px; text-align: right; }

        .seclabel { margin: 20px 0 10px; }
        .attnaffordance { color: var(--dim); font-size: 10px; letter-spacing: .04em; margin: -6px 0 8px; }
        .fleethead { display: flex; align-items: center; justify-content: space-between; gap: 12px 20px; flex-wrap: wrap; }
        /* Direction B (T63.6): state / scope / repo / time controls fold into the
           FLEET header as one right-aligned cluster of segmented controls. */
        .fleetcontrols { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-left: auto; }
        .segmented { display: inline-flex; border: 1px solid var(--line); border-radius: 3px; overflow: hidden; background: var(--panel); }
        .segmented .seg { display: flex; align-items: center; gap: 7px; background: transparent; border: 0; border-right: 1px solid var(--line); color: var(--txt); font: inherit; font-size: 10px; letter-spacing: .1em; padding: 6px 11px; cursor: pointer; }
        .segmented .seg:last-child { border-right: 0; }
        .segmented .seg:hover { background: rgba(255,255,255,.03); }
        .segmented .seg.on { color: var(--cyn); background: rgba(83,214,255,.1); }
        .scopetoggle .seg { font-size: 9px; letter-spacing: .16em; color: var(--dim); }
        .scopetoggle .seg.on { color: var(--cyn); }
        /* Operator/debug mode toggle (ADR-0078, T63.7): a topbar segmented
           control; the <.link> segments reuse the .seg look. */
        .modetoggle .seg { font-size: 9px; letter-spacing: .16em; color: var(--dim); text-decoration: none; }
        .modetoggle .seg.on { color: var(--cyn); }
        /* DEBUG expert-surface nav (ADR-0078, T63.7): only present in debug mode. */
        .debugnav { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; margin: 8px 0 4px; }
        .debugnav .seclabel { margin: 0; }
        .debuglink { font-size: 10px; letter-spacing: .12em; color: var(--dim); text-decoration: none; border: 1px solid var(--line); border-radius: 3px; padding: 5px 10px; }
        .debuglink:hover { color: var(--cyn); border-color: rgba(83,214,255,.45); }
        .filterrow { display: flex; align-items: center; gap: 8px; margin: 0; }
        .filtersel { background: var(--panel); border: 1px solid var(--line); color: var(--txt); font: inherit; font-size: 10px; letter-spacing: .12em; padding: 5px 8px; border-radius: 3px; cursor: pointer; }
        .filtersel:hover { border-color: var(--dim); }
        .mc-busy-indicator { display: none; width: 12px; height: 12px; align-self: center; border: 2px solid var(--line); border-top-color: var(--cyn); border-radius: 50%; animation: mc-spin .6s linear infinite; }
        .filterrow.phx-change-loading .mc-busy-indicator { display: inline-block; }
        @keyframes mc-spin { to { transform: rotate(360deg); } }
        .wave { margin-bottom: 8px; }
        .wavehead { color: var(--cyn); opacity: .8; letter-spacing: .3em; margin: 14px 0 10px; }

        .attnrow { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 14px; }
        .alert { display: flex; align-items: center; gap: 14px; border: 1px solid var(--line); background: var(--panel); padding: 12px 14px; border-radius: 4px; text-decoration: none; color: inherit; }
        .alert:hover { border-color: var(--dim); }
        .al-bad { border-color: rgba(255,85,102,.55); box-shadow: 0 0 22px -10px rgba(255,85,102,.6); }
        .al-warn { border-color: rgba(255,180,84,.45); box-shadow: 0 0 22px -12px rgba(255,180,84,.5); }
        .asev { font-size: 10px; font-weight: 700; letter-spacing: .14em; padding: 4px 8px; border-radius: 2px; flex-shrink: 0; }
        .al-bad .asev { color: var(--red); border: 1px solid rgba(255,85,102,.6); }
        .al-warn .asev { color: var(--amb); border: 1px solid rgba(255,180,84,.5); }
        .abody { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
        .atitle { color: #EAF3FC; font-weight: 700; font-size: 12px; }
        .adetail { color: var(--dim); font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .peek { font-size: 10px; letter-spacing: .12em; color: var(--cyn); border: 1px solid rgba(83,214,255,.4); border-radius: 3px; padding: 6px 10px; flex-shrink: 0; }
        .alert:hover .peek { background: rgba(83,214,255,.1); }

        .grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; padding-bottom: 20px; }
        .card { border: 1px solid var(--line); background: var(--panel); border-radius: 5px; padding: 14px 16px; display: flex; flex-direction: column; gap: 10px; text-decoration: none; color: inherit; }
        a.card:hover { border-color: var(--dim); }
        .c-run { border-color: rgba(83,214,255,.28); }
        .c-ok { border-color: rgba(61,255,160,.4); box-shadow: 0 0 26px -14px rgba(61,255,160,.7); }
        .c-bad { border-color: rgba(255,85,102,.6); box-shadow: 0 0 26px -12px rgba(255,85,102,.7); }
        .c-warn { border-color: rgba(255,180,84,.5); box-shadow: 0 0 26px -14px rgba(255,180,84,.5); }
        .c-claimed { border-color: rgba(83,214,255,.35); border-style: dashed; }
        .c-pending { border-color: var(--line); opacity: .7; }
        .c-todo { border-style: dashed; border-color: var(--line); opacity: .8; }
        .c-todo:hover { opacity: 1; border-color: var(--dim); }
        .cardtop { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
        .gname { color: #EAF3FC; font-weight: 700; font-size: 14px; overflow-wrap: anywhere; }
        .stpill { font-size: 9px; font-weight: 700; letter-spacing: .16em; padding: 3px 8px; border-radius: 2px; flex-shrink: 0; }
        .st-run { color: var(--cyn); border: 1px solid rgba(83,214,255,.4); }
        .st-ok { color: var(--grn); border: 1px solid rgba(61,255,160,.5); }
        .st-bad { color: var(--red); border: 1px solid rgba(255,85,102,.6); }
        .st-warn { color: var(--amb); border: 1px solid rgba(255,180,84,.5); }
        .st-claimed { color: var(--cyn); border: 1px dashed rgba(83,214,255,.5); }
        .st-pending { color: var(--dim); border: 1px solid var(--line); }
        .st-todo { color: var(--dim); border: 1px dashed var(--line); }
        /* Direction B (T63.6): the flat grid groups by project under a ruled
           header; the header carries the org/repo the card badge used to. */
        .projgroup + .projgroup { margin-top: 6px; }
        .projgroup-head { display: flex; align-items: center; gap: 12px; color: var(--cyn); opacity: .85; letter-spacing: .2em; margin: 18px 0 10px; overflow-wrap: anywhere; }
        .projgroup-head::after { content: ""; flex: 1; height: 1px; background: var(--line); }
        .gmeta2 { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
        .csub { color: var(--dim); font-size: 11px; }
        .ws { color: var(--dim); font-size: 11px; }
        .hbadge { font-size: 10px; color: var(--txt); border: 1px solid var(--line); background: var(--panel2); padding: 3px 8px; border-radius: 2px; }
        /* Direction B (T63.6): one right-aligned relative timestamp per card
           (last heartbeat, falling back to run start) replaces the AGE/ACTIVE row. */
        .cardtime { margin-left: auto; font-size: 10px; color: var(--dim); letter-spacing: .08em; }
        .iter { font-size: 10px; color: var(--dim); letter-spacing: .08em; }
        .dnarow { display: flex; gap: 4px; padding: 2px 0; flex-wrap: wrap; align-items: center; }
        .dna { width: 14px; height: 14px; border-radius: 2px; background: #1A2433; }
        .dna.dg { background: rgba(61,255,160,.85); box-shadow: 0 0 7px rgba(61,255,160,.55); }
        .dna.dr { background: rgba(255,85,102,.8); box-shadow: 0 0 7px rgba(255,85,102,.45); }
        .dna.dx { background: #1A2433; }
        .dna-more { font-size: 10px; color: var(--dim); margin-left: 2px; }
        .cardbot { display: flex; align-items: flex-end; justify-content: space-between; gap: 14px; }
        .burnwrap { flex: 1; display: flex; flex-direction: column; gap: 5px; min-width: 0; }
        .burnlabel { font-size: 10px; color: var(--dim); }
        .burn { height: 4px; background: #16202E; border-radius: 2px; overflow: hidden; }
        .burnfill { height: 100%; border-radius: 2px; }
        .b-ok { background: var(--cyn); }
        .b-warn { background: var(--amb); }
        .b-hot { background: var(--red); }
        .spark { width: 72px; height: 20px; flex-shrink: 0; }
        .sparkline { fill: none; stroke: var(--grn); stroke-width: 1.5; opacity: .9; }

        .older-link { display: inline-block; color: var(--dim); font-size: 10px; letter-spacing: .12em; text-decoration: none; padding-bottom: 16px; }
        .older-link:hover { color: var(--cyn); }
        .empty-state { color: var(--dim); font-size: 12px; padding: 24px 0; }

        .river { border-top: 1px solid var(--line); background: var(--panel); }
        .riverin { max-width: 1440px; margin: 0 auto; padding: 10px 28px; display: flex; align-items: center; gap: 18px; box-sizing: border-box; }
        .riverlabel { flex-shrink: 0; margin: 0; }
        .tickerwrap { flex: 1; min-width: 0; overflow: hidden;
          -webkit-mask-image: linear-gradient(90deg, transparent, #000 4%, #000 96%, transparent);
          mask-image: linear-gradient(90deg, transparent, #000 4%, #000 96%, transparent); }
        .ticker { display: flex; width: max-content; }
        .tk { padding-right: 80px; font-size: 11px; color: var(--txt); white-space: nowrap; }

        @media (prefers-reduced-motion: no-preference) {
          .livedot { animation: mc-pulse 1.6s ease-in-out infinite; }
          .c-bad { animation: mc-alarm 2.2s ease-in-out infinite; }
          .ticker { animation: mc-scroll 48s linear infinite; }
        }

        /* Mobile: the alert + fleet grids collapse to a single column and the
           topbar wraps into the thumb zone. No separate tab bar — the card grid
           reflows, which is the whole point of a grid layout. */
        @media (max-width: 820px) {
          .inner, .riverin { padding-left: 16px; padding-right: 16px; }
          .attnrow, .grid { grid-template-columns: 1fr; }
          .topbar { gap: 12px; }
          .clockwrap { width: 100%; justify-content: space-between; }
        }
        @media (max-width: 1080px) and (min-width: 821px) {
          .attnrow, .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
        }
      </style>
    </main>
    """
  end

  # One fleet card — a navigable link when it is backed by a run (there is a
  # drill-in to peek), a plain tile for a declared-but-undispatched roadmap
  # group (nothing to drill into yet).
  attr :card, :map, required: true

  defp fleet_card(%{card: %{run?: true}} = assigns) do
    ~H"""
    <.link
      id={"mc-card-#{@card.goal_ref}"}
      navigate={~p"/goals/#{@card.goal_ref}/drillin"}
      class={@card.card_cls}
      data-goal-ref={@card.goal_ref}
      data-state={@card.state}
      data-run="true"
    >
      <div class="cardtop">
        <div class="gname">{@card.name}</div>
        <div class={@card.pill_cls} data-state={@card.state}>{@card.state_label}</div>
      </div>

      <div class="gmeta2">
        <span class="hbadge">{@card.harness}</span>
        <span :if={@card.ws} class="ws">{@card.ws}</span>
        <span class="iter">ITER {@card.iter}</span>
        <span :if={@card.rel} class="cardtime" data-rel={@card.rel}>{@card.rel} ago</span>
      </div>

      <div class="dnarow">
        <span :for={p <- @card.preds} class={p.cls}></span>
        <span :if={@card.dna_overflow > 0} class="dna-more">+{@card.dna_overflow}</span>
      </div>

      <div class="cardbot">
        <div :if={@card.budget_label} class="burnwrap">
          <div class="burnlabel">{@card.budget_label}</div>
          <div class="burn">
            <div class={@card.burn_cls} style={@card.burn_w}></div>
          </div>
        </div>
        <svg :if={@card.spark != ""} class="spark" viewBox="0 0 64 18" preserveAspectRatio="none">
          <polyline class="sparkline" points={@card.spark}></polyline>
        </svg>
      </div>
    </.link>
    """
  end

  defp fleet_card(assigns) do
    ~H"""
    <div
      id={"mc-card-#{@card.goal_ref}"}
      class={@card.card_cls}
      data-goal-ref={@card.goal_ref}
      data-run="false"
      data-state={@card.state}
      data-remote={to_string(Map.get(@card, :remote?, false))}
    >
      <div class="cardtop">
        <div class="gname">{@card.name}</div>
        <div class={@card.pill_cls} data-state={@card.state}>{@card.state_label}</div>
      </div>
      <div :if={@card.sub} class="csub">{@card.sub}</div>
    </div>
    """
  end
end
