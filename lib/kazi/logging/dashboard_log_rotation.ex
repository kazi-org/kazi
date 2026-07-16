defmodule Kazi.Logging.DashboardLogRotation do
  @moduledoc """
  Manages log rotation for the dashboard output to prevent unbounded growth.

  Implements a rotation mechanism that archives logs when they exceed size limits,
  ensuring the dashboard does not consume excessive disk space over time.
  """

  use GenServer
  require Logger

  @default_max_size 10_000_000
  @rotation_check_interval :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    log_path = Keyword.get(opts, :log_path, default_log_path())
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

  @doc """
  The default `dashboard.log` path: `KAZI_STATE_DIR` > `<user-home>/.kazi`,
  mirroring `Kazi.CrashDump.dir/0`. Resolved at RUNTIME (called from `init/1`
  on every boot), never a compile-time module attribute -- a `@default_log_path
  Path.join([System.user_home() ...])` attribute would freeze
  `System.user_home()` to whatever machine BUILT the release. For a Burrito
  binary that's the CI runner, not the operator's machine, so every fresh
  `kazi dashboard` boot tried to mkdir a path like `/Users/runner/.kazi` and
  crashed the whole VM with `:eacces` (live-verified 2026-07-08). Public so a
  test can assert the resolution honors `KAZI_STATE_DIR` without needing to
  fake a foreign machine's home directory.
  """
  @spec default_log_path() :: Path.t()
  def default_log_path do
    state_dir =
      System.get_env("KAZI_STATE_DIR") ||
        Path.join([System.user_home() || File.cwd!(), ".kazi"])

    Path.join(state_dir, "dashboard.log")
  end
end
