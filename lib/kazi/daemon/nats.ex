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

  ADR-0067 cross-machine (T51.3): when `opts[:nats_host]` is set, `init/1`
  skips binary resolution and `Port.open/2` entirely and CONNECTS to that
  remote host/port instead of spawning a local `nats-server` -- `port/1`
  still returns the (remote) port for the control-socket ping and
  `Kazi.Bus.Provision`'s host/port threading. `terminate/2` is then a no-op
  (there is no local OS process to kill). An optional shared
  `opts[:nats_token]` is passed as `-auth <token>` to the spawned server
  (spawn side) or as `auth_token:` on the `Gnat` connect opts (both spawn
  side's `wait_ready/2` and connect side) -- see `docs/session-bus.md`
  ("Cross-machine setup") for the security tradeoff of running without one.
  """

  use GenServer
  require Logger

  @default_port 4223
  @ready_retry_ms 100
  @ready_timeout_ms 5_000

  defstruct [:port, :os_pid, :nats_host, :nats_port, :nats_token]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The TCP port the supervised (or remote-connected) nats-server is bound to (for `Kazi.Daemon.Control`'s ping response)."
  @spec port(GenServer.server()) :: pos_integer()
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @doc "The nats-server host: `127.0.0.1` when locally spawned, or the connect-mode `opts[:nats_host]`."
  @spec host(GenServer.server()) :: String.t()
  def host(server \\ __MODULE__), do: GenServer.call(server, :host)

  @doc """
  The shared-bus auth token (`opts[:nats_token]`), or `nil` when the bus runs
  unauthenticated. Surfaced through the daemon control handshake so a bus CLIENT
  on the SAME machine can present it to a token-protected nats (issue #1101).
  """
  @spec token(GenServer.server()) :: String.t() | nil
  def token(server \\ __MODULE__), do: GenServer.call(server, :token)

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
  Briefly retries a `Gnat` connection to `host`:`port` until it succeeds or
  `timeout_ms` elapses -- used by the caller to confirm the server is ready
  before running boot provisioning (`Kazi.Bus.Provision`). `host` defaults to
  `127.0.0.1` (the local-spawn case); the connect-mode caller passes the
  remote `opts[:nats_host]` instead. `token` is passed as the `Gnat`
  connection's `auth_token` when the shared bus is running with one.
  """
  @spec wait_ready(pos_integer(), non_neg_integer(), String.t(), String.t() | nil) ::
          :ok | {:error, :timeout}
  def wait_ready(port, timeout_ms \\ @ready_timeout_ms, host \\ "127.0.0.1", token \\ nil) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_ready(host, port, token, deadline)
  end

  defp do_wait_ready(host, port, token, deadline) do
    case Gnat.start_link(connect_opts(host, port, token)) do
      {:ok, conn} ->
        Gnat.stop(conn)
        :ok

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@ready_retry_ms)
          do_wait_ready(host, port, token, deadline)
        end
    end
  end

  defp connect_opts(host, port, nil), do: %{host: host, port: port}
  defp connect_opts(host, port, token), do: %{host: host, port: port, auth_token: token}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Keyword.get(opts, :nats_host) do
      nil -> init_spawn(opts)
      host -> init_connect(host, opts)
    end
  end

  defp init_connect(host, opts) do
    nats_port = Keyword.get(opts, :port, @default_port)

    {:ok,
     %__MODULE__{
       nats_host: host,
       nats_port: nats_port,
       nats_token: Keyword.get(opts, :nats_token)
     }}
  end

  defp init_spawn(opts) do
    with {:ok, bin} <- resolve_bin(opts) do
      nats_port = Keyword.get(opts, :port, @default_port)
      store_dir = Keyword.get(opts, :store_dir, default_store_dir())
      File.mkdir_p!(store_dir)

      token = Keyword.get(opts, :nats_token)
      args = ["-js", "-p", to_string(nats_port), "-sd", store_dir] ++ auth_args(token)

      port =
        Port.open({:spawn_executable, bin}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      {:ok,
       %__MODULE__{
         port: port,
         os_pid: os_pid,
         nats_host: "127.0.0.1",
         nats_port: nats_port,
         nats_token: token
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp auth_args(nil), do: []
  defp auth_args(token), do: ["-auth", token]

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.nats_port, state}

  @impl true
  def handle_call(:host, _from, state), do: {:reply, state.nats_host, state}

  @impl true
  def handle_call(:token, _from, state), do: {:reply, state.nats_token, state}

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
        Path.join([System.user_home() || File.cwd!(), ".kazi"])

    Path.join([state_dir, "daemon", "jetstream"])
  end
end
