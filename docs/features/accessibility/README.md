---
description: Read the frontmost app's accessibility tree — labels, frames in device points, identifiers — or hit-test one point, from the CLI, HTTP or the stream WebSocket. Use to find what to tap without a screenshot.
---

# Accessibility tree

Read the on-screen UI tree (labels, frames, traits, identifiers) of a
booted simulator without taking a screenshot or running a test bundle.
Every flag: [commands.md#baguette-describe-ui](../../commands.md#baguette-describe-ui).

This is the structured-context counterpart to `screenshot.jpg` —
where the screenshot tells an agent *what it looks like*, the AX
tree tells it *what's actually there*: button labels, frame
rectangles in device points, accessibility identifiers, and the
parent / child structure underneath.

## Quick start

```bash
baguette describe-ui --udid <UDID>                       # full tree
baguette describe-ui --udid <UDID> --x 172 --y 880       # the node under one point
baguette describe-ui --udid <UDID> --output tree.json
```

## Workflow: find it, then tap it

A node's `frame` is in **native panel points**, the same space HID input
and the unrotated framebuffer use. The outer result's `screen` reports
`width`, `height` and the observed `orientation` (`portrait`,
`portrait-upside-down`, `landscape-left`, `landscape-right`); take gesture
envelope dimensions from there. Pipe `frame.x + frame.width / 2`,
`frame.y + frame.height / 2` straight back into a `tap` and the touch
lands; never rotate a frame a second time. The application root frame may
cover only part of the screen. Re-read the tree after each gesture — it's
a snapshot.

`screen.target` records the connected `screenId`, the raw `pixelSize` and
the `litPanel` (`primary`, `secondary`, or `null` on a single-panel
device), so a later observation can be compared with this one. The
geometry is read before and after the AX query; a rotation or panel change
in between fails the query instead of returning frames for a screen that
no longer exists. Missing or unknown geometry fails explicitly rather than
assuming a phone-sized portrait panel. On a foldable the observation needs
a fresh hinge sample, which `devicectl` cannot provide for a custom device
set; `describe-ui` on a foldable there reports the display as unavailable
instead of guessing the cover panel.

`baguette input --expected-screen '<screen JSON>'` pins coordinate input to
that observation. The whole `screen` object goes in, `target` included. The
session fails to start when the live screen differs, and every `down` and
`move` re-observes the screen first: different native points, rotation,
pixels or lit panel reject the gesture with `"screen target changed; observe
again before sending new input"`. An envelope that names `width` / `height`
must name the observed native points. A foldable needs a fresh hinge sample
and exactly one framebuffer of the lit panel's size; it never falls back to
the cover panel when the observation fails.

The input process keeps its original HID registration and contact ids. If
the panel changes during a touch, the next `move` fails but `up` still
releases the original contact, so keep the process alive long enough to
read that acknowledgement. A single-panel device re-reads its live screen
properties without spawning `simctl`; a foldable samples the guest hinge,
which is slower. Observation and HID dispatch are separate operations, so
this detects observed changes without making the pair atomic.

## HTTP / WebSocket

On the stream WebSocket (`/simulators/<udid>/stream`, framing in
[wire.md](../../wire.md)):

```json
{ "type": "describe_ui" }
{ "type": "describe_ui", "x": 172, "y": 880 }
```

- No `x` / `y` → full tree of the frontmost application.
- Both `x` and `y` → hit-test: returns the topmost AX node whose
  `frame` contains the point. Coordinates are **device points**,
  same units as the gesture wire (`tap`, `swipe`, `width`,
  `height`).

Reply, on the same socket:

```json
{
  "type": "describe_ui_result",
  "ok": true,
  "tree": {
    "role": "AXButton",
    "subrole": null,
    "label": "Safari",
    "value": null,
    "identifier": "Safari",
    "title": null,
    "help": "Double tap to open",
    "frame": { "x": 136, "y": 844.33, "width": 72, "height": 72 },
    "enabled": true,
    "focused": false,
    "hidden": false,
    "children": []
  }
}
```

`ok: false` with an `error` string when AX isn't available
(framework missing, simulator not booted, no frontmost app, XPC
timeout). The CLI exits non-zero in those cases; the WS message
keeps the socket open and lets the caller try again.

Over HTTP (a trusted browser, or a plugin whose grant carries
`describe-ui`):

```http
GET /simulators/<udid>/describe-ui.json
GET /simulators/<udid>/describe-ui.json?x=172&y=880
```

## Gotchas

- **Container frames do not clip descendants.** A container can have an
  empty or smaller frame while its children remain selectable in the web
  inspector and tree-based hit tests.
- **Tree is a snapshot.** No subscribe / change notifications.
  Callers re-issue `describe_ui` after each gesture.
- **Frontmost-app only.** SpringBoard idle returns `null` for some
  states. Active app is what you get; we don't expose system-level
  overlays (Control Centre, Notification Centre).
- **Group containers occasionally drop children.** Inherited from
  AXP's behaviour on `role=group`; the
  [idb#767](https://github.com/facebook/idb/issues/767) workaround
  is to prefer the `--x --y` hit-test path for elements that don't
  surface in the full tree.
- **Slider / progress values stringify NSNumber.** Anything that
  AXP returns as `NSNumber` for `accessibilityValue` (sliders, page
  pickers) lands in JSON as a stringified number. JSON consumers
  that want to discriminate semantics should check `role`.
- **One XPC handshake per call.** First call after process startup
  pays a ~hundreds-of-ms warm-up while the AX connection comes up;
  subsequent calls reuse it. No connection pool.
- **Status bar and tab-bar items** come from a positional sweep on top
  of the walk, which costs ~1.5–2 s per full tree — see
  [the hit-test sweep](../ax-hit-test-sweep/README.md).

## See also

- [design.md](design.md) — the `AXPTranslator` token-dispatcher recipe and the coordinate projection
- [How `describe-ui` finds every element](../ax-hit-test-sweep/README.md)
- [AX inspector](../ax-inspector/README.md)
