defmodule Kazi.Daemon.Nats do
  @moduledoc """
  T51.2 (ADR-0067 decision point 2): supervises a `nats-server -js` process as
  a linked `Port` so the daemon can run the session bus's JetStream backend
  without an operator standing up their own NATS.

  Binary resolution is `opts[:nats_bin]` (the `kazi daemon start --nats-bin`
  flag) or `System.find_executable("nats-server")`. When neither resolves,
  `start_link/1` returns `{:error, :nats_bin_not_found}` immediately -- the
  daemon does not limp along busless (per the task brief); the caller
  (`Kazi.Daemon.Supervisor`) surfaces this as the ONE clear `kazi daemon
  start` failure line.

  The port binds `opts[:port]` (default 4223 -- deliberately non-standard so
  it never collides with an operator's own NATS on 4222) and stores JetStream
  under `opts[:store_dir]` (default `<state dir>/daemon/jetstream`).
  `wait_ready/2` briefly retries a `Gnat` connection so the caller (the
  supervisor's `init/1`, before `Kazi.Bus.Provision` runs) knows the server
  actually accepted TCP before reporting the daemon ready.
  """

  use GenServer
  require Logger

  @default_port 4223
  @ready_retry_ms 100
  @ready_timeout_ms 5_000

  defstruct [:port, :os_pid, :nats_port]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The TCP port the supervised nats-server is bound to (for `Kazi.Daemon.Control`'s ping response)."
  @spec port(GenServer.server()) :: pos_integer()
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @doc """
  Resolves the `nats-server` binary: an explicit path first, then `PATH`.
  Public so `Kazi.Daemon.start/1` can fail fast (before starting the
  supervision tree) with a clear, single-line error.
  """
  @spec resolve_bin(keyword()) :: {:ok, String.t()} | {:error, :nats_bin_not_found}
  def resolve_bin(opts \\ []) do
    case Keyword.get(opts, :nats_bin) || System.find_executable("nats-server") do
      nil -> {:error, :nats_bin_not_found}
      bin -> {:ok, bin}
    end
  end

  @doc """
  Briefly retries a `Gnat` connection to `port` until it succeeds or
  `timeout_ms` elapses -- used by the caller to confirm the server is ready
  before running boot provisioning (`Kazi.Bus.Provision`).
  """
  @spec wait_ready(pos_integer(), non_neg_integer()) :: :ok | {:error, :timeout}
  def wait_ready(port, timeout_ms \\ @ready_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_ready(port, deadline)
  end

  defp do_wait_ready(port, deadline) do
    case Gnat.start_link(%{host: "127.0.0.1", port: port}) do
      {:ok, conn} ->
        Gnat.stop(conn)
        :ok

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@ready_retry_ms)
          do_wait_ready(port, deadline)
        end
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, bin} <- resolve_bin(opts) do
      nats_port = Keyword.get(opts, :port, @default_port)
      store_dir = Keyword.get(opts, :store_dir, default_store_dir())
      File.mkdir_p!(store_dir)

      args = ["-js", "-p", to_string(nats_port), "-sd", store_dir]

      port =
        Port.open({:spawn_executable, bin}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      {:ok, %__MODULE__{port: port, os_pid: os_pid, nats_port: nats_port}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.nats_port, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("nats-server: #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("kazi daemon: nats-server exited (status #{status})")
    {:stop, {:nats_server_exited, status}, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @stop_wait_ms 2_000
  @stop_poll_ms 20

  @impl true
  def terminate(_reason, %{os_pid: os_pid}) when is_integer(os_pid) do
    # Port.close/1 disconnects the port but does not reliably kill the OS
    # process on every platform; send it a real signal too so a `kazi daemon
    # stop` never leaves an orphaned nats-server behind. Then WAIT for the
    # process to actually exit (bounded) so `terminate/2` returning -- and
    # thus `Supervisor.stop/2` returning -- means the port is genuinely free;
    # otherwise the very next daemon instance to start (a live concern in
    # tests, which start/stop the tree repeatedly) can race a still-dying
    # nats-server for the same TCP port.
    System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)
    wait_for_exit(os_pid, System.monotonic_time(:millisecond) + @stop_wait_ms)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp wait_for_exit(os_pid, deadline) do
    if alive_os_pid?(os_pid) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(@stop_poll_ms)
      wait_for_exit(os_pid, deadline)
    else
      :ok
    end
  end

  defp alive_os_pid?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _other -> false
    end
  end

  defp default_store_dir do
    state_dir =
      System.get_env("KAZI_STATE_DIR") ||
        Path.join([System.user_home!() || File.cwd!(), ".kazi"])

    Path.join([state_dir, "daemon", "jetstream"])
  end
end
