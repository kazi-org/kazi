defmodule Kazi.Runtime.BusMirror do
  @moduledoc """
  T51.5 (ADR-0067 point 1): mirrors an `apply` run's lifecycle onto the session
  bus as best-effort `fact`s -- a run START, each iteration's predicate PROGRESS,
  and the TERMINAL verdict -- so a session supervising the bus sees a long run's
  live state instead of only a growing JSONL sink it cannot watch. Field feedback
  (2026-07-16): a 9-hour single-invocation `apply` ran with no intermediate
  observable state at all; the bus is the channel a supervisor already reads.

  INVARIANT (ADR-0067 point 1, pinned by test): the bus is a MIRROR, never a
  dependency. A goal converges BYTE-IDENTICALLY with the daemon down. Every post
  here is fire-and-forget and every error/timeout/daemon-down collapses to `:ok`,
  so the reconcile loop's outcome can never turn on whether a daemon is up --
  exactly `Kazi.Bus.Hook`'s best-effort contract, and the reason the mirror
  swallows the `{:error, :no_daemon}` `Kazi.Bus.post/3` already returns offline.

  Two delivery modes, chosen by where the post is made:

    * the per-ITERATION post runs DETACHED (an unlinked `Task`) so it adds no
      latency to and leaks no message into the loop's `gen_statem` mailbox -- a
      dropped progress line on a fast run is acceptable, blocking the loop is not;
    * the START and TERMINAL posts are made from the runtime process and wait a
      bounded moment (`Task.async`/`yield`, capped at #{2_000}ms) so the terminal
      verdict lands before a one-shot `kazi apply` process exits.

  All of a run's facts share ONE topic -- `run:<short-run-id>` -- so the board's
  last-value-per-topic retention (ADR-0072/0073) collapses them to ONE current
  line per run: `started ...` -> `iter N: p/t passing` -> `<verdict> ...`.

  The poster is injectable via `:run_mirror_poster` (default `&Kazi.Bus.post/3`)
  so a test can assert the mirrored facts' content without a live daemon.
  """

  alias Kazi.PredicateResult

  @timeout_ms 2_000

  @typedoc "The `Loop.await/2` result shape this mirror projects a verdict from."
  @type await_result :: {:ok, map()} | {:error, term()}

  @doc "Post the run-START fact (goal ref carried in the line, session in headers)."
  @spec started(String.t(), String.t(), String.t() | nil) :: :ok
  def started(goal_ref, run_id, session_name) do
    emit("started #{goal_ref}", run_id, session_name, :wait)
  end

  @doc """
  Post ONE per-iteration PROGRESS fact from the loop's `on_iteration` payload:
  the iteration index and the predicate pass/total, with a regression count when
  any predicate went green->red this observation. Detached -- never blocks the
  loop. Any payload that is not a well-formed iteration is a silent no-op.
  """
  @spec iteration(String.t(), String.t() | nil, map()) :: :ok
  def iteration(run_id, session_name, %{iteration: n, vector: vector} = payload)
      when is_integer(n) do
    {passing, total} = counts(vector)
    regressions = payload |> Map.get(:regressions) |> List.wrap() |> length()
    suffix = if regressions > 0, do: " (#{regressions} regressed)", else: ""
    emit("iter #{n}: #{passing}/#{total} passing#{suffix}", run_id, session_name, :detach)
  end

  def iteration(_run_id, _session_name, _payload), do: :ok

  @doc """
  Post the TERMINAL verdict fact from the `Loop.await/2` result: the honest
  verdict (converged / stuck / over_budget / stopped / error), the final
  pass/total, and the iteration count.
  """
  @spec terminal(String.t(), String.t(), String.t() | nil, await_result()) :: :ok
  def terminal(goal_ref, run_id, session_name, {:ok, %{outcome: outcome} = result}) do
    verdict = verdict(outcome, Map.get(result, :reason))
    {passing, total} = counts(Map.get(result, :vector))
    iters = Map.get(result, :iterations, 0)

    emit(
      "#{verdict} #{goal_ref} (#{passing}/#{total} passing, #{iters} iters)",
      run_id,
      session_name,
      :wait
    )
  end

  def terminal(goal_ref, run_id, session_name, {:error, _reason}) do
    emit("error #{goal_ref}", run_id, session_name, :wait)
  end

  def terminal(_goal_ref, _run_id, _session_name, _other), do: :ok

  defp counts(%{results: results}) do
    total = map_size(results)
    passing = Enum.count(results, fn {_id, r} -> PredicateResult.passed?(r) end)
    {passing, total}
  end

  defp counts(_), do: {0, 0}

  defp verdict(:converged, _reason), do: "converged"
  defp verdict(:over_budget, _reason), do: "over_budget"
  defp verdict(:stopped, :stuck), do: "stuck"
  defp verdict(:stopped, _reason), do: "stopped"
  defp verdict(_outcome, _reason), do: "stopped"

  # The one post seam: build the fact, run the poster contained (a raise/exit/
  # timeout/daemon-down never escapes as anything but :ok), DETACHED for the
  # loop-side iteration post and bounded-synchronous for the runtime-side
  # start/terminal posts.
  defp emit(text, run_id, session_name, mode) do
    poster = Application.get_env(:kazi, :run_mirror_poster, &Kazi.Bus.post/3)
    topic = "run:" <> short(run_id)

    fun = fn ->
      try do
        poster.("fact", text, topic: topic, session_name: session_name)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    case mode do
      :detach ->
        Task.start(fun)

      :wait ->
        task = Task.async(fun)
        Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill)
    end

    :ok
  end

  defp short(run_id) when is_binary(run_id), do: String.slice(run_id, 0, 8)
  defp short(_run_id), do: "unknown"
end
