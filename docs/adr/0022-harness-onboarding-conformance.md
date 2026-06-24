# ADR 0022: Onboarding any CLI coding harness -- the profile conformance contract

## Status
Accepted

## Date
2026-06-23

## Context

ADR-0016 made the harness layer config-driven: a `Kazi.Harness.Profile`
(`{id, command, build_args, parse, supported_opts, env}`) + a `CliAdapter` +
`Registry`, so a new CLI harness is DATA, not a new module. The built-ins are
`:claude` and `:opencode`. The operator wants Codex CLI, Google Antigravity CLI
(`agy`), claw-code, "and any other major coding tool/harness."

Researching their CLI contracts (`docs/devlog.md` 2026-06-23) showed they are NOT
uniform, and one criterion is load-bearing for kazi specifically: **kazi drives a
harness as a NON-INTERACTIVE SUBPROCESS (no TTY) and parses its stdout.** A harness
is first-class only if it (a) runs non-interactively from a single prompt, (b)
emits machine-parseable output (JSON/JSONL preferred) to stdout, and (c) does so
correctly under a non-TTY subprocess. Findings:

- **Codex** -- `codex exec "<prompt>" --json [--model <m>]` -> a clean JSONL event
  stream (`turn.completed` / `item.*` / `error`); auth `OPENAI_API_KEY` (or `codex
  login`). FULLY conformant; the `parse` mirrors opencode's NDJSON path.
- **Antigravity** (`agy` / `antigravity`) -- `--prompt` / `--prompt-file`,
  `--output json`, `--yes`; auth `GEMINI_API_KEY` / `ANTIGRAVITY_API_KEY`. BUT a
  known bug (`google-antigravity/antigravity-cli#76`) drops stdout under a non-TTY
  (pipe/subprocess) -- exactly kazi's mode. Conformant only WITH a workaround
  (`--prompt-file` + `--output json` written to a file we read back, or a fixed
  release).
- **claw-code** -- `claw prompt "<text>"`, env API keys, NO documented JSON
  output, no model flag; self-described "an agent-managed museum exhibit rather
  than a production tool." Does not meet the structured-output bar.

## Decision

1. **A conformance contract for a first-class harness profile** (extends ADR-0016):
   non-interactive single-prompt invocation; machine-parseable stdout (JSON/JSONL
   preferred); CORRECT under a non-TTY subprocess; optional model selection + env
   passthrough. `parse` stays ADDITIVE -- it returns only the fields it can extract;
   the `CliAdapter` always provides `:output`.

2. **An onboarding recipe (data, not modules):** add a `defp <id>` profile to
   `Kazi.Harness.Registry`, register it in `fetch/1` + `ids/0`, and prove it with
   (a) pure unit tests of `build_args`, (b) a GOLDEN-TRANSCRIPT test of `parse`
   against a recorded sample of the tool's real output, and (c) a live smoke tagged
   `:<id>_live` (excluded by default, like `:opencode_live`), run by a maintainer
   with the real binary + creds. A reusable test helper keeps every profile's tests
   uniform.

3. **Tiered support by conformance.** Codex is the priority, fully-conformant
   addition. Antigravity is added WITH the documented non-TTY workaround and a
   recorded risk. claw-code is added BEST-EFFORT only (raw-stdout `parse`, no
   cost/structured extraction), explicitly marked demo-grade. A harness that cannot
   meet the contract is supported best-effort or declined -- never forced into a
   brittle scrape that pretends to be structured.

4. **Coherence.** The harness list is a shared canonical string (README + site,
   drift-checked by T9.9); adding a harness updates `site/src/canonical.mjs`
   HARNESSES + the README in the SAME change, or CI goes red.

## Consequences

- Adding "any other major harness" is a bounded, repeatable recipe (profile + three
  tests + a canonical-string update), not architecture work -- fulfilling ADR-0016's
  promise.
- The contract names the real failure mode (non-TTY stdout) up front, so the
  Antigravity bug is handled deliberately, not discovered in production.
- Best-effort support for non-structured tools (claw-code) keeps kazi honest: it
  runs, but cost/parse fidelity is degraded and LABELLED so.
- Live smokes need each vendor's binary + API key; they stay excluded-by-default so
  CI is hermetic (a maintainer runs them with real creds).
- A tool that breaks the contract in a new release (e.g. Antigravity changing the
  non-TTY behaviour) can regress a profile; the golden-transcript + live smoke are
  the catch, and Antigravity may need version pinning.

## Alternatives rejected

- **A bespoke adapter module per harness.** ADR-0016 already rejected this; profiles
  are data.
- **Forcing claw-code / Antigravity into full conformance by scraping unstructured
  stdout.** Brittle and dishonest about fidelity; best-effort + a documented
  workaround is the truthful posture.
- **Declining non-conformant tools entirely.** The operator asked for breadth;
  best-effort with clear labelling serves that without overpromising.
