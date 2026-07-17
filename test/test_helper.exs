# The `test` mix alias (mix.exs) runs `ecto.create` + `ecto.migrate` before this
# file, so the SQLite read-model exists and is migrated with no external DB step
# (T0.9 CI compatibility). Here we just put the Sandbox into :manual mode for
# per-test isolation.
Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, :manual)

# i795/#795 suite_green hermeticity: `Kazi.Goal.Loader` force-loads a
# predicate's provider module (`Code.ensure_loaded/1`, M3 atom-safety) the
# FIRST time any goal declares that kind. That one-time load interns every
# atom literal in the module's own source — a real, one-off cost, not a
# per-call one. Left to happen lazily, whichever async test process is the
# first in the whole suite to load a given provider absorbs that atom burst,
# and if that process happens to be
# `Kazi.Goal.LoaderAtomSafetyTest`'s atom-count-delta assertion, the burst
# lands inside ITS measurement window and the test flakes — not because the
# loader mis-atomizes anything, but because the one-time load's timing is
# nondeterministic under `async: true` scheduling. Loading every real provider
# module here, before `ExUnit.start/1`, makes that burst happen exactly once,
# deterministically, before any test's atom-count snapshot.
for {_kind, module} <- Kazi.Runtime.provider_modules(), do: Code.ensure_loaded(module)

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

# The live opencode smoke test (tagged `:opencode_live`, T8.9/ADR-0016) is the
# only NON-hermetic test: it drives a REAL `opencode` CLI wired to a locally-hosted
# ~35B model on a GPU host. It is EXCLUDED by default so the standard `mix test`
# stays hermetic (no network, no GPU host) and CI never runs it. Opt in explicitly:
#
#     mix test --only opencode_live test/kazi/opencode_live_test.exs
#
# The test itself probes the model endpoint + `opencode` binary first and SKIPS
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

# The live Gemini CLI smoke test (tagged `:gemini_cli_live`, T37.1/T37.2,
# ADR-0022) drives the operator's REAL `gemini` CLI (`gemini -p "<prompt>" -o
# json --approval-mode yolo`) wired to Google via `GEMINI_API_KEY` (or Google
# OAuth / Vertex `GOOGLE_API_KEY`). Like `:codex_live`/`:antigravity_live` it is
# NON-hermetic and EXCLUDED by default so the standard `mix test` and CI stay
# hermetic (no network, no creds). The live body itself is T37.2; T37.1 only
# registers the tag (and a placeholder). Opt in explicitly:
#
#     mix test --only gemini_cli_live test/kazi/gemini_cli_live_test.exs
#
# The (T37.2) test will probe the `gemini` binary + auth first and SKIP HONESTLY
# (never fail, never fake-pass) when either is unavailable.
gemini_cli_live_excluded = [:gemini_cli_live]

# The release-binary stdout-purity test (tagged `:release_binary_live`, T54.10)
# runs the REAL released `kazi` binary (`KAZI_RELEASE_BIN` or `$PATH`) and stages
# a fake in-use older payload inside its burrito install prefix: the wrapper's
# maintenance pass runs BEFORE the BEAM boots, so only the release binary can be
# tested for it (no in-app guard can help). NON-hermetic and EXCLUDED by default
# so the standard `mix test` and CI stay hermetic (no installed release needed).
# Opt in explicitly:
#
#     mix test --only release_binary_live test/kazi/cli/release_binary_stdout_purity_test.exs
#
# The test itself probes the binary first and SKIPS HONESTLY (never fails, never
# fake-passes) when no burrito-built binary is available. Its once-per-boot
# assertion goes green only once kazi-org/burrito PR #1 is merged, the mix.exs
# fork pin is bumped, and a release built from the new pin is installed locally.
release_binary_live_excluded = [:release_binary_live]

ExUnit.start(
  exclude:
    nats_excluded ++
      graphify_excluded ++
      opencode_live_excluded ++
      codex_live_excluded ++
      antigravity_live_excluded ++
      claw_live_excluded ++ gemini_cli_live_excluded ++ release_binary_live_excluded
)
