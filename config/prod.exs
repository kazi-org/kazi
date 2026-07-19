import Config

# In production the read-model path is supplied at runtime (see
# runtime.exs once a deploy target is provisioned, T0.6h). WAL is inherited from
# config.exs; this block exists so `import_config "prod.exs"` resolves.
config :kazi, Kazi.Repo, pool_size: 5

# Prod dashboard endpoint. The server stays OFF here and the secret is omitted:
# deploying the dashboard as a live production surface (hosting + http binding +
# secret_key_base from the environment) is a separate infra task per ADR-0011,
# wired in a future runtime.exs. This block only sets the compile-time defaults
# so `import_config "prod.exs"` resolves and a release build compiles.
config :kazi, KaziWeb.Endpoint,
  cache_static_manifest: false,
  server: false
