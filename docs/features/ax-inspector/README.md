---
description: Hover the live stream in baguette serve to see the AX node under the cursor, lock it, copy its identifier or JSON, or tap its centre. Use when finding a locator or debugging a flaky coordinate tap without writing a test.
---

# Accessibility inspector (browser UI)

Hover over the live stream and see the bounding box, role, label and identifier
of the AX node under the cursor. Click to lock a selection, then copy its
identifier, copy the full node JSON, or tap its centre, all without leaving the
browser. It is the page's counterpart to
[`describe-ui`](../accessibility/README.md)
([commands.md#baguette-describe-ui](../../commands.md#baguette-describe-ui)):
that one is for scripts and agents, this one is for humans asking "why is
`tap(220, 438)` flaky?" or "what's that button's `accessibilityIdentifier`?".

## Quick start

1. `baguette serve`, then open `http://127.0.0.1:8421/simulators`.
2. **Sidebar mode** (`/simulators`): tick the checkbox on the "Accessibility"
   card in the right-hand sidebar; the selection shows inline in that card.
   **Focus mode** (`/devices/<UDID>`): click the inspector icon in the
   toolbar, next to the bezel-actionable toggle; the selection shows in a
   floating panel at the top right of the device column.
3. Hover the screen. **Blue** is the node under the cursor; click to lock it
   (**red**). The two co-exist while you hover around a locked element.
4. Use the selection's actions: copy identifier, copy node JSON, or **Tap**
   (sends a tap at the frame's centre).

Copying an identifier instead of a pixel coordinate gives you a locator that
survives a layout reflow.

## How it stays current

- The tree is fetched, not subscribed: on enable, on each fresh hover
  (`mouseenter` on the screen), and on every click. No polling timer; idling on
  the page costs nothing.
- Moves *within* a hover hit-test the cached tree, so the highlight tracks the
  cursor at frame rate without a round trip.
- The hit-test picks the deepest node whose `frame` contains the point, the
  same algorithm as `baguette describe-ui --x --y`, so the overlay and the CLI
  always agree.
- While the inspector is off, its overlay ignores the mouse: taps and gestures
  behave exactly as before. Switching it on is the only thing that intercepts
  mouse events.

## WebSocket

No new endpoints or connections: the inspector rides the existing stream socket
`WS /simulators/<UDID>/stream`, which already carries binary frames and JSON text.

```json
{ "type": "describe_ui" }
```

```json
{ "type": "describe_ui_result", "ok": true, "tree": { … } }
```

The tree's shape is the one [`describe-ui`](../accessibility/README.md)
returns; frames are in device points. **Tap** sends the ordinary `tap`
envelope at the frame's centre; see [wire.md](../../wire.md).

## Gotchas

- **Snapshot semantics.** Animations and transitions can briefly mismatch the
  highlight and the live pixels; re-hover or click to pull a fresh tree.
- **Frontmost app only**, inherited from `describe-ui`: SpringBoard idle
  returns `null` for some states, and system overlays (Control Centre,
  Notification Centre) aren't exposed.
- **One inspector per stream.** Tearing the stream down detaches the inspector
  and clears the overlay.
- The tooltip paints above the highlighted frame, or below when the node is at
  the very top of the screen.

## See also

[accessibility](../accessibility/README.md) · [AX hit-test sweep](../ax-hit-test-sweep/README.md) ·
[wire.md](../../wire.md)
