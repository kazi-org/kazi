defmodule Kazi.ReadModel.Guard do
  @moduledoc """
  Bounded execution for read-model writes: "kazi never hangs on its own
  telemetry."

  The read-model (`~/.kazi/kazi.db`) is authoritative for nothing — it is a
  rebuildable projection (concept §7) — yet every `kazi` process on a machine
  shares it, and SQLite allows one writer. Under fleet contention a raw
  `Repo` call can BLOCK (DBConnection's reconnect loop, the migrator waiting
  on a locked DB) rather than error, wedging a run for as long as the lock
  holder lives (lore L-0035: two runs hung ~20 minutes at 0% CPU). A raised
  error already degrades gracefully at every call site; an indefinite block
  bypasses all of that handling.

  `run/3` closes that gap: the write executes in a monitored task with a
  hard deadline. On timeout (or crash) the task is killed, a warning is
  logged, and `{:error, :read_model_unavailable}` is returned — the same
  error-tuple shape every registry/projection call site already tolerates —
  so the reconcile loop continues without persistence instead of hanging.

  Sandbox note: the task inherits `$callers`, so Ecto's SQL Sandbox
  ownership flows through in tests.
  """

  require Logger

  # Generous enough to ride out a peer's write burst on top of the repo's
  # 60s SQLite busy_timeout being the per-statement bound; short enough that
  # a wedged DB costs a run seconds, not minutes.
  @default_timeout_ms 15_000

  @doc """
  Runs `fun` with a hard deadline of `timeout_ms` (default 15s).

  Returns `fun`'s result, or `{:error, :read_model_unavailable}` when the
  call times out, raises, or exits — always with a logged warning naming
  `label`. Never blocks the caller past the deadline.
  """
  @spec run(String.t(), (-> result), non_neg_integer()) ::
          result | {:error, :read_model_unavailable}
        when result: term()
  def run(label, fun, timeout_ms \\ @default_timeout_ms) when is_function(fun, 0) do
    task =
      Task.async(fn ->
        try do
          {__MODULE__, :ok, fun.()}
        rescue
          error -> {__MODULE__, :error, error}
        catch
          kind, reason -> {__MODULE__, :error, {kind, reason}}
        end
      end)

    result =
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {__MODULE__, :ok, result}} ->
          result

        {:ok, {__MODULE__, :error, reason}} ->
          unavailable(label, reason)

        {:exit, reason} ->
          unavailable(label, reason)

        nil ->
          unavailable(label, {:timeout, timeout_ms})
      end

    # `Task.async/1` links the task; a caller that traps exits (the
    # finalizer's signal handling does) would otherwise find the task's
    # `{:EXIT, pid, :normal}` in its mailbox after we return — which its
    # trapped-exit drain would misread as a crashed linked process (and, by
    # re-entering a guarded write, loop forever). Flush it here so the guard
    # is invisible to trapping callers.
    receive do
      {:EXIT, pid, _reason} when pid == task.pid -> :ok
    after
      0 -> :ok
    end

    result
  end

  defp unavailable(label, reason) do
    Logger.warning(fn ->
      "read-model #{label} unavailable (#{inspect(reason)}); continuing without persistence"
    end)

    {:error, :read_model_unavailable}
  end
end
