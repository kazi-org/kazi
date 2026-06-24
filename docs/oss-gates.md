# OSS contribution gates

kazi is a public, Apache-2.0 repository. Two CI gates keep the public surface
honest and free of internal-only detail. Both are defined in ADR-0034 and built
in epic E29.

- Gate 1 -- docs land with the code (T29.1)
- Gate 2 -- no internal-info leak (T29.2)

Each gate is a small, self-contained shell script under `.github/scripts/` that
runs in CI (the `OSS gates` workflow, `.github/workflows/oss-gates.yml`) on every
pull request. The same scripts run locally so you can check a change before you
push.

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

## Where this is enforced

ADR-0034 enforces both rules at three layers:

1. Instruction -- both rules are in this repo's `CLAUDE.md` and the operator's
   global instructions.
2. The `/apply` wave gate -- a wave blocks if a surface change ships without docs
   or the diff introduces a leak.
3. CI -- the two guards documented here (E29).
