// T30.5 tiering accuracy + coherence gate (ADR-0035, UC-045). The in-family
// Claude tiering surfaces -- the install skill, AGENTS.md, README, and the
// marketing site -- ship two claims a stale edit can silently break:
//
//   1. MODEL IDS. The tiering ladder names concrete Claude model ids
//      (`claude-haiku-4-5` -> `claude-sonnet-5` -> `claude-opus-4-8`). A model
//      retires or a release renames an id, and a doc left behind hands the reader
//      an id that 404s on their first `kazi apply --model ...`. The current,
//      real ids live in the claude-api reference (Opus 4.8 / Sonnet 4.6 / Haiku
//      4.5 and the rest of the current generation); this gate scans the tiering
//      surfaces for any `claude-<...>` model id NOT on that allow-list -- catching
//      both an invented id and a once-real-now-stale one (e.g. `claude-3-5-sonnet`,
//      `claude-sonnet-4-5`, `claude-opus-4-1`).
//
//   2. COST NUMBERS. ADR-0033's cost win is DESIGNED-FOR, NOT YET MEASURED -- the
//      headline figure is being measured by the multi-iteration benchmark
//      (T19.7) and must stay hedged until it lands. This gate fails if a tiering
//      surface states a cost NUMBER ("$0.0X", "N% cheaper", "Nx cheaper") as a
//      measured fact -- i.e. on a line that does NOT carry a "being measured" /
//      "not yet measured" / "designed-for" hedge.
//
// ── Compose, don't duplicate ────────────────────────────────────────────────
// The OTHER two coherence guarantees the tiering surfaces need already have
// gates, and this gate does NOT re-implement them:
//   * COMMAND accuracy (no unshipped/stale `kazi <verb>`): README + docs/ by the
//     T28.4 doc-commands gate (.github/scripts/check-doc-commands.mjs); the
//     rendered SKILL.md + AGENTS.md by the T16.4 ExUnit coherence test
//     (test/kazi/teach_coherence_test.exs); the site by the T29.4 verb guard
//     (site/scripts/check-commands.mjs).
//   * README <-> site (T9.9, site/scripts/check-coherence.mjs) and
//     SKILL/AGENTS <-> CLI (T16.4) coherence run in ci.yml / site-smoke.yml.
// The `tiering-coherence` job in oss-gates.yml runs THIS gate; the gate doc
// (docs/oss-gates.md, Gate 6) records the full composition.
//
// Run: `node .github/scripts/check-tiering-coherence.mjs`
//      BLOCKING=0 softens to warn-only; TIERING_FILES (space-separated) points
//      the scanner at a fixture tree (used by the gate's own load-bearing tests).
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, relative } from "node:path";

// Blocking is the default: the tiering surfaces are clean at ship time (T25.11 /
// T30.1 / T30.2 use current ids and keep the cost claim hedged), so a NEW stale
// id or un-hedged cost number should red the PR immediately.
const DEFAULT_BLOCKING = true;
const BLOCKING =
  process.env.BLOCKING === "0" ? false : process.env.BLOCKING === "1" ? true : DEFAULT_BLOCKING;

const here = dirname(fileURLToPath(import.meta.url));
// repo root = two levels up from .github/scripts/.
const repoRoot = join(here, "..", "..");

// ── The current model-id allow-list ─────────────────────────────────────────
// Sourced from the claude-api reference's "Current Models" table: the current
// generation of real, non-retired Claude ids. A user-facing tiering surface must
// point at one of these -- a legacy-but-still-served id (e.g. `claude-sonnet-4-5`,
// `claude-opus-4-1`) is intentionally NOT allowed here, because the tiering docs
// should steer a new reader to a current model, not a deprecated one. Keep this
// in sync when a new model launches or an id retires (the same MODEL-LAUNCH sync
// point the migration guide describes).
export const ALLOWED_MODEL_IDS = new Set([
  "claude-fable-5",
  "claude-mythos-5",
  "claude-opus-4-8",
  "claude-opus-4-7",
  "claude-opus-4-6",
  "claude-sonnet-5",
  "claude-sonnet-4-6",
  "claude-haiku-4-5",
]);

// A token shaped like a Claude model id: `claude-<family>-<ver…>` for the named
// tiers, or `claude-<numeric…>` for the older numeric ids (claude-2, claude-2.1,
// claude-3-5-sonnet-20241022, claude-3-opus-20240229). The numeric branch is what
// catches a stale OLD model name. Case-sensitive: a real id is lowercase, so the
// prose word "Claude" (capitalized, space-separated) never matches.
const MODEL_ID_RE =
  /\bclaude-(?:(?:opus|sonnet|haiku|fable|mythos|instant)-[0-9][0-9a-z.@-]*|[0-9][0-9a-z.@-]*)/g;

