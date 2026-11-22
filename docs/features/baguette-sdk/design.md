---
description: Why the Baguette JS SDK models a simulator as device, parts and behaviours with parts as member fields, and what replaced the page-level transaction scripts.
---

# Baguette JS SDK — design

The SDK replaced the page-level transaction scripts (`bezel-buttons.js`,
`sim-input.js`, `sim-input-bridge.js`) with a thin composition root: consumer
pages call `Baguette.use(...)` and `sim.mount(...)`; everything else is
internal.

## Path

- `Baguette.use` → `GET /simulators/<UDID>/definition.json`, computed in
  Swift (`SimulatorDefinition.compose`) from the device's chrome assets plus
  identity → a JS `Simulator` facade that instantiates one part class per
  present field.
- Each part owns both its rendering and its wire dispatch; one transport
  module is the only code that knows the wire format, and it writes through
  the page-supplied `send`.

## First-principle anchor

A simulator stands in for a physical device. A physical device is composed of
parts. Each part has behaviors. The user interacts with the parts. That's the
whole domain — three nouns: **device**, **parts**, **behaviors**. Different
devices have different parts. iPhone has `screen + buttons + keyboard`. Watch
has `screen + buttons + crown + keyboard`. Apple TV has no
screen-as-input-surface — it has a remote.

The SDK mirrors that shape in both languages: the Swift `Simulator` has
sub-aggregates; the JS `Simulator` has the same sub-objects. Wire envelopes
are a remoting detail, not a domain concern.

## Why this isn't a "data-driven UI"

Earlier proposals shipped a tagged-union "scene with controls[]" and had a
`Mounts[cap.kind]` registry on the JS side that interpreted the data. That was
the **transaction script smell at a different layer** — frontend still had to
know "a `buttons` capability becomes `<button>` overlays, a `crown`
capability becomes a wheel listener."

The current SDK doesn't have a `kind:` switch anywhere. Parts are member
fields; the Simulator constructor instantiates a part class iff the field is
present; each part class owns its rendering AND its wire dispatch. The view
layer asks parts to render themselves; nobody interprets a config. **That's
why the SDK boundary holds across new device families.** A new part is an
optional field on the Swift definition plus one JS part class; consumer
pages, transport and other parts don't change. A new hardware button on
iPhone is data only.

## Migration status

1. **(landed)** SDK skeleton + `/definition.json` route + `/baguette-demo.html` smoke page.
2. **(landed)** Button geometry + transform CSS computed in Swift (anchor switch + mirror formula + image-percent translates).
3. **(landed)** Full gesture interpreter ported into the SDK — drag, pinch, pan, edge-stream, wheel-as-2-finger, Safari gesture events, option-hover preview, touch (iOS WebView).
4. **(landed)** Keyboard part added. W3C-code whitelist consolidated in one file.
5. **(landed)** Cutover of all three consumer pages: `page/devices-stream.js`, `page/device-page.js` (with orientation-aware coord remap at the send boundary), `farm/farm-tile.js` (uses SDK parts à la carte — Transport + Screen + Keyboard — since the tile has its own canvas surface).
6. **(landed)** Deleted: `bezel-buttons.js`, `sim-input.js`, `sim-input-bridge.js`, `device-frame.js`, `keyboard-capture.js`.
7. **(next)** Add a crown part. Apple Watch correctness lands (rotary input, not button).
8. **(eventually)** Add a remote part for Apple TV. Vision Pro adds whatever parts it needs.

The cutover is complete — every browser-side simulator interaction flows
through `Baguette.use({...}).mount(container)` (or, in farm-tile's case,
through the SDK's internal parts assembled by hand).
