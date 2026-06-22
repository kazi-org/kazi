import Config

# Dev read-model lives under priv/ (gitignored — *.db). WAL is inherited from
# config.exs.
config :kazi, Kazi.Repo,
  database: Path.expand("../priv/kazi_dev.db", __DIR__),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
