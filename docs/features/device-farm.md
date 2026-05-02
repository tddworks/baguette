# Device Farm

Multi-device dashboard for the iOS Simulator. One browser tab shows
every booted simulator, with click-to-focus, gesture input on the
selected device, and Grid / Wall / List view modes.

Lives at `GET /farm` under `baguette serve`.

If you want the end-to-end tap-to-`UITouch` story, read
[`../ARCHITECTURE.md`](../ARCHITECTURE.md). This doc is scoped to the
farm feature itself — what the UI does, why it's split the way it is,
and the few non-obvious decisions worth pinning down.

## Why

A single-device stream page (`/simulators/<udid>`) was already in
place. Two real workflows pushed for a fleet view:

- **Multi-device QA** — eyeball the same screen across iOS 18.2,
  iOS 26.0, iPad, and Watch at once during a localization or
  regression sweep.
- **Demos / device-farm style hosting** — share one URL and let a
  reviewer pick a device, drive it, and move on without fishing for
  UDIDs.

The constraint was strict: don't fork the streaming pipeline. Each
device's WebSocket already supports per-stream control
(`set_bitrate` / `set_fps` / `set_scale` / `force_idr` / `snapshot`)
and gesture dispatch on the same channel. A farm view is a thin
client over that — N concurrent sessions, one focused at a time.

## Surface

```
GET /farm                 → farm/farm.html (shell)
GET /farm/:file           → farm/<file>    (CSS + per-component JS)
```

Only two new server routes; the resource bundle gained a `farm/`
subfolder. Everything else (per-device WS, lifecycle POSTs, chrome
JSON, bezel PNG) is the same surface the single-device page uses.

`WebRoot.data(named:)` learned to resolve nested paths
(`farm/farm.html`) so the bundle's directory structure matches the
served URL structure — no rewriting, no flat-file aliasing.

## Page layout

```
┌─ HEADER ──────────────────────────────────────────────────────────┐
│ Baguette / DEVICE FARM   FLEET · FPS · BANDWIDTH · LATENCY · CLOCK│
├──────────┬───────────────────────────────────────────┬────────────┤
│  RAIL    │  GRID / WALL / LIST                       │ FOCUS PANE │
│          │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐      │ big preview│
│ Platform │  │  📱  │ │  📱  │ │  📱  │ │  ⌚  │      │            │
│ Runtime  │  └──────┘ └──────┘ └──────┘ └──────┘      │  TELEMETRY │
│ Status   │  ┌──────┐ ┌──────┐                        │            │
│ Display  │  │  📱  │ │  📱  │                        │  CONTROLS  │
│ Bulk     │  └──────┘ └──────┘                        │  GESTURE   │
└──────────┴───────────────────────────────────────────┴────────────┘
└─ CLI MIRROR: baguette serve --platform … --runtime … --focus <udid> ┘
```

Three columns, one main row, plus header + footer. The CLI mirror
footer reflects the current filter / focus state as a Baguette
invocation — useful for copy-paste reproduction.

## Frontend split

`Resources/Web/farm/` mirrors the IIFE-on-`window` pattern the
single-device page already uses. No bundler, no module graph;
`<script>` tags load in dependency order.

```
farm.html         shell — loads scripts in order
farm.css          design tokens + Grid / Wall / List + focus styles

farm-views.js     pure DOM renderers (one fn per view + sub-region)
farm-tile.js      FarmTile: per-device StreamSession + canvas + mirror
farm-focus.js     FarmFocus: focus-pane chrome (telemetry, controls)
farm-filter.js    FarmFilter: facet state + predicate (extractable)
farm-app.js       FarmApp: orchestrator (boot, render, dispatch)
```

Each script hangs one class on `window`. `farm-app.js` is the only
stateful module; everything else is pure functions or per-device
classes.

### View renderers are pure

`farm-views.js` exports `renderHeader`, `renderRail`, `renderGrid`,
`renderWall`, `renderList`, etc. Each takes a host element + a
`ctx` object and writes DOM. No fetches, no listeners, no global
state. `FarmApp` re-runs them when filter / view / sort / selection
changes — the renderers stay re-runnable and trivially diff-testable.

