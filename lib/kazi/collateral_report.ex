defmodule Kazi.CollateralReport do
  @moduledoc """
  The out-of-intent diff report (issue #860 proposal 3): files changed during a
  run that sit OUTSIDE the goal's declared `[scope].write_paths` — or, absent a
  `write_paths` declaration, outside every predicate's own config references —
  ranked net-deletion-first. This is the 5-line review list a human reads
  instead of the full diff; `kazi apply --json`'s `collateral` field
  (`Kazi.CLI`) is this list rendered for the orchestrator/human to review.

  Net-deletion files rank first because that shape — a pure or majority
  deletion in a file nothing referenced — is exactly the motivating incident's
  signature: a silent, in-scope-but-out-of-intent regression that every
  predicate happened to pass around.
  """

  alias Kazi.{Goal, ScopeDiff}

  @typedoc "One collateral entry: the changed path and its line-change shape."
  @type entry :: %{
          path: String.t(),
          additions: non_neg_integer() | nil,
          deletions: non_neg_integer() | nil,
          net_deletion: boolean()
        }

  @doc """
  Computes the collateral list for `goal`'s run against `workspace`: every path
  changed since `Kazi.ScopeDiff.base_ref/1` that falls outside the intended
  write scope, sorted net-deletion-first, then by deletion count descending.

  A path counts as OUT of scope when:

    * `goal.scope.write_paths` is non-empty and the path is not under any of
      them; or
    * `write_paths` is empty (not declared) and no predicate's own `config`
      plausibly references the path (its full relative path or its basename
      appears in some predicate's rendered config) — the fallback for a goal
      that never declared a narrower write scope.

  Returns `[]` for a non-git / unreadable workspace (degrades gracefully,
  never raises).
  """
  @spec collateral(Goal.t(), String.t() | nil) :: [entry()]
  def collateral(%Goal{} = goal, workspace) when is_binary(workspace) do
    base_ref = ScopeDiff.base_ref(workspace)
    stats = ScopeDiff.numstat(workspace, base_ref)

    workspace
    |> ScopeDiff.changed_paths(base_ref)
    |> Enum.reject(&in_scope?(&1, goal))
    |> Enum.map(&entry(&1, stats))
    |> Enum.sort_by(&sort_key/1)
  end

  def collateral(_goal, _workspace), do: []

  defp in_scope?(path, %Goal{scope: %{write_paths: []}} = goal), do: referenced?(path, goal)

  defp in_scope?(path, %Goal{scope: %{write_paths: write_paths}}),
    do: ScopeDiff.under_any?(path, write_paths)

  # Best-effort fallback when no write_paths is declared: a path is "in scope"
  # when some predicate's own config plausibly names it.
  defp referenced?(path, %Goal{} = goal) do
    basename = Path.basename(path)

    goal
    |> Goal.all_predicates()
    |> Enum.any?(fn predicate ->
      blob = inspect(predicate.config, limit: :infinity, printable_limit: :infinity)
      String.contains?(blob, path) or String.contains?(blob, basename)
    end)
  end

  defp entry(path, stats) do
    %{additions: additions, deletions: deletions} =
      Map.get(stats, path, %{additions: nil, deletions: nil})

    %{
      path: path,
      additions: additions,
      deletions: deletions,
      net_deletion: net_deletion?(additions, deletions)
    }
  end

  defp net_deletion?(additions, deletions) when is_integer(additions) and is_integer(deletions),
    do: deletions > additions

  # A binary file (unmeasurable, "-"/"-" in numstat) can't be judged net-deletion.
  defp net_deletion?(_additions, _deletions), do: false

  # Net-deletion entries first, then by deletion count (missing counts last), for
  # a stable, highest-signal-first order.
  defp sort_key(%{net_deletion: net_deletion, deletions: deletions}) do
    {if(net_deletion, do: 0, else: 1), -(deletions || 0)}
  end
end
