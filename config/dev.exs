import Config

# Dev read-model lives under priv/ (gitignored — *.db). WAL is inherited from
# config.exs.
config :kazi, Kazi.Repo,
  database: Path.expand("../priv/kazi_dev.db", __DIR__),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Dev dashboard endpoint: bind 4000 on all interfaces, run the server so
# `iex -S mix` serves the dashboard, and surface errors in the page. The
# secret_key_base is a fixed dev-only value (never used in prod — see prod.exs
# / a future runtime.exs).
config :kazi, KaziWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  secret_key_base: "kazidevsecretkeybasekazidevsecretkeybasekazidevsecretkeybase00000",
  debug_errors: true,
  check_origin: false

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
