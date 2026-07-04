defmodule Kazi.Scheduler.WorktreeTable do
  @moduledoc """
  A best-effort, globally-readable registry of the git worktree currently
  in-flight for a partition (M8, deep-review-001).

  `Kazi.Scheduler.Worktree.wrap/2` creates a worktree and removes it in a
  `try/after` around the wrapped reconciler — but `after` never runs when that
  process is brutal-killed (`Task.shutdown(task, :brutal_kill)` on a finite
  `:reconcile_timeout`, or an untrappable `Process.exit(pid, :kill)` self-kill),
  which would otherwise leak the worktree directory and its git admin ref
  forever. This table is the survival mechanism: `Worktree.wrap/2` records the
  `{git_cmd, repo, path}` it created BEFORE running the risky work and forgets
  it in the (normal-path) `after` — so a SURVIVING process (the coordinator, or
  `Kazi.Scheduler`'s own `invoke_reconciler/3` after a timeout-triggered
  brutal-kill) can `reap/2` any entry still present after a kill and finish the
  cleanup the dead process never got to run.

  Mirrors `Kazi.Coordination.LeaseTable`'s shape: a small, optional, globally-
  named `Agent` keyed by the partition term itself (the SAME value flows
  through `Worktree.wrap/2`, `Kazi.Scheduler.invoke_reconciler/3`, and the
  coordinator's crash handling, so equality holds trivially). Every operation is
  a no-op when the table is not running (a hermetic test, the escript), so
  recording here never couples the scheduler to anything else.
  """

  use Agent

  @typedoc "What `reap/2` needs to finish a worktree's cleanup."
  @type entry :: %{git_cmd: String.t(), repo: Path.t(), path: Path.t()}

  @doc """
  Starts the table (an empty `partition => entry()` map).

  Accepts `:name` (defaults to `#{inspect(__MODULE__)}`) so the app starts the
  singleton while a test can start an isolated instance.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc """
  Records the worktree currently in-flight for `partition`. Best-effort: a
  no-op when the table is not running.
  """
  @spec record(term(), entry(), atom() | pid()) :: :ok
  def record(partition, %{git_cmd: _, repo: _, path: _} = entry, name \\ __MODULE__) do
    if alive?(name), do: Agent.update(name, &Map.put(&1, partition, entry))
    :ok
  end

  @doc """
  Forgets the worktree recorded for `partition` (it was cleaned up normally).
  Best-effort: a no-op when the table is not running.
  """
  @spec forget(term(), atom() | pid()) :: :ok
  def forget(partition, name \\ __MODULE__) do
    if alive?(name), do: Agent.update(name, &Map.delete(&1, partition))
    :ok
  end

  @doc """
  Atomically pops the entry recorded for `partition`, if any — the survivor's
  half of the M8 fix: a partition whose process died without reaching its
  `after` (a brutal-kill) still has a recorded entry here, so the caller can
  finish removing it. Returns `nil` (and is a no-op) when nothing is recorded
  or the table is not running, so a NORMAL exit (which already forgot its own
  entry) is always a safe no-op to reap.
  """
  @spec reap(term(), atom() | pid()) :: entry() | nil
  def reap(partition, name \\ __MODULE__) do
    if alive?(name) do
      Agent.get_and_update(name, fn table ->
        {Map.get(table, partition), Map.delete(table, partition)}
      end)
    end
  end

  defp alive?(name) when is_atom(name), do: is_pid(Process.whereis(name))
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
end
