# OSS contribution gates

kazi is a public, Apache-2.0 repository. Six CI gates keep the public surface
honest and free of internal-only detail. Gates 1-2 are defined in ADR-0034 (E29);
Gate 3 is defined in ADR-0036 (E31); Gates 4-5 are defined in ADR-0034 (E29; T29.4
and T28.4); Gate 6 is defined in ADR-0035 (T30.5).

- Gate 1 -- docs land with the code (T29.1)
- Gate 2 -- no internal-info leak (T29.2)
- Gate 3 -- docs are fresh (T31.5)
- Gate 4 -- site command accuracy (T29.4)
- Gate 5 -- doc command accuracy (T28.4)
- Gate 6 -- tiering accuracy + coherence (T30.5)

Each gate runs in CI (the `OSS gates` workflow, `.github/workflows/oss-gates.yml`)
on every pull request. Gates 1-3 are small shell scripts under `.github/scripts/`;
Gates 4-6 are Node scanners (Gate 4 under `site/scripts/`, Gates 5-6 under
`.github/scripts/`). The same scripts run locally so you can check a change before
you push.

## Running the guards locally

Both scripts read a base ref from the `BASE_REF` env var (default `origin/main`)
and diff your branch against it.

```sh
# from the repo root, on your feature branch
git fetch origin main

.github/scripts/docs_with_code_guard.sh
.github/scripts/no_internal_leak_guard.sh
```

To point at a different base branch:

```sh
BASE_REF=origin/develop .github/scripts/no_internal_leak_guard.sh
```

## Gate 1 -- docs land with the code (T29.1)

Script: `.github/scripts/docs_with_code_guard.sh`

If a PR changes a user-facing or behavioral surface in `lib/` but does NOT also
change docs, the guard reports a violation.

A "user-facing surface" is a change to one of:

- `lib/kazi/cli.ex` or `lib/kazi/cli/` (a command or flag)
- `lib/kazi/providers/` or `lib/kazi/predicate_provider.ex` (a predicate provider)
- `lib/kazi/harness_adapter.ex` (the harness contract)
- `lib/kazi/mcp/` (the MCP surface)

A "docs change" is any change under `docs/`, or to `README.md` or `AGENTS.md`
(the `kazi help` text lives in `lib/kazi/cli.ex`, so updating help inline counts
as a code change that still needs a user-facing doc note).

### Escape hatch: `[no-docs]`

A genuinely doc-free change (a trivial internal refactor with no surface change
that still happens to touch a guarded path) passes by carrying the literal marker
`[no-docs]` in either:

- the PR title, or
- any commit message on the branch.

Use this only when a doc update truly is not warranted, and say why in the same
message. Example commit subject:

```
refactor(cli): extract arg parser, no behavior change [no-docs]
```

### Phase 1: strict-but-warn

The guard currently runs in WARN mode: it prints the violation but exits 0, so
the CI step is green (non-blocking). This lets the team see the signal without
blocking merges while the docs backlog (E28) is still being worked down.

### Ratchet to blocking

Flip a single toggle to make the gate blocking once the team is ready:

- In CI: set `BLOCKING: "1"` on the `docs-with-code` job in
  `.github/workflows/oss-gates.yml`.
- Locally / for the script default: set `DEFAULT_BLOCKING=1` at the top of
  `docs_with_code_guard.sh`, or run with `BLOCKING=1 ...`.

In blocking mode a violation exits 1 and fails the job.

## Gate 2 -- no internal-info leak (T29.2)

Script: `.github/scripts/no_internal_leak_guard.sh`

The guard scans for internal-only markers and FAILS the job on a real hit. This
gate is blocking.

### Marker patterns (a hit fails the build)

- Private IPv4 addresses (RFC-1918):
  - `192.168.x.x`
  - `10.x.x.x`
  - `172.16.x.x` through `172.31.x.x`
- Absolute home paths: `/Users/<name>/...` and `/home/<name>/...` where `<name>`
  is a real username token.
- Internal infrastructure, tool, or codenames. The list lives in `INTERNAL_NAMES`
  at the top of the script and ships EMPTY in this public repo on purpose: adding
  the real internal names here would itself be a leak. They are configured only
  in the operator's private setup.

