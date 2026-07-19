defmodule Kazi.SessionLiveness do
  @moduledoc """
  Detects and probes the *driving agent session* behind a kazi process — the
  interactive Claude Code (or similar) process that launched `kazi apply`.

  The run registry records the kazi process's own `os_pid`, but a terminal
  run's kazi process is dead by definition; the operator's real question on
  the starmap is whether the SESSION that drove a run still exists (it might
  retry a stuck goal; a dead session's stuck goal is guaranteed to need a
  human). `find_session_pid/0` walks the process ancestry at registration
  time and returns the nearest ancestor that looks like an agent session;
  `alive?/1` probes a recorded pid later (dashboard poll ticks).
  """

  # Ancestor command names that count as a driving agent session. Matched as
  # substrings of `ps -o comm=` output (basename or full path, per OS).
  @session_commands ["claude", "opencode", "codex", "gemini"]

  @doc """
  Walks this process's ancestry (`ps -o ppid=,comm=`) and returns the pid of
  the nearest ancestor whose command names an agent session, as a string —
  or `nil` when no such ancestor exists (kazi launched from a bare shell,
  cron, CI). Best-effort: any `ps` failure returns `nil`, never raises.
  """
  @spec find_session_pid() :: String.t() | nil
  def find_session_pid do
    walk(System.pid(), 0)
  rescue
    _ -> nil
  end

  defp walk(_pid, depth) when depth > 20, do: nil
  defp walk(pid, _depth) when pid in [nil, "0", "1"], do: nil

  defp walk(pid, depth) do
    case probe(pid) do
      {ppid, comm} ->
        # `comm` is PID's OWN command: when it matches, PID itself is the
        # session process — return it, never its parent. (Returning `ppid`
        # here recorded the shell that spawned claude, whose comm then
        # failed the liveness check and mis-filed live runs as CLOSED.)
        if session_command?(comm), do: pid, else: walk(ppid, depth + 1)

      nil ->
        nil
    end
  end

  # {ppid, comm} for PID — the parent pid to continue the walk, and PID's
  # own command name for the session check.
  defp probe(pid) do
    case System.cmd("ps", ["-o", "ppid=,comm=", "-p", pid], stderr_to_stdout: true) do
      {out, 0} ->
        case String.split(String.trim(out), " ", parts: 2, trim: true) do
          [ppid, comm] -> {String.trim(ppid), comm}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp session_command?(comm) do
    base = comm |> String.trim() |> Path.basename() |> String.downcase()
    Enum.any?(@session_commands, &String.contains?(base, &1))
  end

  @doc """
  Whether the recorded session pid is still alive AND still an agent-session
  command (guards against OS pid reuse). `nil`/empty pids are `false` — an
  unrecorded session is not a live one.
  """
  @spec alive?(String.t() | nil) :: boolean()
  def alive?(nil), do: false
  def alive?(""), do: false

  def alive?(pid) when is_binary(pid) do
    case parent_probe(pid) do
      nil -> false
      comm -> session_command?(comm)
    end
  end

  @doc """
  Batch liveness for a dashboard tick: one `ps` call for all distinct
  recorded pids. Returns a map of pid => alive?; pids absent from `ps`
  output (dead) map to `false`.
  """
  @spec alive_map([String.t() | nil]) :: %{String.t() => boolean()}
  def alive_map(pids) do
    pids =
      pids
      |> Enum.filter(&(is_binary(&1) and &1 != "" and String.match?(&1, ~r/^\d+$/)))
      |> Enum.uniq()

    live =
      case pids do
        [] ->
          MapSet.new()

        _some ->
          # ps exits non-zero when ANY listed pid is gone, but still prints
          # the live ones — parse output regardless of exit status.
          {out, _status} =
            System.cmd("ps", ["-o", "pid=,comm=", "-p", Enum.join(pids, ",")],
              stderr_to_stdout: true
            )

          out
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(String.trim(line), " ", parts: 2, trim: true) do
              [pid, comm] -> if session_command?(comm), do: [pid], else: []
              _ -> []
            end
          end)
          |> MapSet.new()
      end

    Map.new(pids, &{&1, MapSet.member?(live, &1)})
  rescue
    _ -> Map.new(pids, &{&1, false})
  end

  # `ps -o comm= -p <pid>` returns the command iff the process exists.
  defp parent_probe(pid) do
    case System.cmd("ps", ["-o", "comm=", "-p", pid], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> nil
          comm -> comm
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
