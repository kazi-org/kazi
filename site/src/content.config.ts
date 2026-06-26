// Astro Content Collections config (T38.1) — foundational infra for the E38
// adoption blog series.
//
// Astro 5+ (this site is on Astro ^7.0.2) replaced the legacy
// `src/content/config.ts` collection API with the Content Layer API:
// `defineCollection` paired with an explicit `loader` (here `glob()` from
// `astro/loaders`), and the config file moved to `src/content.config.ts`.
// We ship the content-layer form because that is what the installed Astro 7
// requires — the legacy `src/content/config.ts` shape is deprecated under
// Astro 7 and would not be honoured.
import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
// `z` is imported from `astro:schema`, the forward-compatible source under
// Astro 7 (re-exporting `z` from `astro:content` is deprecated). `astro check`
// still emits ts(6385) deprecation *hints* on the `z` symbol from the bundled
// zod; those are hints, not type errors, and the build is unaffected.
import { z } from "astro:schema";

// The `blog` collection backs the adoption blog series (epic E38). Entries are
// markdown/mdx files under `src/content/blog/`. The zod schema below is the
// single source of truth for post frontmatter; the editorial style sheet that
// documents these fields for authors is a separate task (T38.5).
const blog = defineCollection({
  loader: glob({ pattern: "**/*.{md,mdx}", base: "./src/content/blog" }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    // `z.coerce.date()` accepts an ISO `YYYY-MM-DD` string in frontmatter and
    // yields a JS Date at the typed boundary.
    date: z.coerce.date(),
    author: z.string(),
    tags: z.array(z.string()),
    series: z.string(),
    // The series is capped at 12 parts; reject anything outside 1–12.
    part: z.number().int().min(1).max(12),
    // Posts default to draft. Draft exclusion: there is no automatic draft
    // filtering in the Content Layer API, so drafts are excluded simply by not
    // being rendered into any public page. No blog route exists yet (the index
    // / post routes are T38.2 / T38.3); when those land they will filter on
    // `data.draft === false` for the production build. Until then a
    // `draft: true`-only collection that builds clean emits no public page.
    draft: z.boolean().default(true),
    ogImage: z.string().optional(),
    // Alt text for the post header / hero image.
    heroAlt: z.string().optional(),
  }),
});

export const collections = { blog };
