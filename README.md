# kazi

**Describe what "done" looks like. kazi makes it true — and proves it.**

*kazi* (Swahili: *work / a job*) is the missing **outer loop** for coding agents.
You tell it the outcome you want — in plain English or as a short goal-file — and
kazi drives a coding agent (Claude Code, Codex, …) in a loop until that outcome is
*objectively* real: tests pass, the endpoint is live, the change is deployed. If it
can't get there, it stops and tells you why (stuck, or out of budget) instead of
pretending it's finished.

Think of it like **Kubernetes for coding goals**: you declare desired state, kazi
watches actual state, and it keeps closing the gap until the two match.

```
You: "the /health endpoint should return 200 with body ok, live in production"
            │
            ▼
kazi:  observe ──► what's failing? ──► dispatch an agent to fix it
            ▲                                      │
            └──── loop until every check passes ◄──┘  then: integrate · deploy · verify live
```

It is **not** another coding agent, terminal, or IDE. kazi *drives* the agent you
already use. As that agent gets better, kazi gets better for free.

---

## Why kazi?

Two problems nobody else owns:

1. **"Done" is the agent's opinion.** A coding agent stops when it *thinks* it's
   finished — even when the work is merely plausible. kazi makes "done" objective:
   the loop can only succeed when *every* check (kazi calls them **predicates**)
   evaluates true, with stored evidence. Truth lives in the controller, not the agent.
2. **Parallel agents collide.** Locking a *task* doesn't stop two agents editing the
   *same files*. kazi coordinates on **resources** — an agent leases its "blast
   radius" before touching code — so concurrent runs converge instead of conflict.

---

## The 60-second mental model

A **goal** is just a list of checkable statements plus a budget:

- **predicates** — the checks that define "done": `the unit tests pass`, `GET /health
  returns 200 ok`, `the production error rate is 0 over 30m`, …
- a **budget** — a hard ceiling (iterations / wall-clock / tokens) so it can never
  run forever or burn money.
- a **scope** — the repo + paths agents are allowed to touch.

kazi loops: **observe** every predicate → the failing ones *are* the to-do list →
**dispatch** an agent to fix them → **integrate** (open a PR, rebase-merge) →
**deploy** → **re-check**. It stops only when all predicates are true (`converged`),
the same checks keep failing (`stuck` → escalate to you), or the budget runs out.

---

## Prerequisites

- **Elixir / Erlang** (OTP 26+) and `mix` — to run kazi.
- **A coding agent on your PATH** — the default harness is `claude` (Claude Code);
  any `-p`-style agent works. kazi shells out to it to make edits.
- **git** — kazi commits and opens PRs in your target repo.
- *(optional, for live deploys)* **gcloud** / a deploy command, and `gh` for PRs.

```sh
git clone https://github.com/kazi-org/kazi && cd kazi
mix deps.get
mix test          # ~700 hermetic tests, should be green
```

Two ways to invoke kazi (same behavior):

```sh
# Mix task — recommended. Boots the full app and persists every iteration to a
# local SQLite read-model (created + migrated automatically on first run).
mix kazi.run <goal-file> --workspace <path-to-your-project>

# Or build a standalone binary:
mix escript.build          # produces ./kazi
./kazi run <goal-file> --workspace <path-to-your-project>
./kazi --help
```

### Build a self-contained release (full read-model)

The escript can't bundle the native SQLite NIF, so it runs **without** the
read-model. A `mix release` bundles ERTS *and* the compiled NIFs, so the released
binary has the **full read-model** (and is the foundation the per-platform binary
is built from — see [ADR-0014](docs/adr/0014-binary-distribution-burrito-homebrew.md)):

```sh
MIX_ENV=prod mix release --overwrite     # builds _build/prod/rel/kazi

# The CLI is invoked through the release's `eval` command, which propagates the
# CLI's exit code (0 on convergence / a recorded proposal / approval, non-zero
# otherwise) — so the release composes in scripts and CI like the escript:
_build/prod/rel/kazi/bin/kazi eval 'Kazi.Release.cli(["--help"])'
_build/prod/rel/kazi/bin/kazi eval \
  'Kazi.Release.cli(["run", "<goal-file>", "--workspace", "<path>"])'
_build/prod/rel/kazi/bin/kazi eval 'Kazi.Release.cli(["list-proposed"])'
```

