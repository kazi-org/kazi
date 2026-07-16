defmodule Kazi.ReadModel.RunReaper do
  @moduledoc """
  T48.15: run reaper for detecting and cleaning up dead runs by OS process liveness.

  The reaper identifies runs that are no longer alive by checking their recorded
  OS PID (`os_pid` field). A run is considered dead when its OS process no longer
  exists. The reaper marks these runs as "abandoned" so they can be distinguished
  from running, stale, or cleanly-terminated runs.
  """

  alias Kazi.ReadModel.Run
  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Repo

  @doc """
  Reaps dead runs by checking OS process liveness and transitioning them to
  "abandoned" status. Never reaps a run whose OS process is still alive, ensuring
  the reaper respects process liveness invariants.

  Returns `{:ok, reaped_runs}` with the list of runs that were abandoned.
  """
  @spec reap() :: {:ok, [Run.t()]}
  def reap do
    stale_runs = RunRegistry.list_stale()

    reaped =
      stale_runs
      |> Enum.filter(fn run -> has_os_pid?(run) end)
      |> Enum.filter(fn run -> not process_alive?(run) end)
      |> Enum.map(&mark_abandoned/1)
      |> Enum.filter(&ok_tuple?/1)
      |> Enum.map(&extract_run/1)

    {:ok, reaped}
  end

  defp has_os_pid?(%Run{os_pid: os_pid}) do
    not is_nil(os_pid) and os_pid != ""
  end

  defp process_alive?(%Run{os_pid: os_pid}) when is_binary(os_pid) do
    case Integer.parse(os_pid) do
      {pid, ""} -> process_exists?(pid)
      _ -> false
    end
  end

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
