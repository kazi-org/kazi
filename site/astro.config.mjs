import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";

// The site is served at the custom domain kazi.sire.run (ADR-0018). `site` is used
// for canonical/OG URLs; `base` stays "/" because the custom domain is the root
// (the default kazi-org.github.io/kazi path is only used before DNS is wired).
export default defineConfig({
  site: "https://kazi.sire.run",
  base: "/",
  vite: {
    plugins: [tailwindcss()],
  },
});
