defmodule Kazi.ReadModel.RunReaper do
  @moduledoc """
  T48.15 / T60.2: run reaper for detecting and cleaning up dead runs.

  A `running` row is a ghost once its process is gone but its status never
  reached a terminal value. The reaper transitions such rows to `"abandoned"`
  so they are distinguishable from live, freshly-heartbeating runs.

  Reaping fires on any of three signals, checked against the set of runs
  `RunRegistry.stale?/2` already flags (no terminal status, heartbeat older
  than the stale bound):

    1. **Dead OS pid** — the run recorded an `os_pid` and that process no
       longer exists (`kill -0` fails). The original T48.15 fast path.
    2. **No verifiable liveness** — the run never recorded an `os_pid` (it
       crashed before `RunRegistry.record_harness_pid/2`, or predates the
       field). There is no process to probe, so once the row is stale it is
       treated as abandoned. This is the primary ghost-row cause fixed by
       T60.2 (#1155): the T48.15 reaper filtered these rows out entirely
       (`has_os_pid?`), so they sat at `running` forever.
    3. **Time backstop** — the heartbeat is older than `abandon_after_seconds`
       (default #{24 * 60 * 60}s / 24h) regardless of pid liveness. This reaps
       a row whose recorded `os_pid` was recycled by the OS to an unrelated,
       now-live process (a false "alive" reading), which no liveness probe can
       ever catch. The bound is far above any legitimate heartbeat gap, so a
       genuinely-live run is never touched.

  A fresh-heartbeat `running` row is never stale and so is never a reap
  candidate — the "never reap a live run" invariant holds through all three
  paths.
  """

  alias Kazi.ReadModel.Run
  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Repo

  # Time backstop: a stale `running` row this old is abandoned regardless of
  # whether its recorded os_pid probes as alive (guards against PID recycling).
  # Bounded well above any legitimate heartbeat gap so a live run is untouched.
  @abandon_after_seconds 24 * 60 * 60

  @doc """
  Reaps ghost runs, transitioning them to `"abandoned"`. Never reaps a run whose
  OS process is still alive AND whose heartbeat is within `abandon_after_seconds`.

  Options:
    * `:abandon_after_seconds` — time-backstop bound (default
      `#{@abandon_after_seconds}`).

  Returns `{:ok, reaped_runs}` with the list of runs that were abandoned.
  """
  @spec reap(keyword()) :: {:ok, [Run.t()]}
  def reap(opts \\ []) do
    abandon_after = Keyword.get(opts, :abandon_after_seconds, @abandon_after_seconds)

    reaped =
      RunRegistry.list_stale()
      |> Enum.filter(fn run -> should_reap?(run, abandon_after) end)
      |> Enum.map(&mark_abandoned/1)
      |> Enum.filter(&ok_tuple?/1)
      |> Enum.map(&extract_run/1)

    {:ok, reaped}
  end

  # A stale run is reaped when its heartbeat has crossed the time backstop, OR
  # its liveness cannot be verified (no os_pid), OR its recorded process is dead.
  defp should_reap?(run, abandon_after_seconds) do
    heartbeat_older_than?(run, abandon_after_seconds) or
      not has_os_pid?(run) or
      not process_alive?(run)
  end

  defp heartbeat_older_than?(%Run{heartbeat_at: heartbeat_at}, seconds)
       when not is_nil(heartbeat_at) do
    DateTime.diff(DateTime.utc_now(), heartbeat_at, :second) > seconds
  end

  defp heartbeat_older_than?(%Run{}, _seconds), do: false

  defp has_os_pid?(%Run{os_pid: os_pid}) do
    not is_nil(os_pid) and os_pid != ""
  end

  defp process_alive?(%Run{os_pid: os_pid}) when is_binary(os_pid) do
    case Integer.parse(os_pid) do
      {pid, ""} -> process_exists?(pid)
      _ -> false
    end
  end

  defp process_alive?(%Run{}), do: false

  defp process_exists?(pid) when is_integer(pid) do
    # Use kill with signal 0 to check process existence without killing it
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      {_, _} -> false
    end
  rescue
    _ -> false
  end

  defp mark_abandoned(run) do
    run
    |> Run.changeset(%{"status" => "abandoned", "finished_at" => DateTime.utc_now()})
    |> Repo.update()
  end

  defp ok_tuple?({:ok, _}), do: true
  defp ok_tuple?(_), do: false

  defp extract_run({:ok, run}), do: run
end