### Allow-list (these pass)

- RFC-5737 documentation example IPs:
  - `192.0.2.x`
  - `198.51.100.x`
  - `203.0.113.x`
- Loopback / unspecified / well-known local names: `127.0.0.1`, `0.0.0.0`,
  `localhost`.
- Placeholder home paths: an explicit angle-bracket placeholder such as
  `/Users/<name>` or `/home/<user>`, or an all-caps template token such as
  `/Users/USER`. A bare lowercase username like `/Users/someone` is treated as a
  real leak.
- Any single line carrying the inline marker `leak-guard:allow` is exempt. Use
  this sparingly for a legitimate documented example, e.g.

  ```
  # example only, not a real host  leak-guard:allow
  ```

The guard's own script, this doc, and the workflow file are excluded from the
scan so their example markers do not self-trip.

### Diff-scoped by default (and why)

To avoid reddening every PR on leaks a contributor did not introduce, the guard
scans only the DIFF of the PR (added lines) versus the base ref by default.

The full working tree was scrubbed by T29.3 and is verified clean by the
full-tree mode (a single `git grep` pre-filter for the leak patterns, then the
per-line allow-list confirm -- fast enough to run on the whole repo). To also
scan the full tree (catches a leak that already sits in a committed file, not
just new diff additions):

- In CI: set `SCAN_TREE: "1"` on the `no-internal-leak` job in
  `.github/workflows/oss-gates.yml`.
- Locally: run with `SCAN_TREE=1 ...`.

## Gate 3 -- docs are fresh (T31.5)

Runner: `.github/scripts/doc_freshness/doc_freshness.sh`

The self-maintaining doc-freshness predicate set (T31.4, ADR-0036) wired into CI
as the `doc-freshness` job. It asserts the docs have not drifted from the code:
every shipped CLI command is in the README (a), no live doc names a removed or
unknown command (b), every ADR a doc cites exists (c), and no done+released task
lingers in the plan (d). Full predicate detail and local-run instructions are in
`docs/doc-freshness.md`.

### Phase 1: strict-but-warn

Like Gate 1, this gate runs in WARN mode. The runner exits 1 while known
offenders stand (README command coverage, the mcp/adopt command-name drift,
and the untrimmed plan); the job converts that nonzero into a `::warning` and
exits 0 via a `FRESHNESS_BLOCKING` env defaulting to `"0"`. The report and the
offender list are printed, but the build stays green so the gate does not red
every PR while the backlog is worked down. Those fixes belong to T22.x / T28.3
(README + drift) and T31.2 (plan trim), not to this gate.

The job runs with `SKIP_SUBSUMED=1` so the subsumed coherence checks (T9.9/T16.4)
are referenced, not invoked -- it does not install the node / mix toolchains they
need, and a missing toolchain must not register a false FAIL. Those keep their
own coverage in `ci.yml` / `site-smoke.yml`.

### Ratchet to blocking

Flip a single toggle once the offenders are cleared and the runner exits 0:

- In CI: set `FRESHNESS_BLOCKING: "1"` on the `doc-freshness` job in
  `.github/workflows/oss-gates.yml`.

In blocking mode a failing predicate set fails the job.

## Gate 4 -- site command accuracy (T29.4)

Script: `site/scripts/check-commands.mjs` (run locally with
`npm --prefix site run check:commands`).

The marketing site must never present a REMOVED kazi verb as a live command. A
stale verb on the site hands a new user a command that errors on their very first
try. The guard scans the site source and reports any removed verb used as a
PRIMARY command.

### What it scans

Every `.astro`, `.mjs`, `.md`, and `.svg` file under `site/`, recursively
(skipping `node_modules`, `dist`, `.astro`). `.svg` is included on purpose: an
SVG asset is XML text and a removed verb can hide inside a `<tspan>`, which is
exactly where one shipped live in the original hand-drawn `proof-loop.svg` mockup
(the gap this gate closes). That hero asset is now a **real recorded cast**
rendered to `proof-loop.gif` (T25.2); other hand-authored SVG diagrams remain, so
`.svg` scanning still earns its keep.

### Marker list (a hit is a removed verb used as a primary command)

