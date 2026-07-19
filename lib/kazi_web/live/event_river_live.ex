defmodule KaziWeb.EventRiverLive do
  @moduledoc """
  The fleet-wide event river (T47.1, UC-061/UC-062, ADR-0057): a single feed
  of every registered run's `events.jsonl`, newest first, so an operator can
  watch the whole fleet's loop activity without opening each run's drill-in
  one at a time.

  `mount/3` reads every run's events sink (`Kazi.Sink.Events.read/1`, the SAME
  torn-tail-tolerant reader the drill-in heatmap and `kazi apply --explain`
  data spine rely on), tags each event with the run it came from (a run's
  events already carry `goal_ref`; the run_id is added here since the sink
  itself has no notion of which run it belongs to), and merges every run's
  events into one list ordered by `observed_at` descending, bounded to
  `@window` entries fleet-wide. A run with no `events_sink_path` (not
  persisted) or an unreadable/missing sink file contributes zero events
  rather than erroring the whole feed — same for a torn final line, which
  `Kazi.Sink.Events.read/1` already drops silently.

  A connected mount polls (`@poll_ms`) and rereads every run's sink, so an
  appended line is visible on the next tick with no restart — the same
  poll-and-reread shape as `KaziWeb.MissionControlLive` and
  `KaziWeb.TranscriptPeekLive`.

  Each entry deep-links to its run's transcript peek and its goal's drill-in,
  so "what happened" (this feed) and "show me everything" (the per-run/per-
  goal views) are one click apart.

  Pure read projection (ADR-0011 §2): it never mutates a run, a goal, or a
  sink file.
  """
  use KaziWeb, :live_view

  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Sink.Events

  # Poll interval for rereading every run's sink (matches MissionControlLive's fleet
  # poll cadence). A LiveView test never waits this long -- it sends `:tick`
  # directly.
  @poll_ms 2_000

  # Fleet-wide bound on how many of the newest events are rendered, so a busy
  # fleet's feed stays a glance rather than an unbounded scroll.
  @window 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_ms)

    {:ok,
     socket
     |> assign(:page_title, "kazi · event river")
     |> assign(:window, @window)
     |> assign_events()}
  end

  @impl true
  def handle_info(:tick, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_ms)

    {:noreply, assign_events(socket)}
  end

  defp assign_events(socket) do
    assign(socket, :events, load_events())
  end

  defp load_events do
    registry().list()
    |> Enum.flat_map(&run_events/1)
    |> Enum.sort_by(& &1.observed_at, {:desc, DateTime})
    |> Enum.take(@window)
  end

  defp run_events(%{events_sink_path: nil}), do: []

  defp run_events(run) do
    run.events_sink_path
    |> Events.read()
    |> Enum.map(&to_entry(&1, run))
  end

  defp to_entry(event, run) do
    %{
      run_id: run.run_id,
      goal_ref: event["goal_ref"] || run.goal_ref,
      type: event["type"] || "event",
      iteration: event["iteration"],
      converged: event["converged"],
      observed_at: parse_observed_at(event["observed_at"])
    }
  end

  defp parse_observed_at(nil), do: DateTime.from_unix!(0)

  defp parse_observed_at(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> DateTime.from_unix!(0)
    end
  end

  # The injectable read-model seam (ADR-0011 §3): override in test config to
  # feed the lookup a fixture registry; defaults to the real one.
  defp registry do
    Application.get_env(:kazi, :event_river_registry, RunRegistry)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="event-river">
      <h1>kazi event river</h1>
      <p>
        Fleet-wide feed of every registered run's <code>events.jsonl</code>,
        newest first (bounded to {@window}).
      </p>

      <p :if={@events == []} id="event-river-empty" class="empty-state">
        No events yet. Start a `kazi apply` and its loop events will appear here.
      </p>

      <ol :if={@events != []} id="event-river-entries" data-event-count={length(@events)}>
        <li
          :for={event <- @events}
          id={"event-river-entry-#{event.run_id}-#{event.iteration}"}
          data-run-id={event.run_id}
          data-goal-ref={event.goal_ref}
          data-type={event.type}
          class="event-river-entry"
        >
          <span class="event-river-goal">{event.goal_ref}</span>
          <span class="event-river-type" data-type={event.type}>{event.type}</span>
          <span :if={event.iteration} class="event-river-iteration">
            iter {event.iteration}
          </span>
          <span :if={event.converged == true} class="event-river-converged">converged</span>

          <.link navigate={~p"/goals/#{event.goal_ref}/drillin"} class="event-river-drillin-link">
            drill in
          </.link>
          <.link navigate={~p"/runs/#{event.run_id}/transcript"} class="event-river-transcript-link">
            transcript
          </.link>
        </li>
      </ol>

      <style>
        .event-river-entry { display: flex; align-items: center; gap: .6rem; padding: .5rem .7rem; border-radius: .4rem; border: 1px solid rgba(0,0,0,.2); margin-bottom: .4rem; }
      </style>
    </main>
    """
  end
end
