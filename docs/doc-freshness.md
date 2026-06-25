# Doc-freshness predicate set (T31.4, ADR-0036)

kazi's docs are part of its public surface, and a public surface drifts. ADR-0036
makes "the docs are fresh" a machine-checkable property: a set of runnable
predicates, each returning pass/fail WITH the offending location, so doc drift is
caught the same way a failing test is.

This is the DEFINITION layer (T31.4): the predicates exist and run. Wiring them
into CI as a gate (warn first, then ratchet to blocking -- the E29 pattern) is a
SEPARATE task, T31.5. Nothing here fails a build yet.

The scripts live alongside the E29 OSS-gate guards under `.github/scripts/`, in
`.github/scripts/doc_freshness/`, and follow the same house style: bash,
`set -euo pipefail`, clear `PASS`/`FAIL` lines with locations, runnable locally.

## Run them

```sh
# from the repo root
.github/scripts/doc_freshness/doc_freshness.sh          # run the whole set, print a report
```

Each predicate is also runnable on its own:

```sh
.github/scripts/doc_freshness/check_a_commands_in_readme.sh
.github/scripts/doc_freshness/check_b_no_dead_command_refs.sh
.github/scripts/doc_freshness/check_c_adr_refs_exist.sh
.github/scripts/doc_freshness/check_d_plan_trimmed.sh
```

The runner exits 0 only if every predicate it runs passes; any failure exits 1.
Predicate (d) is EXPECTED to fail today (see below).

Useful env knobs:

- `RELEASE_REF=<tag>` -- override the release cutoff predicate (d) compares against
  (default: the newest `v*` tag).
- `SKIP_SUBSUMED=1` -- have the runner print the reference for the subsumed
  coherence checks (E)/(F) instead of invoking them.

## The command surface: where the list comes from

Predicates (a) and (b) need the authoritative list of shipped CLI commands. They
read the `@commands` table in `lib/kazi/cli.ex` directly (via `awk` in
`lib.sh:df_commands`). That table is the SOURCE OF TRUTH from which
`kazi help --json` is generated, so parsing it needs no built binary and no
Elixir runtime -- the checks run in a bare CI shell. If a `kazi` binary is on
PATH, a maintainer can cross-check with `kazi help --json | jq -r '.commands[].name'`;
the help-json ExUnit test already pins the two to agree.

The shipped commands today: `apply`, `approve`, `export`, `help`, `init`,
`install-skill`, `lint`, `list-proposed`, `plan`, `reject`, `schema`, `status`,
`version`.

## The predicates

### (a) Every shipped CLI command appears in README.md

`check_a_commands_in_readme.sh`. For each command in the `@commands` table, the
README must contain the literal token `kazi <command>`. A shipped command with no
mention is a FAIL, reported with the command name and the expected file.

Asserts: a newly-shipped command cannot be invisible in the README.

### (b) No live doc references a command absent from the code

`check_b_no_dead_command_refs.sh`. Scans README + the live user-facing guides
under `docs/` (NOT the archival tiers -- see scope below) for two failure classes:

1. A known-removed verb token: `kazi run`, `kazi propose`, `mix kazi.run`
   (removed in v1.0.0, ADR-0032; recorded in `docs/deprecations.md`). Matched on
   a word boundary, so prose like "kazi runs the loop" does NOT trip.
2. A backtick-quoted `` `kazi <cmd>` `` whose `<cmd>` is not in the `@commands`
   table. Catches forward drift such as `kazi mcp` or `kazi adopt` (conceptual
   names that are not shipped commands).

Each offender is reported with `file:line`.

**Scope -- why the archival tiers are excluded.** Predicate (b) deliberately does
NOT scan the history/record tiers, because they legitimately name removed verbs:

- `docs/adr/**` -- frozen decision records (an ADR names the verbs that existed
  when it was written; CLAUDE.md says do not relitigate them).
- `docs/deprecations.md` -- the removal log; its JOB is to name `kazi run` etc.
- `docs/devlog.md` -- append-only session history.
- `docs/plan.md` -- the WBS; records past task wording.
- `docs/lore.md` -- append-only invariants/landmines.

Asserts: the docs that describe the CURRENT surface never name a command the CLI
no longer ships (or never shipped).

### (c) Every ADR referenced by a doc exists

`check_c_adr_refs_exist.sh`. Scans README + all of `docs/` (including
`docs/adr/**` -- a cross-reference between ADRs must also resolve) for ADR
references in any form -- `ADR-0027`, `ADR 0027`, `docs/adr/0027-...` -- and
requires a matching `docs/adr/<NNNN>-*.md` file for each. A dangling reference
(e.g. `ADR-9999`) is a FAIL with the first `file:line` that cited it.

Asserts: no doc points at an ADR number that does not exist.

### (d) No done+released task lingers in the live plan

`check_d_plan_trimmed.sh`. For every `- [x]` task in `docs/plan.md`, if its
`Done: YYYY-MM-DD` date is on or before the last release tag's date, it is stale
residue that the ADR-0036 Layer-1 trim (T31.2) should have archived. Such tasks
are reported with `docs/plan.md:<line>` and the task id. A `[x]` task with NO
`Done:` date is reported as a distinct hygiene offender (it cannot prove it
post-dates the release).

