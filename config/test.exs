import Config

# The test read-model is a per-run SQLite file under tmp/ (gitignored). The
# SQLite3 adapter's Sandbox pool wraps each test in a transaction so tests stay
# isolated and self-contained — CI runs `mix test` with no external DB step
# (the test setup migrates this DB itself). SQLite has a single writer, so the
# pool is sized to one connection.
config :kazi, Kazi.Repo,
  database: Path.expand("../tmp/kazi_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

config :logger, level: :warning
