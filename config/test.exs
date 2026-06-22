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

# Test dashboard endpoint. `server: true` on a fixed port (4002) so the
# Playwright browser smoke test (Tier 3) can drive a real running endpoint;
# ExUnit endpoint/LiveView tests (Tier 1) use Phoenix.ConnTest against the same
# supervised endpoint regardless of the listener. secret_key_base is a fixed
# test-only value.
config :kazi, KaziWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: true,
  secret_key_base: "kazitestsecretkeybasekazitestsecretkeybasekazitestsecretkeybase00",
  check_origin: false

config :logger, level: :warning
