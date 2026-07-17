defmodule Kazi.Bus.Liveness do
  @moduledoc """
  T55.11: pid + process-start-time identity for presence rows, shared by the
  presence upsert (`Kazi.Bus`), the `who` roster renderer, and the daemon's
  periodic sweep (`Kazi.Daemon.PresenceSweep`).

  A pid alone is reusable -- the OS recycles pid numbers -- so a presence row
  that recorded only a pid could be "resurrected" by an unrelated process that
  happened to receive the same number. Recording the process START TIME
  alongside the pid makes the identity reuse-proof: the same pid with a
  DIFFERENT start time is a different process, and the row's session is dead.

  The start time is captured as the verbatim `ps -o lstart=` output -- an
  OPAQUE token compared for byte equality on the SAME machine that recorded
  it. It is never parsed, and never compared across machines (a pid number
  means nothing on another host); `verdict/1` is only meaningful for rows
  whose `machine` is the local one.
  """

  @doc """
  The OS start time of process `pid` as an opaque string, or `nil` when no
  such process exists. `ps -o lstart=` is portable across macOS and Linux and
  is stable for the lifetime of the process, so equality with a previously
  recorded value proves the pid was not recycled.
  """
  @spec proc_started_at(integer() | String.t()) :: String.t() | nil
  def proc_started_at(pid) do
    case System.cmd("ps", ["-o", "lstart=", "-p", to_string(pid)], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> nil
          started -> started
        end

      _no_such_process ->
        nil
    end
  end

  @doc """
  Judges a LOCAL presence entry's recorded process:

    * `:alive` -- the recorded pid exists AND its current start time equals
      the recorded `started_at`.
    * `:dead` -- the pid is gone, or exists with a DIFFERENT start time
      (the pid was reused by an unrelated process).
    * `:unknown` -- inconclusive: the entry recorded no pid, or a pre-T55.11
      row recorded a pid without a start time and that pid is currently
      taken (reuse cannot be ruled out, so no liveness claim is made).

  Only meaningful for entries whose `machine` is THIS machine -- callers must
  never judge a remote machine's row locally.
  """
  @spec verdict(map()) :: :alive | :dead | :unknown
  def verdict(%{"pid" => pid} = entry) when is_integer(pid) do
    case proc_started_at(pid) do
      nil ->
        :dead

      current ->
        case entry["started_at"] do
          ^current -> :alive
          nil -> :unknown
          _different_process -> :dead
        end
    end
  end

  def verdict(_entry), do: :unknown

  @doc """
  Batched start times: ONE `ps -o pid=,lstart=` fork for the whole pid list
  (verification-gate finding: per-row forks made `who` and the sweep O(rows)
  in process spawns). Returns a map of pid (integer) => lstart string; pids
  absent from the map do not exist. An empty list never forks.
  """
  @spec started_map([integer()]) :: %{integer() => String.t()}
  def started_map([]), do: %{}

  def started_map(pids) do
    args = ["-o", "pid=,lstart=", "-p", Enum.map_join(pids, ",", &to_string/1)]

    case System.cmd("ps", args, stderr_to_stdout: true) do
      {out, code} when code in [0, 1] ->
        # exit 1 = some pids not found; the found ones still print.
        out
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(String.trim(line), " ", parts: 2) do
            [pid_s, started] ->
              case Integer.parse(pid_s) do
                {pid, ""} -> Map.put(acc, pid, String.trim(started))
                _bad -> acc
              end

            _bad ->
              acc
          end
        end)

      _ps_unusable ->
        %{}
    end
  end

  @doc """
  `verdict/1` against a preloaded `started_map/1` -- no fork. Same contract:
  `:alive` / `:dead` / `:unknown`.
  """
  @spec verdict(map(), %{integer() => String.t()}) :: :alive | :dead | :unknown
  def verdict(%{"pid" => pid} = entry, started_map) when is_integer(pid) do
    case Map.get(started_map, pid) do
      nil ->
        :dead

      current ->
        case entry["started_at"] do
          ^current -> :alive
          nil -> :unknown
          _different_process -> :dead
        end
    end
  end

  def verdict(_entry, _started_map), do: :unknown
end
