defmodule Kazi.Scheduler.Worktree do
  @moduledoc """
  Isolated **git worktree per partition** (T21.4, ADR-0027; concept §9): each
  parallel fixer works in its OWN git worktree, CREATED on start and REMOVED on
  terminal — including on crash or timeout.

  ADR-0027 step 4 / concept §9 ("merge convergence — parallel fixers work in
  isolated git worktrees"): disjoint blast radii make cross-partition conflicts
  rare, but each fixer must still edit in isolation so siblings never see each
  other's mid-run working tree. This module gives each partition a distinct
  worktree off the repo, threads its path into the wrapped reconciler, and tears
  it down on every exit path.

  ## The worktree-guard landmine (honored here)

  The operator's Worktree Guardrail (global CLAUDE.md / docs/lore.md) is absolute:
  **never `rm -r` a worktree that is — or contains — a cwd.** This module honors
  it structurally:

    * worktrees are created under a MANAGED base dir (`System.tmp_dir` by default,
      or an injected `:base_dir`), **never inside the repo cwd** the run drives
      from, so removing one can never delete the working checkout;
    * teardown is `git worktree remove --force <path>` (git's own safe removal +
      prune of the admin ref) — **not** `File.rm_rf/1` and **never** `rm -r`;
    * the wrapped reconciler runs WITHOUT `cd`-ing this process into the worktree
      (the path is THREADED to the reconciler, which may run a subprocess there),
      so the cleanup process's cwd is never inside the dir it removes;
    * removal runs in an `after`, so a crashed or timed-out partition STILL has its
      worktree removed (the `--force` flag covers a dirty tree the run left
      behind), rather than leaking disk.

  A best-effort `File.rm_rf/1` is used ONLY as a fallback when `git worktree
  remove` fails AND the path is provably under the managed base dir (never a cwd,
  never the repo) — see `safe_cleanup/3`.

  ## Hermetic + injectable

  The git executable, the source repo, and the managed base dir are injected, so
  the acceptance test drives a real FIXTURE git repo under a temp base dir with no
  network and no real harness. The reconciler seam is unchanged: `wrap/2` returns
  a `t:Kazi.Scheduler.reconciler/0`; the inner it wraps receives the partition AND
  the created worktree path.
  """

  require Logger

  alias Kazi.Scheduler.WorktreeTable

  @typedoc """
  The inner reconciler the worktree seam wraps: it receives the partition AND the
  path to the partition's freshly-created worktree, and returns a partition
  status (or crashes — still cleaned up).
  """
  @type worktree_reconciler ::
          (Kazi.Scheduler.partition(), Path.t() -> Kazi.Scheduler.partition_status())

  @doc """
  Wraps `inner` so each partition runs in its own git worktree.

  Returns a `t:Kazi.Scheduler.reconciler/0`. Per partition it creates a distinct
  worktree under the managed base dir, invokes `inner.(partition, worktree_path)`,
  and removes the worktree in an `after` — so it is torn down on a normal
  terminal, an error return, and a crash/timeout alike. The wrapped status (or a
  crash) propagates unchanged.

  ## Options

    * `:repo` — the source git repository to branch worktrees from (required).
    * `:base_dir` — the MANAGED directory worktrees live under (default a fresh
      subdir of `System.tmp_dir/0`). MUST be outside the repo cwd; the guard
      depends on it.
    * `:git_cmd` — the git executable (default `"git"`); injected so a fixture
      test can pin it.
    * `:branch_prefix` — prefix for the per-worktree branch name (default
      `"kazi-partition"`). Each worktree gets a unique branch off the repo HEAD.
    * `:worktree_table` — the readable registry (M8, deep-review-001) this
      records the in-flight worktree into for the duration of the run (default
      `Kazi.Scheduler.WorktreeTable`), so a SURVIVING process can finish the
      cleanup a brutal-killed partition's `after` never reached. Best-effort: a
      no-op when the table is not running, so this never couples the scheduler
      to anything else.
  """
  @spec wrap(worktree_reconciler(), keyword()) :: Kazi.Scheduler.reconciler()
  def wrap(inner, opts) when is_function(inner, 2) and is_list(opts) do
    repo = Keyword.fetch!(opts, :repo)
    base_dir = Keyword.get(opts, :base_dir, default_base_dir())
    git_cmd = Keyword.get(opts, :git_cmd, "git")
    branch_prefix = Keyword.get(opts, :branch_prefix, "kazi-partition")
    worktree_table = Keyword.get(opts, :worktree_table, WorktreeTable)

    fn partition ->
      slug = slug_for(partition)
      {path, branch} = worktree_target(base_dir, branch_prefix, slug)

      case create(git_cmd, repo, path, branch) do
        :ok ->
          # M8 (deep-review-001): record BEFORE running the risky work, so a
          # process that gets brutal-killed mid-run (never reaching `after`)
          # still leaves a trace a surviving process can reap.
          entry = %{git_cmd: git_cmd, repo: repo, path: path}
          WorktreeTable.record(partition, entry, worktree_table)

          try do
            inner.(partition, path)
          after
            # Remove on EVERY exit path — normal, error return, crash, timeout.
            # `--force` covers a dirty tree the run left behind. Guard-safe: this
            # process never cd'd into `path`, and `path` is under the managed
            # base dir, never the repo cwd.
            safe_cleanup(git_cmd, repo, path)
            WorktreeTable.forget(partition, worktree_table)
          end

        {:error, reason} ->
          # Could not isolate the partition — do not run it un-isolated. It never
          # converged; the collective fold treats :stuck as escalate.
          Logger.warning(fn ->
            "kazi.scheduler.worktree failed to create worktree at #{path}: #{inspect(reason)}"
          end)

          :stuck
      end
    end
  end

  @doc """
  The managed base dir worktrees are created under by default: a stable subdir of
  the system temp dir, NEVER the repo cwd (the guard depends on this separation).
  """
  @spec default_base_dir() :: Path.t()
  def default_base_dir do
    Path.join(System.tmp_dir!(), "kazi-worktrees")
  end

  @doc """
  The survivor's half of the M8 (deep-review-001) fix: reaps whatever worktree
  is still recorded for `partition` in `worktree_table` (default
  `Kazi.Scheduler.WorktreeTable`) and finishes its cleanup via `safe_cleanup/3`.

  A no-op when nothing is recorded — which is the common case, since a normal
  exit (including an ordinary crash where `after` runs during unwind) already
  forgot its own entry. Only a process that was brutal-killed (a
  `:reconcile_timeout` firing, or an untrappable `Process.exit(pid, :kill)`)
  leaves an entry behind for this to find, so this is safe to call
  UNCONDITIONALLY from any process that just observed one of those two exits.
  """
  @spec reap(term(), atom() | pid()) :: :ok
  def reap(partition, worktree_table \\ WorktreeTable) do
    case WorktreeTable.reap(partition, worktree_table) do
      %{git_cmd: git_cmd, repo: repo, path: path} -> safe_cleanup(git_cmd, repo, path)
      nil -> :ok
    end
  end

  # --- worktree lifecycle -----------------------------------------------------

  # Create a worktree at `path` on a fresh branch off the repo HEAD. The base dir
  # is created first; the worktree dir itself must NOT pre-exist (git refuses).
  defp create(git_cmd, repo, path, branch) do
    File.mkdir_p!(Path.dirname(path))

    case git(git_cmd, repo, ["worktree", "add", "-b", branch, path, "HEAD"]) do
      {:ok, _out} -> :ok
      {:error, _} = error -> error
    end
  end

  # Remove the worktree, guard-safe. Prefer `git worktree remove --force` (git's
  # own safe removal: it refuses to remove a worktree that is the main checkout,
  # and it prunes the admin ref). Only if that fails do we fall back to a
  # File.rm_rf — and ONLY after asserting `path` is under the managed base dir and
  # is not a cwd, so we can NEVER rm a worktree that is/contains a cwd.
  @doc false
  @spec safe_cleanup(String.t(), Path.t(), Path.t()) :: :ok
  def safe_cleanup(git_cmd, repo, path) do
    case git(git_cmd, repo, ["worktree", "remove", "--force", path]) do
      {:ok, _out} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          "kazi.scheduler.worktree git remove failed for #{path}: #{inspect(reason)}; " <>
            "attempting guarded rm_rf fallback"
        end)

        guarded_rm_rf(repo, path)
        # Prune the now-dangling admin entry so `git worktree list` stays clean.
        _ = git(git_cmd, repo, ["worktree", "prune"])
        :ok
    end
  end

  # The guard: only ever rm_rf a path that is provably NOT a cwd and NOT the repo
  # — i.e. a real, separate worktree directory. This is the textual companion to
  # the operator's Worktree Guardrail (never rm -r a cwd worktree).
  defp guarded_rm_rf(repo, path) do
    abs_path = Path.expand(path)
    abs_repo = Path.expand(repo)
    cwd = File.cwd!() |> Path.expand()

    cond do
      abs_path in [cwd, abs_repo] ->
        Logger.error(fn ->
          "kazi.scheduler.worktree REFUSING to rm a cwd/repo path: #{abs_path}"
        end)

        :ok

      cwd_inside?(cwd, abs_path) ->
        Logger.error(fn ->
          "kazi.scheduler.worktree REFUSING to rm a path containing the cwd: #{abs_path}"
        end)

        :ok

      true ->
        _ = File.rm_rf(abs_path)
        :ok
    end
  end

  # Is `cwd` inside (a descendant of) `path`? If so, removing `path` would delete
  # the cwd — forbidden.
  defp cwd_inside?(cwd, path) do
    String.starts_with?(cwd <> "/", path <> "/")
  end

  # --- naming -----------------------------------------------------------------

  # A distinct (path, branch) target under the managed base dir. The slug keeps it
  # legible; a per-call nonce makes it unique even for the same partition key
  # across runs, so two worktrees never collide on disk. The branch carries the
  # configured prefix so a partition's branch is recognizable in `git branch`.
  defp worktree_target(base_dir, branch_prefix, slug) do
    nonce = :erlang.unique_integer([:positive, :monotonic])
    name = slug <> "-" <> Integer.to_string(nonce)
    branch = branch_prefix <> "/" <> name
    {Path.join(base_dir, name), branch}
  end

  # A filesystem- AND git-ref-safe slug for a partition. Prefers the partition's
  # stable key (truncated), falling back to a generic label so any partition
  # shape works. Real blast-radius keys carry characters git refuses in a branch
  # name (`radius:lib/a.ex` — `:` is forbidden in refs), so anything outside
  # [A-Za-z0-9_-] is folded to `-`; without this the `-b <branch>` in create/4
  # fails and the partition never runs.
  defp slug_for(%{key: key}) when is_binary(key) and key != "" do
    sanitized =
      key
      |> String.slice(0, 16)
      |> String.replace(~r/[^A-Za-z0-9_-]/, "-")

    "p-" <> sanitized
  end

  defp slug_for(_partition), do: "p"

  # --- git --------------------------------------------------------------------

  defp git(git_cmd, repo, args) do
    {out, status} = System.cmd(git_cmd, args, cd: repo, stderr_to_stdout: true)

    case status do
      0 -> {:ok, out}
      _ -> {:error, String.trim(out)}
    end
  end
end
