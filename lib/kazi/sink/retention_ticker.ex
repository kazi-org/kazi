defmodule Kazi.Sink.RetentionTicker do
  @moduledoc """
  Periodically invokes `Kazi.Sink.Events.sweep/2` — the run-sink retention pass
  that drops a run's ENTIRE sink directory (`<sinks_dir>/<run_id>/`) once it is
  aged past the retention bound or oversized, while NEVER touching a directory
  belonging to a live run.

  T60.6 (#1155): `Kazi.Sink.Events.sweep/2` was correct and tested from the
  moment it shipped, but NOTHING ever called it — so per-run sink directories
  accumulated without bound (two machines that reproduced #1155 held 9,731 and
  35,570 sink dirs / 224 MB respectively). This ticker closes that gap exactly
  the way `Kazi.ReadModel.RunReaperTicker` closed the identical gap for the
  zombie-row reaper: a periodic pass started alongside the read-model
  supervision tree, so an aged sink is reclaimed shortly after it ages out
  rather than never.

  Best-effort, like everything on the sink path: the live-run set is read from
  `Kazi.ReadModel.RunRegistry.list_live/0`, and if that read is unavailable the
  tick SKIPS the sweep rather than risk deleting a directory whose run might be
  live; any error raised by the sweep itself is logged, never crashing the
  ticker or a run. Live directories are doubly protected — by `list_live` AND by
  `sweep/2`'s own mtime freshness check.

  `:sinks_dir`, `:live_run_ids`, `:max_age_seconds`, `:max_bytes`,
  `:check_interval`, and `:name` are injectable so a test can drive a fixture
  sink deterministically without the application-supervised instance.
  """

  use GenServer
  require Logger

  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Sink.Events

  @default_check_interval :timer.hours(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :check_interval, @default_check_interval)
    schedule_sweep(interval)
    {:ok, %{interval: interval, opts: opts}}
  end

  @impl true
  def handle_info(:tick, %{interval: interval, opts: opts} = state) do
    log(sweep_now(opts))
    schedule_sweep(interval)
    {:noreply, state}
  end

  @doc """
  Run one retention sweep synchronously (the tick's body, exposed so it runs in
  the caller's process for testing). Resolves the sinks dir and the live-run set,
  then calls `Kazi.Sink.Events.sweep/2`. Returns `{:ok, swept_run_ids}`,
  `{:skipped, reason}`, or `{:error, reason}` — never raises.
  """
  @spec sweep_now(keyword()) :: {:ok, [String.t()]} | {:skipped, term()} | {:error, term()}
  def sweep_now(opts \\ []) do
    case live_run_ids(opts) do
      {:ok, ids} ->
        sweep_opts =
          [live_run_ids: ids]
          |> carry(opts, :max_age_seconds)
          |> carry(opts, :max_bytes)

        {:ok, Events.sweep(sinks_dir(opts), sweep_opts)}

      {:skipped, reason} ->
        {:skipped, reason}
    end
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # An explicit :live_run_ids opt wins (hermetic tests); otherwise the live set
  # is the registry's — and a registry read failure SKIPS the sweep so a live
  # run's directory is never at risk.
  defp live_run_ids(opts) do
    case Keyword.fetch(opts, :live_run_ids) do
      {:ok, ids} ->
        {:ok, ids}

      :error ->
        {:ok, Enum.map(RunRegistry.list_live(), & &1.run_id)}
    end
  rescue
    e -> {:skipped, e}
  catch
    kind, reason -> {:skipped, {kind, reason}}
  end

  defp sinks_dir(opts) do
    Keyword.get(opts, :sinks_dir) ||
      Application.get_env(:kazi, :sinks_dir) ||
      Path.join([System.user_home() || File.cwd!(), ".kazi", "runs"])
  end

  defp carry(sweep_opts, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Keyword.put(sweep_opts, key, value)
      :error -> sweep_opts
    end
  end

  defp log({:ok, []}), do: :ok

  defp log({:ok, swept}),
    do: Logger.info("kazi.sink_retention_ticker swept #{length(swept)} aged sink dir(s)")

  defp log({:skipped, _reason}), do: :ok

  defp log({:error, reason}),
    do: Logger.warning(fn -> "kazi.sink_retention_ticker sweep failed: #{inspect(reason)}" end)

  defp schedule_sweep(interval), do: Process.send_after(self(), :tick, interval)
end
