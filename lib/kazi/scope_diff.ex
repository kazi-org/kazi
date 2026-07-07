defmodule Kazi.ScopeDiff do
  @moduledoc """
  Shared git-diff plumbing for issue #860's scope guards: the base ref a run's
  changes are measured against, the set of changed paths, and per-path
  add/delete line stats. Used by `Kazi.Providers.ScopeGuard` (the `deny`-path
  guard predicate) and `Kazi.CollateralReport` (the terminal `collateral`
  field) so both measure the SAME diff.

  The base ref is the merge-base with `origin/main` when that remote-tracking
  ref exists (the usual case: a goal converges on a feature branch cut from
  main), falling back to the repo's root commit, then to git's empty-tree
  object — so a repo with no `origin/main` (a fixture, a detached clone) still
  gets a sensible "everything so far" diff rather than an error. `git diff
  <base>` (a single ref) compares that commit against the CURRENT WORKING TREE,
  so committed-on-branch and uncommitted changes are both captured in one call;
  untracked (never-`git add`ed) files are invisible to `git diff`, the same
  limitation `Kazi.Enforcement.DiffGuard`'s `safe_diff` already accepts.

  Every git call degrades to an empty result rather than raising — a diff
  source failing must never crash the reconcile loop or the CLI's terminal
  report.
  """

  # git's well-known empty-tree object id — diffing against it reports every
  # file as an addition, the sensible fallback when no real base commit exists.
  @empty_tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  @doc """
  The base ref this run's changes are measured against: the merge-base with
  `origin/main`, else the repo's root commit, else git's empty-tree object. A
  non-git / missing workspace also yields the empty-tree fallback.
  """
  @spec base_ref(String.t() | nil) :: String.t()
  def base_ref(workspace) when is_binary(workspace) do
    case merge_base(workspace, "origin/main") do
      {:ok, ref} ->
        ref

      :error ->
        case root_commit(workspace) do
          {:ok, ref} -> ref
          :error -> @empty_tree
        end
    end
  end

  def base_ref(_workspace), do: @empty_tree

  defp merge_base(workspace, ref) do
    case git(workspace, ["merge-base", ref, "HEAD"]) do
      {:ok, out} -> {:ok, String.trim(out)}
      :error -> :error
    end
  end

  defp root_commit(workspace) do
    case git(workspace, ["rev-list", "--max-parents=0", "HEAD"]) do
      {:ok, out} ->
        case String.split(out, "\n", trim: true) do
          [first | _] -> {:ok, first}
          [] -> :error
        end

      :error ->
        :error
    end
  end

  @doc "The relative paths changed between `base_ref` and the working tree."
  @spec changed_paths(String.t() | nil, String.t()) :: [String.t()]
  def changed_paths(workspace, base_ref) when is_binary(workspace) do
    case git(workspace, ["diff", "--name-only", base_ref]) do
      {:ok, out} -> String.split(out, "\n", trim: true)
      :error -> []
    end
  end

  def changed_paths(_workspace, _base_ref), do: []

  @doc """
  Per-path added/deleted line counts between `base_ref` and the working tree,
  via `git diff --numstat`. A binary file's unmeasurable `-`/`-` counts render
  as `nil`, never a crash.
  """
  @spec numstat(String.t() | nil, String.t()) :: %{
          optional(String.t()) => %{additions: integer() | nil, deletions: integer() | nil}
        }
  def numstat(workspace, base_ref) when is_binary(workspace) do
    case git(workspace, ["diff", "--numstat", base_ref]) do
      {:ok, out} -> parse_numstat(out)
      :error -> %{}
    end
  end

  def numstat(_workspace, _base_ref), do: %{}

  defp parse_numstat(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "\t", parts: 3) do
        [added, deleted, path] ->
          Map.put(acc, path, %{additions: parse_count(added), deletions: parse_count(deleted)})

        _ ->
          acc
      end
    end)
  end

  defp parse_count("-"), do: nil

  defp parse_count(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end

  @doc """
  Whether `path` sits under any of `prefixes` (an exact match or a directory
  prefix — a trailing slash on a prefix is tolerated either way).
  """
  @spec under_any?(String.t(), [String.t()]) :: boolean()
  def under_any?(path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      trimmed = String.trim_trailing(prefix, "/")
      path == trimmed or String.starts_with?(path, trimmed <> "/")
    end)
  end

  defp git(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
