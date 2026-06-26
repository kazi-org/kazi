// T29.4 site command-accuracy guard (ADR-0034 / E29, UC-035): the marketing
// site must never present a REMOVED kazi verb as a live command. `kazi run` and
// `kazi propose` were removed at v1.0.0 (see docs/plan.md T27.9); the current CLI
// has neither. A stale verb on the site sends a new user a command that errors on
// their first try, so we scan the site source -- including the .svg proof assets,
// which are XML text -- and report any removed verb used as a PRIMARY command.
//
// Scope of the verb list (deliberately narrow): only verbs the CLI no longer
// accepts. `kazi approve` / `kazi reject` / `kazi list-proposed` are STILL live
// commands (lib/kazi/cli.ex), so they are NOT flagged -- flagging them would red
// every legitimate doc once this gate ratchets to blocking. The old
// `propose` -> `approve` proposal flow is caught at its `kazi propose` entry
// point, which is the part that actually no longer exists.
//
// Phase: BLOCKING in CI (ratcheted at T38.4). T27.6 + T25.2 cleaned the site, so
// the whole site/ tree -- including the E38 blog content under
// site/src/content/blog/** (now scanned for .md + .mdx) -- passes clean, and the
// oss-gates `site-commands` job runs with BLOCKING=1 (a removed verb reds the PR).
// The local default below stays WARN (exit 0) so an editor can run the scanner
// for a report without it aborting; pass BLOCKING=1 to mirror CI.
//
// Run: `npm --prefix site run check:commands` (or `node site/scripts/check-commands.mjs`).
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, relative, extname } from "node:path";

// Phase-1 default. Flip to `true` (or set BLOCKING=1 in the env / CI job) to make
// a hit fail the build, once the site no longer ships any removed verb.
const DEFAULT_BLOCKING = false;
const BLOCKING = process.env.BLOCKING === "1" ? true : DEFAULT_BLOCKING;

// Verbs the CLI removed at v1.0.0 (T27.9). Used as `kazi <verb>` they are a hit.
const REMOVED_VERBS = ["run", "propose"];
const VERB_RE = new RegExp(`\\bkazi\\s+(${REMOVED_VERBS.join("|")})\\b`);

// Source extensions to scan. .svg is included on purpose: the proof asset is XML
// text and a removed verb can hide in a <tspan>. .md AND .mdx are both scanned so
// the E38 adoption blog content under `site/src/content/blog/**` is covered: the
// walk below is rooted at the site/ tree and recurses every non-skipped dir, so
// every blog post (the collection glob is `**/*.{md,mdx}`, T38.1) is scanned and a
// post can never ship a removed kazi verb (`kazi run` / `kazi propose`) as a live
// command. (T38.4 extended the set from `.md` to also include `.mdx`.)
const SCAN_EXTS = new Set([".astro", ".mjs", ".md", ".mdx", ".svg"]);

const here = dirname(fileURLToPath(import.meta.url));
// Default to the site/ root; SITE_ROOT lets a test point the real scanner at a
// fixture tree without duplicating the matching logic.
const siteRoot = process.env.SITE_ROOT || join(here, "..");

// Directories that hold no hand-authored site copy (build output, deps).
const SKIP_DIRS = new Set(["node_modules", "dist", ".astro"]);

// This scanner names the removed verbs in its own comments/strings, so it is
// excluded from the scan to avoid self-tripping (same pattern as the leak guard).
const selfPath = fileURLToPath(import.meta.url);

// A line that DOCUMENTS the removal -- a labelled "deprecated alias" note, or an
// explicit inline `verb-drift:allow` marker -- is exempt. This lets a single
// honest mention ("`kazi run` is a deprecated alias, removed in v1.0.0") pass
// while a step-2 code block that hands the user `kazi run` is flagged.
function isAllowed(line) {
  return /verb-drift:allow/.test(line) || /deprecated alias/i.test(line);
}

function walk(dir, out) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) walk(full, out);
    } else if (entry.isFile() && SCAN_EXTS.has(extname(entry.name))) {
      out.push(full);
    }
  }
  return out;
}

const files = walk(siteRoot, []).filter((f) => f !== selfPath);

const violations = [];
for (const file of files) {
  const lines = readFileSync(file, "utf8").split("\n");
  lines.forEach((line, i) => {
    if (VERB_RE.test(line) && !isAllowed(line)) {
      const verb = line.match(VERB_RE)[1];
      violations.push({
        file: relative(siteRoot, file),
        line: i + 1,
        verb,
        text: line.trim(),
      });
    }
  });
}

if (violations.length === 0) {
  console.log(
    `site command-accuracy OK (no removed kazi verb [${REMOVED_VERBS.join(", ")}] used as a primary command).`,
  );
  process.exit(0);
}

const label = BLOCKING ? "FAILED" : "WARN";
console.error(
  `site command-accuracy ${label} (T29.4): removed kazi verb(s) used as a primary command.`,
);
console.error(
  `Removed at v1.0.0 (T27.9): ${REMOVED_VERBS.map((v) => `kazi ${v}`).join(", ")}. The current CLI rejects them.`,
);
for (const v of violations) {
  console.error(`  ${v.file}:${v.line}: kazi ${v.verb}  ->  ${v.text}`);
}
console.error(
  "\nFix: replace the removed verb with its live equivalent (e.g. `kazi run` -> `kazi apply`, " +
    "`kazi propose` -> `kazi plan`). A single labelled note documenting the removal can carry " +
    '"deprecated alias" or an inline `verb-drift:allow` marker to pass.',
);

if (BLOCKING) {
  process.exit(1);
}

console.error(
  "\nPhase-1 WARN: reporting only, exiting 0 (does not block the build). " +
    "Set BLOCKING=1 (or DEFAULT_BLOCKING=true) to ratchet to blocking once T27.6 + T25.2 clean the site.",
);
process.exit(0);
