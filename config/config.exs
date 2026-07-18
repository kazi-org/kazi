import Config

# kazi's local read-model is a SQLite (WAL) projection of the kazi.events log:
# predicate/iteration history and convergence analytics. It is rebuildable and
# never authoritative (concept §7 — CQRS: JetStream is the coordination truth,
# SQLite is a disposable projection).
config :kazi, ecto_repos: [Kazi.Repo]

# kazi is a CLI: stdout is the program's output surface (prose, or a single JSON
# object under --json), stderr is diagnostics. The default `:logger` handler
# writes to `:standard_io` (stdout) unless told otherwise, so an Ecto migrator/OTP
# log line (e.g. "Migrations already up") would otherwise land on stdout ahead of
# the JSON object and break a `jq`-based parse (issue #804). Route it to stderr
# everywhere, not just under --json, so the byte-clean-stdout contract holds
# unconditionally.
config :logger, :default_handler, config: [type: :standard_error]

# JSON library Ecto uses to (de)serialize :map columns (the predicate vector and
# action params are stored as JSON text in SQLite).
config :ecto_sqlite3, json_library: Jason

# Phoenix uses Jason for JSON across the framework.
config :phoenix, :json_library, Jason

# ADR-0061 decision 6 / ADR-0060 guardrail 4: the episodic attempt ledger ships
# behind a flag, DEFAULT OFF, until the ADR-0046 benchmark proves it pays rent.
# With the default `false` the dispatch prompt carries no ATTEMPT LEDGER
# section — byte-identical to before the ledger existed (see docs/memory.md).
config :kazi, :attempt_ledger, false

# ADR-0062 decision 4 / ADR-0060 guardrail 4: semantic recall over the
# git-native corpus (`Kazi.Memory.SemanticIndex`) also ships behind a flag,
# DEFAULT OFF, until it pays rent under the ADR-0046 envelope. With the
# default `false` the dispatch prompt carries no recalled-knowledge section —
# byte-identical to before this layer existed (see docs/memory.md).
config :kazi, :memory_recall, false

# Slice-3 operator dashboard endpoint (ADR-0011, T3.6). Compile-time defaults
# shared by all envs; per-env http binding / server enablement / secrets are set
# in dev.exs / test.exs / prod.exs. The endpoint is asset-free (no esbuild), so
# there is no live_reload or watchers block.
config :kazi, KaziWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [html: KaziWeb.ErrorHTML], layout: false],
  pubsub_server: Kazi.PubSub,
  live_view: [signing_salt: "kazi-live"]

# T65.4 (#1430): the tombstone-alias grace window for a bus rename. When
# `kazi bus name` renames an already-named session, the OLD name lingers as a
# resolvable tombstone-alias for this many seconds so an in-flight
# `bus tell <old-name>` still lands (with a renamed-notice on the sender's ack);
# after the window it errors with the current name as a hint. Default 10 minutes.
config :kazi, :bus_rename_grace_s, 600

# Default (dev) read-model database. WAL keeps reads (the LiveView console,
# analytics queries) from blocking the projector's writes (concept §7).
#
# `busy_timeout`: every `kazi` process on a machine shares one read-model DB
# (`~/.kazi/kazi.db`, runtime.exs), so a fleet of concurrent `kazi apply`
# runs contend for the single WAL writer. exqlite's 2s default surfaces as
# SQLITE_BUSY wedges once a handful of processes overlap; 60s lets a waiting
# writer ride out another process's write burst instead of erroring.
config :kazi, Kazi.Repo,
  database: Path.expand("../priv/kazi_dev.db", __DIR__),
  journal_mode: :wal,
  busy_timeout: 60_000,
  pool_size: 5

import_config "#{config_env()}.exs"
