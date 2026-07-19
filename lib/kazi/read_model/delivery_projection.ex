defmodule Kazi.ReadModel.DeliveryProjection do
  @moduledoc """
  Projects git-derived DELIVERY facts into the `delivery_events` read-model table
  (T67.2, ADR-0079 §1/§3). A pure read projection (ADR-0011 §2): it scans a
  workspace's git history for plan ticks and the PRs that merged them and writes
  one row per fact through the daemon write op (ADR-0068, `Kazi.ReadModel.Writer`).
  It never touches the loop and never calls GitHub — every fact is derived from
  the local commit history alone, so a velocity surface can compute
  delivered-tasks and claim→merge lead time without a network hop at render time.

  ## What it derives

  From every commit that touches `docs/plan.md` / `docs/plans/*.md`, in the
  requested range:

    * a **`:task_tick`** row for each added `- [x] TNN ... Done: <date> (PR #N)`
      plan line — carrying the task id, its epic (from the plan file path), the
      `Done:` date, and the PR the line names;
    * a **`:pr_merge`** row for each distinct PR number the commit lands —
      carrying the PR number, the landing commit sha, and the merge time.

  ## Session attribution (ADR-0079 §1)

  The authoritative delivery→session spine is the RUN REGISTRY, not the commit
  trailer. A git-derived tick carries no `goal_ref`, so on a trailer-stripped
  repo — like kazi's own — `session_uuid` is `nil` (an honest fleet-level row,
  ADR-0046), never guessed. Where a repo keeps the `Claude-Session:` trailer, the
  OPTIONAL `trailer_session_id` enrichment is parsed from the commit message. The
  run-registry join (`goal_ref` → `run.harness_session_id`) is applied whenever a
  `goal_ref` is known for a delivery; it is the query-time join T67.4 leans on.

  ## The `Claude-Session:` trailer grammar (documented here per ADR-0079 §1)

  A commit MAY carry a trailer line of the form:

      Claude-Session: https://claude.ai/code/session_<id>

  where `session_<id>` is an opaque token (`session_` followed by URL-safe
  characters). This projection captures that `session_<id>` token verbatim as
  `trailer_session_id`. kazi's own commit hygiene STRIPS this trailer before
  push, so it is absent on the kazi repo and the enrichment yields nothing there
  — by design, not a bug (see `docs/velocity.md`).

  ## Idempotency & incrementality

  Each row is upserted on a composed `dedup_key`
  (`kind|task_id|pr_number|merge_commit_sha`) with `on_conflict: :nothing`, so a
  re-scan of the same history produces each row exactly once (same history in ⇒
  same rows out). `project/2` accepts `:since` (a commit-ish) to bound the git
  log to `<since>..HEAD`; `last_seen_commit/0` returns the newest already-projected
  landing commit so a caller can scan incrementally.
  """

  import Ecto.Query, only: [from: 2]

  alias Kazi.ReadModel.{DeliveryEvent, RunRegistry, Writer}
  alias Kazi.Repo

  @plan_paths ["docs/plan.md", "docs/plans"]

  @tick_re ~r/-\s*\[x\]\s*(?<task>T\d+(?:\.\d+)*)\b.*?Done:\s*(?<date>\d{4}-\d{2}-\d{2})(?:\s*\(PR #(?<pr>\d+)\))?/
  @pr_re ~r/\(PR #(\d+)\)|\(#(\d+)\)/
  @trailer_re ~r/Claude-Session:\s*\S*?(session_[A-Za-z0-9._~-]+)/
  @epic_path_re ~r{plans/(E\d+)\.md}
  @remote_re ~r{[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$}

  @type summary :: %{
          task_ticks: non_neg_integer(),
          pr_merges: non_neg_integer(),
          commits: non_neg_integer()
        }

  @doc """
  Scans `workspace`'s git history and projects delivery rows. Options:

    * `:since` — a commit-ish; only commits in `<since>..HEAD` are scanned
      (defaults to a full scan).
    * `:repo_slug` — override the `org/repo` grouping (defaults to the workspace's
      git `origin` remote, then its basename).

  Returns `{:ok, summary}` with per-kind insert counts, or `{:error, reason}` when
  git is unreadable (a format break degrades to no rows, never a crash).
  """
  @spec project(String.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def project(workspace, opts \\ []) when is_binary(workspace) do
    repo_slug = opts[:repo_slug] || derive_repo_slug(workspace)

    with {:ok, shas} <- commit_shas(workspace, opts[:since]) do
      summary =
        Enum.reduce(shas, %{task_ticks: 0, pr_merges: 0, commits: 0}, fn sha, acc ->
          rows = commit_rows(workspace, sha, repo_slug)
          Enum.each(rows, &upsert/1)

          %{
            task_ticks: acc.task_ticks + Enum.count(rows, &(&1.kind == "task_tick")),
            pr_merges: acc.pr_merges + Enum.count(rows, &(&1.kind == "pr_merge")),
            commits: acc.commits + 1
          }
        end)

      {:ok, summary}
    end
  end

  @doc "The newest already-projected landing commit sha, or `nil` — the incremental cursor."
  @spec last_seen_commit() :: String.t() | nil
  def last_seen_commit do
    Repo.one(
      from(d in DeliveryEvent,
        where: not is_nil(d.merged_at),
        order_by: [desc: d.merged_at],
        limit: 1,
        select: d.merge_commit_sha
      )
    )
  end

  # ---------------------------------------------------------------------------
  # Git scan — oldest commit first, so `merged_at` grows monotonically.
  # ---------------------------------------------------------------------------

  defp commit_shas(workspace, since) do
    range = if is_binary(since) and since != "", do: ["#{since}..HEAD"], else: []

    case git(workspace, ["log"] ++ range ++ ["--format=%H", "--"] ++ @plan_paths) do
      {:ok, out} ->
        {:ok, out |> String.split("\n", trim: true) |> Enum.reverse()}

      {:error, _reason} = error ->
        error
    end
  end

  # The delivery rows a single commit yields: a task_tick per added tick line and
  # a pr_merge per distinct PR the commit lands.
  defp commit_rows(workspace, sha, repo_slug) do
    {merged_at, message} = commit_meta(workspace, sha)
    trailer = parse_trailer(message)
    ticks = parse_ticks(diff(workspace, sha))

    base = %{
      merge_commit_sha: sha,
      merged_at: merged_at,
      repo_slug: repo_slug,
      trailer_session_id: trailer,
      goal_ref: nil,
      session_uuid: nil
    }

    tick_rows =
      Enum.map(ticks, fn tick ->
        Map.merge(base, %{
          kind: "task_tick",
          task_id: tick.task_id,
          epic: tick.epic,
          done_on: tick.done_on,
          pr_number: tick.pr_number
        })
      end)

    pr_numbers =
      (Enum.map(ticks, & &1.pr_number) ++ [parse_pr(message)])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    pr_rows =
      Enum.map(pr_numbers, fn pr ->
        Map.merge(base, %{kind: "pr_merge", task_id: nil, epic: nil, done_on: nil, pr_number: pr})
      end)

    tick_rows ++ pr_rows
  end

  defp commit_meta(workspace, sha) do
    case git(workspace, ["show", "-s", "--format=%cI%x00%B", sha]) do
      {:ok, out} ->
        case String.split(out, "\0", parts: 2) do
          [iso, body] -> {parse_time(iso), body}
          [iso] -> {parse_time(iso), ""}
        end

      {:error, _} ->
        {nil, ""}
    end
  end

  defp diff(workspace, sha) do
    case git(workspace, ["show", sha, "--format=", "--unified=0", "--"] ++ @plan_paths) do
      {:ok, out} -> out
      {:error, _} -> ""
    end
  end

  # ---------------------------------------------------------------------------
  # Parsers
  # ---------------------------------------------------------------------------

  # Added tick lines (diff `+` lines, not the `+++` file header), tagged with the
  # epic from the plan file the hunk touches.
  defp parse_ticks(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({nil, []}, fn line, {epic, acc} ->
      cond do
        String.starts_with?(line, "+++ ") ->
          {epic_from_path(line), acc}

        String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
          case tick_from_line(line, epic) do
            nil -> {epic, acc}
            tick -> {epic, [tick | acc]}
          end

        true ->
          {epic, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp tick_from_line(line, epic) do
    case Regex.named_captures(@tick_re, line) do
      %{"task" => task, "date" => date} = caps when task != "" ->
        %{
          task_id: task,
          done_on: parse_date(date),
          pr_number: parse_int(caps["pr"]),
          epic: epic
        }

      _no_match ->
        nil
    end
  end

  defp epic_from_path(line) do
    case Regex.run(@epic_path_re, line) do
      [_, epic] -> epic
      _ -> nil
    end
  end

  defp parse_pr(text) do
    case Regex.run(@pr_re, text, capture: :all_but_first) do
      [pr, ""] -> parse_int(pr)
      ["", pr] -> parse_int(pr)
      [pr] -> parse_int(pr)
      _ -> nil
    end
  end

  defp parse_trailer(text) do
    case Regex.run(@trailer_re, text, capture: :all_but_first) do
      [token] -> token
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_time(iso) do
    case iso |> String.trim() |> DateTime.from_iso8601() do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Session attribution + persistence
  # ---------------------------------------------------------------------------

  # The run-registry join (ADR-0079 §1): the most-recently-started run for a
  # goal_ref lends its harness session id. `nil` goal_ref (every git-derived
  # tick) yields `nil` — an honest fleet-level row, never a guess.
  defp attribute_session(%{goal_ref: nil} = row), do: row

  defp attribute_session(%{goal_ref: goal_ref} = row) do
    case RunRegistry.list_by_goal_ref(goal_ref, "") do
      [run | _] -> %{row | session_uuid: run.harness_session_id}
      _ -> row
    end
  end

  defp upsert(row) do
    row = attribute_session(row)
    attrs = Map.put(row, :dedup_key, dedup_key(row))

    %DeliveryEvent{}
    |> DeliveryEvent.changeset(attrs)
    |> Writer.insert(on_conflict: :nothing, conflict_target: :dedup_key)
  end

  defp dedup_key(%{kind: kind, task_id: task_id, pr_number: pr, merge_commit_sha: sha}) do
    Enum.join([kind, task_id || "", pr || "", sha], "|")
  end

  # ---------------------------------------------------------------------------
  # Git shell-out + repo slug (the `-C <workspace>` idiom, stderr folded in).
  # ---------------------------------------------------------------------------

  defp git(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _code} -> {:error, String.trim(out)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp derive_repo_slug(workspace) do
    with {:ok, url} <- git(workspace, ["remote", "get-url", "origin"]),
         [_, org, repo] <- Regex.run(@remote_re, String.trim(url)) do
      "#{org}/#{repo}"
    else
      _ -> workspace |> Path.basename() |> then(&if(&1 == "", do: nil, else: &1))
    end
  end
end
