defmodule Kazi.Economy.Rediscovery do
  @moduledoc """
  Behavioral rediscovery-pressure signal (T48.10, ADR-0058 decision 3 --
  "behavior first, opinion second"): folds the T34.3 `tools` counters recorded
  across a goal's dispatches into a RANKED, REPORT-ONLY candidate list for an
  orientation-pack / retrieval-cache investment.

  ## Signal source and fidelity (read before trusting this report)

  The only per-dispatch signal kazi records is `Kazi.Loop.Counters.tools/1`'s
  four AGGREGATE counters (`tool_calls`, `file_reads`, `search_calls`,
  `graph_calls`) -- a per-iteration COUNT, not a list of which files or queries
  were touched. This holds for BOTH persistence paths: the `iterations` SQLite
  table (`Kazi.ReadModel.Iteration.tools`) and the per-run `events.jsonl` sink
  (`Kazi.Sink.Events`) -- a sink line is built from the SAME inserted
  `Iteration` struct the read-model row is (`Kazi.Runtime.build_on_iteration/5`
  composes the sink append inside `persist_iteration/3`), so it carries no
  finer detail. Neither source can name a specific re-read file or a repeated
  query string.

  Given that fidelity, this module reports PER-GOAL PRESSURE by tool category
  (`file_reads` / `search_calls` / `graph_calls` -- the same three
  `Kazi.Economy.KPIs.rediscovery_tool_calls_avoided/1` sums), never a per-file
  candidate list. It does NOT fabricate file-level detail the data cannot
  support -- the ADR-0046 honest-unknown discipline extends to signal
  GRANULARITY, not just presence.

  A category is a REDISCOVERY CANDIDATE when its calls PERSIST past the first
  (expected-cold) tool-bearing dispatch, mirroring `Kazi.Loop.Counters`'s own
  framing: a working stable prefix should show `file_reads`/`search_calls`
  FALL after the first dispatch (the orientation cache flipping miss -> hit).
  A category whose calls persist past the first dispatch means a stable
  prefix (or a retrieval cache) has not yet absorbed that rediscovery cost.

  ## Honest-unknown (ADR-0046 SS6)

  `tools` is populated ONLY when the harness exposed a tool-use stream (absent
  != zero -- see the `Kazi.Loop.Counters` moduledoc). A goal with NO
  tool-bearing iteration recorded -- pre-T34.3 history, or a harness/profile
  that never reports `tool_uses` -- reports `status: :unknown` with a reason,
  NEVER an empty candidate list (an empty list would read as "measured: no
  rediscovery", a claim this module cannot make without a signal). A goal
  WITH a tool-use signal but genuinely no persisting reads/searches (every
  category fell to zero after the first dispatch) reports `status: :ranked`
  with an EMPTY candidates list -- that IS a real, measured "no rediscovery
  pressure", a legitimately different claim from "unknown".

  ## Report-only (hard boundary)

  This module's output feeds NOTHING back into a dispatch prompt: no
  orientation pack, no retrieval cache, no context builder reads this report.
  It is surfaced only via `kazi economy --rediscovery <goal>` for a human to
  read and decide whether a stable prefix / retrieval cache is worth
  building. The benchmark gate (T48.12, ADR-0058 decision 3) is the ONLY path
  a candidate can take toward actually shipping as a prompt/context change.
  See `test/kazi/economy/rediscovery_prompt_boundary_test.exs`, which pins
  that no dispatch-prompt-building module references this one.

  Pure: folds a list of recorded iterations (or iteration-shaped maps); no
  I/O, no Repo access. The CLI (`kazi economy --rediscovery`) is the caller
  that reads `Kazi.ReadModel.list_iterations/1` and passes the result here.
  """

  @rediscovery_categories [:file_reads, :search_calls, :graph_calls]

  @typedoc "One ranked candidate: a tool category whose calls persisted past the first dispatch."
  @type candidate :: %{
          category: atom(),
          label: String.t(),
          total_calls: non_neg_integer(),
          recurring_calls: non_neg_integer(),
          recurring_dispatches: non_neg_integer(),
          dispatches_compared: non_neg_integer(),
          pressure: float()
        }

  @typedoc "The report `kazi economy --rediscovery` renders."
  @type report ::
          %{status: :ranked, candidates: [candidate()]}
          | %{status: :unknown, reason: String.t()}

  @doc """
  Fold a goal's recorded iterations (ascending `iteration_index`, the shape
  `Kazi.ReadModel.list_iterations/1` returns) into a ranked
  rediscovery-pressure report.

  Needs >= 2 TOOL-BEARING iterations to compare a baseline (the first tool
  bearing dispatch, expected cold) against everything after it -- the same
  threshold `Kazi.Economy.KPIs.rediscovery_tool_calls_avoided/1` uses for the
  single-run KPI this per-goal report complements. Fewer than 2 => `:unknown`
  (unmeasurable, never a fabricated zero).
  """
  @spec candidates([Kazi.ReadModel.Iteration.t() | map()]) :: report()
  def candidates(iterations) when is_list(iterations) do
    tool_bearing =
      iterations
      |> Enum.map(&tools_of/1)
      |> Enum.filter(&(map_size(&1) > 0))

    case {iterations, tool_bearing} do
      {[], _} ->
        unknown("no iterations recorded for this goal")

      {_, []} ->
        unknown(
          "no tool-use stream recorded for any iteration of this goal " <>
            "(the harness exposed no tool-use data for its dispatches)"
        )

      {_, [_only]} ->
        unknown(
          "only one tool-bearing dispatch recorded; rediscovery pressure needs " <>
            ">= 2 to compare a baseline against later dispatches"
        )

      {_, [baseline | rest]} ->
        %{status: :ranked, candidates: rank(baseline, rest)}
    end
  end

  @doc """
  Render a `t:report/0` as the JSON-safe object for `kazi economy
  --rediscovery --json`. Candidate `category` atoms render as strings; an
  `:unknown` report carries only `status`/`reason`, NEVER a `candidates` key --
  so a consumer can never mistake "unreported" for "measured empty".
  """
  @spec to_json(report()) :: map()
  def to_json(%{status: :unknown, reason: reason}) do
    %{"status" => "unknown", "reason" => reason}
  end

  def to_json(%{status: :ranked, candidates: candidates}) do
    %{
      "status" => "ranked",
      "candidates" => Enum.map(candidates, &candidate_json/1)
    }
  end

  defp candidate_json(c) do
    %{
      "category" => Atom.to_string(c.category),
      "label" => c.label,
      "total_calls" => c.total_calls,
      "recurring_calls" => c.recurring_calls,
      "recurring_dispatches" => c.recurring_dispatches,
      "dispatches_compared" => c.dispatches_compared,
      "pressure" => c.pressure
    }
  end

  # ===========================================================================
  # ranking
  # ===========================================================================

  defp unknown(reason), do: %{status: :unknown, reason: reason}

  defp rank(baseline, rest) do
    dispatches_compared = length(rest)

    @rediscovery_categories
    |> Enum.map(&candidate_for(&1, baseline, rest, dispatches_compared))
    |> Enum.filter(&(&1.recurring_calls > 0))
    |> Enum.sort_by(&{-&1.pressure, -&1.recurring_calls, &1.category}, :asc)
  end

  defp candidate_for(category, baseline, rest, dispatches_compared) do
    later_counts = Enum.map(rest, &int(fetch(&1, category)))
    recurring_calls = Enum.sum(later_counts)
    recurring_dispatches = Enum.count(later_counts, &(&1 > 0))
    baseline_calls = int(fetch(baseline, category))

    %{
      category: category,
      label: label_for(category),
      total_calls: baseline_calls + recurring_calls,
      recurring_calls: recurring_calls,
      recurring_dispatches: recurring_dispatches,
      dispatches_compared: dispatches_compared,
      pressure: pressure(recurring_calls, recurring_dispatches, dispatches_compared)
    }
  end

  # Pressure rewards BOTH magnitude (recurring_calls) and persistence (the
  # fraction of later dispatches that still paid the cost) -- a single late
  # spike ranks below a smaller cost that recurs on every dispatch.
  defp pressure(_recurring_calls, 0, _dispatches_compared), do: 0.0

  defp pressure(recurring_calls, recurring_dispatches, dispatches_compared)
       when dispatches_compared > 0 do
    recurring_calls * (recurring_dispatches / dispatches_compared)
  end

  defp label_for(:file_reads),
    do: "orientation-pack candidate -- file reads recur past the first dispatch"

  defp label_for(:search_calls),
    do: "retrieval-cache candidate -- search/grep calls recur past the first dispatch"

  defp label_for(:graph_calls),
    do: "retrieval-cache candidate -- code-graph queries recur past the first dispatch"

  # ===========================================================================
  # normalization + small helpers (mirrors Kazi.Economy.KPIs's atom-or-string
  # tolerance -- iterations come from Ecto structs, cross-run JSON, or fixtures)
  # ===========================================================================

  defp tools_of(%_{tools: tools}) when is_map(tools), do: tools
  defp tools_of(%{tools: tools}) when is_map(tools), do: tools
  defp tools_of(%{"tools" => tools}) when is_map(tools), do: tools
  defp tools_of(_), do: %{}

  defp fetch(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, to_string(key))) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp int({:ok, n}) when is_integer(n) and n >= 0, do: n
  defp int(_), do: 0
end