`Kazi.Release.cli/1` dispatches to the same `Kazi.CLI` core as the escript and
`mix kazi.run`, so every subcommand (`run` / `propose` / `list-proposed` /
`approve` / `reject` / `--help`) behaves identically.

### Build a single-file native binary (Burrito)

[Burrito](https://github.com/burrito-elixir/burrito) wraps the `mix release`
above into one self-contained per-platform executable that bundles ERTS **and**
the compiled exqlite NIF — so the binary has the **full SQLite read-model** with
no Erlang prerequisite on the user's machine (T6.2, [ADR-0014](docs/adr/0014-binary-distribution-burrito-homebrew.md)).
The `kazi` release declares four targets: macOS `aarch64`/`x86_64` and Linux
`aarch64`/`x86_64`.

Building requires [Zig](https://ziglang.org) **0.15.2** (Burrito's pinned
version) and `xz` on `PATH`; cross-target builds also need `7z` for Windows
(kazi ships no Windows target). Build the host target and run it:

```sh
# Build the binary for the current host platform (set BURRITO_TARGET to one of
# macos_aarch64 / macos_x86_64 / linux_aarch64 / linux_x86_64; omit it to build
# every declared target). Output lands in ./burrito_out/.
BURRITO_TARGET=macos_aarch64 MIX_ENV=prod mix release --overwrite

# The wrapped binary takes the CLI args directly — no `eval`. It reads them via
# Burrito's argv and dispatches through the same Kazi.CLI core:
./burrito_out/kazi_macos_aarch64 --help
./burrito_out/kazi_macos_aarch64 run <goal-file> --workspace <path>
./burrito_out/kazi_macos_aarch64 list-proposed
```

The binary persists its read-model to `$KAZI_DB` if set, otherwise
`~/.kazi/kazi.db` (created on first run; see `config/runtime.exs`). Unlike the
escript, every iteration and proposal is persisted — the NIF is bundled.

> **macOS 26 + Zig note.** Burrito 1.5.0 pins Zig **0.15.2**, which cannot link
> native binaries against the macOS 26 SDK (Xcode 26); Zig 0.16 links it but is
> API-incompatible with Burrito's `build.zig`. On a macOS 26 host the wrap step
> fails at the Zig link; build the macOS binaries on a macOS 15 (or earlier)
> runner — which is what the release CI matrix (T6.3) targets.

---

## Quickstart 1 — describe a goal in plain English

You don't have to write a goal-file by hand. Tell kazi the outcome you want and it
drafts the machine-checkable predicates for you (using your coding agent), then
holds them for your review — **nothing runs until you approve**:

```sh
# 1. Describe "done" in natural language. kazi proposes acceptance predicates:
kazi propose "the /health endpoint should return 200 with the body ok" \
  --workspace ./my-service
#
#   PROPOSED  proposal=prop-health-endpoint-3f9c1a2b  goal=health-endpoint
#     • go test ./... passes
#     • GET /health returns 200 with body "ok"

# 2. Review what it drafted (you're the approver — agents propose, humans dispose):
kazi list-proposed
#   prop-health-endpoint-3f9c1a2b   proposed   health-endpoint   (2 predicates)

# 3. Approve the goal you want kazi to pursue:
kazi approve prop-health-endpoint-3f9c1a2b
#   APPROVED   proposal=prop-health-endpoint-3f9c1a2b  goal=health-endpoint
#   The goal is now runnable: kazi run <goal-file> --workspace <path>
```

`propose` / `approve` are the natural-language **front door** (an agent drafts,
a human approves — the only write path the dashboard and Telegram bridge share too).
Approving blesses the goal; to drive it, hand `kazi run` a goal-file (next section) —
the same predicates, captured as a file you can version and re-run.

> More natural-language ideas kazi can draft predicates for:
> - `kazi propose "the login form must reject an empty password with a 422"`
> - `kazi propose "add a /metrics endpoint and keep test coverage from dropping"`
> - `kazi propose "the checkout API p95 latency should be under 300ms"`

---

## Quickstart 2 — write a tiny goal-file and ship it

A goal-file is a few lines of TOML. Here's one that says *"the unit tests pass AND
the deployed `/livez` endpoint returns `ok`"* — code **and** live production, in one
declaration:

```toml
# my-goal.toml
id = "health-green-and-live"
name = "health endpoint returns ok, tests green and live"

[budget]
max_iterations = 8        # hard ceilings — kazi can never loop forever
max_tokens = 500000

[scope]
workspace = "."           # the repo kazi may edit
paths = ["main.go"]

# A CODE check: the project's tests must pass.
[[predicate]]
id = "tests"
provider = "test_runner"
description = "unit tests pass"
cmd = "go"
args = ["test", "./..."]

# A LIVE check: the *deployed* service must answer correctly. This is what makes
# convergence real — green-on-my-laptop is not enough.
[[predicate]]
id = "livez-live"
provider = "http_probe"
description = "deployed GET /livez returns 200 body \"ok\""
url = "https://your-service.run.app/livez"
expect_status = 200
expect_body = "ok"
body_match = "exact"      # exact, not substring — "ok" is a substring of "not-ok"!
```

Run it:

```sh
mix kazi.run my-goal.toml --workspace ./my-service
```

kazi prints each iteration and a final verdict, and exits `0` only on convergence:

```
kazi.loop goal=health-green-and-live iter=1 failing=["tests","livez-live"]   → dispatch agent
kazi.loop goal=health-green-and-live iter=2 failing=["livez-live"]           → integrate (PR #42)
kazi.loop goal=health-green-and-live iter=3 failing=["livez-live"]           → deploy
kazi.loop goal=health-green-and-live iter=4 failing=[]                       → CONVERGED ✓
OUTCOME: :converged   (tests pass · live /livez = "ok")
```

**Predicate providers** you can use today:

| `provider`     | checks… | key config |
|----------------|---------|------------|
| `test_runner`  | a command's exit code (unit/integration tests) | `cmd`, `args` |
| `http_probe`   | a live URL's status + body | `url`, `expect_status`, `expect_body`, `body_match` |
| `browser`      | a real browser flow (Playwright) | per-flow config |
| `prod_log`     | a production-log condition (e.g. 5xx rate) | per-check config |

Add `guard = true` to a predicate to make it an **invariant** (e.g. "coverage must
not drop") — kazi blocks the "delete the failing test" shortcut.

---

## A real worked example: failing test → live production

This is kazi's own end-to-end proof (the **T0.12 dogfood**), and you can read it in
[`docs/devlog.md`](docs/devlog.md). The fixture in
[`fixtures/deploy-target/`](fixtures/deploy-target/) is a tiny Go web service whose
`/livez` endpoint returns `"not-ok"` and whose unit test therefore **fails on
purpose**. Given the goal *"tests pass AND deployed `/livez` returns ok"*, kazi:

1. **Observed** both checks failing — and refused to call it done.
2. **Dispatched** a `claude -p` agent, which made the one-line fix.
3. **Integrated** it — opened a PR and rebase-merged it to `main`.
4. **Deployed** the new build to Cloud Run.
5. **Re-checked** the live endpoint → `200 "ok"` → **converged**.

Crucially, through steps 1–4 the live check kept failing and kazi **stayed
non-converged** — it only reported success once the real, deployed endpoint was
correct. That's the whole point: done is observed, not asserted.

> Live deploys need a deploy target configured (the service / project / region and a
> deploy command). The fixture's setup — GCP roles, the Cloud Run quirks kazi
> discovered, and the goal-file — is documented in
> [`fixtures/deploy-target/README.md`](fixtures/deploy-target/README.md) and
> [`docs/lore.md`](docs/lore.md).

---

## Watch it work (and steer from your phone)

- **LiveView dashboard** — a goal board, live agent presence, the lease map, and
  per-goal convergence history. Read-only inspection, decoupled from the loop
  ([ADR-0011](docs/adr/0011-slice3-operator-surfaces.md)).
- **Telegram bridge** — declare a goal from your phone and get pinged on
  `converged` / `stuck` / `over-budget`. The human sets *direction*, not keystrokes.

---

## CLI reference

```
kazi propose "<idea>" [--workspace <path>]   # draft predicates from plain English
kazi list-proposed [--status <state>]        # review drafts (proposed/approved/rejected)
kazi approve <proposal-ref>                  # bless a drafted goal
kazi reject  <proposal-ref>                  # discard a draft
kazi run <goal-file> --workspace <path>      # drive a goal to convergence
        [--env <name>]                       #   target a deploy environment (staging/prod)
        [--standing]                         #   run continuously (re-converge on drift)
kazi --help
```

`kazi run` exits `0` on convergence, non-zero otherwise — so it composes in CI/scripts.

> **Read-model note.** The Mix task (`mix kazi.run`) creates and migrates the SQLite
> read-model on startup, so every iteration is persisted. The standalone escript
> can't bundle the native SQLite NIF, so it runs without persistence (it still
> converges; it just won't record history).

---

## How it works (under the hood)

- **Positioning** — a harness-agnostic outer loop, never a harness ([ADR-0001](docs/adr/0001-positioning-outer-loop-reconciler.md)).
- **Goals** — machine-checkable predicate sets, evidence-backed ([ADR-0002](docs/adr/0002-goals-as-predicates.md)).
- **Runtime** — Elixir / OTP + Phoenix LiveView ([ADR-0003](docs/adr/0003-language-elixir-otp.md)); one supervised process per active goal.
- **Coordination** — NATS JetStream KV leases (revision-CAS + TTL) and graph-aware blast-radius partitioning ([ADR-0004](docs/adr/0004-coordination-substrate-nats-jetstream.md), [ADR-0006](docs/adr/0006-coordination-leases-and-graph-partitioning.md)).
- **Data split** — Git (code) · JetStream (coordination) · ETS (live state) · SQLite (read-model) ([ADR-0005](docs/adr/0005-data-layer-split.md)).
- **Harness & context** — stateless per iteration; kazi owns context as a thin, deterministic evidence projection plus a blast-radius orientation pack — never conversation memory ([ADR-0008](docs/adr/0008-harness-invocation-and-context.md), [ADR-0009](docs/adr/0009-prompt-construction-thin-evidence-projection.md), [ADR-0010](docs/adr/0010-context-injection-reexploration-mitigation.md)).

Full narrative: [`docs/concept.md`](docs/concept.md). Decisions: [`docs/adr/`](docs/adr/).
Build plan: [`docs/plan.md`](docs/plan.md).

---

## Status

Slices 0–3 are implemented and green (Elixir/OTP; ~700 hermetic ExUnit tests), and
the live idea → production loop is proven end-to-end (the T0.12 dogfood above). What
works today:

- **Convergence core** — the reconcile loop drives predicates to truth via a
  stateless agent harness plus integrate (branch → PR → rebase-merge) and deploy
  actions; evidence persisted to SQLite.
- **Trustworthy loops** — regression detection, flake quarantine, hard budgets,
  stuck-escalation, and a production-log predicate.
- **Creation mode** — kazi builds *new* features from failing acceptance predicates,
  not only repairs. From here on, kazi builds kazi.
- **Coordination & surfaces** — NATS leases + presence, graph partitioning,
  natural-language authoring, a LiveView dashboard, and a Telegram bridge.
- **Context injection** — every stateless iteration starts *oriented* (a
  deterministic blast-radius pack + an optional, off-by-default retrieval adapter),
  without reintroducing conversation memory.

**By design, kazi will never**: become a coding agent/harness; decide *what* to
build (that's your judgment); or put a vector DB in the core loop (the retrieval
adapter is an optional augmentation, never the foundation).

## License

MIT.
