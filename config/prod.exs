import Config

# In production the read-model path is supplied at runtime (see
# runtime.exs once a deploy target is provisioned, T0.6h). WAL is inherited from
# config.exs; this block exists so `import_config "prod.exs"` resolves.
config :kazi, Kazi.Repo, pool_size: 5