### One tile = one StreamSession

`FarmTile` owns:

- **`canvas`** — the `StreamSession`'s draw target. Lives in its
  grid host for the entire life of the tile. Re-parented across
  Grid / Wall / List re-renders by `attach(host, opts)`, but never
  moved on selection.
- **`mirror`** — a second `<canvas>` redrawn from `canvas` via a
  `requestAnimationFrame` copy loop. Mounted in the focus pane
  while focused. Uses `drawImage(src, 0, 0)` per tick — deterministic
  bitmap blit, no `captureStream` fragility.

That split means selection only affects the focus pane:

- The grid tile keeps its canvas painting in place. **Zero DOM swap
  in the grid on selection** — no flash, no orphan moments.
- The focus pane mounts the mirror, starts the copy loop, runs at
  full quality. On clear-focus, the mirror is detached and the rAF
  loop stops.

Why a copy-canvas instead of `canvas.captureStream() → <video>`? In
practice `captureStream` is fragile across browsers — the produced
track sometimes stalls silently while the source canvas keeps
drawing. A direct `drawImage` is one bitmap blit, no autoplay or
codec edge cases, and easy to reason about.

### Bezel mode

A "Show bezels" toggle in the rail wraps each tile's canvas in
`DeviceFrame` (the same module sim-stream uses). On enable, FarmApp
fetches every booted device's `chrome.json` in parallel and caches
the layouts in a `Map<udid, layout>`.

`FarmTile._mountIn` carries a fit-inside computation: the wrapper
gets explicit pixel `width`/`height` matching the chrome composite's
aspect ratio while staying inside the host's bounding box. That
keeps every device's bezel correctly proportioned regardless of
container size — including the squarish ones (Apple Watch) where
the original `max-width: 100%` strategy distorted screen-area
percentages.

### Gesture input

`SimInputBridge` is a small shared module (under `Resources/Web/`)
that translates `SimInput`'s asc-cli plugin dialect to Baguette's
GestureRegistry wire format. Both `sim-stream.js` and `farm-tile.js`
use it.

When a tile is focused, `FarmTile.wireInput()` attaches a
`MouseGestureSource` + a `PinchOverlay` to the **mirror canvas in
the focus pane** (not the grid canvas). Mouse coords normalize
against the listener element's bounding box, so the focus pane is
the right target — that's the one the user clicks.

Modifiers mirror sim-stream:

- no modifier → 1-finger tap / swipe
- ⌥ + drag → 2-finger pinch (mirrored through screen center)
- ⌥ + ⇧ + drag → 2-finger parallel pan
- ⌃ + wheel / Safari `gesture*` → pinch stream

Only `home` and `lock` round-trip cleanly today (per `Press.swift`);
the focus pane wires the rest of the hardware-button row
(Vol+, Vol−, Snap UI, Rotate) so they activate as soon as
`DeviceButton` is widened in Domain.

## Streaming policy

Each booted device runs one MJPEG stream over the existing per-device
WebSocket. Two profiles:

| profile | fps | scale | bitrate |
| ------- | ---:| -----:| -------:|
| THUMB   | 8   | 4     | 600 kbps |
| FULL    | 60  | 1     | 6 Mbps  |

Selecting a tile sends the FULL config; clearing focus drops back to
THUMB. Both go over the standard `set_fps` / `set_scale` /
`set_bitrate` reconfig protocol — no new endpoints.

This is a pragmatic tradeoff between fleet bandwidth (N devices ×
THUMB) and focused-device quality (1 × FULL). It can be tuned in
`farm-tile.js` by changing the two config dicts.

## View modes

- **Grid** — primary view. Cards with bezel + status pip + readout.
  Fixed-height (`320px`) screen container, bezel sized to fit so
  rows align across mixed device shapes.
- **Wall** — uniform 3:4 monitor-wall panels. Top strip carries
  status pip + channel; bottom strip carries device name + FPS.
  Bezel optional (honors global toggle).
