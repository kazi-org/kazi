// T28.4 doc command-accuracy gate (ADR-0034 / E28-E29, UC-042): every kazi
// command and flag a LIVE doc presents as a runnable command must exist in the
// REAL CLI surface. A doc that hands the reader `kazi frobnicate` or
// `kazi apply --frobnicate` sends them a command that errors on their first try.
// This is the docs-tree sibling of the site verb guard (T29.4,
// site/scripts/check-commands.mjs): same family, wider check (commands AND
// flags), pointed at README + docs/ instead of site/.
//
// ── How it learns the REAL surface (no hardcoded list) ──────────────────────
// The truth source is the `@commands` / `@switches` table in lib/kazi/cli.ex.
// `kazi help --json` is GENERATED from that table (see the cli.ex moduledoc),
// and an ExUnit test (test/kazi/cli_help_schema_test.exs) pins that the two stay
// in sync -- every command/flag `help --json` reports is one the parser
// dispatches, and vice versa. So parsing the table here is, transitively, the
// shipped `kazi help --json` surface, with NO Elixir runtime / built binary
// needed in the gate (the same runtime-free choice the doc-freshness predicates
// document in .github/scripts/doc_freshness/lib.sh). A maintainer with a built
// binary can cross-check: `kazi help --json | jq -r '.commands[].name'`.
//
// ── What counts as a "command reference" (command-context only) ──────────────
// We DELIBERATELY do not flag every `kazi <word>` -- prose like "kazi is a
// reconciler" or "kazi owns parallelism" is not a command. A `kazi <verb>` is
// only checked when it appears in COMMAND CONTEXT:
//   * the start of a line inside a fenced code block (``` … ```), optionally
//     after a `$`/`>` shell prompt -- where runnable examples live; or
//   * the start of an inline backtick code span, e.g. `kazi apply`.
// A `#`-prefixed comment line in a code block ("# kazi then converges") has the
// verb off the command position, so it is not flagged. This mirrors the
// backtick discipline of the doc-freshness (b) predicate, extended to fenced
// example blocks.
//
// ── What is flagged ─────────────────────────────────────────────────────────
//   1. A REMOVED verb used as a primary command: `kazi run`, `kazi propose`,
//      `mix kazi.run` (removed at v1.0.0, ADR-0032 / docs/deprecations.md).
//   2. A `kazi <verb>` whose verb is NOT in the shipped command table.
//   3. A `--flag` on a kazi invocation whose flag is NOT in @switches.
// A finding carries file:line and the offending token.
//
// ── Allow-list ──────────────────────────────────────────────────────────────
// A line that DOCUMENTS a removal -- carrying the case-insensitive phrase
// `deprecated alias`, or an explicit inline `verb-drift:allow` marker -- is
// exempt, so a single honest "`kazi run` is a deprecated alias" mention passes
// while a code block that hands the reader the dead verb is flagged.
//
// Run: `node .github/scripts/check-doc-commands.mjs`
//      BLOCKING=1 to fail on a hit; KAZI_DOC_FILES / KAZI_CLI_FILE to point the
//      real scanner at a fixture tree (used by the gate's own fixture tests).
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, relative } from "node:path";

// Blocking is the default: the docs tree is clean at ship time (T27.6 + T28.3
// cleaned the verbs), so a NEW stale ref should red the PR immediately. Set
// BLOCKING=0 to soften to warn-only (reports + exits 0).
const DEFAULT_BLOCKING = true;
const BLOCKING =
  process.env.BLOCKING === "0" ? false : process.env.BLOCKING === "1" ? true : DEFAULT_BLOCKING;

const here = dirname(fileURLToPath(import.meta.url));
// repo root = two levels up from .github/scripts/.
const repoRoot = join(here, "..", "..");

const CLI_FILE = process.env.KAZI_CLI_FILE || join(repoRoot, "lib", "kazi", "cli.ex");

// Verbs the CLI removed at v1.0.0 (T27.9 / ADR-0032). Always a finding when used
// as `kazi <verb>` or `mix kazi.<verb>`.
const REMOVED_VERBS = new Set(["run", "propose"]);

// ── Surface extraction from lib/kazi/cli.ex ─────────────────────────────────

// Slice the body of a `@attr [ … ]` block. Brace/bracket-naive but the table is
// a flat literal, so the first `]` at column 2 closes the block (same anchor the
// doc-freshness awk parser uses).
function sliceBlock(src, header) {
  const start = src.indexOf(header);
  if (start === -1) throw new Error(`could not find ${header} in ${CLI_FILE}`);
  const afterHeader = start + header.length;
  // close on the first line that is exactly "  ]" (two-space indent).
  const closeRe = /\n {2}\]/;
  const rest = src.slice(afterHeader);
  const closeIdx = rest.search(closeRe);
  if (closeIdx === -1) throw new Error(`could not find close of ${header}`);
  return rest.slice(0, closeIdx);
}

