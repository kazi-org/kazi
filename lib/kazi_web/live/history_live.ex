defmodule KaziWeb.HistoryLive do
  @moduledoc """
  The per-goal iteration / evidence history view (T3.6d, UC-018, ADR-0011).

  Renders an ORDERED timeline of every iteration the read-model has recorded for
  one goal (oldest-first, by `iteration_index`): for each iteration its index,
  its full predicate vector (each predicate's id, status, and the structured
  evidence that justified the status), the action the loop took, any regression
  flags, the release ref, and when it was observed.

  Like the goal board (T3.6b) this is a pure READ projection: it queries
  `Kazi.ReadModel.list_iterations/1` and subscribes to the read-model's
  goal-board PubSub topic so a freshly recorded iteration for THIS goal appends
  to the timeline live. It NEVER calls into `Kazi.Loop` or `Kazi.Harness.*`
  (ADR-0011 §2).

  The data source is injectable (ADR-0011 §3): it defaults to `Kazi.ReadModel`
  but can be overridden via the `:history_source` application env so a LiveView
  test can drive the timeline from a fixture source with no NATS and no harness.
  The default source IS the (sandbox-isolated) read-model, which is itself the
  hermetic fixture for the LiveView/Playwright tests.

  When the goal has no recorded iterations the view renders a clear empty state.
  """
  use KaziWeb, :live_view

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
    # timeline so the newly recorded iteration appends, then push the diff.
    {:noreply, load_timeline(socket)}
  end

  # An iteration for a DIFFERENT goal: ignore — this view tracks one goal only.
  def handle_info({:iteration_recorded, _other_goal_ref}, socket), do: {:noreply, socket}

  defp load_timeline(socket) do
    assign(socket, :iterations, socket.assigns.source.list_iterations(socket.assigns.goal_ref))
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
      <h1>kazi history · {@goal_ref}</h1>
      <p>
        Read-only iteration/evidence timeline for this goal (ADR-0011).
        Live-updating, oldest first.
      </p>

      <nav>
        <.link navigate={~p"/goals"} id="nav-goal-board">Back to goal board</.link>
      </nav>

      <ol :if={@iterations != []} id="timeline">
        <li
          :for={iteration <- @iterations}
          id={"iteration-#{iteration.iteration_index}"}
          class="iteration"
          data-iteration-index={iteration.iteration_index}
        >
          <header class="iteration-header">
            <span class="iteration-index" data-iteration-index={iteration.iteration_index}>
              Iteration {iteration.iteration_index}
            </span>
            <span
              :if={iteration.converged}
              class="converged"
              data-converged="true"
            >
              converged
            </span>
            <span class="observed-at">{format_observed_at(iteration.observed_at)}</span>
          </header>

          <ul class="predicate-vector" data-predicate-count={predicate_count(iteration)}>
            <li
              :for={{id, result} <- predicates(iteration)}
              id={"iteration-#{iteration.iteration_index}-predicate-#{id}"}
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

          <p
            :if={iteration.action_kind not in [nil, ""]}
            class="action"
            data-action-kind={iteration.action_kind}
          >
            Action: {iteration.action_kind}
          </p>

          <p
            :if={iteration.release_ref not in [nil, ""]}
            class="release-ref"
            data-release-ref={iteration.release_ref}
          >
            Release: {iteration.release_ref}
          </p>
        </li>
      </ol>

      <p :if={@iterations == []} id="history-empty" class="empty-state">
        No iterations recorded for this goal yet.
      </p>
    </main>
    """
  end

  # The iteration's predicate vector as a stably-ordered list of {id, result}
  # pairs (sorted by predicate id) so the timeline renders deterministically and
  # the Playwright/LiveView tests can assert a fixed order. The vector is
  # rehydrated via the read-model so each result is a %Kazi.PredicateResult{}.
  defp predicates(%Iteration{} = iteration) do
    iteration
    |> Kazi.ReadModel.to_predicate_vector()
    |> Map.fetch!(:results)
    |> Enum.sort_by(fn {id, _result} -> id end)
  end

  defp predicate_count(%Iteration{} = iteration), do: length(predicates(iteration))

  # Render evidence as a compact, stable key=value string (sorted by key) so the
  # proof behind each status is visible and assertable. An empty evidence map
  # renders as an empty string.
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