The verb list is deliberately narrow -- only verbs the current CLI no longer
accepts:

- `kazi run` -- removed at v1.0.0 (T27.9); use `kazi apply`.
- `kazi propose` -- removed at v1.0.0 (T27.9); use `kazi plan`.

A match is `kazi <verb>` for any removed verb (word-boundary anchored).

`kazi approve`, `kazi reject`, and `kazi list-proposed` are STILL live commands
(`lib/kazi/cli.ex`) and are NOT flagged -- flagging them would red every
legitimate doc once this gate ratchets to blocking. The old `propose` -> `approve`
proposal flow is caught at its `kazi propose` entry point, which is the part that
actually no longer exists.

### Allow-list (these pass)

A line that DOCUMENTS the removal is exempt, so a single honest mention passes
while a code block that hands the user the dead verb is flagged. A line is
allow-listed if it contains either:

- the case-insensitive phrase `deprecated alias`, e.g.
  ``` `kazi run` is a deprecated alias, removed in v1.0.0 -- use `kazi apply`. ```
- an explicit inline `verb-drift:allow` marker.

The scanner's own file is excluded from the scan (it names the removed verbs in
its comments) so it cannot self-trip.

### Phase 2: blocking (current)

The site is now CLEAN: the `kazi propose` in `index.astro` step 2 was corrected
(T27.6) and the `proof-loop.svg` mockup that showed `kazi run` was replaced by a
real recorded cast (`proof-loop.gif`, T25.2). With both gone, the gate ratcheted
to BLOCKING (T38.4): the `site-commands` job runs with `BLOCKING: "1"`, so a
removed verb used as a primary command in any scanned `site/` file exits 1 and
reds the PR. It still skips PRs that do not touch `site/`. (It began as
strict-but-warn while the site copy was still being corrected.)

### Ratchet to blocking

Flip a single toggle once the site no longer ships any removed verb:

- In CI: set `BLOCKING: "1"` on the `site-commands` job in
  `.github/workflows/oss-gates.yml`.
- Locally / for the script default: set `DEFAULT_BLOCKING = true` at the top of
  `check-commands.mjs`, or run with `BLOCKING=1 ...`.

In blocking mode a hit exits 1 and fails the job.

### Scoped to site/ PRs

`oss-gates.yml` triggers on every PR (no workflow-level path filter), so the
`site-commands` job first checks whether the PR diff touches `site/` and skips
(exits 0) when it does not -- the scanner only inspects `site/` source. Tests can
point the real scanner at a fixture tree via the `SITE_ROOT` env var without
duplicating the matching logic.

## Gate 5 -- doc command accuracy (T28.4)

Script: `.github/scripts/check-doc-commands.mjs` (run locally with
`node .github/scripts/check-doc-commands.mjs`).

The docs-tree sibling of Gate 4. Where Gate 4 guards the marketing site against a
removed verb, Gate 5 guards the README + `docs/` against ANY kazi command or flag
that does not ship: a doc that hands the reader `kazi frobnicate` or
`kazi apply --frobnicate` sends them a command that errors on their first try.

### How it learns the real CLI surface (no hardcoded list)

The truth source is the `@commands` / `@switches` table in `lib/kazi/cli.ex`.
`kazi help --json` is GENERATED from that table, and an ExUnit test
(`test/kazi/cli_help_schema_test.exs`) pins that the two stay in sync. So the
scanner parses that table -- which is, transitively, the shipped
`kazi help --json` surface -- with no Elixir runtime or built binary needed in
the gate (the same runtime-free choice the doc-freshness predicates document in
`.github/scripts/doc_freshness/lib.sh`). A maintainer with a built binary can
cross-check: `kazi help --json | jq -r '.commands[].name'`.

### What it scans

`README.md` plus every top-level `docs/*.md` (which includes `docs/concept.md`),
EXCEPT the history / archival tiers that legitimately name removed verbs:
`deprecations.md`, `devlog.md`, `plan.md`, `lore.md`, `doc-freshness.md`, and this
gate's own `oss-gates.md`. `docs/adr/**`, `docs/research/**`, and `docs/schemas/**`
are skipped (frozen records and machine schemas, not live command guides).

