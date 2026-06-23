# kazi logo

The mark is a **reconcile loop converging to a checkmark**: an open ring (the
control loop — observe, diff, dispatch, re-observe) wrapped around a bold check
(predicates become *objectively true*). The mark is drawn in a **vibrant
teal → emerald → lime gradient** that sweeps around the loop and into the check —
the color literally progresses toward "green / converged", which is what kazi
does.

## Files

| File | Use |
|------|-----|
| `kazi-mark.svg` | Icon only (emerald). Primary mark. |
| `kazi-mark-mono.svg` | Icon in `currentColor` — inherits the surrounding text color for light/dark themes. |
| `kazi-wordmark.svg` | Mark + "kazi" wordmark, for light backgrounds. |
| `kazi-wordmark-dark.svg` | Wordmark for dark backgrounds. |
| `kazi-badge.svg` | Rounded-square app icon / favicon / avatar (emerald mark on slate). |

## Colors

The mark is a gradient (`id="kaziGrad"`), a diagonal sweep across the loop:

- **Teal** `#2DD4BF` → **Emerald** `#10B981` → **Lime-green** `#4ADE80` — the mark.
  On dark surfaces the start is nudged to emerald `#34D399` for contrast.
- **Slate ink** `#0F172A` — wordmark text on light.
- **Slate-100** `#F1F5F9` — wordmark text on dark.
- **Badge background** — a subtle slate gradient `#1E293B` → `#0F172A` (`id="kaziBg"`).

The single-color `kazi-mark-mono.svg` deliberately stays flat `currentColor` (no
gradient) so it inherits the surrounding text color for light/dark themes.

## Notes

- SVG is the source of truth; rasterize as needed (e.g. `rsvg-convert -w 512
  kazi-badge.svg -o icon.png`).
- The wordmarks use a system geometric-sans font stack as a faithful stand-in.
  For a final brand wordmark, outline the text to paths so it renders identically
  on every machine regardless of installed fonts.
