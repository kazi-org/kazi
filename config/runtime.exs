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

# ADR-0060 guardrail 4 / ADR-0061 / ADR-0062: the episodic attempt ledger and
# semantic recall ship DEFAULT OFF (config/config.exs) until they prove they
# pay rent under the ADR-0046 envelope. That proof requires running a RELEASED
# binary with the layer ON against real goals — but compile-time config is
# baked false into the artifact, so without a runtime override the benchmark
# the guardrail demands is impossible to run on the shipped binary. These env
# hooks are that override: opt-in per PROCESS, nothing baked, default
# unchanged ("1"/"true" enable; anything else — including unset — leaves the
# compile-time default in force).
if System.get_env("KAZI_ATTEMPT_LEDGER") in ~w(1 true) do
  config :kazi, :attempt_ledger, true
end

if System.get_env("KAZI_MEMORY_RECALL") in ~w(1 true) do
  config :kazi, :memory_recall, true
end
