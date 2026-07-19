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

    # T52.4 (ADR-0068 point 2): migrate-before-serve. The daemon is the ONE and
    # ONLY read-model migrator AND writer (#1019: a mixed migration-writer field
    # is the exact class ADR-0068 closes) -- so BEFORE any child starts we, in
    # order: (1) START the read-model writer `Kazi.Repo` (#1504), then (2) run
    # the bounded, degrading boot migration ONCE against it. `Kazi.Daemon.Write`
    # (the write server) is then ordered before `Kazi.Daemon.Listener`, so by
    # the time the socket accepts a `write` the writer is up, the read-model is
    # migrated, and a client write is never served against an unmigrated file
    # ("no such table") or a not-started repo ("could not lookup Ecto repo").
    #
    # Fail-loud (#1504): a writer that CANNOT start makes the daemon REFUSE to
    # serve. We do NOT raise here -- a raise out of `init/1` propagates as a
    # linked exit that would KILL `Kazi.Daemon.start/1`'s caller (the CLI /
    # test) with a stack trace, not return the documented `{:error, _}`.
    # Instead we install a single child that fails to start, so
    # `Supervisor.start_link/1` returns CLEANLY -- the caller survives, gets
    # `{:error, {:shutdown, {:failed_to_start_child, ...}}}`, and `kazi daemon
    # start` prints "could not start daemon: ..." and exits non-zero, no socket
    # ever bound.
    case ensure_repo_started(opts) do
      :ok ->
        run_boot_migration(opts)

        write_opts =
          [name: default_write_name(opts)]
          |> maybe_put(:repo, Keyword.get(opts, :migrate_repo))
          |> maybe_put(:on_start, Keyword.get(opts, :write_on_start))

        # T67.6 (ADR-0079): the production trigger for the opt-in session-stats
        # collector. Named per-supervisor (as PresenceSweep/Nats are) so two
        # co-existing lifecycle-test trees never race for the process name. The
        # `:velocity_*` keys are test seams (a short interval, a fixture
        # transcript dir, an injected collector); production uses config +
        # defaults. Boot never blocks on it -- the first collection is on its
        # first timer tick, not in its `init/1`.
        velocity_opts =
          [name: default_velocity_ticker_name(opts)] ++
            Enum.flat_map(opts, fn
              {:velocity_interval_ms, v} -> [interval_ms: v]
              {:velocity_dir, v} -> [dir: v]
              {:velocity_state_dir, v} -> [state_dir: v]
              {:velocity_collect_fun, v} -> [collect_fun: v]
              {:velocity_workspaces, v} -> [workspaces: v]
              {:velocity_project_fun, v} -> [project_fun: v]
              _other -> []
            end)

        children = [
          {Kazi.Daemon.Nats, nats_opts},
          {Kazi.Daemon.PresenceSweep, sweep_opts},
          {Kazi.Daemon.VelocityTicker, velocity_opts},
          {Kazi.Daemon.Write, write_opts},
          {Kazi.Daemon.Listener,
           sock_path: sock_path,
           pid_path: pid_path,
           name: listener_name,
           sup_pid: self(),
           nats_name: nats_name}
        ]

        Supervisor.init(children, strategy: :one_for_one)

      {:error, reason} ->
        Supervisor.init([refusal_child(reason)], strategy: :one_for_one)
    end
  end

  # #1504: START the read-model writer (`Kazi.Repo`) BEFORE the boot migration
  # and BEFORE any write is served, and LEAVE IT RUNNING for the daemon's
  # lifetime. The daemon is the ONE writer/migrator (ADR-0068), so under a
  # standalone (Burrito) binary -- where `Kazi.Application.start/2` hands
  # straight to the CLI and never stands up the supervision tree that would own
  # `Kazi.Repo` -- the daemon must open the read-model read-write ITSELF.
  # Mirrors the reader-side standalone path
  # (`Kazi.CLI.migrate_read_model_direct`): `storage_up` creates the SQLite file
  # if absent, then `start_link` opens it. Idempotent: a no-op when the repo is
  # already supervised (the mix / dev / test / non-Burrito release path -- where
  # the app tree owns exactly one repo, never double-started) or already started
  # here. Absent this the boot migration hits "could not lookup Ecto repo
  # Kazi.Repo because it was not started", degrades to no-persistence, and the
  # daemon serves anyway with every run-registry / KPI write silently lost.
  #
  # Fail-loud contract (#1504): unlike `run_boot_migration/1` -- which is DESIGNED
  # to degrade on its OWN bounded cases (a peer holding the migration lock, a
  # newer schema stamp: never fatal, always logged, per ADR-0068) -- a repo that
  # CANNOT start (an unwritable state dir, a corrupt db) leaves the daemon with
  # NO writer at all. That is NOT a silent-degrade case: it returns `{:error,
  # reason}` and `init/1` installs `refusal_child/1` so the daemon REFUSES to
  # serve (see the `init/1` comment for why a return, not a raise). Returns `:ok`
  # once the writer is up (or already was). `:repo_start_fun`/`:migrate_repo` are
  # test seams (mirror `:migrate_fun`): a lifecycle test injects a start that
  # fails (to pin the refusal) or points the writer at a throwaway repo.
  @spec ensure_repo_started(keyword()) :: :ok | {:error, term()}
  defp ensure_repo_started(opts) do
    start_fun =
      Keyword.get(opts, :repo_start_fun, fn ->
        repo = Keyword.get(opts, :migrate_repo, Kazi.Repo)

        if repo_started?(repo) do
          :ok
        else
          _ = repo.__adapter__().storage_up(repo.config())

          case repo.start_link() do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end
      end)

    start_fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp repo_started?(repo) do
    is_pid(Process.whereis(repo)) or is_pid(GenServer.whereis(repo))
  end

  # The fail-loud refusal (#1504): a child spec whose start returns `{:error,
  # reason}`, so `Supervisor.start_link/1` fails CLEANLY (the linked caller
  # survives with `{:error, {:shutdown, {:failed_to_start_child, ...}}}`) rather
  # than the raw linked-exit a raise out of `init/1` would deliver. It is the
  # ONLY child on the refusal path, so no socket/listener is ever bound.
  # `:temporary` so the failure is terminal, never restart-looped.
  defp refusal_child(reason) do
    %{
      id: :read_model_writer,
      start: {__MODULE__, :refuse_start, [reason]},
      restart: :temporary
    }
  end

  @doc false
  # Invoked by the supervisor as `refusal_child/1`'s start MFA. Always fails,
  # carrying the writer-start `reason` out through the supervisor's clean
  # failed-to-start-child path.
  @spec refuse_start(term()) :: {:error, term()}
  def refuse_start(reason), do: {:error, reason}

  # The boot migration. `Kazi.ReadModel.Migrate.run/2` is itself bounded and
  # degrading (L-0035: never raises, never blocks past its bound), so a peer
  # holding the SQLite lock costs this boot a few seconds of no-persistence,
  # never a hang -- and its result is deliberately not fatal to daemon start
  # (a degraded read-model is the read-model's own concern, not the daemon's).
  # `:migrate_fun`/`:migrate_repo` are test seams: a lifecycle test injects a
  # recorder (to prove ordering) or points the migration at a throwaway repo.
  defp run_boot_migration(opts) do
    migrate_fun =
      Keyword.get(opts, :migrate_fun, fn ->
        Kazi.ReadModel.Migrate.run(Keyword.get(opts, :migrate_repo, Kazi.Repo), [])
      end)

    _ = migrate_fun.()
    :ok
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

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

  @doc """
  The `Kazi.Daemon.Write` process name `init/1` uses absent an explicit
  `opts[:write_name]` -- derived from this supervisor's own `opts[:name]`
  exactly like `default_nats_name/1`, so two co-existing supervisor instances
  (the double-start lifecycle test) never race for one registered write-server
  name (T52.4).
  """
  @spec default_write_name(keyword()) :: atom()
  def default_write_name(opts) do
    Keyword.get(opts, :write_name, Module.concat(Keyword.get(opts, :name, __MODULE__), Write))
  end

  @doc """
  The `Kazi.Daemon.VelocityTicker` process name `init/1` uses absent an explicit
  `opts[:velocity_name]` -- derived from this supervisor's own `opts[:name]` for
  the same reason as `default_sweep_name/1`, so two co-existing supervisor
  instances (the double-start lifecycle test) never race for one registered
  ticker name (T67.6).
  """
  @spec default_velocity_ticker_name(keyword()) :: atom()
  def default_velocity_ticker_name(opts) do
    Keyword.get(
      opts,
      :velocity_name,
      Module.concat(Keyword.get(opts, :name, __MODULE__), VelocityTicker)
    )
  end

  defp daemon_dir do
    state_dir =
      System.get_env("KAZI_STATE_DIR") ||
        Path.join([System.user_home() || File.cwd!(), ".kazi"])

    Path.join(state_dir, "daemon")
  end
end
