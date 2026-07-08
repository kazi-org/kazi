defmodule Kazi.Logging.DashboardLogRotation do
  @moduledoc """
  Manages log rotation for the dashboard output to prevent unbounded growth.

  Implements a rotation mechanism that archives logs when they exceed size limits,
  ensuring the dashboard does not consume excessive disk space over time.
  """

  use GenServer
  require Logger

  @default_log_path Path.join([System.user_home!() || File.cwd!(), ".kazi", "dashboard.log"])
  @default_max_size 10_000_000
  @rotation_check_interval :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    log_path = Keyword.get(opts, :log_path, @default_log_path)
    max_size = Keyword.get(opts, :max_size, @default_max_size)

    log_dir = Path.dirname(log_path)
    File.mkdir_p!(log_dir)

    # Schedule periodic rotation checks
    schedule_rotation_check()

    {:ok, %{log_path: log_path, max_size: max_size}}
  end

  @impl true
  def handle_info(:check_rotation, state) do
    perform_rotation_check(state)
    schedule_rotation_check()
    {:noreply, state}
  end

  defp perform_rotation_check(%{log_path: log_path, max_size: max_size}) do
    case File.stat(log_path) do
      {:ok, stat} when stat.size >= max_size ->
        rotate_log(log_path)

      _ ->
        :ok
    end
  end

  defp rotate_log(log_path) do
    case File.read(log_path) do
      {:ok, content} ->
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
        archive_path = "#{log_path}.#{timestamp}"

        case File.write(archive_path, content) do
          :ok ->
            File.write!(log_path, "")
            Logger.info("Rotated dashboard log to #{archive_path}")

          {:error, reason} ->
            Logger.warning("Failed to rotate dashboard log: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Failed to read dashboard log for rotation: #{inspect(reason)}")
    end
  end

  defp schedule_rotation_check do
    Process.send_after(self(), :check_rotation, @rotation_check_interval)
  end
end
