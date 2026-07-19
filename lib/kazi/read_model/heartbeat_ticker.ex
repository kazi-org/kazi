defmodule Kazi.ReadModel.HeartbeatTicker do
  @moduledoc """
  A supervised periodic timer that advances the heartbeat_at timestamp of a run
  every ~30 seconds, independent of loop iterations (T31, issue #856).

  The ticker is spawned as part of the run's supervision tree when a run starts
  with persistence enabled. It sends `RunRegistry.heartbeat/1` messages to update
  the heartbeat_at column on a fixed interval, keeping healthy long-running
  dispatches from appearing stale in the starmap.

  When the run process terminates, the ticker is automatically shut down by the
  supervision tree. The tick interval is ~30 seconds (30000 milliseconds).
  """

  use GenServer
  require Logger

  alias Kazi.ReadModel.RunRegistry

  # ~30 second heartbeat interval (30000 ms)
  @heartbeat_interval_ms 30000

  @doc """
  Starts a heartbeat ticker process for the given `run_id`.

  Returns `{:ok, pid}` when started successfully.
  """
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(run_id) when is_binary(run_id) do
    GenServer.start_link(__MODULE__, run_id)
  end

  @impl GenServer
  def init(run_id) do
    # Schedule the first heartbeat after the interval
    schedule_heartbeat()
    {:ok, run_id}
  end

  @impl GenServer
  def handle_info(:tick, run_id) do
    # Advance the heartbeat timestamp
    case RunRegistry.heartbeat(run_id) do
      {:ok, _run} ->
        # Re-schedule the next heartbeat
        schedule_heartbeat()
        {:noreply, run_id}

      {:error, :not_found} ->
        # Run is not in the registry (shouldn't happen during normal operation)
        Logger.debug("HeartbeatTicker: run #{run_id} not found in registry")
        schedule_heartbeat()
        {:noreply, run_id}

      {:error, :read_model_unavailable} ->
        # The read-model degraded (Guard hard-deadline, T52.7 refuse, or a
        # transient CLI-side degrade -- issue #1511). This is the SAME degrade
        # shape the Writer already tolerates: skip the beat quietly and keep the
        # ticker alive rather than crash-looping. Logged at most ONCE per ticker
        # (not per 30s tick) so a persistence-blind run stays visible without
        # spamming the log.
        log_degrade_once(run_id)
        schedule_heartbeat()
        {:noreply, run_id}
    end
  end

  defp log_degrade_once(run_id) do
    unless Process.get(:heartbeat_degrade_logged) do
      Logger.warning(
        "HeartbeatTicker: read-model unavailable for run #{run_id}; " <>
          "skipping heartbeats without persistence"
      )

      Process.put(:heartbeat_degrade_logged, true)
    end
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :tick, @heartbeat_interval_ms)
  end
end
