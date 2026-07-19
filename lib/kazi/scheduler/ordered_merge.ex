defmodule Kazi.Scheduler.OrderedMerge do
  @moduledoc """
  `needs`-ordered merge with `git cherry` silent-revert verification (T44.11,
  ADR-0055) — MERGE-mode landing for a `[integration] mode = "merge"` group goal.

  When a goal's `[[group]]` taxonomy carries `needs` edges, T44.10 lands each
  group on its own branch. This module LANDS those group branches into the shared
  base in the TOPOLOGICAL order the scheduler already computes
  (`Kazi.Goal.DepGraph.frontiers/1`) — a group merges ONLY after every one of its
  `needs` ancestors has already merged — and, after EACH merge, verifies that
  every previously-merged group's patch content still survives.

  ## Silent-revert verification (`git cherry`)

  A cross-group merge can SILENTLY drop an earlier group's hunk (two groups touch
  overlapping lines; a naive merge resolves by keeping one side). Nothing errors —
  the earlier group's work just vanishes from the base. After each merge this
  module runs `git cherry <base> <group-branch>` for every ALREADY-merged group: a
  `+`-prefixed line means that group's commit has NO patch-equivalent on the base
  anymore — it was reverted. `git cherry` compares by PATCH-ID, so a clean
  rebase-merge (new SHAs, same content) reports `-` (survived) while a dropped hunk
  reports `+` (lost), regardless of the merge's commit shape.

  On the FIRST `+` the merge HALTS with `{:error, {:silent_revert, %{lost:,
  caused_by:, commits:}}}` naming BOTH the group whose content was lost AND the
  group whose merge caused the loss. It NEVER proceeds silently past a detected
  revert — a lost hunk is a hard stop, not a warning. When `git cherry` itself
  cannot run the check fails CLOSED (`{:error, {:verify_unavailable, ...}}`) — an
  unverifiable merge is never treated as a silent pass.

  Detection boundary: `git cherry` catches a group's commit being DROPPED from the
  base's history (a rebase that skips it, a force-overwrite/reset that rewrites the
  base) — the loss modes a cross-group landing actually produces. It does NOT flag
  a later commit that ADDITIVELY undoes an earlier group's effect while leaving its
  original patch in history (that patch still reports `-`); patch-presence, not
  final-tree effect, is what a merge-safety gate needs, and it is what the house
  rebase-merge preserves.

  ## `pr` vs `merge` (mode-gated)

  This is MERGE-mode only. Under `mode = :pr` the groups' PRs are OPENED in the
  same topological order but NOTHING is merged and no `cherry` check runs (there is
  no new base state to verify) — `run/2` returns the opened-PR sequence with the
  base branch untouched. `mode = :merge` is the ordered rebase-merge + verification
  above.

  ## Seams

  Both the per-group merge and the per-group PR open are injectable so tests drive
  a real fixture repo without gh/network, and a test can substitute a deliberately
  LOSSY merger to fabricate a silent revert the `cherry` check must catch:

    * `:merger` — `fn merge_ctx -> {:ok, merge_commit} | {:error, reason}` (default
      a real local rebase-merge into the base);
    * `:pr_opener` — `fn merge_ctx -> {:ok, pr_ref} | {:error, reason}` (used only
      in `:pr` mode);

  where `merge_ctx` is `%{repo:, base:, group:, branch:}`. The `cherry` check is
  the module's OWN product code (never injected), so the verification holds no
  matter how a merger behaves.
  """

  alias Kazi.Goal.DepGraph

  @type group_id :: String.t()
  @type merge_ctx :: %{repo: String.t(), base: String.t(), group: group_id(), branch: String.t()}

  @type result :: %{
          mode: :merge | :pr,
          sequence: [group_id()],
          merged: [%{group: group_id(), branch: String.t(), merge_commit: String.t()}],
          prs: [%{group: group_id(), branch: String.t(), pr: term()}]
        }

  @doc """
  The flattened topological merge order for `goal`'s `needs`-DAG — the frontiers of
  `Kazi.Goal.DepGraph.frontiers/1` concatenated in wave order (declared order
  within a wave). This is the SAME layering `apply --explain` prints; T44.11 reuses
  it rather than recomputing an ordering.
  """
  @spec merge_order(Kazi.Goal.t()) :: [group_id()]
  def merge_order(goal), do: goal |> DepGraph.frontiers() |> List.flatten()

  @doc """
  Lands `goal`'s converged group branches in `needs`-topological order.

  Options:

    * `:repo` — the base checkout every group branch lands into (required);
    * `:base` — the base branch (default `"main"`);
    * `:branch_for` — `fn group_id -> branch` mapping a group to its converged
      branch (required);
    * `:mode` — `:merge` (default) or `:pr`;
    * `:merger` / `:pr_opener` — the injectable seams (see the module doc).

  Returns `{:ok, result()}` or, on a detected silent revert, `{:error,
  {:silent_revert, %{lost:, caused_by:, commits:}}}`; a merger failure is
  `{:error, {:merge_failed, group_id, reason}}`.
  """
  @spec run(Kazi.Goal.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(%Kazi.Goal{} = goal, opts) when is_list(opts) do
    repo = Keyword.fetch!(opts, :repo)
    base = Keyword.get(opts, :base, "main")
    branch_for = Keyword.fetch!(opts, :branch_for)
    mode = Keyword.get(opts, :mode, :merge)

    order = merge_order(goal)

    ctx = %{
      repo: repo,
      base: base,
      branch_for: branch_for,
      merger: Keyword.get(opts, :merger, &default_merger/1),
      pr_opener: Keyword.get(opts, :pr_opener, &default_pr_opener/1)
    }

    case mode do
      :merge -> run_merge(order, ctx)
      :pr -> run_pr(order, ctx)
      other -> {:error, {:unsupported_mode, other}}
    end
  end

  # --- merge mode: ordered rebase-merge + cherry verification ------------------

  defp run_merge(order, ctx) do
    Enum.reduce_while(order, {:ok, []}, fn group, {:ok, merged} ->
      merge_ctx = %{repo: ctx.repo, base: ctx.base, group: group, branch: ctx.branch_for.(group)}

      case ctx.merger.(merge_ctx) do
        {:ok, merge_commit} ->
          entry = %{group: group, branch: merge_ctx.branch, merge_commit: merge_commit}

          case verify_survivors(ctx, merged, group) do
            :ok -> {:cont, {:ok, [entry | merged]}}
            {:error, _} = err -> {:halt, err}
          end

        {:error, reason} ->
          {:halt, {:error, {:merge_failed, group, reason}}}
      end
    end)
    |> case do
      {:ok, merged} ->
        merged = Enum.reverse(merged)
        {:ok, %{mode: :merge, sequence: Enum.map(merged, & &1.group), merged: merged, prs: []}}

      {:error, _} = err ->
        err
    end
  end

  # After merging `caused_by`, every PREVIOUSLY-merged group's patch content must
  # still be represented on the base. A `+` line from `git cherry <base> <branch>`
  # is a commit with no patch-equivalent upstream — it was silently reverted.
  defp verify_survivors(ctx, merged, caused_by) do
    Enum.reduce_while(merged, :ok, fn %{group: prev, branch: prev_branch}, :ok ->
      case cherry_lost(ctx.repo, ctx.base, prev_branch) do
        {:ok, []} ->
          {:cont, :ok}

        {:ok, lost} ->
          {:halt, {:error, {:silent_revert, %{lost: prev, caused_by: caused_by, commits: lost}}}}

        # Fail CLOSED: an inability to verify is a hard stop, never a silent pass —
        # the whole point is to never proceed past an UNVERIFIED revert.
        {:error, reason} ->
          {:halt, {:error, {:verify_unavailable, %{group: prev, reason: reason}}}}
      end
    end)
  end

  # --- pr mode: open PRs in order, merge NOTHING -------------------------------

  defp run_pr(order, ctx) do
    Enum.reduce_while(order, {:ok, []}, fn group, {:ok, prs} ->
      merge_ctx = %{repo: ctx.repo, base: ctx.base, group: group, branch: ctx.branch_for.(group)}

      case ctx.pr_opener.(merge_ctx) do
        {:ok, pr} ->
          {:cont, {:ok, [%{group: group, branch: merge_ctx.branch, pr: pr} | prs]}}

        {:error, reason} ->
          {:halt, {:error, {:pr_open_failed, group, reason}}}
      end
    end)
    |> case do
      {:ok, prs} ->
        prs = Enum.reverse(prs)
        {:ok, %{mode: :pr, sequence: Enum.map(prs, & &1.group), merged: [], prs: prs}}

      {:error, _} = err ->
        err
    end
  end

  # --- git plumbing ------------------------------------------------------------

  # `git cherry <upstream> <head>` lists head's commits not equivalent-present on
  # upstream: `+ <sha>` = NOT applied upstream (its patch was dropped), `- <sha>` =
  # equivalent found (survived). Returns `{:ok, [lost_sha]}` (the `+` lines) or
  # `{:error, reason}` when cherry cannot run — the caller fails CLOSED on the error.
  defp cherry_lost(repo, base, branch) do
    case git(repo, ["cherry", base, branch]) do
      {:ok, out} ->
        lost =
          out
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, "+ "))
          |> Enum.map(&(&1 |> String.trim_leading("+ ") |> String.trim()))

        {:ok, lost}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The real default merger: a local rebase-merge of the group branch onto the
  # base — the house rule (never squash, never a merge commit). Mutates the base
  # checkout's HEAD to the base branch, advanced by `--ff-only` to the rebased tip.
  defp default_merger(%{repo: repo, base: base, branch: branch}) do
    with {:ok, _} <- git(repo, ["checkout", branch]),
         {:ok, _} <- git(repo, ["rebase", base]),
         {:ok, _} <- git(repo, ["checkout", base]),
         {:ok, _} <- git(repo, ["merge", "--ff-only", branch]),
         {:ok, sha} <- git(repo, ["rev-parse", base]) do
      {:ok, String.trim(sha)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # The default PR opener is intentionally absent — opening a real PR requires a
  # configured remote + `gh`, which the caller (the scheduler/CLI landing wiring)
  # supplies. Called only in `:pr` mode; a caller that reaches here without an
  # injected opener gets a clear error rather than a silent no-op.
  defp default_pr_opener(_merge_ctx), do: {:error, :no_pr_opener}

  defp git(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    _, _ -> {:error, :git_crashed}
  end
end