- **List** — dense data table. Click-to-sort columns, inline
  sparkline-ready FPS column, hover-revealed quick actions.

Switching views re-runs the renderers and reparents tile canvases
into whichever new screen-host elements got rendered. The streaming
pipeline is undisturbed.

## Filtering

`FarmFilter` (in `farm-filter.js`) owns four facets:

- **platforms**: `iphone` / `ipad` / `watch` / `tv` (inferred from
  device name)
- **runtimes**: discovered from `/simulators.json`, seeded into the
  filter as devices arrive
- **states**: `live` / `boot` / `idle` / `off` / `error` (mapped
  from CoreSimulator state strings)
- **search**: free-text over name + UDID + runtime + platform

`apply(devices)` is a pure predicate; counts come from `counts(devices)`
for the rail's "(N)" badges. The class is small, dependency-free,
and unit-testable in isolation.

## Bulk actions

The rail has four bulk buttons: Boot Filtered, Snapshot All, Reset
Streams, Shutdown Filtered. They fan out per-device POSTs against
the existing `/simulators/<udid>/boot|shutdown` endpoints (no new
bulk endpoints yet). After a boot/shutdown cycle, FarmApp refetches
`/simulators.json` and starts/stops tiles to match.

## Telemetry

Per-tile FPS comes from `StreamSession.onFps`. `FarmApp` rolls them
up into the header's "Aggregate FPS" stat. Other header stats
(bandwidth, P50 latency) are placeholders today — wiring them
needs server-side instrumentation that doesn't yet exist.

The focus pane's gauges (FPS, Latency P95, Bitrate, Memory) are
similarly partial — FPS is real; the rest are display-only until
the server reports them.

## Known limits

- **Concurrency cap is empirical.** Streaming N MJPEG decoders at
  60 fps is fine; at 8 fps it's cheaper, but past ~16 simultaneous
  thumbs the browser starts dropping rAF ticks on lower-end Macs.
  No automatic backpressure today.
- **Bulk endpoints don't exist yet.** Bulk actions are client-side
  fan-outs; if 30 devices boot at once they'll all serialize through
  the framework warm-up.
- **Saved layouts / persistent groups** aren't built. The "Groups"
  section in the rail is a static placeholder.
- **Aggregate telemetry is partial** (see above).

## Surface deltas vs. single-device page

| concern              | `/simulators/<udid>`   | `/farm`                       |
| -------------------- | ---------------------- | ----------------------------- |
| streams per page     | 1                      | N (one per booted device)     |
| stream profile       | full quality           | thumb (fleet) + full (focus)  |
| input target         | the canvas             | the mirror (in focus pane)    |
| selection effect     | n/a                    | mirror swap + input wire only |
| bezel toggle         | always on              | rail toggle                   |

Both pages share `sim-input.js`, `sim-input-bridge.js`,
`stream-session.js`, `frame-decoder.js`, `device-frame.js`. The
farm page adds five files in `Resources/Web/farm/` and two server
routes — that's the entire delta.

## Extension points

- **New view mode**: add a renderer in `farm-views.js` and a case in
  `FarmApp.render()`. Tiles attach to `[data-screen-host]` regardless
  of markup.
- **New filter facet**: add a `Set` to `FarmFilter` and a UI section
  in `renderRail`. The predicate already pattern-matches on
  `filter[facet]` lookups.
- **New per-device action**: wire it on the focus pane preset row
  and forward to `FarmTile`. Gesture-shaped actions can land in
  `Domain/Input/`; stream-control verbs ride the existing reconfig
  protocol.
- **New bulk operation**: extend `FarmApp.runBulk()` and the rail's
  `[data-bulk]` button row.

## Testing approach

The frontend is currently exercised manually via the live UI; a
later iteration could add a thin DOM test harness around
`farm-views.js` (pure renderers, easy to fake state).

The new server routes have a Swift Testing suite at
`Tests/BaguetteTests/Server/WebRootSubdirTests.swift` covering the
nested-path lookup `WebRoot` learned. Higher-level routing tests
would benefit from a Hummingbird router fixture — not yet in the
repo.
