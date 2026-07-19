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
    source = socket.assigns.source
    goal_ref = socket.assigns.goal_ref
    iterations = source.list_iterations(goal_ref)

    socket
    |> assign(:iterations, iterations)
    |> assign(:gap, gap_fields(source, goal_ref))
    |> assign(:summary, summarize(iterations))
  end

  # The injectable read-model seam (ADR-0011 §3): override in test config to feed
  # the matrix a fixture source; defaults to the real read-model.
  defp source do
    Application.get_env(:kazi, :drillin_source, Kazi.ReadModel)
  end

  # T63.10's gap-field projection (narrative intent, predicate display groups,
  # missing-counter tally). Read through the same injectable source when it
  # exposes the projection, else the real read-model — a fixture source that only
  # implements `list_iterations/1` still renders (empty gap fields).
  defp gap_fields(source, goal_ref) do
    if function_exported?(source, :goal_gap_fields, 1) do
      source.goal_gap_fields(goal_ref)
    else
      Kazi.ReadModel.goal_gap_fields(goal_ref)
    end
  end

  # ---------------------------------------------------------------------------
  # Summary + narrative (#1379 mock): plain-language reads over the REAL vectors.
  # ---------------------------------------------------------------------------

  # A one-sentence read of the goal's latest state: status, iteration, pass/total,
  # named blockers, and a regression tally — every number straight from the
  # persisted vectors, never fabricated. `nil` when the goal has no iterations.
  defp summarize([]), do: nil

  defp summarize(iterations) do
    latest = List.last(iterations)
    %Kazi.PredicateVector{results: results} = Kazi.ReadModel.to_predicate_vector(latest)
    sorted = Enum.sort_by(results, fn {id, _result} -> id end)
    passing = Enum.count(sorted, fn {_id, result} -> result.status == :pass end)
    blocking = for {id, result} <- sorted, result.status in [:fail, :error], do: to_string(id)
    regressions = iterations |> Enum.flat_map(& &1.regressions) |> length()
    converged? = latest.converged == true

    %{
      status: if(converged?, do: "converged", else: "in_progress"),
      status_label: if(converged?, do: "converged", else: "in progress"),
      index: latest.iteration_index,
      total: length(sorted),
      pass: passing,
      blocking: blocking,
      regressions: regressions
    }
  end

  defp summary_blocking(%{blocking: []}), do: ", none blocking — all green"

  defp summary_blocking(%{blocking: names}),
    do: ", #{length(names)} blocking convergence (#{Enum.join(names, ", ")})"

  defp summary_regressions(%{regressions: 0}), do: "No regressions recorded yet."

  defp summary_regressions(%{regressions: n}),
    do: "#{n} regression#{if n == 1, do: "", else: "s"} recorded across the history."

  # The display group for a predicate id, from T63.10's projection (the id's own
  # prefix convention) — `nil` for an id with no separable prefix (honest-unknown).
  defp predicate_group(%{predicate_groups: groups}, predicate_id),
    do: Map.get(groups, to_string(predicate_id))

  defp predicate_group(_gap, _predicate_id), do: nil

  # The detail panel's narrative-first line: the recorded action (T63.10
  # narrative-intent, paraphrased — never manufactured), the vector counts, and
  # the verdict for the selected iteration.
  defp detail_narrative(%Iteration{} = iteration) do
    %Kazi.PredicateVector{results: results} = Kazi.ReadModel.to_predicate_vector(iteration)
    passing = Enum.count(results, fn {_id, result} -> result.status == :pass end)

    action =
      case iteration.action_kind do
        kind when is_binary(kind) and kind != "" -> "action: #{kind}"
        _none -> "observation only (no dispatch recorded)"
      end

    verdict = if iteration.converged, do: "converged", else: "not converged"

    "Iteration #{iteration.iteration_index}: #{action} → " <>
      "#{passing} of #{map_size(results)} predicates pass → #{verdict}."
  end

  defp detail_narrative(_nil), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <main id="drillin" data-goal-ref={@goal_ref}>
      <h1 id="drillin-title">Drill-in · {@goal_ref}</h1>
      <%!-- T63.11 (#1379 mock): a one-line PURPOSE statement — the question the
      view answers — replaces the old mechanism-describing subtitle. --%>
      <p id="drillin-purpose" class="purpose">
        What this view is for: see exactly <b>which predicate is blocking this goal,
        on which iteration, and what the evidence says</b>.
      </p>

      <nav>
        <.link navigate={~p"/goals/#{@goal_ref}/history"} id="nav-history">
          → Full history (narrative)
        </.link>
      </nav>

      <p :if={@iterations == []} id="drillin-empty" class="empty-state">
        No iterations recorded for this goal yet — nothing to drill into. This goal
        has not run, so there is no heatmap to show (not an error).
      </p>

      <%!-- Plain-language summary sentence (#1379 mock): counts + named blockers
      read straight from the latest real vector; never a fabricated claim. --%>
      <p :if={@summary} id="drillin-summary" class="summary" data-status={@summary.status}>
        This goal is <b>{@summary.status_label}, iteration {@summary.index}</b>: {@summary.pass} of {@summary.total} predicates pass{summary_blocking(
          @summary
        )}. {summary_regressions(@summary)}
      </p>

      <%!-- On-page LEGEND (#1379 mock): the cell colors/glyphs were previously
      decodable only by reading the inline stylesheet. --%>
      <div :if={@iterations != []} id="drillin-legend" class="legend">
        <span class="section-label">LEGEND</span>
        <span class="legend-item" data-legend="pass">
          <span class="swatch status-pass"></span> ● pass — predicate satisfied
        </span>
        <span class="legend-item" data-legend="fail">
          <span class="swatch status-fail"></span> ✕ fail — predicate not satisfied
        </span>
        <span class="legend-item" data-legend="error">
          <span class="swatch status-error"></span> ! error — predicate could not be evaluated
        </span>
        <span class="legend-item" data-legend="not_evaluated">
          <span class="swatch status-not_evaluated"></span>
          · not evaluated — predicate not yet in the vector
        </span>
        <span class="legend-item" data-legend="regression-flip">
          <span class="swatch regression-flip"></span>
          amber outline — a green→red regression flipped here
        </span>
      </div>

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
              <th class="predicate-col" title="the goal's acceptance predicates (rows)">
                predicate <span class="col-hint">(click an iteration number to inspect it)</span>
              </th>
              <th
                :for={iteration <- @iterations}
                id={"heatmap-col-#{iteration.iteration_index}"}
                class={col_class(iteration, @iterations)}
                data-iteration-index={iteration.iteration_index}
                data-current={to_string(current?(iteration, @iterations))}
                title="iteration (a single reconcile-loop observation), oldest to newest"
              >
                <button
                  type="button"
                  phx-click="scrub"
                  phx-value-index={iteration.iteration_index}
                  id={"scrub-#{iteration.iteration_index}"}
                >
                  {iteration.iteration_index}
                  <span :if={current?(iteration, @iterations)} class="col-current">
                    · current
                  </span>
                </button>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={predicate_id <- predicate_ids(@iterations)}
              id={"heatmap-row-#{predicate_id}"}
              data-predicate-id={predicate_id}
              data-group={predicate_group(@gap, predicate_id)}
            >
              <th class="predicate-col">
                {predicate_id}<span
                  :if={predicate_group(@gap, predicate_id)}
                  class="group-tag"
                  data-group-tag={predicate_group(@gap, predicate_id)}
                >{predicate_group(@gap, predicate_id)}</span>
              </th>
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
        <h2>
          Iteration {selected(@iterations, @selected_index).iteration_index} — what happened here
        </h2>

        <%!-- Narrative-first line (#1379 mock), paraphrasing T63.10's
        narrative-intent (the recorded action_kind — never a manufactured
        sentence) plus the vector counts. --%>
        <p id="drillin-detail-narrative" class="detail-narrative">
          {detail_narrative(selected(@iterations, @selected_index))}
        </p>

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

        <%!-- Honest-unknown note (#1379 mock gap #2, T63.10 missing_counters):
        say how much tool/context history is genuinely unavailable rather than
        letting the "-" placeholders read as zeros. --%>
        <p
          :if={@gap.missing_counters.tools_missing > 0 or @gap.missing_counters.context_missing > 0}
          id="drillin-detail-missing"
          class="detail-missing"
          data-tools-missing={@gap.missing_counters.tools_missing}
          data-context-missing={@gap.missing_counters.context_missing}
        >
          Tool/context counters are unavailable for {@gap.missing_counters.tools_missing} of {@gap.missing_counters.total_iterations} iterations (tools) and {@gap.missing_counters.context_missing} of {@gap.missing_counters.total_iterations} (context) — a "-" means "not
          recorded", not zero.
        </p>
      </section>

      <style>
        /* T63.11 (#1379 mock): purpose header, summary, legend, group tags. */
        .purpose { color: var(--dim); font-size: .95rem; margin: 0 0 1rem; }
        .summary { background: var(--panel, #101a2e); border: 1px solid var(--line, #1c2a45);
          border-radius: 8px; padding: .8rem 1rem; margin: 1rem 0; font-size: 1rem; }
        .summary b { color: var(--amb); }
        .legend { display: flex; gap: 1.1rem; flex-wrap: wrap; align-items: center;
          margin: 1rem 0 1.4rem; font-size: .8rem; color: var(--dim); }
        .legend-item { display: inline-flex; align-items: center; gap: .35rem; }
        .legend .swatch { width: 12px; height: 12px; border-radius: 2px; display: inline-block; background: #152134; }
        .legend .swatch.status-pass { background: var(--grn); }
        .legend .swatch.status-fail { background: var(--red); }
        .legend .swatch.status-error { background: var(--red); opacity: .7; }
        .legend .swatch.regression-flip { background: #152134; outline: 2px solid var(--amb); }
        .col-hint { color: var(--dim); font-weight: 400; font-size: .72rem; }
        .col-current { color: var(--amb); font-size: .72rem; }
        .group-tag { color: var(--amb); font-size: .68rem; margin-left: .4rem; opacity: .8; }
        .detail-narrative { color: var(--dim); margin: .2rem 0 1rem; }
        .detail-missing { color: var(--amb); font-size: .8rem; margin-top: .8rem; }
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
