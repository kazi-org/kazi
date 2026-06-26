// The blog RSS feed (T38.4, epic E38) served at `/blog/rss.xml`.
//
// Lists PUBLISHED (non-draft) posts only, newest-first — the SAME filter and
// ordering the index uses (site/src/pages/blog/index.astro): `!data.draft`,
// sorted by `date` descending. Drafts are never syndicated. The feed is empty-
// safe: until Post 1 ships (T38.6) the published set is honestly EMPTY, so the
// channel renders with zero <item>s rather than faking a post.
//
// Channel metadata is sourced from the canonical site config: `context.site` is
// the `site` value from astro.config.mjs (https://kazi.sire.run, ADR-0018), so
// the feed link and per-item permalinks can never drift from the deployed host.
import rss from "@astrojs/rss";
import { getCollection } from "astro:content";

export async function GET(context) {
  // Published posts only, newest first (mirrors the index route filter/order).
  const posts = (await getCollection("blog", ({ data }) => !data.draft)).sort(
    (a, b) => b.data.date.valueOf() - a.data.date.valueOf(),
  );

  return rss({
    title: "The kazi blog",
    description:
      "Hands-on writing about driving coding agents to an objective definition of done — a ladder from vibe coding to a reconciliation workflow.",
    // `context.site` is astro.config's `site` (https://kazi.sire.run).
    site: context.site,
    items: posts.map((post) => ({
      title: post.data.title,
      description: post.data.description,
      pubDate: post.data.date,
      // The post permalink mirrors the index/[...slug] route shape (`/blog/<id>`).
      link: `/blog/${post.id}/`,
      categories: post.data.tags,
      author: post.data.author,
    })),
    // A self-describing stylesheet is optional; omit to keep the feed minimal.
  });
}