### Command-context discipline (why prose is safe)

The gate does NOT flag every `kazi <word>`. Prose like "kazi is a reconciler" or
"kazi owns parallelism" is not a command. A `kazi <verb>` is checked only in
COMMAND CONTEXT: the start of a line inside a fenced code block (optionally after
a `$`/`>` prompt), or the start of an inline backtick code span (`` `kazi apply` ``).
A `#`-comment line in a code block has the verb off the command position, so it is
not flagged. Flags are likewise read only off a kazi invocation, at a token
boundary, so a hyphen inside a placeholder (`<goal-file>`) or word ("opt-in") is
never mistaken for a flag.

### Marker list (a hit fails the build)

1. A removed verb used as a primary command: `kazi run`, `kazi propose`,
   `mix kazi.run` (removed at v1.0.0, ADR-0032).
2. A `kazi <verb>` whose verb is NOT in the shipped command table.
3. A `--flag` on a kazi invocation whose flag is NOT in `@switches`.

Each finding is reported with `file:line` and the offending token.

### Allow-list (these pass)

A line that DOCUMENTS a removal or a forward-reference is exempt, so a single
honest mention passes while a code block that hands the reader a dead token is
flagged. A line is allow-listed if it contains either:

- the case-insensitive phrase `deprecated alias`, or
- an explicit inline `verb-drift:allow` marker (an HTML comment
  `<!-- verb-drift:allow: ... -->` works and renders invisibly in Markdown).

The scanner's own file and `oss-gates.md` are excluded from the scan so their
example tokens do not self-trip.

### Blocking (not warn)

Unlike Gates 1, 3, and 4, Gate 5 ships BLOCKING. The docs tree was already clean
when the gate landed (T27.6 + T28.3 cleared the stale verbs; the one remaining
forward-reference -- `kazi plan --from-acc` in `acc-predicates-bridge.md` -- is
allow-listed), so there is no dirty backlog to soften for: a new fake command or
flag should red the PR immediately. The scanner scans the FULL docs tree (not just
the diff). To soften to warn-only locally, set `BLOCKING=0`.

### Scoped to docs/README/cli.ex PRs

`oss-gates.yml` triggers on every PR (no workflow-level path filter), so the
`doc-commands` job first checks whether the PR diff touches `README.md`, `docs/`,
or `lib/kazi/cli.ex` and skips (exits 0) otherwise -- a CLI change is included
because it can orphan a doc reference even when no doc file changed. Tests can
point the real scanner at a fixture tree via `KAZI_DOC_FILES` (a space-separated
file list) and `KAZI_CLI_FILE` without duplicating the matching logic.

## Gate 6 -- tiering accuracy + coherence (T30.5)

Script: `.github/scripts/check-tiering-coherence.mjs` (run locally with
`node .github/scripts/check-tiering-coherence.mjs`).

The in-family Claude tiering surfaces -- the install skill
(`lib/kazi/teach/install_skill.ex`), `AGENTS.md`, `README.md`, and the marketing
site (`site/src/`) -- carry two claims a stale edit can silently break. This gate
guards both, and **composes** the existing command / coherence gates for the rest
(it does not re-implement them).

### What it checks itself (the two new invariants)

1. **Model ids are current.** The tiering ladder names concrete Claude model ids
   (`claude-haiku-4-5` -> `claude-sonnet-5` -> `claude-opus-4-8`). A model
   retires or a release renames an id, and a doc left behind hands the reader an
   id that errors on the first `kazi apply --model ...`. The gate scans the four
   surfaces for any `claude-<...>` model id and fails on one that is NOT in the
   current-generation allow-list (sourced from the claude-api reference: Fable 5,
   Opus 4.8/4.7/4.6, Sonnet 4.6, Haiku 4.5). This catches an invented id AND a
   once-real-now-stale one (`claude-3-5-sonnet`, `claude-sonnet-4-5`,
   `claude-opus-4-1`). A legacy-but-still-served id is intentionally rejected --
   a tiering doc should steer a new reader to a current model. The id regex is
   case-sensitive and shape-specific, so the prose word "Claude" and non-id
   tokens (`claude` the harness, the `claude-api` skill) never trip it.

