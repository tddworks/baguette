# Accessibility inspector (browser UI)

Hover over the live stream and see the bounding box, role, label, and
identifier of the AX node under the cursor. Click to lock a selection
and copy its identifier, copy the full node JSON, or send a `tap`
envelope at its centre — all without leaving the browser.

Two surfaces, one inspector:

- **Sidebar mode** — `/simulators` (the list view + click-to-stream).
  An "Accessibility" card in the right-hand sidebar carries a checkbox
  toggle and an inline selection card.
- **Focus mode** — `/simulators/<UDID>` (deep-link / native window).
  A new toolbar icon next to the bezel-actionable toggle drives
  enable/disable; selection details surface in a glass-styled
  floating panel anchored top-right of the device column.

The inspector is the UI counterpart to the
[`describe-ui`](accessibility.md) wire protocol. Where the wire
protocol is for scripts and agents, the inspector is for humans
debugging "why is `tap(220, 438)` flaky?" or "what's the
`accessibilityIdentifier` of that button?" without writing a test.

## Why

Three things kept coming up:

- **Coordinates without a stopwatch.** Pixel-coord taps in
  test/demo flows broke whenever a layout reflowed. Inspecting an
  element in-browser and copying its identifier produces a
  layout-resilient locator.
- **Discovery, not just verification.** `describe-ui` returned the
  whole tree; eyeballing 30+ nodes of JSON to find the one button
  that's hidden was painful. Hover hit-testing makes the tree
  navigable visually.
- **Round-trip without re-flow.** Going simulator → screenshot →
  drawing tool → coordinate-by-eye → CLI was slow and broke focus.
  The overlay lets you bounce ideas (tap centre? edge? long-press
  identifier?) without leaving the page.

The constraint: don't disturb the live stream. The inspector reuses
the existing `/simulators/:udid/stream` WebSocket for both directions
(it sends `describe_ui`, receives `describe_ui_result`). No new
endpoints, no extra connections, no polling.

## Surface

```
GET /sim-ax-inspector.js     — AXInspector module (overlay + state machine)
WS  /simulators/:udid/stream — request/response carried over the existing stream socket
```

The stream WS already multiplexes binary video frames + JSON text.
The inspector adds two text envelopes to the existing dialect:

```json
// client → server (request a fresh tree)
{ "type": "describe_ui" }

// server → client (the snapshot)
{ "type": "describe_ui_result", "ok": true, "tree": { … } }
```

Wire shape mirrors [`accessibility.md`](accessibility.md) exactly —
the inspector is just the first first-class consumer.

## Pipeline

```
mouse hover     ↓                                       ┌──────────────┐
on overlay      ↓     hit-test cached tree, draw        │ stream WS    │
                ↓     blue highlight + tooltip          │ (binary +    │
                                                        │  JSON text)  │
mouseenter      ↓     send describe_ui (fresh hover)  ──┤              │
                                                        │              │
click           ↓     lock selection (red highlight),   │              │
                ↓     render Tap / Copy actions,        │              │
                ↓     send describe_ui (refresh)      ──┤              │
                                                        │              │
tap button      ↓     send tap{x, y, width, height}   ──┤              │
                                                        └──────────────┘
```

The tree is cached client-side between fetches. Hit-testing runs
against the cache on every `mousemove`, so the highlight tracks
the cursor at frame rate without round-tripping. Each fresh hover
(`mouseenter` on the screen) and every click trigger a new
`describe_ui` so the cache stays current with the simulator's
state without polling.

## Coordinate handling

The AX tree's `frame` is in **device points**, the same unit as the
gesture wire (`tap`, `swipe`). The inspector:

1. Reads the streamed canvas's CSS bounding box.
2. Maps the cursor's screen-space `(clientX, clientY)` to a fractional
   `(fx, fy)` within that box.
3. Multiplies by the chrome layout's screen size (from
   `chrome.json`) to get device-point coordinates.
4. Recurses into the cached tree picking the deepest node whose
   `frame` contains the point — same algorithm as
   [`AXNode.hitTest`](../../Sources/Baguette/Domain/Accessibility/AXNode.swift)
   on the Swift side, so the browser overlay and the
   `--x --y` CLI hit-test always agree.

The "Tap" button forwards the centre of the locked selection's frame
back through the same WS as a `{"type":"tap","x":…,"y":…,"width":…,"height":…}`
envelope — the canonical
[`Tap`](../../Sources/Baguette/Domain/Input/Tap.swift) gesture, no
indirection.

## UX notes worth pinning down

- **`pointer-events:none` when disabled.** The overlay canvas always
  occupies the screen rect, but is non-interactive until the toggle
  is on. Taps and gestures behave exactly as before; switching the
  inspector on is the only thing that intercepts mouse events.
- **No polling timer.** The tree refresh fires only on `enable`,
  `mouseenter`, and `click`. Idling on the page costs nothing.
- **Per-hover refresh.** Each fresh `mouseenter` over the screen
  treats the inspection as a new session; the tree is re-fetched so
  the user always sees current state. Moves *within* a hover use the
  cached tree.
- **Two visual layers.** Blue is the live hover hit-test result;
  red is the click-locked selection. They co-exist while the user
  hovers around a locked element.
- **Tooltip placement.** The text label paints above the highlighted
  frame, falling back to below when the node is at the very top of
  the screen. Horizontal placement clamps to the canvas edges so
  long labels don't overflow.

## Known limits

- **Snapshot semantics.** The tree is fetched, not subscribed.
  Animations and transitions in the simulator can briefly mismatch
  the highlight and the live pixels — a re-hover (or a click) pulls
  a fresh tree.
- **Frontmost-app only.** Inherited from `describe-ui`: SpringBoard
  idle returns `null` for some states; AXP doesn't expose system-
  level overlays (Control Centre, Notification Centre).
- **One inspector per stream.** Sidebar mode mounts one against the
  active stream; focus mode mounts one against its session. Tearing
  the stream down detaches the inspector and clears the overlay.

## Further reading

- [`accessibility.md`](accessibility.md) — the wire protocol the
  inspector consumes (`describe_ui` / `describe_ui_result`).
- [`Sources/Baguette/Resources/Web/sim-ax-inspector.js`](../../Sources/Baguette/Resources/Web/sim-ax-inspector.js)
  — module source, including the static
  `AXInspector.renderSelectionInto(host, node, ctx)` helper that
  both modes share.
- [`Sources/Baguette/Domain/Accessibility/AXNode.swift`](../../Sources/Baguette/Domain/Accessibility/AXNode.swift)
  — `hitTest` algorithm the JS overlay mirrors.
