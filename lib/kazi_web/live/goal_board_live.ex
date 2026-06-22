defmodule KaziWeb.GoalBoardLive do
  @moduledoc """
  The operator goal board (T3.6b, UC-018, ADR-0011).

  Lists every goal the read-model has recorded an iteration for, each with its
  derived status, a pass/total predicate-vector summary, and its iteration count.
  The board is a pure READ projection: it queries `Kazi.ReadModel.list_goals/0`
  and subscribes to the read-model's goal-board PubSub topic so a newly recorded
  iteration pushes a LIVE diff — it NEVER calls into `Kazi.Loop` or
  `Kazi.Harness.*` (ADR-0011 §2).

  The data source is injectable (ADR-0011 §3): it defaults to `Kazi.ReadModel`
  but can be overridden via the `:read_model` application env so a LiveView test
  can drive the board from a fixture source with no NATS and no harness. The
  default source IS the (sandbox-isolated) read-model, which is itself the
  hermetic fixture for the LiveView/Playwright tests.

  When no goals have been recorded the board renders a clear empty state.
  """
  use KaziWeb, :live_view

  alias Kazi.ReadModel.GoalSummary

  @impl true
  def mount(_params, _session, socket) do
    source = read_model_source()

    # Live updates: subscribe to the read-model's goal-board topic on the
    # connected mount only (the disconnected/static render has no socket to push
    # to). A broadcast re-reads the board and pushes a diff.
    if connected?(socket), do: Phoenix.PubSub.subscribe(Kazi.PubSub, source.goal_board_topic())

    {:ok,
     socket
     |> assign(:page_title, "kazi · goal board")
     |> assign(:source, source)
     |> load_goals()}
  end

  @impl true
  def handle_info({:iteration_recorded, _goal_ref}, socket) do
    # A new iteration landed: re-read the board so status, vector summary, and
    # iteration count reflect it, then let LiveView push the minimal diff.
    {:noreply, load_goals(socket)}
  end

  defp load_goals(socket) do
    assign(socket, :goals, socket.assigns.source.list_goals())
  end

  # The injectable read-model seam (ADR-0011 §3): override in test config to feed
  # the board a fixture source; defaults to the real read-model.
  defp read_model_source do
    Application.get_env(:kazi, :goal_board_source, Kazi.ReadModel)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="goal-board">
      <h1>kazi goal board</h1>
      <p>Read-only projection of the reconciler (ADR-0011). Live-updating.</p>

      <table :if={@goals != []} id="goals">
        <thead>
          <tr>
            <th>Goal</th>
            <th>Status</th>
            <th>Predicates</th>
            <th>Iterations</th>
            <th>History</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={goal <- @goals} id={"goal-#{goal.goal_ref}"} data-goal-ref={goal.goal_ref}>
            <td class="goal-ref">{goal.goal_ref}</td>
            <td>
              <span class={"status status-#{goal.status}"} data-status={goal.status}>
                {status_label(goal.status)}
              </span>
            </td>
            <td class="predicates" data-predicates={predicate_badge(goal)}>
              {predicate_badge(goal)}
            </td>
            <td class="iterations" data-iterations={goal.iteration_count}>
              {goal.iteration_count}
            </td>
            <td class="history">
              <.link navigate={~p"/goals/#{goal.goal_ref}/history"} class="history-link">
                Timeline
              </.link>
            </td>
          </tr>
        </tbody>
      </table>

      <p :if={@goals == []} id="goal-board-empty" class="empty-state">
        No goals yet. Author a goal and run the reconciler to populate the board.
      </p>
    </main>
    """
  end

  # The pass/total predicate badge, e.g. "2/3". Rendered into the row and mirrored
  # into a data attribute so the Playwright/LiveView tests can assert on it.
  defp predicate_badge(%GoalSummary{} = goal) do
    {passing, total} = GoalSummary.predicate_summary(goal)
    "#{passing}/#{total}"
  end

  defp status_label(:converged), do: "converged"
  defp status_label(:in_progress), do: "in progress"
end