// ── Cost-number patterns ────────────────────────────────────────────────────
// A cost figure stated as a measured fact. The currency pattern requires a
// DECIMAL so a shell variable (`$1`, `$GOAL`) in an example block is never a
// false hit; the percent / multiple patterns require a cost word adjacent so an
// unrelated "100% of predicates" never trips.
const COST_PATTERNS = [
  { re: /\$[0-9]+\.[0-9]+/, what: "currency amount" },
  {
    re: /\b[0-9]+(?:\.[0-9]+)?\s*%\s*(?:cheaper|less|fewer|savings?|reduction|lower|off|discount)\b/i,
    what: "percent saving",
  },
  {
    re: /\b[0-9]+(?:\.[0-9]+)?\s*%\s+of\s+(?:the\s+)?cost\b/i,
    what: "percent of cost",
  },
  {
    re: /\b[0-9]+(?:\.[0-9]+)?\s*[x×]\s*(?:cheaper|less|the\s+cost)\b/i,
    what: "cost multiple",
  },
  {
    re: /\b[0-9]+(?:\.[0-9]+)?\s*times\s+(?:cheaper|less\s+expensive)\b/i,
    what: "cost multiple",
  },
];

// A line that frames the cost as not-yet-measured is exempt -- a single hedged
// mention passes while a bare measured figure is flagged.
const HEDGE_RE =
  /being measured|not yet measured|designed[- ]for|not a measured|not an unproven|intended economics|illustrative|hypothetical|for example|e\.g\./i;

// ── Surface resolution ──────────────────────────────────────────────────────
// The four tiering surfaces named by the task: the install skill (its model ids
// and commands live as literal text in install_skill.ex), AGENTS.md, README, and
// the marketing site source (scanned recursively for .astro/.md/.mjs).
function walk(dir, exts, out) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (["node_modules", "dist", ".astro"].includes(entry.name)) continue;
      walk(full, exts, out);
    } else if (exts.some((e) => entry.name.endsWith(e))) {
      out.push(full);
    }
  }
}

function defaultTieringFiles() {
  const out = [];
  for (const rel of ["README.md", "AGENTS.md", "lib/kazi/teach/install_skill.ex"]) {
    const p = join(repoRoot, rel);
    if (existsSync(p)) out.push(p);
  }
  const siteSrc = join(repoRoot, "site", "src");
  if (existsSync(siteSrc) && statSync(siteSrc).isDirectory()) {
    walk(siteSrc, [".astro", ".md", ".mjs"], out);
  }
  return out;
}

function tieringFiles() {
  if (process.env.TIERING_FILES) {
    return process.env.TIERING_FILES.split(/\s+/).filter(Boolean);
  }
  return defaultTieringFiles();
}

// ── Scan ────────────────────────────────────────────────────────────────────
// Pure over an explicit file list so the tests can drive it against a fixture
// tree without touching the real surfaces. Returns a list of findings.
export function scanTiering(files) {
  const findings = [];
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    text.split("\n").forEach((line, i) => {
      const lineno = i + 1;

      // (1) model ids: every id-shaped token must be a current, allowed id.
      for (const m of line.matchAll(MODEL_ID_RE)) {
        const id = m[0];
        if (!ALLOWED_MODEL_IDS.has(id)) {
          findings.push({ file, lineno, kind: "stale-model-id", token: id, text: line.trim() });
        }
      }

      // (2) cost numbers: a measured-looking figure on a non-hedged line.
      if (!HEDGE_RE.test(line)) {
        for (const { re, what } of COST_PATTERNS) {
          const m = line.match(re);
          if (m) {
            findings.push({
              file,
              lineno,
              kind: "unhedged-cost-number",
              token: `${m[0].trim()} (${what})`,
              text: line.trim(),
            });
          }
        }
      }
    });
  }
  return findings;
}

// ── Main (skipped when imported as a module) ────────────────────────────────
function main() {
  const files = tieringFiles();
  const findings = scanTiering(files);
  const rel = (f) => relative(repoRoot, f);

  if (findings.length === 0) {
    console.log(
      `tiering accuracy + coherence OK (${files.length} surfaces scanned; every Claude ` +
        `model id is current and no cost figure is stated as measured).`,
    );
    process.exit(0);
  }

  const label = BLOCKING ? "FAILED" : "WARN";
  console.error(`tiering accuracy + coherence ${label} (T30.5): a tiering surface drifted.`);
  console.error(
    `Allowed model ids (claude-api current generation): [${[...ALLOWED_MODEL_IDS].sort().join(", ")}].`,
  );
  for (const v of findings) {
    console.error(`  ${rel(v.file)}:${v.lineno}: ${v.kind}: ${v.token}  ->  ${v.text}`);
  }
  console.error(
    "\nFix: replace a stale model id with a current one (e.g. `claude-sonnet-4-6` -> " +
      "`claude-sonnet-5`), or hedge a cost figure (state the SHAPE of the saving, not an " +
      'unproven number) until the multi-iteration benchmark (T19.7) lands. A hedged line ' +
      'carries "being measured" / "not yet measured" / "designed-for".',
  );

  if (BLOCKING) process.exit(1);
  console.error("\nWARN mode (BLOCKING=0): reporting only, exiting 0.");
  process.exit(0);
}

// Run only as a script, not when imported by the tests. `process.argv[1]` is the
// invoked file; compare to this module's path.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
