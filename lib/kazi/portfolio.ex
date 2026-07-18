defmodule Kazi.Portfolio do
  @moduledoc """
  T60.4 (#1160): the fleet's PORTFOLIO state -- planned / in progress / stuck /
  complete -- composed ONLY from kazi's own objective surfaces (the
  read-only-projection line, ADR-0011): proposed goals (`list-proposed`), the
  run registry, the attention queue (`Kazi.Attention.Queue`, ADR-0057), and
  the cross-machine bus facts T60.1's `Kazi.Runtime.BusMirror` posts. No
  manual curation, no new task-management data model -- every entry traces to
  an existing objective source.

  `build/0` returns:

    * `:planned` -- proposals `proposed`/`approved` but not yet applied
      (`kazi list-proposed`'s own rows). Not grouped by repo: a proposal
      carries no workspace until it is applied, so forcing one would fabricate
      data (ADR-0046 honest-unknown) rather than reflect it.
    * `:by_repo` -- LOCAL runs (which DO carry a workspace) grouped by repo,
      each repo's runs further split into `:in_progress` / `:stuck` /
      `:complete` via `bucket/2` -- the SAME classifier `:fleet_remote` uses
      below, so "what counts as stuck" has exactly one definition, not two.
    * `:fleet_remote` -- runs in flight on OTHER machines, read from the SAME
      `run:<short-id>` bus facts T60.1's Mission Control remote cards use.
      These carry no workspace (a text bus fact has no repo field), so they
      are reported fleet-wide only, not force-grouped into `:by_repo`.

  Best-effort throughout (ADR-0011 §2 / ADR-0067 point 1's mirror invariant):
  an unreachable daemon degrades `:fleet_remote` to `[]`, never an error --
  the LOCAL portfolio (`:planned` + `:by_repo`) is unaffected either way.
  """

  alias Kazi.Attention.Queue, as: AttentionQueue
  alias Kazi.Goal
  alias Kazi.PredicateVector
  alias Kazi.ReadModel
  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Scheduler.DagSnapshot

  @type bucket :: :in_progress | :stuck | :complete

  @typedoc """
  The five-bucket sitrep taxonomy (E64, David's verbatim names) — every bucket a
  read-model/DAG projection (ADR-0011), nothing hand-set:

    * `:planned` — proposals `proposed` (awaiting approval).
    * `:todo`    — proposals `approved` with NO registered run (ready to dispatch).
    * `:running` — registry runs still converging.
    * `:blocked` — stuck/over_budget/error runs PLUS DAG-blocked roadmap goals
      (`DagSnapshot`'s `:blocked`). Each entry names its `:cause`.
    * `:done`    — terminal converged runs.
  """
  @type five_bucket :: :planned | :todo | :running | :blocked | :done

  # Headline order (highest signal first) — the tabular percentage line reads
  # done -> in-progress -> blocked -> todo -> planned.
  @bucket_order [:done, :running, :blocked, :todo, :planned]

  @doc "The full portfolio: planned proposals, local runs by repo, and cross-machine runs."
  @spec build() :: %{
          planned: [map()],
          by_repo: %{String.t() => %{bucket() => [map()]}},
          fleet_remote: [map()],
          buckets: %{five_bucket() => [map()]},
          totals: map()
        }
  def build do
    runs = RunRegistry.list()
    stuck_refs = attention_stuck_refs(runs)
    buckets = five_buckets(runs, stuck_refs)

    %{
      planned: planned_entries(),
      by_repo: local_by_repo(runs, stuck_refs),
      fleet_remote: remote_entries(runs),
      buckets: buckets,
      totals: totals(buckets)
    }
  end

  # ===========================================================================
  # Five-bucket model (E64/T64.1) — the sitrep classification + headline totals.
  # ===========================================================================

  # Classify every tracked item into exactly one of the five buckets. A goal
  # appears once: a run's own state wins over a DAG-blocked projection (R-E64-3),
  # and an approved proposal whose goal already has a run is represented by that
  # run, not double-counted as `:todo`.
  @spec five_buckets([Run.t()], MapSet.t()) :: %{five_bucket() => [map()]}
  defp five_buckets(runs, stuck_refs) do
    latest_runs = latest_run_per_ref(runs)
    run_refs = latest_runs |> Enum.map(& &1.goal_ref) |> MapSet.new()

    run_bucketed =
      Enum.group_by(latest_runs, &run_bucket(&1, stuck_refs), &five_run_entry(&1, stuck_refs))

    dag_blocked = dag_blocked_entries(runs, run_refs)

    %{
      planned: proposal_entries("proposed"),
      todo: todo_entries(run_refs),
      running: Map.get(run_bucketed, :running, []),
      blocked: Map.get(run_bucketed, :blocked, []) ++ dag_blocked,
      done: Map.get(run_bucketed, :done, [])
    }
  end

  # `RunRegistry.list/0` is ordered `desc: started_at`, so the FIRST row seen per
  # `goal_ref` is the latest — the run whose state wins when a goal was retried
  # (the SAME "latest wins" rule mission control's wave grouping applies).
  defp latest_run_per_ref(runs) do
    runs
    |> Enum.reduce({%{}, []}, fn %Run{goal_ref: ref} = run, {seen, acc} ->
      if Map.has_key?(seen, ref), do: {seen, acc}, else: {Map.put(seen, ref, true), [run | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # A run's five-bucket, reusing the existing `bucket/2` classifier so "what
  # counts as stuck" has exactly one definition (attention-flagged live runs
  # included), then mapping onto the sitrep names.
  defp run_bucket(%Run{} = run, stuck_refs) do
    case bucket(run, stuck_refs) do
      :complete -> :done
      :stuck -> :blocked
      :in_progress -> :running
    end
  end

  defp five_run_entry(%Run{} = run, stuck_refs) do
    base = %{goal_ref: run.goal_ref, run_id: run.run_id, status: run.status}

    case run_bucket(run, stuck_refs) do
      :blocked -> Map.merge(base, blocked_attribution(run))
      _other -> base
    end
  end

  # The named blocker for a blocked run (T64.2, UC-033/UC-061): every blocked
  # entry carries a `:cause` AND the data that names WHY, read from the run's own
  # objective surfaces (ADR-0011) — never hand-set:
  #
  #   * `:over_budget` — the run hit its declared iteration ceiling: the recorded
  #     iteration count over the run's `max_iterations` cap.
  #   * `:error`/`:stuck` — the persistently-red predicate slice from the run's
  #     LAST recorded vector: the same failing predicates `kazi economy`'s cause
  #     detail implicates, each with how many trailing iterations it stayed red.
  #
  # T64.1 recorded the coarse cause so the blocked bucket already carried distinct
  # causes; T64.2 enriches each with its named blocker (rendered by
  # `blocker_label/1`).
  defp blocked_attribution(%Run{status: "over_budget"} = run) do
    %{cause: :over_budget, iterations: iteration_count(run.goal_ref), cap: run.max_iterations}
  end

  defp blocked_attribution(%Run{status: "error"} = run) do
    %{cause: :error, red_predicates: red_predicate_slice(run.goal_ref)}
  end

  defp blocked_attribution(%Run{} = run) do
    %{cause: :stuck, red_predicates: red_predicate_slice(run.goal_ref)}
  end

  # The persistently-red predicate slice from the run's LAST recorded vector: the
  # ids failing in the final observation, each tagged with how many trailing
  # consecutive iterations it stayed red (the "N iterations" persistence signal).
  # An empty history yields `[]` (honest-unknown, ADR-0046) — never a fabricated
  # blocker.
  defp red_predicate_slice(goal_ref) do
    history = ReadModel.iteration_history(goal_ref)

    case List.last(history) do
      nil ->
        []

      {_index, last_vector} ->
        vectors = history |> Enum.map(fn {_index, vector} -> vector end) |> Enum.reverse()

        last_vector
        |> PredicateVector.failing()
        |> Enum.map(&%{id: to_string(&1), red_iterations: trailing_red_count(vectors, &1)})
    end
  end

  # How many trailing (most-recent-first) iterations `id` stayed red before the
  # first non-red observation — the persistence depth of a failing predicate.
  defp trailing_red_count(vectors_newest_first, id) do
    Enum.reduce_while(vectors_newest_first, 0, fn vector, count ->
      case PredicateVector.get(vector, id) do
        %Kazi.PredicateResult{status: :fail} -> {:cont, count + 1}
        _other -> {:halt, count}
      end
    end)
  end

  defp iteration_count(goal_ref), do: goal_ref |> ReadModel.iteration_history() |> length()

  @doc """
  Renders a blocked entry's named cause into a one-line human blocker string
  (T64.2, UC-033). Every blocked entry — DAG-blocked, over-budget, stuck, or
  errored — names WHY it is blocked; a stuck run with no recorded vector degrades
  to an honest "no recorded vector" rather than an empty or fabricated blocker.
  """
  @spec blocker_label(map()) :: String.t()
  def blocker_label(%{cause: :dag, blocked_by: dep}), do: "blocked by: #{dep}"

  def blocker_label(%{cause: :over_budget, iterations: iters, cap: cap}),
    do: "blocked: #{iters}/#{cap} iterations"

  def blocker_label(%{cause: cause, red_predicates: reds}) when cause in [:stuck, :error] do
    case reds do
      [] -> "blocked: #{cause} (no recorded vector)"
      reds -> "blocked: " <> Enum.map_join(reds, ", ", &red_label/1)
    end
  end

  defp red_label(%{id: id, red_iterations: n}), do: "#{id} red #{n} iterations"

  # `:todo` — approved proposals whose goal has NO registered run yet (ready to
  # dispatch). An approved proposal already under a run is represented by that
  # run, so it is filtered out here rather than counted twice.
  defp todo_entries(run_refs) do
    "approved"
    |> proposal_entries()
    |> Enum.reject(&MapSet.member?(run_refs, &1.goal_id))
  end

  defp proposal_entries(status) do
    for row <- ReadModel.list_proposed_goals(status: status) do
      %{proposal_ref: row.proposal_ref, goal_id: row.goal_id, idea: row.idea, status: row.status}
    end
  end

  # DAG-blocked roadmap goals: reuse `DagSnapshot`'s `:blocked` — the SAME
  # reachability the scheduler and mission control's roadmap fold compute — over
  # the configured roadmap goal (the `:starmap_roadmap_goal` app-env seam
  # `kazi dashboard --roadmap` sets, and tests seed). NO second walk. A goal
  # already carried by a run (run-state wins, R-E64-3) is excluded.
  defp dag_blocked_entries(runs, run_refs) do
    case roadmap_goal() do
      %Goal{} = goal ->
        dep_states = roadmap_dep_states(goal, runs)

        goal
        |> DagSnapshot.from(dep_states)
        |> Map.fetch!(:nodes)
        |> Enum.filter(&(&1.state == :blocked))
        |> Enum.reject(&MapSet.member?(run_refs, &1.id))
        |> Enum.map(&%{goal_ref: &1.id, cause: :dag, blocked_by: &1.blocked_by})

      _none ->
        []
    end
  end

  # Per-group dep state from each group's LATEST run — the SAME derivation
  # mission control's `build_waves/2` feeds `DagSnapshot.from/2`.
  defp roadmap_dep_states(%Goal{groups: groups}, runs) do
    latest_by_ref = Map.new(latest_run_per_ref(runs), &{&1.goal_ref, &1})
    Map.new(groups, fn %Goal.Group{id: id} -> {id, dep_state(Map.get(latest_by_ref, id))} end)
  end

  defp dep_state(nil), do: :pending
  defp dep_state(%Run{status: "converged"}), do: :converged

  defp dep_state(%Run{status: status}) when status in ["stuck", "over_budget", "error"],
    do: :stuck

  defp dep_state(%Run{status: "running"}), do: :running
  defp dep_state(%Run{}), do: :pending

  defp roadmap_goal, do: Application.get_env(:kazi, :starmap_roadmap_goal)

  # ===========================================================================
  # Headline totals — count + INTEGER percentage per bucket, summing to 100 via
  # largest-remainder. Base = all bucketed items; an empty portfolio is flagged
  # `empty?: true` so the renderer says "nothing tracked yet", never divides by 0.
  # ===========================================================================

  @doc """
  The headline totals for the five buckets: an ordered `rows` list (count +
  integer percentage per bucket, percentages summing to 100), the percentage
  `base` (all bucketed items), and an `empty?` flag when nothing is tracked.
  """
  @spec totals(%{five_bucket() => [map()]}) :: %{
          base: non_neg_integer(),
          empty?: boolean(),
          rows: [%{bucket: five_bucket(), count: non_neg_integer(), pct: non_neg_integer()}]
        }
  def totals(buckets) do
    counts = Enum.map(@bucket_order, &length(Map.get(buckets, &1, [])))
    base = Enum.sum(counts)
    pcts = largest_remainder(counts, base)

    rows =
      @bucket_order
      |> Enum.zip(Enum.zip(counts, pcts))
      |> Enum.map(fn {bucket, {count, pct}} -> %{bucket: bucket, count: count, pct: pct} end)

    %{base: base, empty?: base == 0, rows: rows}
  end

  # Largest-remainder (Hamilton) apportionment: floor each share, then hand the
  # leftover points to the largest fractional remainders so the integer
  # percentages sum to exactly 100. An empty base yields all-zero (no divide).
  defp largest_remainder(_counts, 0), do: []

  defp largest_remainder(counts, base) do
    scaled = Enum.map(counts, &(&1 * 100 / base))
    floors = Enum.map(scaled, &trunc/1)
    remainder = 100 - Enum.sum(floors)

    winners =
      scaled
      |> Enum.with_index()
      |> Enum.sort_by(fn {share, idx} -> {-(share - trunc(share)), idx} end)
      |> Enum.take(remainder)
      |> Enum.map(&elem(&1, 1))
      |> MapSet.new()

    floors
    |> Enum.with_index()
    |> Enum.map(fn {floor, idx} ->
      if MapSet.member?(winners, idx), do: floor + 1, else: floor
    end)
  end

  # ===========================================================================
  # :planned -- proposals not yet applied
  # ===========================================================================

  defp planned_entries do
    for status <- ["proposed", "approved"],
        row <- ReadModel.list_proposed_goals(status: status) do
      %{proposal_ref: row.proposal_ref, goal_id: row.goal_id, idea: row.idea, status: row.status}
    end
  end

  # ===========================================================================
  # :by_repo -- local runs, grouped by repo then by bucket
  # ===========================================================================

  defp local_by_repo(runs, stuck_refs) do
    runs
    |> Enum.group_by(&repo_label/1)
    |> Map.new(fn {repo, repo_runs} ->
      {repo, repo_runs |> Enum.group_by(&bucket(&1, stuck_refs)) |> Map.new(&bucket_entry/1)}
    end)
  end

  defp bucket_entry({bucket, runs}), do: {bucket, Enum.map(runs, &run_entry/1)}

  defp run_entry(%Run{} = run) do
    %{goal_ref: run.goal_ref, run_id: run.run_id, status: run.status}
  end

  # `:complete` is the run's own terminal status; `:stuck` is either an
  # explicit terminal failure status OR a live run the attention queue has
  # already flagged (`Kazi.Attention.Queue.build/2`'s :cause/:stuck/:budget
  # signals -- the same detectors, not a second stuck definition); everything
  # else still running is `:in_progress`.
  @spec bucket(Run.t(), MapSet.t()) :: bucket()
  def bucket(%Run{status: "converged"}, _stuck_refs), do: :complete

  def bucket(%Run{status: status}, _stuck_refs)
      when status in ["stuck", "over_budget", "error"],
      do: :stuck

  def bucket(%Run{goal_ref: ref}, stuck_refs) do
    if MapSet.member?(stuck_refs, ref), do: :stuck, else: :in_progress
  end

  defp attention_stuck_refs(runs) do
    runs |> AttentionQueue.build() |> Enum.map(& &1.goal_ref) |> MapSet.new()
  end

  # "org/repo" resolved from the workspace's git `origin` remote, falling back
  # to the last two path segments -- the SAME grouping key Mission Control's
  # `project_label/1` derives (`lib/kazi_web/live/mission_control_live.ex`),
  # kept as its own small copy here rather than a cross-module dependency
  # between a web LiveView and this pure-Elixir module.
  defp repo_label(%Run{workspace: ws}) when is_binary(ws) and ws != "" do
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

  defp repo_label(_run), do: "unknown"

  defp parse_remote(url) do
    case Regex.run(~r{[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$}, url) do
      [_, org, repo] -> {:ok, "#{org}/#{repo}"}
      _no_match -> :error
    end
  end

  # ===========================================================================
  # :fleet_remote -- cross-machine runs, from T60.1's bus facts
  # ===========================================================================

  defp remote_entries(local_runs) do
    local_refs = local_runs |> Enum.map(& &1.goal_ref) |> MapSet.new()

    remote_run_facts()
    |> Enum.map(&parse_remote_fact/1)
    |> Enum.filter(& &1)
    |> Enum.reject(&MapSet.member?(local_refs, &1.goal_ref))
    |> Enum.uniq_by(& &1.goal_ref)
  end

  # Injectable (ADR-0011 §3), the SAME seam name Mission Control's remote
  # cards use (`:remote_run_facts_fetcher`) so one fixture override drives
  # both surfaces in a test with no daemon.
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

  defp parse_remote_fact(%{"topic" => "run:" <> _short, "machine" => machine, "text" => text})
       when is_binary(machine) and is_binary(text) do
    if machine != Kazi.Bus.hostname() do
      case remote_fact_bucket(text) do
        {goal_ref, bucket} -> %{goal_ref: goal_ref, bucket: bucket, machine: machine}
        nil -> nil
      end
    end
  end

  defp parse_remote_fact(_other), do: nil

  defp remote_fact_bucket(text) do
    cond do
      m = Regex.named_captures(@remote_started_re, text) ->
        {m["goal_ref"], :in_progress}

      m = Regex.named_captures(@remote_iter_re, text) ->
        {m["goal_ref"], :in_progress}

      m = Regex.named_captures(@remote_terminal_re, text) ->
        {m["goal_ref"], remote_verdict_bucket(m["verb"])}

      m = Regex.named_captures(@remote_terminated_re, text) ->
        {m["goal_ref"], :stuck}

      true ->
        nil
    end
  end

  defp remote_verdict_bucket("converged"), do: :complete
  defp remote_verdict_bucket(_stuck_over_budget_stopped_error), do: :stuck
end