function realSurface() {
  const src = readFileSync(CLI_FILE, "utf8");

  // Commands: each @commands entry is `name: "<cmd>",` immediately followed by a
  // `summary:` line. Positional-arg names (`%{name: "goal-file", required: …}`)
  // are followed by `required:`, not `summary:`, so the look-ahead excludes them.
  const cmdBlock = sliceBlock(src, "@commands [");
  const commands = new Set();
  const cmdRe = /name: "([a-z][a-z-]*)",?\s*\n\s*summary:/g;
  for (let m; (m = cmdRe.exec(cmdBlock)); ) commands.add(m[1]);
  if (commands.size === 0) throw new Error("parsed zero commands from @commands");

  // Flags: each @switches entry is `<atom>: :<type>,`. Render the atom as a CLI
  // flag (underscore → dash), e.g. dry_run → --dry-run. We read @switches (the
  // full parser-accepted set) rather than the per-command `flags:` arrays, so
  // genuinely-global flags the help-json per-command view omits -- `--help`,
  // `--version`, `--parallelism` -- still pass; a doc using `kazi apply --help`
  // must not be flagged. This is a safe superset of `kazi help --json`'s flags.
  const swBlock = sliceBlock(src, "@switches [");
  const flags = new Set();
  const swRe = /^\s*([a-z][a-z_]*):\s*:(?:string|boolean|integer)/gm;
  for (let m; (m = swRe.exec(swBlock)); ) flags.add(m[1].replace(/_/g, "-"));
  if (flags.size === 0) throw new Error("parsed zero flags from @switches");

  // Short aliases (@aliases [h: :help, …]) → single-dash short flags.
  const shortFlags = new Set();
  const aliasBlock = src.match(/@aliases \[([^\]]*)\]/);
  if (aliasBlock) {
    const aRe = /([a-z]):\s*:[a-z_]+/g;
    for (let m; (m = aRe.exec(aliasBlock[1])); ) shortFlags.add(m[1]);
  }
  return { commands, flags, shortFlags };
}

// ── Doc scanning ────────────────────────────────────────────────────────────

// History / archival tiers legitimately name removed verbs and are EXCLUDED
// (same exclusion list the doc-freshness (b) predicate uses), plus this gate's
// own doc (it quotes `kazi frobnicate` / removed verbs as examples).
const EXCLUDE_DOCS = new Set([
  "deprecations.md", // the removal log -- its job is to name kazi run / propose
  "devlog.md", // append-only session history
  "plan.md", // the WBS records past task wording
  "lore.md", // append-only invariants/landmines
  "doc-freshness.md", // sibling gate's doc, quotes example commands
  "oss-gates.md", // THIS gate's doc, quotes kazi frobnicate / removed verbs
]);

function defaultDocFiles() {
  const out = [join(repoRoot, "README.md")];
  // Top-level docs/*.md only (skips docs/adr/**, docs/research/**, docs/schemas/**
  // -- frozen records and machine schemas, not live command guides).
  const docsDir = join(repoRoot, "docs");
  for (const entry of readdirSync(docsDir, { withFileTypes: true })) {
    if (
      entry.isFile() &&
      entry.name.endsWith(".md") &&
      !EXCLUDE_DOCS.has(entry.name)
    ) {
      out.push(join(docsDir, entry.name));
    }
  }
  return out;
}

function docFiles() {
  if (process.env.KAZI_DOC_FILES) {
    return process.env.KAZI_DOC_FILES.split(/\s+/).filter(Boolean);
  }
  return defaultDocFiles();
}

function isAllowed(line) {
  return /verb-drift:allow/.test(line) || /deprecated alias/i.test(line);
}

