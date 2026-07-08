import Config

# Runtime configuration — evaluated when the release (or Burrito binary) BOOTS,
# not at compile time. This is where a shipped artifact resolves machine-specific
# paths and secrets that cannot be baked in at build time.
#
# The read-model DB path is the load-bearing case for the Burrito binary (T6.2,
# ADR-0014): the compile-time default in `config/config.exs` points at
# `priv/kazi_dev.db` relative to the source tree's `__DIR__`, which does not exist
# on an end user's machine. A Burrito binary runs from an arbitrary working
# directory, so it needs a stable, writable location for its SQLite read-model.
#
# `KAZI_DB` lets an operator pin the path explicitly; otherwise we default to
# `<user-home>/.kazi/kazi.db` so two runs from different directories share one
# read-model (iteration history, the proposal queue). WAL is inherited from
# `config/config.exs`. We create the parent directory here so the very first run
# can open/migrate the DB instead of failing on a missing directory.
if config_env() == :prod do
  db_path =
    System.get_env("KAZI_DB") ||
      Path.join([System.user_home!() || File.cwd!(), ".kazi", "kazi.db"])

  File.mkdir_p!(Path.dirname(db_path))

  config :kazi, Kazi.Repo, database: db_path

  # Bound logger output to info level in production to avoid debug/trace spam
  # and reduce noise in dashboards and monitoring systems.
  config :logger, level: :info
end
