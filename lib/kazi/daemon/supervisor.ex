defmodule Kazi.Daemon.Supervisor do
  @moduledoc """
  T51.1 (ADR-0067 decision point 1): the daemon's own supervision tree — today
  just `Kazi.Daemon.Listener`, the control-socket. Started ONLY via
  `Kazi.Daemon.start/1` (in turn only reached by `kazi daemon start`); nothing
  else in the codebase depends on it (ADR-0067: convergence never depends on
  the bus). Later tasks (T51.2+) add siblings here (the supervised
  `nats-server` port, etc.) without touching the listener.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    sock_path = Keyword.get(opts, :sock_path, default_sock_path())
    pid_path = Keyword.get(opts, :pid_path, default_pid_path())
    listener_name = Keyword.get(opts, :listener_name, Kazi.Daemon.Listener)

    children = [
      {Kazi.Daemon.Listener,
       sock_path: sock_path, pid_path: pid_path, name: listener_name, sup_pid: self()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  The default control socket: `<state dir>/daemon/daemon.sock`, where the
  state dir is `KAZI_STATE_DIR` > `<user-home>/.kazi` — the same resolution
  chain as `Kazi.CrashDump.dir/0` and `Kazi.Logging.DashboardLogRotation`,
  resolved at RUNTIME (never a compile-time attribute — see those modules for
  why a frozen build-time home directory is a live boot hazard).
  """
  @spec default_sock_path() :: Path.t()
  def default_sock_path, do: Path.join(daemon_dir(), "daemon.sock")

  @doc "The default pidfile: `<state dir>/daemon/daemon.pid`."
  @spec default_pid_path() :: Path.t()
  def default_pid_path, do: Path.join(daemon_dir(), "daemon.pid")

  defp daemon_dir do
    state_dir =
      System.get_env("KAZI_STATE_DIR") ||
        Path.join([System.user_home!() || File.cwd!(), ".kazi"])

    Path.join(state_dir, "daemon")
  end
end
