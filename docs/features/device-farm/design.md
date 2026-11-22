---
description: Why the farm is a thin client over per-device streams, why the focus pane mirrors a tile's canvas instead of moving it or using captureStream, and how bezels stay proportioned. Read before changing the farm page.
---

# Device Farm: design

## Stable catalog identity

The list envelope reads `deviceType.identifier`, `deviceType.productFamily`,
`runtime.identifier` and `runtime.versionString` from each SimDevice. On Xcode
26.6 `productFamily` is a string such as `iPhone`, and `runtime.version` is a
packed integer, so version comparisons use `versionString`. Missing metadata
stays `null`; a family is never derived from the user-editable name. The
line-oriented `list` output keeps its four-field shape.

## Constraint: don't fork the streaming pipeline

Each device's WebSocket already supports per-stream control (`set_bitrate` /
`set_fps` / `set_scale` / `force_idr` / `snapshot`) and gesture dispatch on the
same channel. The farm is a thin client over that: N concurrent sessions, one
focused at a time. The whole server-side delta is two routes (`/farm`,
`/farm/:file`); `WebRoot.data(named:)` learned to resolve nested paths
(`farm/farm.html`) so the bundle's directory structure matches the served URL
structure, with no rewriting or flat-file aliasing.

The page is ES modules, no bundler: `farm.html` loads `farm-app.js`, which
imports the rest. `FarmApp` is the only stateful module; the
view renderers take a host element + a `ctx` and write DOM (no fetches, no
listeners, no global state), so they are re-runnable whenever filter, view,
sort or selection changes. `FarmFilter.apply(devices)` is a pure predicate and
`counts(devices)` feeds the rail's "(N)" badges.

## One tile = one stream session, plus a mirror

A tile owns two canvases:

- **`canvas`**: the stream session's draw target. It lives in its grid host for
  the tile's whole life; re-parented across Grid / Wall / List re-renders, but
  never moved on selection.
- **`mirror`**: a second `<canvas>` redrawn from `canvas` by a
  `requestAnimationFrame` loop doing `drawImage(src, 0, 0)` per tick. Mounted in
  the focus pane while focused; on clear-focus it's detached and the loop stops.

So selection only affects the focus pane: **zero DOM swap in the grid**, no
flash, no orphan moments.

**Dead end: `canvas.captureStream() → <video>`.** In practice `captureStream`
is fragile across browsers: the produced track sometimes stalls silently while
the source canvas keeps drawing. A direct `drawImage` is one bitmap blit, no
autoplay or codec edge cases.

Input is attached to the **mirror** (`MouseGestureSource` + `PinchOverlay`),
not the grid canvas: mouse coords normalise against the listener element's
bounding box, and the focus pane is what the user clicks. `SimInputBridge`,
shared with `page/devices-stream.js`, translates `SimInput`'s dialect to the gesture
wire.

The focus pane's button row maps only `home` and `lock` to device buttons; Vol+,
Vol−, Snap UI and Rotate are in the UI waiting for that mapping.

## Bezel mode

"Show bezels" wraps each tile's canvas in a Baguette SDK `Simulator` instance
(the composition `Baguette.use` returns on the single-device page). On enable,
the farm fetches every booted device's `definition.json` in parallel and caches
it per udid. Each tile mounts `new _Simulator(def, transport).mount(host)` and
grafts its own live canvas in place of the bezel's freshly-minted one, so
bezel, button overlays, screen and keyboard wire up in one call. Grid tiles
detach screen input post-mount (`sim.screen.detach()`) so clicks select the
tile; the focus mirror keeps full input.

The tile wrapper gets explicit pixel `width`/`height` matching the bare
composite's aspect ratio (`def.screen.viewport.width / .height`) while staying
inside the host's box. That keeps every bezel correctly proportioned at any
container size, including squarish devices (Apple Watch), where the original
`max-width: 100%` strategy distorted the screen-area percentages.

## Streaming profiles

THUMB (8 fps, scale 4, 600 kbps) for the fleet and FULL (60 fps, scale 1,
6 Mbps) for the focused device trade fleet bandwidth (N × THUMB) against
focused-device quality (1 × FULL). Both are config dicts in `farm-tile.js`.
The ~16-thumbnail ceiling on lower-end Macs is empirical.
