defmodule Kazi.Scheduler.SerialLanding do
  @moduledoc """
  The **1-partition landing step** (T50.2, ADR-0065 decision 2), extracted from
  the CLI so every path that runs a goal in a kazi-owned task worktree — the
  serial `kazi apply` (T50.1) and each fleet member (T50.5) — lands its
  converged work through ONE implementation.

  A T50.1-isolated run that CONVERGED must land its task-branch commits on the
  base before the ephemeral worktree is cleaned up — converging in a worktree
  nobody integrates is a silent drop. The landing follows T21.5 exactly:
  `Kazi.Scheduler.Integration.integrate/2` over the single worktree entry,
  `:base` set explicitly to the CALLER's checked-out branch (never the module's
  hardcoded "main" default), the integrator seam injectable via
  `runtime_opts[:integrate]` (the same opts shape the group scheduler's
  `:integrate` takes), and a conflict routed through Integration's
  `:redispatcher` seam bounded by `:max_attempts`. Nothing on this path ever
  runs `git reset` or `git clean` against the base checkout; a failed landing
  leaves the task branch alive (the branch outlives worktree removal by
  design), so the work is never lost.
  """

  alias Kazi.Goal

  @typedoc """
  The landing verdict:

    * `:nothing_to_land` — no committed work on the kazi-owned task branch (an
      uncommitted tree, a checkout that moved off the task branch, or a worktree
      at the base tip);
    * `{:landed, info}` — the task-branch commits were integrated onto the base;
    * `{:unlanded, info}` — integration failed; `info` names the surviving task
      branch and the reason.
  """
  @type verdict :: :nothing_to_land | {:landed, map()} | {:unlanded, map()}

  @doc """
  Lands only COMMITTED work ON THE KAZI-OWNED TASK BRANCH: the worktree's
  commits ahead of the base HEAD, while the worktree is still checked out on the
  goal's OWNED branch (`Kazi.Goal.integration_branch/1` — the same real branch
  `Kazi.Scheduler.Worktree.wrap/2`'s `:owned_branch` checks the worktree out
  onto). T54.1 (#1079/#1080): the run-owned branch is recognized by EXPLICIT
  IDENTITY (this exact branch name), not by a `kazi-partition/` naming
  convention — a run whose worktree checkout moved OFF it owns its own landing
  (most importantly the run's own :integrate ACTION, ADR-0055, or an agent that
  created its own branch), so it is NOT double-integrated. An uncommitted
  working tree is the goal's own `landed`-predicate problem (the T50.1 contract
  keeps the base byte-identical for such runs); a worktree at the base tip has
  nothing to land. A detached base checkout has no branch to rebase-merge onto —
  surfaced honestly rather than guessing a target.
  """
  @spec land(Goal.t(), keyword(), Path.t(), Path.t(), keyword()) :: verdict()
  def land(%Goal{} = goal, runtime_opts, base_workspace, worktree, opts \\ []) do
    owned_branch = Goal.integration_branch(goal)

    with {:ok, base_sha} <- git(base_workspace, ["rev-parse", "HEAD"]),
         {:ok, task_branch} <- git(worktree, ["rev-parse", "--abbrev-ref", "HEAD"]),
         true <- task_branch == owned_branch,
         {:ok, ahead} <- git(worktree, ["rev-list", "--count", base_sha <> "..HEAD"]),
         true <- ahead != "0" do
      case git(base_workspace, ["rev-parse", "--abbrev-ref", "HEAD"]) do
        {:ok, "HEAD"} ->
          {:unlanded,
           %{
             landed: false,
             task_branch: task_branch,
             reason: "base checkout is detached (no branch to land on)"
           }}

        {:ok, base_branch} ->
          integrate(goal, runtime_opts, base_workspace, worktree, base_branch, task_branch, opts)

        {:error, reason} ->
          {:unlanded, %{landed: false, task_branch: task_branch, reason: inspect(reason)}}
      end
    else
      # No commits ahead, or the worktree/base state is unreadable — nothing
      # integrable. Fail-open: landing is additive; it never breaks a converge.
      _ -> :nothing_to_land
    end
  end

  defp integrate(%Goal{} = goal, runtime_opts, base_workspace, worktree, base, branch, opts) do
    integrate_opts =
      runtime_opts
      |> Keyword.get(:integrate, [])
      |> Keyword.put_new(:base, base)
      |> Keyword.put_new_lazy(:integrator, fn -> default_integrator(base_workspace) end)
      |> Keyword.update(
        :integrator_opts,
        default_integrator_opts(base_workspace, goal, opts),
        &merge_integrator_opts(&1, base_workspace, goal, opts)
      )

    {:ok, integration} =
      Kazi.Scheduler.Integration.integrate([{%{key: goal.id}, worktree}], integrate_opts)

    base = Keyword.get(integrate_opts, :base, base)

    case integration do
      %{collective: :converged, integrated: [{_partition, refs}]} ->
        {:landed, %{landed: true, base: base, task_branch: branch, refs: json_safe_refs(refs)}}

      %{conflicts: conflicts} ->
        {:unlanded,
         %{
           landed: false,
           base: base,
           task_branch: branch,
           reason: Enum.map_join(conflicts, "; ", fn {_partition, r} -> inspect(r) end)
         }}
    end
  end

  # The integrator opts carry BOTH the base-repo (LocalIntegrator's fast-forward
  # target) AND the integrate-context the ActionIntegrator threads into the real
  # `Kazi.Actions.Integrate` action -- the goal (so the landing commit/PR names
  # the REAL goal id and change summary instead of `unknown-goal`/`converged
  # change`) and the converged predicate vector (so the commit message's
  # converged-predicate list is populated instead of `(none recorded)`), issue
  # #1550. The vector is optional: a caller that does not thread one still lands,
  # with the predicate list simply omitted.
  defp default_integrator_opts(base_workspace, goal, opts) do
    [base_repo: base_workspace, integrate_context: integrate_context(goal, opts)]
  end

  defp merge_integrator_opts(integrator_opts, base_workspace, goal, opts) do
    integrator_opts
    |> Keyword.put_new(:base_repo, base_workspace)
    |> Keyword.put_new(:integrate_context, integrate_context(goal, opts))
  end

  defp integrate_context(goal, opts) do
    case Keyword.get(opts, :vector) do
      nil -> [goal: goal]
      vector -> [goal: goal, vector: vector]
    end
  end

  # ADR-0065 decision 2: land exactly as a parallel partition does. With an
  # origin remote and `gh` on PATH the default is the REAL ActionIntegrator
  # (branch → push → PR → rebase-merge); a local-only repo (no remote, or no
  # gh) lands by a plain local rebase-merge instead — a surviving task branch
  # is the honest degraded mode when even that fails, never a silent drop.
  defp default_integrator(base_workspace) do
    if has_origin_remote?(base_workspace) and System.find_executable("gh") do
      &Kazi.Scheduler.Integration.ActionIntegrator.integrate/2
    else
      &Kazi.Scheduler.Integration.LocalIntegrator.integrate/2
    end
  end

  defp has_origin_remote?(workspace) do
    match?(
      {_, 0},
      System.cmd("git", ["-C", workspace, "remote", "get-url", "origin"], stderr_to_stdout: true)
    )
  rescue
    _ -> false
  end

  defp git(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The integrator's refs must survive Jason encoding whatever a stub returned.
  defp json_safe_refs(refs) when is_map(refs) do
    Map.new(refs, fn {k, v} -> {k, json_safe_value(v)} end)
  end

  defp json_safe_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp json_safe_value(v) when is_atom(v), do: to_string(v)
  defp json_safe_value(v), do: inspect(v)
end
