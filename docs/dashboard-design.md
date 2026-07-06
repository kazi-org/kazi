# Dashboard visual design spec — the starmap look (ADR-0057)

The committed, textual distillation of the approved dashboard design. The
dashboard's LiveViews are styled to THIS spec; a change of visual direction
edits this file first. (The originating design mockups live outside the repo;
this document is self-contained on purpose.)

## Design tokens (CSS custom properties, exact)

```css
:root {
  --bg:   #070B16;  /* void background */
  --rail: #0A1120;  /* left rail */
  --line: #16233A;  /* hairlines / borders */
  --txt:  #BFD2EA;  /* primary text */
  --dim:  #46587A;  /* secondary text / labels */
  --cyn:  #56CCF2;  /* converging / active / accent */
  --grn:  #2EE6A8;  /* landed / live */
  --red:  #FF5C6C;  /* stuck / errors */
  --amb:  #FFB454;  /* stale / budget warnings */
}
```

Typography: body 12px "JetBrains Mono" (mono everywhere); display headings
"Space Grotesk" 700 (wordmark 16px letter-spacing .2em; panel title 21px).
Section labels: 9px, letter-spacing .26–.28em, --dim, uppercase.

## Layout shell

- `.shell` flex, min-height 100vh.
- Left rail: 280px fixed, bg --rail, right hairline --line; sections in order:
  wordmark ("KAZI STARMAP", STARMAP in --cyn) + LIVE badge (green pulsing dot,
  box-shadow glow); FLEET stat tiles (big 20px numbers: cyan RUNNING, green
  LANDED, red STUCK); NEEDS YOU (attention queue: glowing 7px dot red/amber +
  one-line summary, bold goal name); SESSIONS (S1..Sn chips, cyan border —
  red variant for a stuck session's chip); a dashed-border hint box; LEGEND
  pinned to bottom (six state dots, see zoo).
- Canvas: flex-1, starfield via layered 1px radial-gradients; a slow conic
  "radar sweep" overlay (18s rotate, cyan 5% alpha) behind the SVG.
- SVG DAG (viewBox ~1160x742): alternating vertical wave bands (band-a fill
  rgba(86,204,242,0.028), band-b transparent), dashed band separators
  (stroke rgba(22,35,58,0.8), dasharray 2 6), wave labels top-center per band
  (10px, letter-spacing .32em, fill #3D4F6E): "WAVE N · LANDED/ACTIVE/
  FRONTIER/HORIZON".
- Edges: 1.5px, #152840; edges on the active path: rgba(86,204,242,0.5).
- Event river: fixed 38px bottom bar (rgba(10,17,32,.92), top hairline),
  "EVENT RIVER" label + masked marquee ticker (52s linear scroll, duplicated
  span for seamless loop), entries `[HH:MM:SS] goal · event`.


## Canvas composition (NORMATIVE — the part that makes it a starmap)

The main content area is ONE full-height SVG constellation, not a list:

- **Every registered run renders as an SVG `<circle>` node ON the canvas**
  (r=13; pending r=10), carrying its `nd-*` state class, with its goal name
  as a `<text>` label beneath (12px bold #D7E4F4) and a state sublabel under
  that (8px, letter-spacing .22em, state-colored): "LANDED · vX.Y.Z",
  "ITER n · k/m GREEN", "STUCK · ITER n", "STALE · NO HEARTBEAT nm".
  There is NO chip/pill list of runs anywhere on the page — the circles ARE
  the fleet view. Active (converging/stuck) nodes get the pulse `.ring`
  circle behind them and a session tag (`.stag`, S-number) at the upper
  right.
- **Nodes are laid out in vertical wave-band columns** spanning the full
  canvas height: alternating band fills (band-a rgba(86,204,242,0.028) /
  band-b transparent), dashed separators, and a top-center `.wlabel` per
  band ("WAVE N · LANDED / ACTIVE / FRONTIER / HORIZON"). With a roadmap
  goal-file, bands = its --explain frontiers and nodes = its groups (runs
  attach to their group's node); without one, bands derive from run state
  (landed | active | stuck/stale | horizon). Within a band, nodes distribute
  vertically with even spacing.
- **`needs` edges** draw as 1.5px lines (#152840; rgba(86,204,242,0.5) when
  either endpoint is active) between group nodes.
- **The event river is a 38px bottom bar ON the starmap page** (rgba(10,17,32,.92),
  top hairline): "EVENT RIVER" label + a masked, seamlessly-looping ticker of
  the newest events ("[HH:MM:SS] goal · event"), duplicated span, 52s scroll
  (reduced-motion-gated). The /events page remains the full feed.
- Overflow rule: the canvas shows the most recent ~24 runs as nodes (newest
  heartbeats first); a single dim `.wlabel`-style count ("+N older") links to
  the full registry list on /goals. Fleet counts stay in the rail tiles.

## Node state zoo (SVG circles r=13; pending r=10)

| state      | class       | fill      | stroke                    | extra |
|------------|-------------|-----------|---------------------------|-------|
| landed     | .nd-landed  | --grn     | none                      | drop-shadow 0 0 8px rgba(46,230,168,.65) |
| converging | .nd-conv    | #0A1526   | --cyn 2px                 | glow rgba(86,204,242,.55) + pulse ring |
| stuck      | .nd-stuck   | #160D14   | --red 2px                 | glow rgba(255,92,108,.65) + FAST pulse ring |
| claimed    | .nd-claimed | #0B1424   | --cyn 1.5px dash 4 4      | opacity .85 |
| pending    | .nd-pending | #0D1626   | #223350 1.5px             | r=10, dim sublabel |
| stale      | .nd-stale   | #141118   | --amb 1.5px dot 2 4       | glow rgba(255,180,84,.35) |

Pulse ring `.ring`: r=14 cyan 1.5px, scale 1→1.7 fade-out 2.6s infinite;
`.ring.redr` same at 1.4s (urgency). Selection ring `.selring`: #EAF6FF
dasharray 3 5 slow-spin 9s. Node label 12px bold #D7E4F4 below node; sublabel
8px letter-spacing .22em colored by state (g/c/r/a/d classes), e.g.
"LANDED · v1.68.0", "ITER 4 · 5/8 GREEN", "STUCK · ITER 9",
"CLAIMED · NEXT", "PENDING · NEEDS 3", "STALE · NO HEARTBEAT 4m".
Session tag `.stag` next to active nodes: S-number, 10px bold cyan (red when
that session drives a stuck goal).

## Slide-over drill-in panel (click node or attention entry)

470px right slide-over, rgba(9,15,28,.97), cyan-tinted left hairline,
-24px 0 60px shadow. Contents top→bottom: goal name (Space Grotesk 21px) +
chips (workspace, harness · model, state pill cyan/red); ITER n + budget
line; burn bar (4px: cyan ok / amber warn ≥~70% / red hot ≥~85%);
PREDICATE VECTOR as DNA strip (15px squares: green glow pass, red glow fail,
#152134 not-evaluated); CONVERGENCE heatmap (predicate rows × iteration
cells, 15x13px, green/red/void — regression flips visible); TRANSCRIPT TAIL
(live or "post-mortem · run ended without terminal status"): message lines
11px --txt, tool calls as bordered pills "▸ Bash mix test" + right-aligned
meta ("0 failures · 14.2s"; red border/meta on failing tool); footer button
"FULL ANALYST VIEW →" (cyan ghost button) linking to the drill-in page.

## Motion (all inside @media (prefers-reduced-motion: no-preference))

sweep rotate 18s linear; ring pulse 2.6s (red 1.4s); livedot opacity pulse
1.6s; ticker translateX -50% 52s linear; selring spin 9s. No motion
otherwise — static styles must read correctly with animations off.

## Mapping to existing views

- StarmapLive: rail + canvas + river (river content from T47.1 events).
- DrillinHeatmapLive: full-page version of the panel heatmap (same cells).
- TranscriptPeekLive: full-page version of the transcript tail (same pills).
- States map: landed→nd-landed, converging→nd-conv, stuck→nd-stuck,
  claimed→nd-claimed, pending→nd-pending, stale→nd-stale (registry states
  already exist; claimed/pending come from the wave-band DAG source).
