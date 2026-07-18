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
  alias Kazi.ReadModel
  alias Kazi.ReadModel.{Run, RunRegistry}

  @type bucket :: :in_progress | :stuck | :complete

  @doc "The full portfolio: planned proposals, local runs by repo, and cross-machine runs."
  @spec build() :: %{
          planned: [map()],
          by_repo: %{String.t() => %{bucket() => [map()]}},
          fleet_remote: [map()]
        }
  def build do
    runs = RunRegistry.list()
    stuck_refs = attention_stuck_refs(runs)

    %{
      planned: planned_entries(),
      by_repo: local_by_repo(runs, stuck_refs),
      fleet_remote: remote_entries(runs)
    }
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
