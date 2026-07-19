defmodule KaziWeb.HistoryLive do
  @moduledoc """
  The per-goal history view — the goal's whole story, newest event first
  (T3.6d rebuilt in T63.12 per the approved #1379 / T63.3 mock; UC-018, UC-062,
  ADR-0011).

  Reads the ORDERED iteration timeline the read-model recorded for one goal and
  renders it as a NEWEST-FIRST narrative: a one-line purpose header, a
  plain-language convergence summary, then one narrative event per iteration
  ("iteration N: dispatched -> predicates X passed -> verdict") instead of a raw
  dump of every predicate row. Each event's narrative is computed from the
  iteration's action plus a diff of its predicate vector against the PRIOR
  iteration's (which predicates flipped fail->pass, which regressed), so a reader
  gets what changed each step rather than a wall of statuses. The full vector is
  still available per event behind a `<details>` disclosure.

  Honest-unknown (ADR-0046): the summary never implies an iteration budget it
  does not have ("of an unknown total"), and an in-progress iteration renders a
  "not yet converged" pending state — NOT a fabricated terminal verdict. A
  verdict clause is emitted only for an iteration the controller actually judged
  converged.

  Like the goal board (T3.6b) this is a pure READ projection: it queries
  `Kazi.ReadModel.list_iterations/1` and subscribes to the read-model's
  goal-board PubSub topic so a freshly recorded iteration for THIS goal updates
  the timeline live. It NEVER calls into `Kazi.Loop` or `Kazi.Harness.*`
  (ADR-0011 §2).

  The data source is injectable (ADR-0011 §3): it defaults to `Kazi.ReadModel`
  but can be overridden via the `:history_source` application env so a LiveView
  test can drive the timeline from a fixture source with no NATS and no harness.
  """
  use KaziWeb, :live_view

  alias Kazi.PredicateVector
  alias Kazi.ReadModel.Iteration

  @impl true
  def mount(%{"id" => goal_ref}, _session, socket) do
    source = history_source()

    # Live updates: subscribe to the read-model's goal-board topic on the
    # connected mount only (the disconnected/static render has no socket to push
    # to). A broadcast for THIS goal re-reads its timeline and pushes a diff.
    if connected?(socket), do: Phoenix.PubSub.subscribe(Kazi.PubSub, source.goal_board_topic())

    {:ok,
     socket
     |> assign(:page_title, "kazi · history · #{goal_ref}")
     |> assign(:goal_ref, goal_ref)
     |> assign(:source, source)
     |> load_timeline()}
  end

  @impl true
  def handle_info({:iteration_recorded, goal_ref}, %{assigns: %{goal_ref: goal_ref}} = socket) do
    # A new iteration landed for the goal this view is showing: re-read its
    # timeline so the newly recorded iteration takes its place at the top.
    {:noreply, load_timeline(socket)}
  end

  # An iteration for a DIFFERENT goal: ignore — this view tracks one goal only.
  def handle_info({:iteration_recorded, _other_goal_ref}, socket), do: {:noreply, socket}

  defp load_timeline(socket) do
    iterations = socket.assigns.source.list_iterations(socket.assigns.goal_ref)
    events = build_events(iterations)

    socket
    |> assign(:events, events)
    |> assign(:summary, build_summary(events))
  end

  # The injectable read-model seam (ADR-0011 §3): override in test config to feed
  # the timeline a fixture source; defaults to the real read-model.
  defp history_source do
    Application.get_env(:kazi, :history_source, Kazi.ReadModel)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="history" data-goal-ref={@goal_ref}>
      <h1>History · {@goal_ref}</h1>
      <p class="purpose">
        What this view is for: read the goal's whole story, newest event first —
        what was tried each iteration and what it changed.
      </p>

      <nav>
        <.link navigate={~p"/goals"} id="nav-goal-board">Back to goal board</.link>
      </nav>

      <section
        :if={@summary}
        id="history-summary"
        class="summary"
        data-status={@summary.status}
        data-iteration-count={@summary.iteration_count}
        data-pass={@summary.pass_count}
        data-fail={@summary.fail_count}
      >
        {summary_sentence(@summary)}
      </section>

      <ol :if={@events != []} id="timeline" class="timeline">
        <li
          :for={event <- @events}
          id={"iteration-#{event.index}"}
          class={"event #{event_class(event)}"}
          data-iteration-index={event.index}
        >
          <header class="event-head">
            <span class="idx" data-iteration-index={event.index}>
              Iteration {event.index}
            </span>
            <span
              :if={event.converged}
              class="badge converged"
              data-verdict="converged"
            >
              converged
            </span>
            <span
              :if={not event.converged and event.latest?}
              class="badge pending"
              data-pending="true"
            >
              in progress
            </span>
            <time class="observed-at">{format_observed_at(event.observed_at)}</time>
          </header>

          <p class="narrative" data-narrative={narrative(event)}>
            {narrative(event)}
          </p>

          <details>
            <summary>full predicate vector ({event.total})</summary>
            <ul class="vector" data-predicate-count={event.total}>
              <li
                :for={{id, result} <- event.results}
                id={"iteration-#{event.index}-predicate-#{id}"}
                class="predicate"
                data-predicate-id={id}
              >
                <span class="predicate-id">{id}</span>
                <span class={"predicate-status status-#{result.status}"} data-status={result.status}>
                  {result.status}
                </span>
                <span class="predicate-evidence" data-evidence={format_evidence(result.evidence)}>
                  {format_evidence(result.evidence)}
                </span>
              </li>
            </ul>
          </details>

          <p
            :if={event.release_ref not in [nil, ""]}
            class="release-ref"
            data-release-ref={event.release_ref}
          >
            Release: {event.release_ref}
          </p>
        </li>
      </ol>

      <p :if={@events == []} id="history-empty" class="empty-state">
        No iterations recorded for this goal yet.
      </p>
    </main>
    """
  end

  # ── Narrative construction ────────────────────────────────────────────────
  #
  # Walk the oldest-first iteration timeline, building one event per iteration
  # whose narrative diffs its predicate vector against the PRIOR iteration's, then
  # reverse so the newest event renders first.
  defp build_events(iterations) do
    pairs = Enum.map(iterations, fn %Iteration{} = it -> {it, predicate_results(it)} end)
    latest_index = length(pairs) - 1

    pairs
    |> Enum.with_index()
    |> Enum.map(fn {{it, results}, i} ->
      prior = if i > 0, do: elem(Enum.at(pairs, i - 1), 1), else: nil
      build_event(it, results, prior, i == latest_index)
    end)
    |> Enum.reverse()
  end

  defp build_event(%Iteration{} = it, results, prior, latest?) do
    passing = for {id, r} <- results, r.status == :pass, do: id
    failing = for {id, r} <- results, r.status == :fail, do: id

    {newly_passing, regressed} = flips(results, prior)

    %{
      index: it.iteration_index,
      observed_at: it.observed_at,
      converged: it.converged,
      action_kind: it.action_kind,
      release_ref: it.release_ref,
      latest?: latest?,
      first?: prior == nil,
      pass_count: length(passing),
      fail_count: length(failing),
      total: map_size(results),
      newly_passing: Enum.sort(newly_passing),
      regressed: Enum.sort(regressed),
      results: Enum.sort_by(results, fn {id, _} -> id end)
    }
  end

  # A predicate is newly passing when it passes now but failed in the prior
  # vector; it regressed when it fails now but passed before. The first iteration
  # has no prior to diff against, so it carries no flips.
  defp flips(_results, nil), do: {[], []}

  defp flips(results, prior) do
    newly_passing =
      for {id, r} <- results,
          r.status == :pass,
          match?(%{status: :fail}, Map.get(prior, id)),
          do: id

    regressed =
      for {id, r} <- results,
          r.status == :fail,
          match?(%{status: :pass}, Map.get(prior, id)),
          do: id

    {newly_passing, regressed}
  end

  defp predicate_results(%Iteration{} = it) do
    %PredicateVector{results: results} = Kazi.ReadModel.to_predicate_vector(it)
    Map.new(results)
  end

  defp build_summary([]), do: nil

  defp build_summary([latest | _] = events) do
    %{
      status: if(latest.converged, do: :converged, else: :in_progress),
      iteration_count: length(events),
      pass_count: latest.pass_count,
      fail_count: latest.fail_count,
      total: latest.total,
      index: latest.index,
      regressed: latest.regressed
    }
  end

  # ── Rendering helpers ─────────────────────────────────────────────────────

  defp event_class(%{converged: true}), do: "converged"
  defp event_class(%{latest?: true}), do: "inprogress"
  defp event_class(_), do: "past"

  # The plain-language headline both the summary panel here and the drill-in view
  # share. "of an unknown total" is deliberate ADR-0046 honest-unknown phrasing:
  # the read-model records no iteration budget, so this view must not imply one.
  defp summary_sentence(%{status: :converged} = s) do
    "This goal converged in #{count_word(s.iteration_count, "iteration")}: " <>
      "#{s.pass_count} of #{s.total} predicates pass." <> regression_clause(s)
  end

  defp summary_sentence(%{status: :in_progress} = s) do
    "This goal is in progress, iteration #{s.index} of an unknown total: " <>
      "#{s.pass_count} of #{s.total} predicates pass, #{s.fail_count} fail." <>
      regression_clause(s)
  end

  defp regression_clause(%{regressed: [_ | _] = ids}),
    do:
      " #{count_word(length(ids), "regression")} at the latest iteration (#{Enum.join(ids, ", ")})."

  defp regression_clause(%{iteration_count: 1}),
    do: " No regressions recorded — only one observation exists so far."

  defp regression_clause(_), do: " No regressions at the latest iteration."

  # One-sentence narrative for an event, arrow-separated, computed from the
  # iteration's action and its diff against the prior vector. A verdict clause is
  # appended ONLY when the controller judged this iteration converged — an
  # in-progress iteration ends at the count, never a fabricated terminal verdict.
  defp narrative(%{first?: true} = e) do
    ["iteration #{e.index}: first observation"]
    |> then(&(&1 ++ ["#{e.pass_count} of #{e.total} predicates passing"]))
    |> then(&(&1 ++ ["#{e.fail_count} failing"]))
    |> append_verdict(e)
    |> Enum.join(" -> ")
  end

  defp narrative(%{} = e) do
    [lead_clause(e), change_clause(e), "#{e.pass_count} of #{e.total} predicates passing"]
    |> append_verdict(e)
    |> Enum.join(" -> ")
  end

  defp lead_clause(%{index: index, action_kind: kind}) when kind not in [nil, ""],
    do: "iteration #{index}: dispatched #{kind}"

  defp lead_clause(%{index: index}), do: "iteration #{index}: observed"

  defp change_clause(%{newly_passing: np, regressed: rg}) do
    parts =
      []
      |> maybe_clause(np, "flipped fail->pass")
      |> maybe_clause(rg, "regressed pass->fail")

    case parts do
      [] -> "no predicate changed"
      clauses -> Enum.join(clauses, "; ")
    end
  end

  defp maybe_clause(acc, [], _label), do: acc
  defp maybe_clause(acc, ids, label), do: acc ++ ["#{Enum.join(ids, ", ")} #{label}"]

  defp append_verdict(parts, %{converged: true}), do: parts ++ ["converged"]
  defp append_verdict(parts, _), do: parts

  defp count_word(1, noun), do: "1 #{noun}"
  defp count_word(n, noun), do: "#{n} #{noun}s"

  # Render evidence as a compact, stable key=value string (sorted by key) so the
  # proof behind each status stays visible and assertable behind the disclosure.
  defp format_evidence(evidence) when is_map(evidence) do
    evidence
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{format_value(value)}" end)
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)

  defp format_observed_at(%DateTime{} = observed_at),
    do: DateTime.to_iso8601(observed_at)

  defp format_observed_at(_), do: ""
end
