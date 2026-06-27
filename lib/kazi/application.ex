defmodule Kazi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Burrito binary entry (T6.2, ADR-0014). A Burrito-wrapped binary boots this
    # release instead of running an `eval` command, so the CLI args the operator
    # typed (`kazi run goal.toml ...`) arrive as Burrito's argv, not via an `eval`
    # expression. When we detect a standalone Burrito run (the `__BURRITO` env var
    # is set), hand straight to the CLI dispatch — it runs the command and halts
    # the VM, so `start/2` never returns and the supervision tree below is not
    # stood up (the CLI starts only what it needs via `Kazi.CLI.ensure_read_model`).
    # `running_standalone?/0` is false under the escript, `mix kazi.run`, the
    # release `eval` path, dev, and test, so every other entry starts normally.
    if burrito_standalone?() do
      Kazi.Release.burrito_main()
    end

    # Local read-model: SQLite (WAL) projection of the kazi.events log (T0.9).
    # The repo is omitted when the native SQLite (exqlite) NIF can't be loaded —
    # notably under the `kazi` escript, whose archive cannot bundle a NIF. Booting
    # the repo there would crash-loop the supervisor on a missing NIF; instead the
    # CLI degrades to a non-persistent run (see `Kazi.CLI`). `mix kazi.run` and any
    # real release boot with the NIF present, so the read-model starts normally.
    #
    # The Slice-3 operator dashboard (ADR-0011, T3.6) is supervised alongside the
    # read-model it projects: Phoenix.PubSub (LiveView diff transport) then the
    # KaziWeb.Endpoint. Both are gated on the same NIF check so the `kazi`
    # escript / CLI never tries to stand up an HTTP server it doesn't need — only
    # the full app (`mix kazi.run`, releases, dev, test) boots the web tree. The
    # endpoint reads the read-model and NATS state only; it never couples into
    # Kazi.Loop or Kazi.Harness (ADR-0011).
    # The parallel-scheduler supervision anchor (T21.1, ADR-0027): the
    # DynamicSupervisor that owns one reconciler per partition of a native
    # parallel run. It is always supervised (no NIF/web dependency) so a
    # `kazi run` over a partitioned goal-set can spawn its reconciler population
    # in one BEAM, NATS-free. It sits empty until a `Kazi.Scheduler` run starts
    # children under it.
    scheduler_children = [
      {Kazi.Scheduler.PartitionSupervisor, name: Kazi.Scheduler.PartitionSupervisor}
    ]

    children =
      scheduler_children ++
        if sqlite_nif_available?() do
          # PubSub before the DAG-snapshot cache (it subscribes on init, T23.7)
          # before the endpoint that serves the dashboard reading from it.
          [
            Kazi.Repo,
            {Phoenix.PubSub, name: Kazi.PubSub},
            # The readable native-lease registry (the dashboard-lease-map fix): the
            # NATS-free lease map source (`KaziWeb.CoordinationSource.Native`) reads
            # the active per-run leases the scheduler records here, so `/leases`
            # renders on a native run instead of 500-ing on the NATS transport. It
            # is read by the web tree, so it boots alongside it; absent it, lease
            # recording is a no-op and the dashboard renders the empty state.
            Kazi.Coordination.LeaseTable,
            KaziWeb.DagSource.Cache,
            KaziWeb.Endpoint
          ]
        else
          []
        end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kazi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The exqlite driver is a NIF; if its NIF module didn't load, no SQLite
  # connection can be opened, so the read-model repo must not be supervised.
  defp sqlite_nif_available? do
    Code.ensure_loaded?(Exqlite.Sqlite3NIF) and
      function_exported?(Exqlite.Sqlite3NIF, :open, 2)
  end

  # True only when this VM is the entry process of a Burrito-wrapped binary
  # (Burrito sets the `__BURRITO` env var when its launcher boots the release).
  # Guarded with `Code.ensure_loaded?` so the check is safe even if Burrito is
  # ever absent from a build (it stays a no-op rather than raising).
  defp burrito_standalone? do
    Code.ensure_loaded?(Burrito.Util) and
      function_exported?(Burrito.Util, :running_standalone?, 0) and
      Burrito.Util.running_standalone?()
  end
end
