// T38.20 per-post header art generator (ADR-0048 dec. 7). Emits one lightweight,
// hand-templated SVG banner per post of the "From Vibe Coding to Reconciliation"
// series into site/public/blog/art/part-NN.svg.
//
// These are EXPLANATORY header diagrams in the site's visual language (the
// ADR-0018 cyan->blue->violet gradient on the ink surface), NOT glossy ad
// creative. Each banner is a vector (16:9 viewBox) so it stays crisp at any
// render size: small as a series-row thumbnail, full-width as a post header
// (wired via the T38.1 `ogImage` / `heroAlt` frontmatter fields when each post
// ships, T38.6-T38.17). The art encodes the post's position on the rung ladder so
// the reader sees the climb at a glance.
//
// The generator is committed alongside its output for provenance and so the
// twelve banners stay consistent; re-run to regenerate:
//   node site/scripts/gen-post-art.mjs
import { writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, "..", "public", "blog", "art");
mkdirSync(outDir, { recursive: true });

const SERIES = "From Vibe Coding to Reconciliation";

// Short post titles, in part order. These mirror the series scaffold titles in
// site/src/pages/blog/from-vibe-coding-to-reconciliation.astro and docs/plans/E38.md.
const TITLES = [
  'The ceiling of "looks good to me"',
  "Teach your agent to remember",
  "Decisions need a home: knowledge tiers",
  "Give your agent eyes (all the way to prod)",
  "Stop re-reading the whole repo",
  "From prompts to skills",
  "Plan the work, then work the plan",
  'A definition of "done" that can\'t lie',
  "One developer, many agents",
  "The pattern underneath: reconciliation",
  'Meet kazi: "done," proven',
  "Your on-ramp",
];

// XML-escape text destined for SVG text nodes.
const esc = (s) =>
  s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");

// XML-escape text destined for an attribute value (also escapes quotes).
const escAttr = (s) => esc(s).replace(/"/g, "&quot;").replace(/'/g, "&#39;");

// Greedy word-wrap into at most `maxLines` lines of <= `maxChars` chars.
function wrap(text, maxChars, maxLines) {
  const words = text.split(/\s+/);
  const lines = [];
  let cur = "";
  for (const w of words) {
    const next = cur ? `${cur} ${w}` : w;
    if (next.length > maxChars && cur) {
      lines.push(cur);
      cur = w;
      if (lines.length === maxLines - 1) break;
    } else {
      cur = next;
    }
  }
  if (cur && lines.length < maxLines) lines.push(cur);
  // Fold any remaining words into the last line so no text is dropped.
  const used = lines.join(" ").split(/\s+/).length;
  if (used < words.length) {
    lines[lines.length - 1] += " " + words.slice(used).join(" ");
  }
  return lines;
}

// Descriptive alt text for the art, exported as a sidecar JSON so the page and
// future posts share one source of truth for `heroAlt`.
const alts = {};

for (let i = 0; i < TITLES.length; i++) {
  const part = i + 1;
  const title = TITLES[i];
  const titleLines = wrap(title, 30, 2);
  const alt = `Header art for Part ${part} of "${SERIES}": ${title}. A rung-${part}-of-12 position marker on the kazi gradient.`;
  alts[part] = alt;

  // 12-segment ladder-position marker: filled up to the current part.
  const segW = 46;
  const segGap = 8;
  const baseX = 64;
  const segY = 470;
  const segs = Array.from({ length: 12 }, (_, k) => {
    const x = baseX + k * (segW + segGap);
    const filled = k < part;
    const fill = filled ? "url(#pa-grad)" : "#1e293b";
    const op = filled ? "1" : "1";
    return `<rect x="${x}" y="${segY}" width="${segW}" height="10" rx="5" fill="${fill}" opacity="${op}"/>`;
  }).join("");

  const titleSvg = titleLines
    .map(
      (ln, idx) =>
        `<tspan x="64" dy="${idx === 0 ? 0 : 64}">${esc(ln)}</tspan>`,
    )
    .join("");
  const titleY = titleLines.length === 1 ? 300 : 264;

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 630" width="1200" height="630" font-family="ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif" role="img" aria-label="${escAttr(alt)}">
  <defs>
    <linearGradient id="pa-grad" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#22d3ee"/>
      <stop offset="0.5" stop-color="#3b82f6"/>
      <stop offset="1" stop-color="#8b5cf6"/>
    </linearGradient>
  </defs>
  <rect width="1200" height="630" fill="#0b1220"/>
  <rect x="0" y="0" width="10" height="630" fill="url(#pa-grad)"/>
  <text x="64" y="96" font-size="22" font-weight="700" letter-spacing="3" fill="#64748b">FROM VIBE CODING TO RECONCILIATION</text>
  <text x="64" y="190" font-size="34" font-weight="800" fill="url(#pa-grad)">Part ${String(part).padStart(2, "0")}</text>
  <text x="64" y="${titleY}" font-size="56" font-weight="800" fill="#e2e8f0">${titleSvg}</text>
  ${segs}
  <text x="64" y="520" font-size="20" fill="#64748b">Rung ${part} of 12</text>
  <text x="1136" y="600" text-anchor="end" font-size="20" font-weight="700" fill="#475569">kazi</text>
</svg>
`;

  writeFileSync(join(outDir, `part-${String(part).padStart(2, "0")}.svg`), svg);
}

// Emit the alt-text map next to the art so the series page and future posts wire
// identical `heroAlt` strings without re-deriving them.
writeFileSync(join(outDir, "alt.json"), JSON.stringify(alts, null, 2) + "\n");

console.log(`Wrote ${TITLES.length} per-post art SVGs + alt.json to ${outDir}`);
