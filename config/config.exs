import Config

# kazi's local read-model is a SQLite (WAL) projection of the kazi.events log:
# predicate/iteration history and convergence analytics. It is rebuildable and
# never authoritative (concept §7 — CQRS: JetStream is the coordination truth,
# SQLite is a disposable projection).
config :kazi, ecto_repos: [Kazi.Repo]

# JSON library Ecto uses to (de)serialize :map columns (the predicate vector and
# action params are stored as JSON text in SQLite).
config :ecto_sqlite3, json_library: Jason

# Default (dev) read-model database. WAL keeps reads (the LiveView console,
# analytics queries) from blocking the projector's writes (concept §7).
config :kazi, Kazi.Repo,
  database: Path.expand("../priv/kazi_dev.db", __DIR__),
  journal_mode: :wal,
  pool_size: 5

import_config "#{config_env()}.exs"
