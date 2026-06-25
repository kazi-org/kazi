defmodule Kazi.Enforcement.Isolation do
  @moduledoc """
  Clean-tree + separate-process checker isolation (T32.4 guarantee 1, ADR-0042 §1).

  The empirical mandate (METR 2025-06-05: reward hacking was >43x more common when
  the model could see the entire scoring function; Anthropic *Sycophancy to
  Subterfuge*: a model that learned to rewrite its own grader) is to keep the
  checker out of the agent's reach. This module realizes the two rungs ADR-0042 §1
  commits to (full container isolation deferred):

    * **clean tree** — the checker's definitions and inputs are resolved from a
      CLEAN git tree (a throwaway detached worktree at a clean ref), NOT the agent's
      working copy. An in-iteration edit to a checker/test file in the working copy
      therefore cannot change the verdict — the worktree is the committed state at
      `ref`.
    * **separate OS process** — the checker runs in a fresh subprocess the agent
      cannot introspect or monkey-patch. This rung is already held by kazi's
      command-runner providers (`Kazi.Providers.CustomScript` / `TestRunner` /
      `Ratchet` all shell out via `System.cmd`, `Kazi.Providers.CommandRunner`); a
      port-spawned subprocess is distinct from the agent's own `claude -p` dispatch
      (`Kazi.Loop`'s harness run). This module's contribution is the clean tree the
      subprocess runs in.

  ## The verified seam (precondition, ADR-0042 §"Consequences")

  The only place `Kazi.Loop` invokes a provider is `run_provider/3`, with a context
  carrying `workspace: data.workspace` (the agent's working copy). The isolation
  seam is therefore: when enforcement is active, swap that workspace for a clean
  detached worktree for the duration of the observation, run every checker against
  it, then remove it. `with_clean_tree/3` is that wrapper; `Kazi.Loop.observe/1`
  calls it once per tick. The worktree mechanism is the same `git worktree add
  --detach` pattern `Kazi.Ratchet.resolve_git_ref/3` already uses for its baseline
  comparison.

  ## Graceful degradation (honest reporting)

  Isolation needs a git workspace with `ref` checkable out. When that is not true
  (no `.git`, a detached/unborn ref, git absent, a worktree-add failure), the
  checker MUST still run — degrade to the working copy and let the caller record
  that `:clean_tree` is NOT among the active guarantees. `prepare/2` returns
  `{:ok, clean_path, cleanup}` on success or `{:degraded, reason}` so the loop
  reports the ACTUAL guarantee level, never a fabricated one (the precondition's
  honesty bar). Lore L-0014 (shared-tree reset hazard) is why the clean tree is a
  throwaway temp dir, always removed, never the shared working dir.
  """

  @doc """
  Prepares a clean detached worktree of `workspace` at `ref`.

  Returns `{:ok, clean_path, cleanup_fun}` where `cleanup_fun/0` removes the
  worktree (call it in an `after`), or `{:degraded, reason}` when isolation could
  not be established (not a git repo, ref unresolvable, git unavailable). On
  `:degraded` the caller runs the checker in the working copy and reports that
  clean-tree isolation is not active.
  """
  @spec prepare(String.t() | nil, String.t()) ::
          {:ok, String.t(), (-> :ok)} | {:degraded, term()}
  def prepare(workspace, ref) when is_binary(workspace) and is_binary(ref) do
    tmp = Path.join(System.tmp_dir!(), "kazi-enforce-#{System.unique_integer([:positive])}")

    case git(workspace, ["worktree", "add", "--detach", tmp, ref]) do
      {:ok, _output} ->
        {:ok, tmp, fn -> remove(workspace, tmp) end}

      {:error, reason} ->
        {:degraded, {:worktree_add_failed, String.trim(to_string(reason))}}
    end
  end

  def prepare(_workspace, _ref), do: {:degraded, :no_workspace}

  @doc """
  Runs `fun` against a clean detached worktree of `workspace` at `ref`, always
  removing the worktree afterwards.

  Returns `{:ok, fun_result}` when isolation was established (clean-tree active), or
  `{:degraded, reason, fun_result_in_workspace}` when it could not be — in which
  case `fun` is still run, but against the ORIGINAL `workspace`, and the caller
  drops `:clean_tree` from the reported guarantees. This is the honest-degradation
  contract: the checker always runs; the reported guarantee matches reality.
  """
  @spec with_clean_tree(String.t() | nil, String.t(), (String.t() -> result)) ::
          {:ok, result} | {:degraded, term(), result}
        when result: term()
  def with_clean_tree(workspace, ref, fun) when is_function(fun, 1) do
    case prepare(workspace, ref) do
      {:ok, clean_path, cleanup} ->
        try do
          {:ok, fun.(clean_path)}
        after
          cleanup.()
        end

      {:degraded, reason} ->
        {:degraded, reason, fun.(workspace)}
    end
  end

  # Remove the throwaway worktree (best-effort: a failed removal is logged, never
  # raised — it must not break the reconcile tick).
  defp remove(workspace, tmp) do
    case git(workspace, ["worktree", "remove", "--force", tmp]) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        File.rm_rf(tmp)
        git(workspace, ["worktree", "prune"])
        :ok
    end
  end

  defp git(workspace, args) do
    {output, exit_code} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
    if exit_code == 0, do: {:ok, output}, else: {:error, output}
  rescue
    error in [ErlangError, File.Error] -> {:error, Exception.message(error)}
  end
end
