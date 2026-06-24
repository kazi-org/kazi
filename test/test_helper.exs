# The `test` mix alias (mix.exs) runs `ecto.create` + `ecto.migrate` before this
# file, so the SQLite read-model exists and is migrated with no external DB step
# (T0.9 CI compatibility). Here we just put the Sandbox into :manual mode for
# per-test isolation.
Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, :manual)

# Integration tests tagged `:nats` need a real NATS JetStream server and are
# EXCLUDED by default so the standard `mix test` stays hermetic (no NATS, no
# network). They run only when `NATS_URL` is set in the environment:
#
#     NATS_URL=nats://127.0.0.1:4222 mix test --include nats
#
# `--include nats` overrides the default exclusion; the test itself reads
# `NATS_URL` to connect (see test/kazi/coordination/lease/nats_test.exs).
nats_excluded = if System.get_env("NATS_URL"), do: [], else: [:nats]

# Integration tests tagged `:graphify` need the real graphify embeddings tool and
# are EXCLUDED by default so the standard `mix test` stays hermetic (no embedding
# model, no index, no network). They run only when `GRAPHIFY_CMD` names the
# executable:
#
#     GRAPHIFY_CMD=graphify mix test --include graphify
#
# `--include graphify` overrides the default exclusion; the test reads
# `GRAPHIFY_CMD` for the command (see test/kazi/retrieval/graphify_integration_test.exs).
graphify_excluded = if System.get_env("GRAPHIFY_CMD"), do: [], else: [:graphify]

# The live opencode->DGX smoke test (tagged `:opencode_live`, T8.9/ADR-0016) is the
# only NON-hermetic test: it drives the operator's REAL `opencode` CLI wired to the
# DGX-hosted Qwen3.6 model. It is EXCLUDED by default so the standard `mix test`
# stays hermetic (no network, no DGX) and CI never runs it. Opt in explicitly:
#
#     mix test --only opencode_live test/kazi/opencode_live_test.exs
#
# The test itself probes the DGX endpoint + `opencode` binary first and SKIPS
# HONESTLY (never fails, never fake-passes) when either is unreachable.
opencode_live_excluded = [:opencode_live]

# The live codex smoke test (tagged `:codex_live`, T14.2/ADR-0022) drives the
# operator's REAL `codex` CLI (`codex exec … --json`) wired to OpenAI via
# `OPENAI_API_KEY` / `codex login`. Like `:opencode_live` it is NON-hermetic and
# EXCLUDED by default so the standard `mix test` and CI stay hermetic (no network,
# no creds). Opt in explicitly:
#
#     mix test --only codex_live test/kazi/codex_live_test.exs
#
# The test itself probes the `codex` binary + auth first and SKIPS HONESTLY
# (never fails, never fake-passes) when either is unavailable.
codex_live_excluded = [:codex_live]

# The live antigravity smoke test (tagged `:antigravity_live`, T14.3/ADR-0022)
# drives the operator's REAL `antigravity`/`agy` CLI with the #76 non-TTY
# workaround (`antigravity run --prompt-file … --output json --yes`) wired to
# Google via `GEMINI_API_KEY` / `ANTIGRAVITY_API_KEY`. Like `:codex_live` it is
# NON-hermetic and EXCLUDED by default so the standard `mix test` and CI stay
# hermetic (no network, no creds). Opt in explicitly:
#
#     mix test --only antigravity_live test/kazi/antigravity_live_test.exs
#
# The test itself probes the `antigravity`/`agy` binary + auth first and SKIPS
# HONESTLY (never fails, never fake-passes) when either is unavailable.
antigravity_live_excluded = [:antigravity_live]

# The live claw smoke test (tagged `:claw_live`, T14.4/ADR-0022) drives the
# operator's REAL `claw` CLI (`claw prompt "<text>"`) wired to a model via env API
# keys (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`). claw is added BEST-EFFORT /
# DEMO-GRADE (no structured output — `Kazi.Harness.Profiles.Claw`). Like
# `:codex_live` it is NON-hermetic and EXCLUDED by default so the standard `mix
# test` and CI stay hermetic (no network, no creds). Opt in explicitly:
#
#     mix test --only claw_live test/kazi/claw_live_test.exs
#
# The test itself probes the `claw` binary + auth first and SKIPS HONESTLY (never
# fails, never fake-passes) when either is unavailable.
claw_live_excluded = [:claw_live]

ExUnit.start(
  exclude:
    nats_excluded ++
      graphify_excluded ++
      opencode_live_excluded ++
      codex_live_excluded ++ antigravity_live_excluded ++ claw_live_excluded
)
