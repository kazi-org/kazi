defmodule Kazi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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
    children =
      if sqlite_nif_available?() do
        [Kazi.Repo, {Phoenix.PubSub, name: Kazi.PubSub}, KaziWeb.Endpoint]
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
end