The cutoff is the newest `v*` tag's commit date (override with `RELEASE_REF`).

**This predicate is EXPECTED to FAIL today.** The trim tool (T31.2) has not run,
so done+released work still sits in the live plan. That is the point: the check
enumerates exactly the offenders a future trim will clear. It is not a regression.

Asserts: once T31.2 runs, the live plan holds only open/unreleased work.

## Subsumed coherence checks (referenced, not reimplemented)

Two drift guards already exist and are FOLDED IN by reference -- the runner
invokes them when their toolchain is present and otherwise prints how to run
them. They are NOT copied into the freshness scripts.

### (E) README <-> website canonical-string coherence (T9.9, ADR-0018)

`site/scripts/check-coherence.mjs`. Asserts the canonical strings the marketing
site renders (`site/src/canonical.mjs`) appear verbatim in `README.md`, so the
two surfaces cannot silently diverge.

```sh
npm --prefix site run check:coherence      # or: node site/scripts/check-coherence.mjs
```

### (F) skill / AGENTS.md <-> CLI command-flag coherence (T16.4, ADR-0024)

`test/kazi/teach_coherence_test.exs`. Asserts the rendered Claude Code skill and
the root `AGENTS.md` reference only commands/flags that `kazi help --json`
reports -- the drift guard for kazi's self-teaching surface.

```sh
mix test test/kazi/teach_coherence_test.exs
```

The runner reports (F) as `SKIP` when project deps are not fetched (it must not
report a false FAIL when `mix` errors on missing deps rather than on coherence).

## Predicate -> check map

| Predicate | What it asserts | Script / reference |
|-----------|-----------------|--------------------|
| (a) | every shipped CLI command is in the README | `check_a_commands_in_readme.sh` |
| (b) | no live doc names a removed/unknown command | `check_b_no_dead_command_refs.sh` |
| (c) | every ADR a doc cites exists | `check_c_adr_refs_exist.sh` |
| (d) | no done+released task lingers in the plan | `check_d_plan_trimmed.sh` |
| (E) | README <-> website canonical strings (T9.9) | `site/scripts/check-coherence.mjs` (subsumed) |
| (F) | skill / AGENTS.md <-> CLI (T16.4) | `test/kazi/teach_coherence_test.exs` (subsumed) |

## CI enforcement (T31.5): phase-1 WARN

This file and these scripts are the DEFINITION. The CI gate is the `doc-freshness`
job in the OSS-gates workflow (`.github/workflows/oss-gates.yml`), alongside the
E29 docs-with-code and no-internal-leak gates. It runs on every pull request.

The job checks out the full history and tags (predicate (d) needs the newest
`v*` tag's date) and runs the runner:

```sh
.github/scripts/doc_freshness/doc_freshness.sh
```

It runs with `SKIP_SUBSUMED=1`, so the (E)/(F) coherence checks (T9.9/T16.4) are
referenced, not invoked: this lightweight gate does not fetch the node site deps
or the mix deps those checks need, and the runner must not report a false FAIL
from a missing toolchain. Those two checks keep their own coverage in `ci.yml` /
`site-smoke.yml`.

### Phase 1: WARN only (current)

Like the E29 gates, the freshness gate starts warn-first. The runner exits 1
while the known offenders stand, so a raw run would red every PR. The job wraps
it: a `FRESHNESS_BLOCKING` env (default `"0"`) converts the runner's nonzero exit
into a GitHub `::warning` plus an `exit 0`. The report and the offender list are
printed in full, but the build stays green.

The offenders the gate reports on `main` today, and who fixes them (NOT T31.5):

- **(a) commands missing from README** -- e.g. `kazi export`, `kazi status`,
  `kazi schema`, `kazi version`, `kazi help`, `kazi lint`, `kazi install-skill`.
  Fixed by the README command-coverage work (**T22.x / T28.3**).
- **(b) dead/unknown command references** -- `kazi mcp` and `kazi adopt` named in
  `docs/concept.md` and `docs/orchestrator-recipe.md` (conceptual names, not
  shipped commands). Fixed by the docs drift cleanup (**T28.3**).
- **(d) untrimmed plan** -- done+released `- [x]` tasks still sitting in
  `docs/plan.md`. Cleared by the ADR-0036 Layer-1 plan trim (**T31.2**).

Predicate (c) passes today.

### Ratchet to blocking

Once T22.x / T28.3 fix the README + drift offenders and T31.2 trims the plan, the
runner will exit 0 and the gate can become blocking. Flip a single toggle:

- In CI: set `FRESHNESS_BLOCKING: "1"` on the `doc-freshness` job in
  `.github/workflows/oss-gates.yml`. A failing predicate set then fails the job.
- Locally, the runner already exits nonzero on any failure, so no toggle is
  needed to see the blocking signal -- just run it.

This is the same warn -> block ratchet the E29 gates use (`docs/oss-gates.md`).