// Extract the substrings inside inline backtick spans on a line.
function inlineCodeSpans(line) {
  const spans = [];
  const re = /`([^`]+)`/g;
  for (let m; (m = re.exec(line)); ) spans.push(m[1]);
  return spans;
}

// From a kazi invocation string ("kazi apply <g> --workspace x --json"), return
// the flag tokens (without leading dashes), preserving long/short distinction.
// A flag is a dash-group ONLY at a token boundary -- the start of the string, or
// after whitespace / an opening bracket-or-paren. This is the crucial guard: a
// hyphen INSIDE a placeholder (`<goal-file>` -> `-file`) or a word ("opt-in" ->
// `-in`, "to-do" -> `-do`) is preceded by a letter, so it is NOT a flag. We also
// drop a trailing `# comment` so a comment that mentions `--foo` cannot trip.
function flagsOf(invocation) {
  const out = [];
  const code = invocation.replace(/\s#.*$/, "");
  const re = /(?:^|[\s[(])(--?)([a-zA-Z][a-zA-Z-]*)/g;
  for (let m; (m = re.exec(code)); ) {
    out.push({ long: m[1] === "--", name: m[2] });
  }
  return out;
}

function scan(surface, files) {
  const { commands, flags, shortFlags } = surface;
  const findings = [];

  const record = (file, lineno, kind, token, text) =>
    findings.push({ file, lineno, kind, token, text: text.trim() });

  // Check one kazi invocation found in command context.
  const checkInvocation = (file, lineno, line, verb, rest) => {
    if (isAllowed(line)) return;
    if (REMOVED_VERBS.has(verb)) {
      record(file, lineno, "removed-command", `kazi ${verb}`, line);
      return; // a removed verb's flags are moot
    }
    if (!commands.has(verb)) {
      record(file, lineno, "unknown-command", `kazi ${verb}`, line);
      return;
    }
    for (const f of flagsOf(rest)) {
      const known = f.long ? flags.has(f.name) : shortFlags.has(f.name);
      if (!known) {
        record(file, lineno, "unknown-flag", `--${f.name}`, line);
      }
    }
  };

  // `kazi <verb> …rest` at the start of a string (after optional $/> prompt).
  const KAZI_AT_START = /^\s*[$>]?\s*kazi\s+([a-z][a-z-]*)(.*)$/;
  // `mix kazi.<verb>` removed-alias form (only run/propose are flagged).
  const MIX_REMOVED = /\bmix\s+kazi\.(run|propose)\b/;

  for (const file of files) {
    const text = readFileSync(file, "utf8");
    const lines = text.split("\n");
    let inFence = false;
    let fenceMarker = "";

    lines.forEach((line, i) => {
      const lineno = i + 1;
      const trimmed = line.trim();

      // Toggle fenced-code state on ``` or ~~~ markers.
      const fenceOpen = trimmed.match(/^(```+|~~~+)/);
      if (fenceOpen) {
        if (!inFence) {
          inFence = true;
          fenceMarker = fenceOpen[1][0];
        } else if (trimmed.startsWith(fenceMarker)) {
          inFence = false;
        }
        return; // the fence line itself carries no command
      }

      // mix kazi.run / mix kazi.propose anywhere (code or prose) is a removed ref.
      const mix = line.match(MIX_REMOVED);
      if (mix && !isAllowed(line)) {
        record(file, lineno, "removed-command", `mix kazi.${mix[1]}`, line);
      }

      if (inFence) {
        // Code line: a command sits at the start (optionally after a prompt).
        const m = line.match(KAZI_AT_START);
        if (m) checkInvocation(file, lineno, line, m[1], m[2]);
      } else {
        // Prose line: only inline backtick spans are command context.
        for (const span of inlineCodeSpans(line)) {
          const m = span.match(KAZI_AT_START);
          if (m) checkInvocation(file, lineno, line, m[1], m[2]);
        }
      }
    });
  }
  return findings;
}

// ── Main ────────────────────────────────────────────────────────────────────

const surface = realSurface();
const files = docFiles();
const findings = scan(surface, files);

const rel = (f) => relative(repoRoot, f);

if (findings.length === 0) {
  console.log(
    `doc command-accuracy OK (${files.length} docs scanned; every kazi command/flag ` +
      `matches the live CLI surface: ${surface.commands.size} commands, ${surface.flags.size} flags).`,
  );
  process.exit(0);
}

const label = BLOCKING ? "FAILED" : "WARN";
console.error(`doc command-accuracy ${label} (T28.4): docs reference a CLI command/flag that does not ship.`);
console.error(
  `Real surface (from ${rel(CLI_FILE)}, == kazi help --json): commands [${[...surface.commands].sort().join(", ")}]; ` +
    `flags [${[...surface.flags].sort().map((f) => "--" + f).join(", ")}].`,
);
for (const v of findings) {
  console.error(`  ${rel(v.file)}:${v.lineno}: ${v.kind}: ${v.token}  ->  ${v.text}`);
}
console.error(
  "\nFix: replace the stale token with a real command/flag (e.g. `kazi run` -> `kazi apply`, " +
    "`kazi propose` -> `kazi plan`). A single line documenting a removal can carry " +
    '"deprecated alias" or an inline `verb-drift:allow` marker to pass.',
);

if (BLOCKING) process.exit(1);
console.error("\nWARN mode (BLOCKING=0): reporting only, exiting 0.");
process.exit(0);
