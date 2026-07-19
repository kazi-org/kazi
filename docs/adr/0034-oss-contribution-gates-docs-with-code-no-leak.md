# ADR 0034: OSS contribution gates -- docs land with code; no internal-info leakage

## Status
Accepted

## Date
2026-06-24

## Context

kazi is a PUBLIC, open-source repository being readied for adoption (the content
rewrite, ADR-0025/0030). Two recurring quality problems threaten that:

1. **Code outruns docs.** Features (commands, flags, providers, the agent-drivable
   surface) have repeatedly shipped while `docs/concept.md` + README lagged ~10 ADRs
   behind (the gap E28 exists to close). When code lands without its docs, the public
   surface lies and the doc backlog compounds.
2. **Internal details leak into public files.** A scan found ~48 hits in `docs/` +
   README of internal-only specifics -- private IPs, an internal GPU host, internal
   tool/codename references, personal absolute paths. In a public repo these are a
   professionalism and (potentially) a security problem, and they make the operator's
   private setup look like the product.

Both are PROCESS problems. The operator asked to ENFORCE two rules, reflected in the
local + global CLAUDE.md and the `/apply` skill.

## Decision

Adopt two contribution gates, enforced at three layers (instruction, `/apply` wave
gate, and CI):

### Gate 1 -- Docs land with the code
A user-facing or behavioral change (a command/flag, CLI/API surface, predicate
provider, config, or public capability) is NOT done until the matching docs are
updated **in the same change** (README / `docs/` / `kazi help` text / the relevant
ADR). A code change with no doc counterpart is unfinished. The only exception is a
trivial internal refactor with no surface change. Under `/apply` this is a wave gate:
a surface-changing task with no doc update either gets the doc or an explicit,
justified `[no-docs]` note in the wave report -- never a silent skip.

### Gate 2 -- No internal-info leakage
No internal-only details in code, comments, docs, commit messages, issues, or PRs:
private IPs/hostnames (e.g. `192.168.*`), internal infrastructure or tool names,
internal company/project codenames, personal usernames or absolute home paths,
customer names, or "how we run it internally" process detail. Genericize ("a local
model", "a deploy target") or omit. Honest engineering findings + benchmarks are fine
once scrubbed of internal specifics.

### Enforcement (three layers)
1. **Instruction:** both rules in the local `CLAUDE.md` (this repo) and the operator's
   global `CLAUDE.md`.
2. **`/apply` wave gate:** the apply skill's verification gate adds a docs-land check
   and a no-leak diff scan; a wave blocks if either fails.
3. **CI guards (E29):** (a) a docs-with-code check -- a PR touching `lib/` surface
   without a `docs/`/README change fails unless labelled/justified; (b) a no-leak
   scan -- the diff (and the tree) is grepped for the internal-marker patterns and
   fails on a hit. Plus a one-time scrub of the existing ~48 leaks.

## Consequences

- The public docs stay honest and current; the doc backlog (E28) cannot silently
  re-accumulate.
- The public repo stops exposing internal infra/process; the operator's private
  setup is no longer mistaken for the product.
- A real, automatable definition of "leak" and "surface change" is needed -- the CI
  guards (E29) must be tuned to avoid false positives (e.g. a legitimate mention of a
  public IP in a test fixture) and false negatives; start strict-but-warn, then
  ratchet to blocking.
- Slightly more friction per change (a doc edit + a scan). This is the intended cost:
  it is the discipline a public, adoption-targeted repo requires.
- Honest-findings exception keeps the devlog/benchmarks useful (e.g. "a local model
  was too slow" stays; the specific host/IP goes).

## Alternatives rejected

- **Rely on reviewer diligence alone.** Already failed twice (the doc lag + the 48
  leaks). Needs an automatable gate, not just good intentions.
- **Block ALL code without docs, no exception.** Too blunt -- trivial internal
  refactors don't need docs; the `[no-docs]` justified-note escape valve keeps it
  practical.
- **Scrub leaks once, no ongoing guard.** They would re-accumulate; the CI scan is
  what makes it stick.
- **Make these global-only (CLAUDE.md) with no CI.** Instructions drift and are not
  enforced on a contributor who never reads them; CI is the load-bearing layer.
