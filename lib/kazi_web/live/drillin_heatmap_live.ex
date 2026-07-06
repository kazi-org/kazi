defmodule KaziWeb.DrillinHeatmapLive do
  @moduledoc """
  The per-goal drill-in convergence heatmap + iteration scrubber (T46.7, UC-062,
  ADR-0057).

  Renders a **predicates x iterations matrix** from the read-model's per-iteration
  vectors: rows are predicate ids (the union seen across the goal's history),
  columns are iterations oldest-to-newest, and each cell is that predicate's
  status at that observation (pass / fail / error / unknown / not-evaluated when
  the predicate wasn't part of the vector yet). A green->red regression flip
  (`Kazi.Loop.RegressionDetector`, T1.2) is marked visually distinct on the cell
  where it was observed, and the newest column is marked **current**.

  A **scrubber** (click a column header) selects one iteration; the detail panel
  below the matrix then shows that iteration's full predicate vector, its
  dispatch action, and the ADR-0046 context/tool counters. With no explicit
  selection the detail panel follows the current (latest) iteration.

  Like `KaziWeb.HistoryLive` this is a pure READ projection: it reads
  `Kazi.ReadModel.list_iterations/1` and subscribes to the read-model's
  goal-board PubSub topic so a freshly recorded iteration appends to the matrix
  live. It never calls into `Kazi.Loop` or `Kazi.Harness.*` (ADR-0011 §2).

  The data source is injectable (ADR-0011 §3): it defaults to `Kazi.ReadModel`
  but can be overridden via the `:drillin_source` application env so a LiveView
  test can drive the matrix from a fixture source with no NATS and no harness.
  """
  use KaziWeb, :live_view

  alias Kazi.ReadModel.Iteration

  @impl true
  def mount(%{"id" => goal_ref}, _session, socket) do
    source = source()

    # Live updates: subscribe to the read-model's goal-board topic on the
    # connected mount only (the disconnected/static render has no socket to push
    # to). A broadcast for THIS goal re-reads its history so the matrix grows a
    # column and the detail panel (if following "current") advances.
    if connected?(socket), do: Phoenix.PubSub.subscribe(Kazi.PubSub, source.goal_board_topic())

    {:ok,
     socket
     |> assign(:page_title, "kazi · drill-in · #{goal_ref}")
     |> assign(:goal_ref, goal_ref)
     |> assign(:source, source)
     |> assign(:selected_index, nil)
     |> load_iterations()}
  end

  @impl true
  def handle_info({:iteration_recorded, goal_ref}, %{assigns: %{goal_ref: goal_ref}} = socket) do
    {:noreply, load_iterations(socket)}
  end

  def handle_info({:iteration_recorded, _other_goal_ref}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("scrub", %{"index" => index}, socket) do
    {:noreply, assign(socket, :selected_index, String.to_integer(index))}
  end

  defp load_iterations(socket) do
    assign(socket, :iterations, socket.assigns.source.list_iterations(socket.assigns.goal_ref))
  end

  # The injectable read-model seam (ADR-0011 §3): override in test config to feed
  # the matrix a fixture source; defaults to the real read-model.
  defp source do
    Application.get_env(:kazi, :drillin_source, Kazi.ReadModel)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="drillin" data-goal-ref={@goal_ref}>
      <h1>kazi drill-in · {@goal_ref}</h1>
      <p>
        Predicate x iteration convergence heatmap, with a scrubber onto each
        iteration's vector, dispatch, and context counters (ADR-0011, read-only).
      </p>

      <nav>
        <.link navigate={~p"/goals/#{@goal_ref}/history"} id="nav-history">Full history</.link>
      </nav>

      <p :if={@iterations == []} id="drillin-empty" class="empty-state">
        No iterations recorded for this goal yet.
      </p>

      <div
        :if={@iterations != []}
        id="drillin-dna-strip"
        class="dna-strip"
        data-square-count={length(dna_squares(@iterations))}
      >
        <span class="section-label">PREDICATE VECTOR</span>
        <div class="dna-squares">
          <span
            :for={square <- dna_squares(@iterations)}
            id={"dna-square-#{square.id}"}
            class={"dna-square status-#{square.status}"}
            data-predicate-id={square.id}
            data-status={square.status}
            title={square.id}
          ></span>
        </div>
      </div>

      <div
        :if={@iterations != []}
        id="drillin-matrix"
        data-iteration-count={length(@iterations)}
      >
        <table id="heatmap">
          <thead>
            <tr>
              <th>predicate</th>
              <th
                :for={iteration <- @iterations}
                id={"heatmap-col-#{iteration.iteration_index}"}
                class={col_class(iteration, @iterations)}
                data-iteration-index={iteration.iteration_index}
                data-current={to_string(current?(iteration, @iterations))}
              >
                <button
                  type="button"
                  phx-click="scrub"
                  phx-value-index={iteration.iteration_index}
                  id={"scrub-#{iteration.iteration_index}"}
                >
                  {iteration.iteration_index}
                </button>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={predicate_id <- predicate_ids(@iterations)}
              id={"heatmap-row-#{predicate_id}"}
              data-predicate-id={predicate_id}
            >
              <th>{predicate_id}</th>
              <td
                :for={iteration <- @iterations}
                id={"heatmap-cell-#{predicate_id}-#{iteration.iteration_index}"}
                class={cell_class(predicate_id, iteration)}
                data-status={cell_status(predicate_id, iteration)}
                data-regression-flip={to_string(regression_flip?(predicate_id, iteration))}
              >
                {cell_glyph(cell_status(predicate_id, iteration))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <section
        :if={selected(@iterations, @selected_index)}
        id="drillin-detail"
        data-selected-index={selected(@iterations, @selected_index).iteration_index}
      >
        <h2>Iteration {selected(@iterations, @selected_index).iteration_index}</h2>

        <ul id="drillin-detail-vector">
          <li
            :for={{id, result} <- detail_predicates(selected(@iterations, @selected_index))}
            id={"drillin-detail-predicate-#{id}"}
            class={"predicate-status status-#{result.status}"}
            data-predicate-id={id}
            data-status={result.status}
          >
            <span class="predicate-id">{id}</span>
            <span class="predicate-status">{result.status}</span>
          </li>
        </ul>

        <p
          :if={selected(@iterations, @selected_index).action_kind not in [nil, ""]}
          id="drillin-detail-action"
          data-action-kind={selected(@iterations, @selected_index).action_kind}
        >
          Action: {selected(@iterations, @selected_index).action_kind}
        </p>

        <dl id="drillin-detail-counters">
          <dt>tool_calls</dt>
          <dd data-counter="tool_calls">
            {counter(selected(@iterations, @selected_index), :tools, "tool_calls")}
          </dd>
          <dt>file_reads</dt>
          <dd data-counter="file_reads">
            {counter(selected(@iterations, @selected_index), :tools, "file_reads")}
          </dd>
          <dt>orientation_tokens</dt>
          <dd data-counter="orientation_tokens">
            {counter(selected(@iterations, @selected_index), :context, "orientation_tokens")}
          </dd>
          <dt>evidence_tokens</dt>
          <dd data-counter="evidence_tokens">
            {counter(selected(@iterations, @selected_index), :context, "evidence_tokens")}
          </dd>
          <dt>tier</dt>
          <dd data-counter="tier">
            {counter(selected(@iterations, @selected_index), :context, "tier")}
          </dd>
        </dl>
      </section>

      <style>
        .dna-strip { margin: 1rem 0; }
        .dna-squares { display: flex; gap: 3px; flex-wrap: wrap; margin-top: .4rem; }
        .dna-square { width: 15px; height: 15px; display: inline-block; background: #152134; border-radius: 2px; }
        .dna-square.status-pass { background: var(--grn); box-shadow: 0 0 6px rgba(46,230,168,.5); }
        .dna-square.status-fail { background: var(--red); box-shadow: 0 0 6px rgba(255,92,108,.5); }
        .dna-square.status-error { background: var(--red); }
        .dna-square.status-not_evaluated { background: #152134; }
        .heatmap-cell.status-pass { background: var(--grn); }
        .heatmap-cell.status-fail { background: var(--red); }
        .heatmap-cell.regression-flip { outline: 2px solid var(--amb); }
      </style>
    </main>
    """
  end

  # The stably-ordered union of predicate ids seen across the goal's whole
  # history (sorted) — a predicate introduced mid-run still gets a row, with
  # "not-evaluated" cells for the iterations before it existed.
  defp predicate_ids(iterations) do
    iterations
    |> Enum.flat_map(fn %Iteration{predicate_vector: vector} -> Map.keys(vector) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp cell_status(predicate_id, %Iteration{predicate_vector: vector}) do
    case Map.get(vector, predicate_id) do
      %{"status" => status} -> status
      nil -> "not_evaluated"
    end
  end

  defp cell_class(predicate_id, %Iteration{} = iteration) do
    base = "heatmap-cell status-#{cell_status(predicate_id, iteration)}"

    if regression_flip?(predicate_id, iteration) do
      base <> " regression-flip"
    else
      base
    end
  end

  # A regression flip cell: this predicate is recorded in THIS iteration's
  # `regressions` list as the one whose green->red transition was first
  # observed here (T1.2, `red_iteration == iteration.iteration_index`).
  defp regression_flip?(predicate_id, %Iteration{regressions: regressions} = iteration) do
    Enum.any?(regressions, fn flag ->
      flag["predicate_id"] == predicate_id && flag["red_iteration"] == iteration.iteration_index
    end)
  end

  defp cell_glyph("pass"), do: "●"
  defp cell_glyph("fail"), do: "✕"
  defp cell_glyph("error"), do: "!"
  defp cell_glyph("unknown"), do: "?"
  defp cell_glyph(_not_evaluated), do: "·"

  defp col_class(iteration, iterations) do
    if current?(iteration, iterations), do: "heatmap-col current", else: "heatmap-col"
  end

  defp current?(%Iteration{iteration_index: index}, iterations) do
    case List.last(iterations) do
      %Iteration{iteration_index: ^index} -> true
      _ -> false
    end
  end

  # The iteration the detail panel shows: the explicitly scrubbed one, or the
  # current (latest) iteration when nothing has been scrubbed yet. `nil` when
  # the goal has no iterations at all.
  defp selected(iterations, nil), do: List.last(iterations)

  defp selected(iterations, index) do
    Enum.find(iterations, &(&1.iteration_index == index)) || List.last(iterations)
  end

  # The selected iteration's predicate vector, rehydrated and stably sorted by
  # id (mirrors `KaziWeb.HistoryLive`'s presentation of a vector).
  defp detail_predicates(%Iteration{} = iteration) do
    iteration
    |> Kazi.ReadModel.to_predicate_vector()
    |> Map.fetch!(:results)
    |> Enum.sort_by(fn {id, _result} -> id end)
  end

  defp detail_predicates(nil), do: []

  # The DNA strip (docs/dashboard-design.md): the LATEST iteration's predicate
  # vector as a flat, stably-ordered list of squares -- the same predicates
  # `detail_predicates/1` shows for the current iteration, just a compact
  # glance instead of the full id/status list.
  defp dna_squares(iterations) do
    iterations
    |> List.last()
    |> detail_predicates()
    |> Enum.map(fn {id, result} -> %{id: id, status: result.status} end)
  end

  defp counter(%Iteration{} = iteration, field, key) do
    iteration
    |> Map.fetch!(field)
    |> Map.get(key)
    |> case do
      nil -> "-"
      value -> value
    end
  end

  defp counter(nil, _field, _key), do: "-"
end
