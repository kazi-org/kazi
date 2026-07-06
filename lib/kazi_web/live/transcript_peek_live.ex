defmodule KaziWeb.TranscriptPeekLive do
  @moduledoc """
  The per-run transcript peek (T46.8, UC-062, ADR-0057): tails a run's
  `transcript.jsonl` (`Kazi.Sink.Transcript`) so an operator can watch (or
  post-mortem-replay) the raw harness stream a `kazi apply` iteration produced.

  There is exactly ONE code path for both cases: `mount/3` resolves the run
  (`Kazi.ReadModel.RunRegistry.get/1`) and reads its transcript sink fully;
  a connected mount additionally polls on a short interval and reloads the
  events when `@follow` is enabled — for a live run this streams newly
  appended lines in; for a finished/dead run the file simply never grows, so
  the SAME poll is a no-op and the initial read already shows the whole
  transcript with no watcher required.

  Tool-shaped events (`"type"` starting with `"tool"`, e.g. `tool_use` /
  `tool_result`) collapse to a one-line pill (tool name); clicking a pill
  expands it to its full payload. A `{"type": "truncated"}` marker
  (`Kazi.Sink.Transcript`'s size-cap event) renders as an explicit notice
  rather than folding or silently vanishing. The **follow** toggle pauses/
  resumes picking up newly tailed lines without losing what's already
  rendered.

  Pure read projection (ADR-0011 §2): it never mutates a run or a sink file.
  """
  use KaziWeb, :live_view

  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Sink.Transcript

  # Poll interval for tailing the sink file. Cheap either way: a live run's
  # sink grows between ticks; a finished run's sink is stable so the reread is
  # a no-op. A LiveView test never waits this long — it sends `:tick` directly.
  @poll_ms 500

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_ms)

    run = registry().get(run_id)

    {:ok,
     socket
     |> assign(:page_title, "kazi · transcript · #{run_id}")
     |> assign(:run_id, run_id)
     |> assign(:run, run)
     |> assign(:follow, true)
     |> assign(:expanded, MapSet.new())
     |> assign(:events, load_events(run))}
  end

  @impl true
  def handle_info(:tick, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_ms)

    socket =
      if socket.assigns.follow do
        assign(socket, :events, load_events(socket.assigns.run))
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_follow", _params, socket) do
    {:noreply, assign(socket, :follow, !socket.assigns.follow)}
  end

  def handle_event("toggle_event", %{"index" => index}, socket) do
    index = String.to_integer(index)
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, index) do
        MapSet.delete(expanded, index)
      else
        MapSet.put(expanded, index)
      end

    {:noreply, assign(socket, :expanded, expanded)}
  end

  # The injectable read-model seam (ADR-0011 §3): override in test config to
  # feed the lookup a fixture registry; defaults to the real one.
  defp registry do
    Application.get_env(:kazi, :transcript_peek_registry, RunRegistry)
  end

  defp load_events(nil), do: []
  defp load_events(%{transcript_sink_path: nil}), do: []
  defp load_events(%{transcript_sink_path: path}), do: Transcript.read(path)

  defp tool_event?(%{"type" => type}) when is_binary(type) do
    String.starts_with?(type, "tool")
  end

  defp tool_event?(_event), do: false

  defp truncated_event?(%{"type" => "truncated"}), do: true
  defp truncated_event?(_event), do: false

  defp pill_label(event), do: event["name"] || event["type"]

  defp expanded_payload(event), do: event |> Map.delete("type") |> Jason.encode!()

  defp text_line(%{"type" => "text", "text" => text}), do: text
  defp text_line(event), do: inspect(event)

  @impl true
  def render(assigns) do
    ~H"""
    <main id="transcript-peek" data-run-id={@run_id}>
      <h1>kazi transcript peek · {@run_id}</h1>
      <p>
        Tails a run's redacted <code>transcript.jsonl</code>
        (the same code path for a live run and a finished one -- see <code>Kazi.Sink.Transcript</code>).
      </p>

      <p :if={is_nil(@run)} id="transcript-peek-missing">
        No run registered for {@run_id}.
      </p>

      <div :if={@run}>
        <p id="transcript-peek-status" data-status={@run.status}>
          status: {@run.status}
        </p>

        <button
          type="button"
          phx-click="toggle_follow"
          id="follow-toggle"
          data-follow={to_string(@follow)}
        >
          {if @follow, do: "Following", else: "Paused"}
        </button>

        <p :if={@events == []} id="transcript-peek-empty">No transcript events yet.</p>

        <ol :if={@events != []} id="transcript-events" data-event-count={length(@events)}>
          <li
            :for={{event, index} <- Enum.with_index(@events)}
            id={"transcript-event-#{index}"}
            data-event-type={event["type"]}
          >
            <p
              :if={truncated_event?(event)}
              class="truncated-notice"
              id={"transcript-event-#{index}-truncated"}
            >
              Transcript truncated: {event["reason"] || "size_cap_exceeded"}
            </p>

            <div :if={tool_event?(event)} class="tool-pill">
              <button
                type="button"
                phx-click="toggle_event"
                phx-value-index={index}
                id={"toggle-event-#{index}"}
              >
                {pill_label(event)}
              </button>
              <pre
                :if={MapSet.member?(@expanded, index)}
                id={"transcript-event-#{index}-output"}
              >{expanded_payload(event)}</pre>
            </div>

            <p
              :if={!tool_event?(event) and !truncated_event?(event)}
              class="transcript-line"
              id={"transcript-event-#{index}-text"}
            >
              {text_line(event)}
            </p>
          </li>
        </ol>
      </div>
    </main>
    """
  end
end
