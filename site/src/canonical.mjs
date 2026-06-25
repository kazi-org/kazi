// Canonical strings shared by the website AND README.md (ADR-0018). These are the
// single source of truth for kazi's positioning + install; the drift-check
// (scripts/check-coherence.mjs, task T9.9) asserts each one appears verbatim in
// ../README.md, so the two surfaces can never silently diverge.
export const INSTALL_CMD = "brew install kazi-org/tap/kazi";
export const POSITIONING = "the outer/reconciliation loop for coding agents";
export const KUBERNETES_LINE = "Kubernetes for coding goals";
// The decided line-1 hook (T25.1, ADR-0030). Rendered byte-identically in the
// site hero AND the README H1; the precise category (POSITIONING) is the second beat.
export const HERO_TAGLINE = 'Your coding agent says "done." kazi proves it.';
// The decided invocation phrase (T25.6, ADR-0030) — the Context7 "use context7"
// pattern. Documented identically across README, the site, the install-skill
// SKILL.md, and AGENTS.md, and recognized by the kazi skill's trigger list.
export const INVOCATION_PHRASE = "have kazi drive this until done";
// Harnesses kazi can drive today (must match the README's "Use a different coding harness"
// tier table). Order mirrors Kazi.Harness.Registry.ids/0 (ADR-0022).
export const HARNESSES = ["claude", "opencode", "codex", "antigravity", "claw"];
