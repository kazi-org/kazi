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

  **Never fails the caller either**, and that now holds for EVERY caller rather
  than only ones that trap exits (#1652). The fun runs in an UNLINKED monitored
  worker, so an exit the worker cannot convert — an async signal from a dying
  linked process, or the SQLite NIF taking it down — reaches this function as a
  `:DOWN` message and degrades to the error tuple, instead of propagating to the
  caller and killing it. Do not reintroduce `Task.async` here: it links.
  """
  @spec run(String.t(), (-> result), non_neg_integer()) ::
          result | {:error, :read_model_unavailable}
        when result: term()
  def run(label, fun, timeout_ms \\ @default_timeout_ms) when is_function(fun, 0) do
    # #1652: the worker is UNLINKED and monitored (`spawn_monitor`), not a
    # `Task.async`. `Task.async/1` LINKS the task to its caller, and while the
    # `try/rescue/catch` below converts every failure the fun RAISES, it cannot
    # convert an ASYNCHRONOUS exit signal — a linked process dying delivers a
    # signal that kills the process outright rather than unwinding through
    # `catch`. That signal then propagated task -> caller and KILLED any caller
    # that does not trap exits (`KaziWeb.MissionControlLive` is exactly such a
    # caller, and reaches here via `RunRegistry.list/0`). Demonstrated in
    # `guard_exit_demonstration_test.exs`: the two arms differ only in
    # `Process.flag(:trap_exit, ...)` and that flipped survive/killed.
    #
    # Unlinking makes the guard's documented contract TRUE for every caller: an
    # untrappable death in the worker surfaces to the parent as `:DOWN` and
    # degrades to `{:error, :read_model_unavailable}` like everything else,
    # instead of propagating. The worker deliberately does NOT trap exits — it
    # already classifies raised failures as values via `try/rescue/catch`, and
    # letting an async death take the worker down preserves the pre-existing
    # semantic ("a linked death degrades this write to unavailable") rather than
    # silently continuing a fun whose dependency just vanished.
    #
    # `$callers` must be propagated by hand: `Task.async/1` did this for us, and
    # Ecto's SQL Sandbox reads it to route ownership in tests.
    parent = self()
    ref = make_ref()
    callers = [parent | Process.get(:"$callers", [])]

    {pid, mon} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)

        result =
          try do
            {:ok, fun.()}
          rescue
            error -> {:error, error}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, {:ok, value}} ->
        Process.demonitor(mon, [:flush])
        value

      {^ref, {:error, reason}} ->
        Process.demonitor(mon, [:flush])
        unavailable(label, reason)

      # An exit the worker could not convert (an async signal from a dying
      # linked process, or the SQLite NIF taking it down). The caller is NOT
      # linked, so this is a value here rather than a death there.
      {:DOWN, ^mon, :process, ^pid, reason} ->
        unavailable(label, reason)
    after
      timeout_ms ->
        # Parity with the `Task.shutdown(task, :brutal_kill)` this replaced,
        # which flushed the task's reply for us. The worker can complete in the
        # window between the deadline firing and the kill landing, and a `send`
        # to a local process reaches the mailbox synchronously — so its reply
        # could otherwise sit in a long-lived caller's mailbox forever (Mission
        # Control and the daemon both outlive individual guarded calls). Waiting
        # for `:DOWN` first makes the drain exhaustive rather than hopeful:
        # signals from one process to another are ordered, so once the worker's
        # death is observed, any reply it sent is already queued ahead of it.
        #
        # Narrow by construction and NOT reproduced — no test pins this race;
        # it is defensive parity with the code being replaced, not a fix for an
        # observed leak.
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^mon, :process, ^pid, _reason} -> :ok
        after
          timeout_ms -> Process.demonitor(mon, [:flush])
        end

        receive do
          {^ref, _result} -> :ok
        after
          0 -> :ok
        end

        unavailable(label, {:timeout, timeout_ms})
    end
  end

  defp unavailable(label, reason) do
    Logger.warning(fn ->
      "read-model #{label} unavailable (#{inspect(reason)}); continuing without persistence"
    end)

    {:error, :read_model_unavailable}
  end
end
