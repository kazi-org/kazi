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
    nats_name = default_nats_name(opts)

    nats_opts =
      opts
      |> Keyword.take([:nats_bin, :port, :store_dir, :nats_host, :nats_token])
      |> Keyword.put(:name, nats_name)

    # T55.11: the presence sweep (idle-vs-dead liveness for `bus who`). Named
    # per-supervisor for the same reason as `default_nats_name/1` -- lifecycle
    # tests run two co-existing trees. `:sweep_interval_ms`/`:sweep_idle_after_s`
    # are test seams; production uses the sweep's own defaults.
    sweep_opts =
      [
        name: Keyword.get(opts, :sweep_name, default_sweep_name(opts)),
        nats_name: nats_name
      ] ++
        Enum.flat_map(opts, fn
          {:sweep_interval_ms, v} -> [interval_ms: v]
          {:sweep_idle_after_s, v} -> [idle_after_s: v]
          _other -> []
        end)

    children = [
      {Kazi.Daemon.Nats, nats_opts},
      {Kazi.Daemon.PresenceSweep, sweep_opts},
      {Kazi.Daemon.Listener,
       sock_path: sock_path,
       pid_path: pid_path,
       name: listener_name,
       sup_pid: self(),
       nats_name: nats_name}
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

  @doc """
  The `Kazi.Daemon.Nats` process name `init/1` uses absent an explicit
  `opts[:nats_name]`: derived from THIS supervisor's own `opts[:name]`
  (fixed `Kazi.Daemon.Supervisor` in production -- one daemon per machine)
  rather than a bare module-atom default, so two co-existing supervisor
  instances (as `daemon_lifecycle_test.exs` deliberately runs, to prove
  double-start refusal) never race for the same registered process name.
  Exposed so `Kazi.Daemon.do_start/3` resolves the IDENTICAL name after
  `Supervisor.start_link/1` returns (it cannot read the child's runtime
  opts back out any other way).
  """
  @spec default_nats_name(keyword()) :: atom()
  def default_nats_name(opts) do
    Keyword.get(opts, :nats_name, Module.concat(Keyword.get(opts, :name, __MODULE__), Nats))
  end

  @doc """
  The `Kazi.Daemon.PresenceSweep` process name `init/1` uses absent an
  explicit `opts[:sweep_name]` -- derived from this supervisor's own
  `opts[:name]` exactly like `default_nats_name/1`, so two co-existing
  supervisor instances never race for one registered sweep name.
  """
  @spec default_sweep_name(keyword()) :: atom()
  def default_sweep_name(opts) do
    Module.concat(Keyword.get(opts, :name, __MODULE__), PresenceSweep)
  end

  defp daemon_dir do
    state_dir =
      System.get_env("KAZI_STATE_DIR") ||
        Path.join([System.user_home() || File.cwd!(), ".kazi"])

    Path.join(state_dir, "daemon")
  end
end
