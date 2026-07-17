defmodule Kazi.ReadModel.RunReaperTicker do
  @moduledoc """
  Periodically invokes `Kazi.ReadModel.RunReaper.reap/0` (T48.15).

  `RunReaper.reap/0` was correct and tested from the moment it shipped, but
  nothing ever called it — every zombie `running` row (a dead process, stale
  heartbeat) sat in the read-model forever, exactly the bug it was written to
  fix. This ticker closes that gap the same way `DashboardLogRotation` closes
  the equivalent gap for the log file: a periodic check started alongside the
  read-model/dashboard supervision tree, so a zombie run is reaped shortly
  after it goes stale rather than never.
  """

  use GenServer
  require Logger

  @default_check_interval :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :check_interval, @default_check_interval)
    schedule_reap(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:tick, %{interval: interval} = state) do
    reap_and_log()
    schedule_reap(interval)
    {:noreply, state}
  end

  defp reap_and_log do
    case Kazi.ReadModel.RunReaper.reap() do
      {:ok, []} ->
        :ok

      {:ok, reaped} ->
        Logger.info("kazi.run_reaper_ticker reaped #{length(reaped)} zombie run(s)")
    end
  end

  defp schedule_reap(interval) do
    Process.send_after(self(), :tick, interval)
  end
end
