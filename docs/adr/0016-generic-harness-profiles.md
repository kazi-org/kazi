# ADR 0016: Generic harness profiles — config-driven multi-harness support

## Status
Accepted

## Date
2026-06-22

## Context

kazi drives a coding agent (the inner loop) as a replaceable subprocess
(ADR-0001), invoked headless and stateless per iteration (ADR-0008). The boundary
is the `Kazi.HarnessAdapter` behaviour: `run(prompt, workspace, opts)` returning a
normalized result map the loop reads for evidence and budget. ADR-0001 R4 promised
the boundary is "language- and vendor-neutral — a better Claude Code makes kazi
better for free", and ADR-0008 promised "the same shape drives Codex or any other
`-p`-style tool".

In practice only one concrete adapter exists — `Kazi.Harness.ClaudeAdapter` — and
the promise is only half kept. Three things are hard-coded to Claude:

1. **The argv shape.** `["-p", prompt, "--output-format", "json"]` plus Claude's
   hygiene flags (`--max-budget-usd`, `--allowed-tools`, `--permission-mode`).
2. **The output parser.** A single Claude JSON envelope with `result`, a `usage`
   object (input/output/cache token components), and `total_cost_usd`.
3. **Resolution.** `Kazi.Runtime` binds `@harness Kazi.Harness.ClaudeAdapter`
   directly; there is no way to pick a different harness per run, per goal, or by
   config. `Kazi.Loop` is already generic over the `:harness` module, but nothing
   feeds it anything but Claude.

The operator now runs `opencode` wired to a local Qwen3.6 35B-A3B on a local GPU
host and wants kazi to drive it — and to drive Codex, gemini-cli, antigravity, claw-code,
etc. The blocker is that "a different harness" today means "write a whole new
adapter module". And the harnesses genuinely differ at the boundary: opencode is
`opencode run "<msg>" --model provider/model --format json`, where `--format json`
emits a **stream of JSON events** (NDJSON), not Claude's single envelope; token
usage comes from those events or `opencode stats`, not a `usage` object.

## Decision

**Generalize the single adapter into a config-driven, profile-parameterized CLI
adapter, plus a harness resolution seam.** Three pieces:

1. **`Kazi.Harness.Profile`** — a data description of one harness: a stable `id`,
   the `command`, an **argv template** (how the prompt, model, output-format flag,
   and any harness-specific flags are assembled into the subprocess args), and a
   **parser strategy** (how the harness's stdout maps to the normalized result map
   `%{output, exit, result, tokens, cost_usd, touched, cost: %{tokens: n}}`).
   Profiles also declare which optional hygiene flags they support, so a
   Claude-only flag is never passed to opencode.

2. **`Kazi.Harness.CliAdapter`** — one generic `Kazi.HarnessAdapter` implementation
   parameterized by a resolved profile. It builds argv from the profile, runs
   `System.cmd` with `cd:` set to the workspace (ADR-0008), and parses output via
   the profile's parser. A built-in profile **registry** ships `:claude` (capturing
   today's exact argv + envelope parsing, byte-for-byte) and `:opencode`; further
   harnesses (`:codex`, `:gemini_cli`, ...) are added as profile DATA, not new
   modules. A fully custom harness can be declared in config without touching kazi.

3. **`Kazi.Harness.resolve/1`** — picks the harness with a fixed precedence:
   explicit `:harness` opt (CLI `--harness`) > the goal-file `[harness]` table >
   app config `:kazi, :harness` > default `:claude`. It returns the
   `{adapter_module, adapter_opts}` the loop already consumes, carrying the profile
   plus a `:model` and any provider/endpoint env (so opencode points at the local
   model). `Kazi.Runtime`, `Kazi.Authoring`, and `Kazi.Adopt` (enrich) all resolve
   through this seam instead of hard-coding Claude.

Harness-neutral prompt construction (`build_prompt/2,3`,
`render_retrieval_section/1`, `truncate_evidence/2`) moves out of `ClaudeAdapter`
into a neutral `Kazi.Harness.Prompt` module so every adapter — and `Kazi.Loop` —
shares one renderer rather than coupling to the Claude module.

**Statelessness and neutrality from ADR-0008 are preserved.** Each iteration is
still a fresh subprocess; profiles do not enable `--continue`/`--resume` by
default (opencode's `--continue`/`--session` stay off, matching the Claude default).
A harness that cannot report token usage degrades the budget's token dimension to
the existing estimate — ADR-0008 already permits this.

## Consequences

- **Any CLI harness drops in by data.** opencode ships now; Codex/gemini-cli/etc.
  are a profile entry plus a parser, often reusing an existing parser strategy. A
  custom harness needs only config — the R4/ADR-0008 promise is finally real.
- **One adapter, many harnesses.** Less code than N bespoke adapters, and the
  Claude path is pinned by a golden argv+parse test so generalization cannot
  silently regress today's behavior.
- **Parser strategy is a first-class profile field** because output shapes diverge
  (Claude single envelope vs opencode NDJSON event stream). This is the part that
  genuinely differs per harness and the main implementation cost per new harness.
- **Budget fidelity varies by harness.** Claude reports exact tokens/cost; a
  harness that does not degrades to an estimate (ADR-0008). Surfaced honestly, not
  silently.
- **Backward compatible.** With no harness configured, resolution returns `:claude`
  and the CliAdapter produces byte-identical behavior to the old ClaudeAdapter;
  existing goals, tests, and the escript are unaffected.

## Alternatives rejected

- **One bespoke adapter module per harness.** Honors the behaviour but multiplies
  near-duplicate modules (argv assembly + System.cmd + parse) and still leaves
  selection hard-coded. The differences worth isolating are the argv template and
  the parser; everything else is shared — a profile captures exactly that.
- **A network/SDK integration per provider (bypass the CLIs).** Re-introduces
  vendor coupling and loses the "drives whatever the user already has installed and
  authed" property that makes the subprocess boundary valuable (ADR-0001). The user
  already wired opencode to a local GPU host; kazi should drive that, not reimplement it.
- **Keep Claude-only, document Codex as future work.** Leaves R4/ADR-0008 unmet and
  blocks the operator's opencode + local-model setup, which is the concrete trigger.
