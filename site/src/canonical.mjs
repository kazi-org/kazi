// Canonical strings shared by the website AND README.md (ADR-0018). These are the
// single source of truth for kazi's positioning + install; the drift-check
// (scripts/check-coherence.mjs, task T9.9) asserts each one appears verbatim in
// ../README.md, so the two surfaces can never silently diverge.
export const INSTALL_CMD = "brew install kazi-org/tap/kazi";
export const POSITIONING = "the missing outer loop for coding agents";
export const KUBERNETES_LINE = "Kubernetes for coding goals";
export const HERO_TAGLINE = 'Describe what "done" looks like. kazi makes it true — and proves it.';
// Harnesses kazi can drive today (must match the README's "Use a different coding harness"
// tier table). Order mirrors Kazi.Harness.Registry.ids/0 (ADR-0022).
export const HARNESSES = ["claude", "opencode", "codex", "antigravity", "claw"];
