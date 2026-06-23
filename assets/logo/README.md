# kazi logo

The mark is a **reconcile loop converging to a checkmark**: an open ring (the
control loop — observe, diff, dispatch, re-observe) wrapped around a bold check
(predicates become *objectively true*). The color is the green of a passing
check, because turning checks green is literally what kazi does.

## Files

| File | Use |
|------|-----|
| `kazi-mark.svg` | Icon only (emerald). Primary mark. |
| `kazi-mark-mono.svg` | Icon in `currentColor` — inherits the surrounding text color for light/dark themes. |
| `kazi-wordmark.svg` | Mark + "kazi" wordmark, for light backgrounds. |
| `kazi-wordmark-dark.svg` | Wordmark for dark backgrounds. |
| `kazi-badge.svg` | Rounded-square app icon / favicon / avatar (emerald mark on slate). |

## Colors

- **Emerald** `#10B981` — the mark ("converged / green").
- **Slate ink** `#0F172A` — wordmark text on light; badge background.
- **Slate-100** `#F1F5F9` — wordmark text on dark.

## Notes

- SVG is the source of truth; rasterize as needed (e.g. `rsvg-convert -w 512
  kazi-badge.svg -o icon.png`).
- The wordmarks use a system geometric-sans font stack as a faithful stand-in.
  For a final brand wordmark, outline the text to paths so it renders identically
  on every machine regardless of installed fonts.
