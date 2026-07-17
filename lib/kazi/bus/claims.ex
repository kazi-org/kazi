defmodule Kazi.Bus.Claims do
  @moduledoc """
  T55.8 (ADR-0073 point 2): the board's ownership section, read AT SOURCE from
  `refs/claims/*` on the shared remote.

  Claims are already cross-machine -- the `/claim` primitive pushes every claim
  to `origin` -- and already self-describing -- the claim commit's subject is
  `claim <task> by <identity>@<host> <stamp>`. So this reader keeps NO copy and
  derives NO staleness class: it does ONE fresh, pruned fetch of the claim refs
  into a private namespace and projects them straight back out. Because the path
  is pure git against the shared remote, there is NO daemon anywhere in it --
  claiming, and seeing claims, work with the daemon down BY CONSTRUCTION, not by
  discipline.

  When the remote cannot be reached inside the short timeout the caller degrades
  to a single honest line (`{:error, :unreachable}`) rather than presenting a
  possibly-stale local cache as live truth: a stale render is worse than an
  absent one, because it reads as authoritative ownership that has already moved
  on. The fetch is therefore BOTH the reachability gate and the source -- the
  local namespace is only ever read immediately after a successful fresh fetch,
  never trusted on its own.

  Landmine (L-0037): a claim commit is minted as the repo's configured git
  identity, so N pool sessions on one machine all claim as ONE `owner` string.
  The `owner` rendered here is that git identity plus the host it was claimed
  from -- honest about what it is, but unable to tell sibling pool sessions
  apart until the claim primitive itself embeds a session name. Doing that lives
  in the claim tooling OUTSIDE this repo's delivery (ADR-0067 point 6), so it is
  out of scope here; this reader projects faithfully whatever the subject holds.
  """

  alias Kazi.Providers.CommandRunner

  @default_timeout_ms 3_000
  @namespace "refs/kazi/board-claims"

  @typedoc "One projected claim: task + owner/host + age in seconds."
  @type claim :: %{required(String.t()) => term()}

  @doc """
  Reads `refs/claims/*` from `opts[:remote]` (default `origin`) in the git repo
  at `opts[:cwd]` (default the current working directory) and projects each into
  `%{"task", "owner", "host", "age_s"}`, sorted by task.

  Returns `{:ok, claims}` on a successful fresh read (possibly `[]`), or
  `{:error, :unreachable}` when the fetch fails or overruns `opts[:timeout_ms]`
  (default #{@default_timeout_ms}ms) -- never a stale render.
  """
  @spec read(keyword()) :: {:ok, [claim()]} | {:error, :unreachable}
  def read(opts \\ []) do
    remote = opts[:remote] || "origin"
    cwd = opts[:cwd] || File.cwd!()
    timeout = opts[:timeout_ms] || @default_timeout_ms
    now = opts[:now] || System.system_time(:second)

    case fetch_claims(cwd, remote, timeout) do
      :ok -> {:ok, project(cwd, now)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The single network round-trip AND the reachability gate. `--prune` drops any
  # local namespace ref whose claim was released on the remote, so a fresh fetch
  # leaves the namespace an exact mirror; `+` forces the update because each
  # claim is an unattached commit-tree commit (never a fast-forward). Any
  # non-zero exit or timeout is an unreachable remote -- we degrade, we do not
  # fall back to whatever the namespace last held.
  defp fetch_claims(cwd, remote, timeout) do
    refspec = "+refs/claims/*:#{@namespace}/*"
    args = ["-C", cwd, "fetch", "--prune", "--no-tags", remote, refspec]

    case CommandRunner.run("git", args, [stderr_to_stdout: true], timeout) do
      {:ran, _out, 0} -> :ok
      _ -> {:error, :unreachable}
    end
  end

  # Reads the just-fetched namespace locally (no network): one line per claim,
  # tab-separated so the free-form subject stays intact as the final field.
  defp project(cwd, now) do
    fmt = "%(refname:lstrip=3)%09%(committerdate:unix)%09%(contents:subject)"
    args = ["-C", cwd, "for-each-ref", "--format=" <> fmt, @namespace <> "/"]

    case CommandRunner.run("git", args, [stderr_to_stdout: true], nil) do
      {:ran, out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_line(&1, now))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1["task"])

      _ ->
        []
    end
  end

  @subject ~r/^claim\s+\S+\s+by\s+(?<who>.+)\s+\S+\s*$/

  @doc false
  @spec parse_line(String.t(), integer()) :: claim() | nil
  def parse_line(line, now) do
    case String.split(line, "\t") do
      [task, unix, subject] when task != "" ->
        {owner, host} = parse_subject(subject)

        %{
          "task" => task,
          "owner" => owner,
          "host" => host,
          "age_s" => age_seconds(unix, now)
        }

      _ ->
        nil
    end
  end

  @doc false
  # The subject is `claim <task> by <identity>@<host> <stamp>`. `<identity>` is a
  # git email and MAY itself contain `@`, so host is the segment after the LAST
  # `@` and owner is everything before it -- never a naive first-`@` split.
  @spec parse_subject(String.t()) :: {String.t() | nil, String.t() | nil}
  def parse_subject(subject) do
    case Regex.named_captures(@subject, subject) do
      %{"who" => who} -> split_identity(who)
      _ -> {nil, nil}
    end
  end

  defp split_identity(who) do
    case String.split(who, "@") do
      [only] -> {only, nil}
      parts -> {parts |> Enum.drop(-1) |> Enum.join("@"), List.last(parts)}
    end
  end

  defp age_seconds(unix, now) do
    case Integer.parse(unix) do
      {claimed_at, _} -> max(now - claimed_at, 0)
      :error -> nil
    end
  end
end
