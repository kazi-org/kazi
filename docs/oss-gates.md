# OSS contribution gates

kazi is a public, Apache-2.0 repository. Four CI gates keep the public surface
honest and free of internal-only detail. Gates 1-2 are defined in ADR-0034 (E29);
Gate 3 is defined in ADR-0036 (E31); Gate 4 is defined in ADR-0034 (E29, T29.4).

- Gate 1 -- docs land with the code (T29.1)
- Gate 2 -- no internal-info leak (T29.2)
- Gate 3 -- docs are fresh (T31.5)
- Gate 4 -- site command accuracy (T29.4)

Each gate runs in CI (the `OSS gates` workflow, `.github/workflows/oss-gates.yml`)
on every pull request. Gates 1-3 are small shell scripts under `.github/scripts/`;
Gate 4 is a Node scanner under `site/scripts/`. The same scripts run locally so you
can check a change before you push.

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
(skipping `node_modules`, `dist`, `.astro`). `.svg` is included on purpose: the
`proof-loop.svg` asset is XML text and a removed verb can hide inside a `<tspan>`,
which is exactly where one shipped live (the original gap this gate closes).

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

### Phase 1: strict-but-warn

The site is CURRENTLY DIRTY: `proof-loop.svg` shows `kazi run` and
`site/src/pages/index.astro` step 2 shows `kazi propose`. So the guard runs in
WARN mode -- it prints every offending `file:line` and a fix hint, but exits 0
(non-blocking). This surfaces the signal without reddening every PR while the site
copy is still being corrected (that cleanup is T27.6 + T25.2, not this gate).

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

## Where this is enforced

ADR-0034 enforces both rules at three layers:

1. Instruction -- both rules are in this repo's `CLAUDE.md` and the operator's
   global instructions.
2. The `/apply` wave gate -- a wave blocks if a surface change ships without docs
   or the diff introduces a leak.
3. CI -- the two guards documented here (E29).