2. **The cost claim stays hedged.** ADR-0033's cost win is DESIGNED-FOR, NOT YET
   MEASURED -- the headline figure is being measured by the multi-iteration
   benchmark (T19.7). The gate fails if a surface states a cost NUMBER (`$0.0X`,
   `N% cheaper`, `Nx cheaper`) as a measured fact -- i.e. on a line lacking a
   "being measured" / "not yet measured" / "designed-for" hedge. The currency
   pattern requires a decimal, so a shell variable (`$1`, `$GOAL`) in an example
   block is never a false hit.

### What it composes (commands + coherence, reused not rebuilt)

- **Command accuracy** (no unshipped/stale `kazi <verb>`): README + `docs/` are
  covered by Gate 5 (T28.4); the rendered SKILL.md + `AGENTS.md` by the T16.4
  ExUnit coherence test (`test/kazi/teach_coherence_test.exs`); the site by Gate 4
  (T29.4).
- **README <-> site** canonical-string coherence (T9.9,
  `site/scripts/check-coherence.mjs`) and **SKILL/AGENTS <-> CLI** coherence
  (T16.4) run in `ci.yml` / `site-smoke.yml`.

### Blocking, and how it is proven load-bearing

The gate ships BLOCKING: the tiering surfaces are clean at ship (T25.11 / T30.1 /
T30.2 use current ids and keep the cost claim hedged), so a new stale id or
un-hedged cost number reds the PR. The `tiering-coherence` job scans the full set
of surfaces when a PR touches any of them (or `cli.ex`), and **always** runs the
load-bearing tests (`node --test .github/scripts/check-tiering-coherence.test.mjs`)
-- proving the gate FAILS on a planted bad/stale id, an un-hedged cost number, and
(via the composed Gate 5) an unshipped `kazi frobnicate`, and PASSES on the clean
current surfaces. Tests point the scanner at a fixture tree via `TIERING_FILES`
(a space-separated file list); `BLOCKING=0` softens to warn-only.

## Release-stage gate -- MCP-parity smoke (T33.4, ADR-0044)

The gates above run on every PR. One more gate runs at RELEASE time, not on PRs:
a smoke that proves the shipped binary can serve the MCP server path.

Script: `.github/scripts/mcp_release_smoke.sh <path-to-kazi-binary>`

ADR-0044 made `kazi mcp` a real verb on the installed binary, and named a
launch-parity smoke (start via `kazi mcp`, list tools, call `kazi_status`)
sufficient to verify the release ships a working MCP server path. T33.4 wires
that smoke into `.github/workflows/release.yml`: after each Burrito target is
built, the workflow runs the freshly-built INSTALLED binary (NOT `mix`) as an MCP
stdio server, performs the JSON-RPC handshake, asserts `tools/list` advertises
`kazi_status`, and asserts a `kazi_status` tool call answers with a structured
status payload (`isError: false`, a `kind` + `schema_version` result). The binary
boots its bundled SQLite read-model first (the prod path migrates
`<home>/.kazi/kazi.db`), so the smoke also proves the read-model the MCP tools
read is genuinely up in the shipped artifact.

The step runs BEFORE the release assets are uploaded, in both the native-arch
matrix jobs and the arm64 container job, so a non-zero exit BLOCKS the release: a
binary that cannot serve `kazi mcp` never becomes a GitHub Release asset.

Run it locally against a `mix`-run server with the shim pattern (the dev `mix
kazi.mcp` path boots `app.start` WITHOUT migrating, so create + migrate the
read-model first):

```sh
mix ecto.create && mix ecto.migrate
printf '#!/usr/bin/env bash\nexec mix kazi.mcp\n' > /tmp/kazi-shim && chmod +x /tmp/kazi-shim
.github/scripts/mcp_release_smoke.sh /tmp/kazi-shim
```

## Where this is enforced

ADR-0034 enforces both rules at three layers:

1. Instruction -- both rules are in this repo's `CLAUDE.md` and the operator's
   global instructions.
2. The `/apply` wave gate -- a wave blocks if a surface change ships without docs
   or the diff introduces a leak.
3. CI -- the two guards documented here (E29).
