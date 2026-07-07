# Quickstart — drive kazi from Claude Code

This is the fastest path from zero to a goal kazi has driven to **objective**
done. You will wire kazi into Claude Code once, then converge one real goal
end-to-end — without operating kazi by hand.

The core idea: **you don't run kazi, your coding agent does.** You chat with
Claude Code in plain language; Claude Code drives kazi as a tool, kazi drives a
coding harness in a loop until your goal's predicates are objectively true (or it
stops and tells you why). kazi holds the bar still; the agent reaches for it.

> New to the concept? Read [concept.md](concept.md) for the why. This page is the
> tutorial; the [reference pages](#where-to-go-next) follow.

---

## Prerequisites

- **kazi installed.** The fastest path is a single self-contained binary:

  ```sh
  brew install kazi-org/tap/kazi
  kazi version
  ```

  (Building from source — `mix deps.get && mix escript.build` — is documented in
  the [README](../README.md#install).)
- **A coding harness on your `PATH`.** kazi *drives* a coding agent; it does not
  bundle one. `claude` (Claude Code) is the default harness. `opencode`, `codex`,
  and others are supported per-run with `--harness` (see
  [add-a-harness.md](add-a-harness.md)).
- **`git`** in your target repo (kazi commits and opens PRs there).

---

## Step 1 — wire kazi into Claude Code

Teach Claude Code the kazi skill once. This is opt-in and consent-first — a normal
kazi session never writes to your `~/.claude` directory:

```sh
kazi install-skill            # writes the skill to ~/.claude/skills/kazi
kazi install-skill --dir <path>   # or target a custom skill directory
```

That writes a skill describing the kazi recipe (the same recipe in
[orchestrator-recipe.md](orchestrator-recipe.md)) so Claude Code knows how to
author predicates, approve them, and run the convergence loop on your behalf.

> kazi also ships an MCP server: `kazi mcp` starts it over stdio (ADR-0044), the
> same server `mix kazi.mcp` runs in a source checkout. Point an MCP client at it
> with `{ "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } }` to
> drive the plan → approve → apply loop through self-describing tools. The skill
> (`kazi install-skill`) remains the prose-free on-ramp for Claude Code.

---

## Step 2 — hand Claude Code the goal

In your normal Claude Code session, describe what you want and add the canonical
invocation phrase:

> **have kazi drive this until done**

That phrase is the trigger on the kazi skill (the same way `use context7` pulls
Context7 into a session). Claude Code recognizes it and:

1. authors the **acceptance predicates** that define "done" (`kazi plan`),
2. **approves** them once they look right (`kazi approve`),
3. runs `kazi apply` until every predicate is *objectively* true — or kazi stops
   at `stuck` / `over-budget` and reports back.

You set the bar in plain English; kazi enforces it. The phrase only routes to
kazi once the skill from Step 1 is installed.

---

## Step 3 — what kazi does under the hood (and how to run it yourself)

You can drive the exact same loop directly at the CLI. This is what Claude Code
is doing for you.

### A goal is a small declarative file

A **goal-file** is a list of checkable **predicates** plus a budget and scope.
Here is a minimal one (`my-goal.toml`) that converges when the project's tests
pass *and* a deployed endpoint answers:

```toml
id = "ship-healthz"
name = "ship a /healthz endpoint and prove it live"

[budget]
max_iterations = 15        # a hard ceiling so the loop can never run forever
max_tokens = 750000

[scope]
paths = ["lib/", "test/"]  # the blast radius agents may touch

# the test suite must pass (test_runner provider)
[[predicate]]
id = "tests-pass"
provider = "test_runner"
description = "project test suite passes"
cmd = "go"
args = ["test", "./..."]

# the DEPLOYED endpoint must answer (http_probe provider) — green-on-my-machine
# is never enough; this is the predicate that proves the change is really live
[[predicate]]
id = "healthz-live"
provider = "http_probe"
description = "GET /healthz returns 200 in the deployed service"
path = "/healthz"
expect_status = 200
```

The goal's acceptance is the **conjunction** of all predicates — there is no
"the agent thinks it's done." Ready-made examples live in
[`priv/examples/`](../priv/examples/) (`create_feature.toml`,
`deploy_target.toml`, `browser_acceptance.toml`, …). See
[concept.md §5](concept.md#5-the-goal-contract-adr-0002) for the full goal
contract and the [`[budget]`](../lib/kazi/goal/loader.ex) keys
(`max_iterations`, `max_wall_clock_ms`, `max_tokens`, `max_dispatches` — a
ceiling on `:dispatch_agent` actions only, so a run stuck polling a
persistently-erroring live predicate can't trip it by spinning cheap observe
ticks (T48.6, ADR-0058) — and `cached_read_weight`, the discount cached-read
input tokens get against the `max_tokens` ceiling so a cache-hit-heavy run is
not falsely flagged `over_budget`; defaults to a low flat weight, ADR-0046).

#### Held-out acceptance predicates (anti-gaming)

A `[[predicate]]` may set `held_out = true`:

```toml
# the acceptance test the agent must satisfy but never sees
[[predicate]]
id = "gold-acceptance"
provider = "test_runner"
held_out = true        # evaluated + required for convergence, but hidden from the agent
cmd = "mix"
args = ["test", "test/gold_acceptance_test.exs"]
```

A held-out predicate is still evaluated by the controller and still required to
pass before kazi reports `:converged` — but its id, definition, and evidence are
**withheld from the agent's dispatch context**. This is the
*visible-for-iteration vs hidden-for-acceptance* split (Codeforces pretests vs
system tests; SWE-bench withholds the gold tests): a capable agent can game only
what it can see, so withholding the acceptance subset keeps the bar honest. The
visible predicates still seed the agent's fix context. See
[ADR-0042 §6](adr/0042-anti-gaming-enforcement.md) for the rationale.

### Converge it

```sh
kazi apply my-goal.toml --workspace <path-to-your-project>
```

kazi loops: **observe** every predicate → the failing ones *are* the work-list →
**dispatch** the harness to fix them → **integrate** → **re-check**. Add `--json`
for one machine-readable terminal result, or `--json --stream` for a per-iteration
progress stream (the schema is in
[docs/schemas/run-result.md](schemas/run-result.md)).

Run a cheaper inner harness with `--harness` / `--model` — the two-tier split
(strong model authors predicates, cheap model grinds):

```sh
kazi apply my-goal.toml --workspace <path> --harness opencode --model local/qwen3.6
```

### Author predicates from a prose idea (instead of writing the file)

If you would rather not hand-author the TOML, `kazi plan` drafts the predicates
for you, then you review and approve:

```sh
kazi plan "a /healthz endpoint that returns 200" --yes   # drafts a reviewable proposal
kazi list-proposed                                        # browse the queue
kazi approve <proposal-ref>                               # proposed → approved
```

`approve` makes the goal runnable by `kazi apply`. The full `--json`
propose → approve → apply flow an agent uses is documented in
[orchestrator-recipe.md](orchestrator-recipe.md).

### Watch where it stands

```sh
kazi status <goal-id>        # a pure read of the latest predicate vector
```

---

## Step 4 — how it ends

kazi stops in exactly one of three terminal states, and tells you which:

| Terminal state | What it means | What to do |
|---|---|---|
| **converged** | every predicate is objectively true | done — ship / report |
| **stuck** | the same predicates failed N iterations in a row | inspect the failing vector; the loop escalated to you |
| **over-budget** | the iteration / token / wall-clock ceiling was hit | raise the budget and re-run, or rethink the goal |

The exit code mirrors this: `0` only on `converged`, non-zero otherwise — so kazi
composes in scripts and CI. There is no "done because it felt finished."

---

## Where to go next

The reference and guides, in roughly the order you'll want them:

- **[Concept & architecture](concept.md)** — what kazi is, the goal contract, the
  convergence loop, coordination model.
- **[Orchestrator recipe](orchestrator-recipe.md)** — the full `--json`
  propose → approve → converge flow an agent drives (the source of truth the
  installed skill teaches).
- **[`--json` result schemas](schemas/run-result.md)** — the versioned terminal
  result, [`status`](schemas/status.md), and the
  [collective result](schemas/collective-result.md). Pin `schema_version`.
- **[Add a harness](add-a-harness.md)** — drive `opencode`, `codex`, or your own
  CLI coding agent; the tier table.
- **[Deprecations](deprecations.md)** — removed verbs and the removal schedule
  (the old `run` / `propose` aliases are now `kazi apply` / `kazi plan`).
- **[All docs →](README.md)** — the full index.
