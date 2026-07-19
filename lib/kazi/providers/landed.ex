defmodule Kazi.Providers.Landed do
  @moduledoc """
  The `:landed` predicate provider (T44.2, ADR-0055): the deterministic check
  that a goal's CONVERGED work has actually LANDED to the degree its
  `[integration] mode` declares. Synthesized (never authored) by
  `Kazi.Goal.landed_predicate/1` and appended to the goal's predicate vector at
  load time whenever `mode != :none`.

  ## Why this exists (the T0.8 termination invariant)

  Code-green is not the same as work-landed. Before `landed`, a goal whose test
  predicates all passed while the working tree was still DIRTY (or the branch
  unpushed, or no PR opened) would report `:converged` with the fix stranded in
  an uncommitted worktree. `landed` is the predicate that SUPPLIES the
  unsatisfied signal in that "code-green + dirty tree" state, so the loop keeps
  going until the work is genuinely committed / pushed / PR-open / merged. It
  does NOT replace or weaken the T0.8 termination guard — it is one more ordinary
  predicate the whole vector must satisfy for `:converged`.

  ## Working-tree evaluation (the ADR-0042 / L-0024 invariant)

  `landed` is a VISIBLE, ordinary predicate — NOT a guard and NOT held-out. That
  is load-bearing: the loop scopes clean-tree isolation (grading from a frozen
  `clean_ref`, ADR-0042 / L-0015 / L-0024) to the tamper-prone GRADERS only;
  visible predicates evaluate against the agent's live working copy
  (`context.workspace`). `landed` MUST see the real, uncommitted working-tree
  state — a dirty tree, an in-progress commit — because that is exactly the state
  it gates on. Grading it from a frozen clean ref would report a permanently
  clean tree, so `landed` would pass while the fix was still stranded: the H1
  deadlock class L-0024 closed, silently reintroduced. Keeping it a visible
  predicate is what preserves the working-tree contract.

  ## Modes (cumulative, ADR-0055)

  Each mode asserts a clean tree PLUS progressively-further landing state:

    * `:commit` — HEAD is a real commit on a NON-base branch (work committed,
      not left uncommitted or sitting on the base branch);
    * `:branch` — the above, plus the branch is pushed (has an upstream, or
      exists on `origin`);
    * `:pr` — the above, plus an OPEN PR exists for the branch against the base;
    * `:merge` — the branch's PR is MERGED (the house rule: rebase-merged, never
      squashed, never a merge commit).

  A failing result names the SPECIFIC obstruction as evidence — the dirty paths,
  the on-base branch, the unpushed branch — so the loop feeds an actionable
  signal to the next dispatch, not a generic "not landed". When a required tool
  cannot run (no `gh` for `:pr`/`:merge`) the result is `:unknown` (could not
  evaluate), never a false `:fail`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.PredicateResult

  @impl true
  def evaluate(%Kazi.Predicate{kind: :landed, config: config}, context) do
    config = config || %{}
    mode = Map.get(config, :mode, :none)
    branch = Map.get(config, :branch)
    workspace = Map.get(context, :workspace)

    cond do
      not is_binary(workspace) ->
        PredicateResult.error(%{reason: :no_workspace, mode: mode})

      not git_repo?(workspace) ->
        PredicateResult.error(%{reason: :not_a_git_repo, mode: mode, workspace: workspace})

      true ->
        base = resolve_base(workspace, Map.get(config, :base))
        evaluate_clean_then_mode(mode, workspace, branch, base)
    end
  end

  # Clean tree is the shared precondition for EVERY landing mode — check it first
  # so a dirty tree names its paths regardless of how far the mode lands.
  defp evaluate_clean_then_mode(mode, workspace, branch, base) do
    case dirty_paths(workspace) do
      :error ->
        PredicateResult.error(%{reason: :git_status_failed, mode: mode})

      [] ->
        evaluate_mode(mode, workspace, branch, base)

      dirty ->
        PredicateResult.fail(%{
          reason: :dirty_tree,
          mode: mode,
          branch: branch,
          dirty_paths: dirty
        })
    end
  end

  # :commit — HEAD is a real commit on a non-base branch.
  defp evaluate_mode(:commit, workspace, branch, base) do
    committed_on_branch(workspace, branch, base, %{mode: :commit})
  end

  # :branch — committed on a non-base branch AND the branch is pushed.
  defp evaluate_mode(:branch, workspace, branch, base) do
    with :ok <- committed_on_branch_ok(workspace, branch, base, %{mode: :branch}) do
      current = current_branch(workspace) || branch

      if branch_pushed?(workspace, current) do
        PredicateResult.pass(%{mode: :branch, branch: current, base: base})
      else
        PredicateResult.fail(%{reason: :branch_not_pushed, mode: :branch, branch: current})
      end
    end
  end

  # :pr — pushed AND an OPEN PR exists for the branch against the base.
  defp evaluate_mode(:pr, workspace, branch, base) do
    with :ok <- committed_on_branch_ok(workspace, branch, base, %{mode: :pr}) do
      current = current_branch(workspace) || branch

      case open_pr_count(workspace, current, base) do
        {:ok, 0} ->
          PredicateResult.fail(%{reason: :no_open_pr, mode: :pr, branch: current, base: base})

        {:ok, _n} ->
          PredicateResult.pass(%{mode: :pr, branch: current, base: base})

        {:error, reason} ->
          PredicateResult.unknown(%{reason: reason, mode: :pr, branch: current, base: base})
      end
    end
  end

  # :merge — the branch's PR is MERGED (rebase-merged; the house rule).
  defp evaluate_mode(:merge, workspace, branch, base) do
    current = current_branch(workspace) || branch

    case merged_pr?(workspace, current, base) do
      {:ok, true} ->
        PredicateResult.pass(%{mode: :merge, branch: current, base: base})

      {:ok, false} ->
        PredicateResult.fail(%{reason: :pr_not_merged, mode: :merge, branch: current, base: base})

      {:error, reason} ->
        PredicateResult.unknown(%{reason: reason, mode: :merge, branch: current, base: base})
    end
  end

  # An unrecognized mode should never be synthesized, but degrade honestly.
  defp evaluate_mode(mode, _workspace, _branch, _base) do
    PredicateResult.error(%{reason: :unknown_mode, mode: mode})
  end

  # commit-mode result, reused verbatim by :commit.
  defp committed_on_branch(workspace, branch, base, evidence) do
    case committed_on_branch_ok(workspace, branch, base, evidence) do
      :ok ->
        PredicateResult.pass(
          Map.merge(evidence, %{branch: current_branch(workspace), base: base})
        )

      %PredicateResult{} = failed ->
        failed
    end
  end

  # The shared "committed on a non-base branch" gate: returns :ok or a ready
  # `:fail` PredicateResult naming the obstruction.
  defp committed_on_branch_ok(workspace, _branch, base, evidence) do
    current = current_branch(workspace)

    cond do
      not has_commit?(workspace) ->
        PredicateResult.fail(Map.put(evidence, :reason, :no_commit))

      current == nil ->
        PredicateResult.fail(Map.put(evidence, :reason, :detached_head))

      current == base ->
        PredicateResult.fail(
          Map.merge(evidence, %{reason: :on_base_branch, branch: current, base: base})
        )

      true ->
        :ok
    end
  end

  # --- git plumbing (degrades, never raises) --------------------------------

  defp git_repo?(workspace) do
    match?({:ok, _}, git(workspace, ["rev-parse", "--is-inside-work-tree"]))
  end

  # `git status --porcelain` lists tracked AND untracked changes; the path is the
  # substring after the two status columns and their separating space (offset 3).
  # A rename renders as "old -> new", kept verbatim as actionable evidence.
  defp dirty_paths(workspace) do
    case git(workspace, ["status", "--porcelain"]) do
      {:ok, out} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.slice(&1, 3..-1//1))
        |> Enum.reject(&(&1 == ""))

      :error ->
        :error
    end
  end

  defp has_commit?(workspace) do
    match?({:ok, _}, git(workspace, ["rev-parse", "--verify", "--quiet", "HEAD"]))
  end

  defp current_branch(workspace) do
    case git(workspace, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, out} ->
        case String.trim(out) do
          "" -> nil
          "HEAD" -> nil
          name -> name
        end

      :error ->
        nil
    end
  end

  # Pushed = has a configured upstream, OR the branch exists on `origin` (a push
  # that never set upstream tracking still counts as landed).
  defp branch_pushed?(workspace, branch) do
    has_upstream?(workspace) or on_origin?(workspace, branch)
  end

  defp has_upstream?(workspace) do
    match?(
      {:ok, _},
      git(workspace, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
    )
  end

  defp on_origin?(workspace, branch) when is_binary(branch) do
    case git(workspace, ["ls-remote", "--heads", "origin", branch]) do
      {:ok, out} -> String.trim(out) != ""
      :error -> false
    end
  end

  defp on_origin?(_workspace, _branch), do: false

  # The base branch a pr/merge targets: the goal's declared `[integration] base`
  # verbatim, else the origin default (`origin/HEAD`), else `main`.
  defp resolve_base(_workspace, base) when is_binary(base) and base != "", do: base

  defp resolve_base(workspace, _base) do
    case git(workspace, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) do
      {:ok, out} ->
        out |> String.trim() |> String.replace_prefix("origin/", "")

      :error ->
        "main"
    end
  end

  # --- gh plumbing (pr/merge; :unknown when unavailable) --------------------

  defp open_pr_count(workspace, branch, base) do
    case gh(workspace, [
           "pr",
           "list",
           "--head",
           branch,
           "--base",
           base,
           "--state",
           "open",
           "--json",
           "number"
         ]) do
      {:ok, out} ->
        case decode_pr_list(out) do
          {:ok, list} -> {:ok, length(list)}
          :error -> {:error, :gh_output_unparseable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merged_pr?(workspace, branch, base) do
    case gh(workspace, [
           "pr",
           "list",
           "--head",
           branch,
           "--base",
           base,
           "--state",
           "merged",
           "--json",
           "number"
         ]) do
      {:ok, out} ->
        case decode_pr_list(out) do
          {:ok, list} -> {:ok, list != []}
          :error -> {:error, :gh_output_unparseable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_pr_list(out) do
    case Jason.decode(out) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> :error
    end
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

  defp gh(workspace, args) do
    case System.cmd("gh", args, cd: workspace, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {_out, _code} -> {:error, :gh_failed}
    end
  rescue
    _ -> {:error, :gh_unavailable}
  catch
    _, _ -> {:error, :gh_unavailable}
  end
end
