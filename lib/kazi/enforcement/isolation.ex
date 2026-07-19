defmodule Kazi.Enforcement.Isolation do
  @moduledoc """
  Clean-tree + separate-process checker isolation (T32.4 guarantee 1, ADR-0042 §1).

  The empirical mandate (METR 2025-06-05: reward hacking was >43x more common when
  the model could see the entire scoring function; Anthropic *Sycophancy to
  Subterfuge*: a model that learned to rewrite its own grader) is to keep the
  checker out of the agent's reach. This module realizes the two rungs ADR-0042 §1
  commits to (full container isolation deferred):

    * **clean tree, candidate-graded** — the checker runs in a throwaway detached
      worktree seeded at a clean ref, but the agent's WORKING-TREE state (tracked
      edits + untracked new files) is overlaid onto it before the checker runs
      (`overlay_working_tree/3`). Only the `read_only_paths` — the grader's OWN
      definition files — are then re-checked-out from `ref` (`restore_grader_paths/3`),
      overwriting any overlay of them. So an in-iteration edit to a *grader* file
      cannot change the verdict (still the committed state at `ref`), while an
      in-iteration edit to the *candidate* fix — the thing the grader is checking —
      IS seen, and a held-out/guard predicate can converge (deep-review H1: grading
      frozen `HEAD` wholesale made held-out acceptance predicates structurally
      unable to converge, because the fix under test never reaches `ref` until
      `integrate` commits it, and `integrate` is itself gated on the held-out
      predicate passing).
    * **separate OS process** — the checker runs in a fresh subprocess the agent
      cannot introspect or monkey-patch. This rung is already held by kazi's
      command-runner providers (`Kazi.Providers.CustomScript` / `TestRunner` /
      `Ratchet` all shell out via `System.cmd`, `Kazi.Providers.CommandRunner`); a
      port-spawned subprocess is distinct from the agent's own `claude -p` dispatch
      (`Kazi.Loop`'s harness run). This module's contribution is the clean tree the
      subprocess runs in.

  ## Why `read_only_paths` is what stays pinned

  Before this fix, `prepare/2` swapped the ENTIRE checker cwd to frozen `ref`, so
  clean-tree isolation protected every file uniformly but also hid every candidate
  fix. That is too strong: it protects code the operator never asked to protect
  (defeating held-out convergence) while not being any MORE protective for the
  files that actually matter (the grader's own script/test/config). Pinning only
  `enforcement.read_only_paths` — the same list guarantee 2 (the read-only lease)
  already content-hashes — gives one coherent "this is the grader" declaration
  instead of two different implicit ones. An operator who wants a file protected
  from BOTH silent working-copy edits (guarantee 2) AND clean-tree overlay
  (guarantee 1) lists it once, in `read_only_paths`.

  ## The verified seam (precondition, ADR-0042 §"Consequences")

  The only place `Kazi.Loop` invokes a provider is `run_provider/3`, with a context
  carrying `workspace: data.workspace` (the agent's working copy). The isolation
  seam is therefore: when enforcement is active, swap that workspace for a clean
  detached worktree (candidate-overlaid, grader-pinned) for the duration of the
  observation, run every checker against it, then remove it. `with_clean_tree/4` is
  that wrapper; `Kazi.Loop.observe_with_isolation/1` calls it once per tick. The
  worktree mechanism is the same `git worktree add --detach` pattern
  `Kazi.Ratchet.resolve_git_ref/3` already uses for its baseline comparison.

  ## Graceful degradation (honest reporting)

  Isolation needs a git workspace with `ref` checkable out. When that is not true
  (no `.git`, a detached/unborn ref, git absent, a worktree-add failure, or the
  overlay/restore steps fail), the checker MUST still run — degrade to the working
  copy and let the caller record that `:clean_tree` is NOT among the active
  guarantees. `prepare/3` returns `{:ok, clean_path, cleanup}` on success or
  `{:degraded, reason}` so the loop reports the ACTUAL guarantee level, never a
  fabricated one (the precondition's honesty bar). Lore L-0014 (shared-tree reset
  hazard) is why the clean tree is a throwaway temp dir, always removed, never the
  shared working dir.
  """

  @doc """
  Prepares a clean detached worktree of `workspace` at `ref`, overlaid with the
  working tree's candidate state, with `read_only_paths` re-pinned to `ref`.

  Returns `{:ok, clean_path, cleanup_fun}` where `cleanup_fun/0` removes the
  worktree (call it in an `after`), or `{:degraded, reason}` when isolation could
  not be established (not a git repo, ref unresolvable, git unavailable, the
  overlay/restore steps failed). On `:degraded` the caller runs the checker in the
  working copy and reports that clean-tree isolation is not active.
  """
  @spec prepare(String.t() | nil, String.t(), [String.t()]) ::
          {:ok, String.t(), (-> :ok)} | {:degraded, term()}
  def prepare(workspace, ref, read_only_paths)
      when is_binary(workspace) and is_binary(ref) and is_list(read_only_paths) do
    tmp = Path.join(System.tmp_dir!(), "kazi-enforce-#{System.unique_integer([:positive])}")

    with {:ok, _output} <- git(workspace, ["worktree", "add", "--detach", tmp, ref]),
         :ok <- overlay_working_tree(workspace, tmp, ref),
         :ok <- restore_grader_paths(tmp, ref, read_only_paths) do
      {:ok, tmp, fn -> remove(workspace, tmp) end}
    else
      {:error, reason} ->
        remove(workspace, tmp)
        {:degraded, {:worktree_add_failed, String.trim(to_string(reason))}}
    end
  end

  def prepare(_workspace, _ref, _read_only_paths), do: {:degraded, :no_workspace}

  @doc """
  Runs `fun` against a clean, candidate-overlaid detached worktree of `workspace`
  at `ref` (see the moduledoc), always removing the worktree afterwards.

  Returns `{:ok, fun_result}` when isolation was established (clean-tree active), or
  `{:degraded, reason, fun_result_in_workspace}` when it could not be — in which
  case `fun` is still run, but against the ORIGINAL `workspace`, and the caller
  drops `:clean_tree` from the reported guarantees. This is the honest-degradation
  contract: the checker always runs; the reported guarantee matches reality.
  """
  @spec with_clean_tree(String.t() | nil, String.t(), [String.t()], (String.t() -> result)) ::
          {:ok, result} | {:degraded, term(), result}
        when result: term()
  def with_clean_tree(workspace, ref, read_only_paths, fun) when is_function(fun, 1) do
    case prepare(workspace, ref, read_only_paths) do
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

  # Overlays `workspace`'s candidate state — tracked edits (staged + unstaged) AND
  # untracked new files — onto the clean worktree `tmp`, so an isolated checker
  # grades the agent's actual fix instead of frozen `ref`. Tracked changes travel as
  # a `git diff ref` patch applied against `tmp` (same base, so it always applies
  # cleanly); untracked files (respecting .gitignore, so build artifacts like
  # `_build`/`deps` are never copied) are copied file-by-file. Returns `:ok` or
  # `{:error, reason}` — a failure here degrades isolation entirely (honest
  # reporting) rather than running the checker against a half-overlaid tree.
  @spec overlay_working_tree(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defp overlay_working_tree(workspace, tmp, ref) do
    ls_files_args = ["ls-files", "--others", "--exclude-standard", "-z"]

    with {:ok, diff} <- git(workspace, ["diff", "--binary", ref]),
         :ok <- apply_diff(tmp, diff),
         {:ok, untracked} <- git(workspace, ls_files_args) do
      copy_untracked(workspace, tmp, untracked)
    end
  end

  defp apply_diff(_tmp, ""), do: :ok

  defp apply_diff(tmp, diff) do
    name = "kazi-overlay-#{System.unique_integer([:positive])}.patch"
    patch = Path.join(System.tmp_dir!(), name)
    File.write!(patch, diff)

    result =
      case git(tmp, ["apply", "--binary", "--whitespace=nowarn", patch]) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, reason}
      end

    File.rm(patch)
    result
  end

  defp copy_untracked(_workspace, _tmp, ""), do: :ok

  defp copy_untracked(workspace, tmp, untracked) do
    untracked
    |> String.split("\0", trim: true)
    |> Enum.each(fn rel ->
      dest = Path.join(tmp, rel)
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(Path.join(workspace, rel), dest)
    end)

    :ok
  rescue
    error in [File.Error] -> {:error, Exception.message(error)}
  end

  # Re-pins `read_only_paths` — the grader's OWN definition files — to `ref` in the
  # overlaid clean worktree `tmp`, so a working-copy edit to a grader/checker/test
  # file cannot change the verdict even though the rest of the tree is now the
  # candidate state. A path that does not exist at `ref` (e.g. an agent-authored
  # file not yet committed) has no committed state to restore, so its overlay is
  # removed instead — the clean state for an uncommitted grader path is absence.
  @spec restore_grader_paths(String.t(), String.t(), [String.t()]) :: :ok
  defp restore_grader_paths(_tmp, _ref, []), do: :ok

  defp restore_grader_paths(tmp, ref, read_only_paths) do
    Enum.each(read_only_paths, fn path ->
      case git(tmp, ["checkout", ref, "--", path]) do
        {:ok, _output} -> :ok
        {:error, _reason} -> File.rm_rf(Path.join(tmp, path))
      end
    end)

    :ok
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
