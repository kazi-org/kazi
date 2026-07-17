defmodule Kazi.Daemon.Listener do
  @moduledoc """
  T51.1: the daemon's Unix-domain-socket control-plane listener. Binds
  `sock_path` (`:gen_tcp.listen/2` with `ifaddr: {:local, sock_path}`),
  accepts connections on a linked acceptor process, and answers each with
  `Kazi.Daemon.Control.handle/2` over a line-delimited JSON protocol.

  By the time this GenServer's `init/1` runs, the caller (`Kazi.Daemon.start/1`)
  has already probed `sock_path` via `Kazi.Daemon.Probe` and established it is
  either absent or a stale leftover from a dead process — this module never
  probes on its own, so it never races to steal a socket a live daemon holds.

  A `{"op":"shutdown"}` request causes the connection handler to notify this
  process, which asks its OWN supervisor (`opts[:sup_pid]`, passed down by
  `Kazi.Daemon.Supervisor.init/1` — `self()` there IS the supervisor pid) to
  stop, tearing down the WHOLE daemon tree (not just this one child). This
  process traps exits (`Process.flag(:trap_exit, true)` in `init/1`) so its
  `terminate/2` reliably runs on that supervisor-forced shutdown and closes
  the listen socket + removes both the socket file and the pidfile — a plain
  (non-trapping) GenServer, verified empirically, does NOT get its
  `terminate/2` invoked on a `Supervisor.stop/2`-driven exit signal, which
  would otherwise leave the socket/pidfile behind as false "still running"
  state (ADR-0067 decision point 1: down/stale detection must be trustworthy).
  """

  use GenServer
  require Logger

  alias Kazi.Daemon.Control

  defstruct [:sock_path, :pid_path, :listen_socket, :acceptor, :started_at, :sup_pid, :nats_name]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    sock_path = Keyword.fetch!(opts, :sock_path)
    pid_path = Keyword.fetch!(opts, :pid_path)
    sup_pid = Keyword.get(opts, :sup_pid)
    nats_name = Keyword.get(opts, :nats_name, Kazi.Daemon.Nats)

    File.mkdir_p!(Path.dirname(sock_path))
    File.mkdir_p!(Path.dirname(pid_path))
    # A leftover file at sock_path (verified dead by the caller's probe, or
    # simply absent) would make :gen_tcp.listen fail with :eaddrinuse.
    File.rm(sock_path)

    listen_opts = [
      :binary,
      packet: :line,
      active: false,
      backlog: 16,
      # The SAME line budget the client connects with -- `packet: :line`
      # truncates an over-long line silently on whichever end is receiving
      # (T55.7; see Kazi.Daemon.Probe.socket_buffer/0).
      buffer: Kazi.Daemon.Probe.socket_buffer(),
      ifaddr: {:local, sock_path}
    ]

    case :gen_tcp.listen(0, listen_opts) do
      {:ok, listen_socket} ->
        started_at = System.monotonic_time(:second)
        File.write!(pid_path, to_string(os_pid()))

        owner = self()
        acceptor = spawn_link(fn -> accept_loop(listen_socket, owner, started_at, nats_name) end)

        {:ok,
         %__MODULE__{
           sock_path: sock_path,
           pid_path: pid_path,
           listen_socket: listen_socket,
           acceptor: acceptor,
           started_at: started_at,
           sup_pid: sup_pid,
           nats_name: nats_name
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:shutdown_requested, state) do
    # Stopping via the supervisor (not `{:stop, :normal, state}` on this
    # process) tears down the whole tree; run it from an unlinked async
    # process so `Supervisor.stop/2` (which waits for this very process to
    # terminate) never deadlocks against the process making the call.
    sup_pid = state.sup_pid
    if sup_pid, do: spawn(fn -> Supervisor.stop(sup_pid, :normal) end)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.listen_socket, do: :gen_tcp.close(state.listen_socket)
    if state.sock_path, do: File.rm(state.sock_path)
    if state.pid_path, do: File.rm(state.pid_path)
    :ok
  end

  defp accept_loop(listen_socket, owner, started_at, nats_name) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> handle_conn(socket, owner, started_at, nats_name) end)
        accept_loop(listen_socket, owner, started_at, nats_name)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("kazi daemon: accept failed: #{inspect(reason)}")
        accept_loop(listen_socket, owner, started_at, nats_name)
    end
  end

  defp handle_conn(socket, owner, started_at, nats_name) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 5000),
         {:ok, request} <- Jason.decode(line) do
      response = Control.handle(request, started_at: started_at, nats_name: nats_name)
      _ = :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
      if request["op"] == "shutdown", do: send(owner, :shutdown_requested)
    else
      {:error, _reason} ->
        _ =
          :gen_tcp.send(
            socket,
            Jason.encode!(%{"ok" => false, "error" => "invalid_json"}) <> "\n"
          )
    end

    :gen_tcp.close(socket)
  end

  defp os_pid, do: :os.getpid() |> to_string() |> String.to_integer()
end
