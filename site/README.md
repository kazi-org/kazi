# Kazi website

Astro builds this site for https://kazi.sire.run. GitHub Pages deploys changes
under `site/` after they reach `main`; the existing Pages workflow owns the
custom domain and publication.

## Landing page

`src/pages/index.astro` contains the landing page copy. It uses
`src/layouts/LandingLayout.astro` for canonical URLs, social metadata, and the
existing config-gated analytics component. The blog and proof gallery retain
their existing shared layout and routes.

The landing page is static HTML with CSS and vanilla JavaScript in
`public/landing/`. Its appearance follows `prefers-color-scheme`, including
live device-setting changes, without a stored theme override. Reduced-motion
preferences hide and pause the decorative video. The video can also be paused
manually. A local Geist Pixel Circle font (self-hosted; no third-party font
mirror) backs the display headings.

Shared product terminology and the installation command remain imported from
`src/canonical.mjs`. The release label comes from the release manifest through
the existing Astro configuration.

## Validate

```sh
npm ci
npm run check:coherence
BLOCKING=1 npm run check:commands
npm run build
npx playwright install chromium
npm test
```

The smoke tests cover installation, clipboard behavior, mobile navigation,
automatic light/dark changes, reduced motion, metadata, and the proof gallery.
Optional external font/video requests are stubbed in landing-page tests so CDN
availability does not determine application correctness. Local assets and all
blog tests remain real.
