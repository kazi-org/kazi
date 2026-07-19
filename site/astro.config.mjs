import { readFileSync } from "node:fs";
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import tailwindcss from "@tailwindcss/vite";

// Single source of truth for the displayed version: release-please's manifest at
// the repo root. Read here (config eval, plain Node — resolves relative to this
// file) and injected via Vite `define`, so the hero badge can never drift from
// the actual release (the v0.1.1-while-shipping-0.3.0 bug).
const manifestUrl = new URL("../.release-please-manifest.json", import.meta.url);
const KAZI_VERSION = JSON.parse(readFileSync(manifestUrl, "utf8"))["."];

// The site is served at the custom domain kazi.sire.run (ADR-0018). `site` is used
// for canonical/OG URLs; `base` stays "/" because the custom domain is the root
// (the default kazi-org.github.io/kazi path is only used before DNS is wired).
export default defineConfig({
  site: "https://kazi.sire.run",
  base: "/",
  // @astrojs/sitemap (T38.4) emits sitemap-index.xml + sitemap-0.xml at build,
  // enumerating every static route — including the blog index, the series
  // landing page, and each published post route — so search engines discover the
  // blog. It walks the generated route set, so a new published post is picked up
  // automatically; draft posts emit no route and are therefore absent.
  integrations: [sitemap()],
  vite: {
    plugins: [tailwindcss()],
    define: { __KAZI_VERSION__: JSON.stringify(KAZI_VERSION) },
  },
});
