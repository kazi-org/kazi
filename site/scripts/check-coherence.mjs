// T9.9 coherence drift-check (ADR-0018): the canonical strings the website shows
// MUST appear verbatim in ../README.md, so the marketing site and the README can
// never silently diverge. Editing a canonical string in only one surface fails CI.
//
// Run: `npm --prefix site run check:coherence` (or `node site/scripts/check-coherence.mjs`).
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  INSTALL_CMD,
  POSITIONING,
  KUBERNETES_LINE,
  HERO_TAGLINE,
  INVOCATION_PHRASE,
} from "../src/canonical.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const readmePath = join(here, "..", "..", "README.md");
const readme = readFileSync(readmePath, "utf8");

// Each canonical string the site renders must be present verbatim in the README.
const checks = [
  ["install command", INSTALL_CMD],
  ["positioning one-liner", POSITIONING],
  ["Kubernetes framing", KUBERNETES_LINE],
  ["hero tagline", HERO_TAGLINE],
  ["invocation phrase", INVOCATION_PHRASE],
];

const missing = checks.filter(([, value]) => !readme.includes(value));

if (missing.length > 0) {
  console.error("README <-> website coherence check FAILED (ADR-0018).");
  console.error("These canonical strings are on the site but NOT verbatim in README.md:");
  for (const [name, value] of missing) {
    console.error(`  - ${name}: ${JSON.stringify(value)}`);
  }
  console.error(
    "\nFix: make README.md and site/src/canonical.mjs agree (edit both surfaces together).",
  );
  process.exit(1);
}

console.log(`README <-> website coherence OK (${checks.length} canonical strings match).`);
