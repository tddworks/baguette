# Wire protocol — `baguette input` / WebSocket

Newline-delimited JSON. One gesture per line. `baguette input` writes
`{"ok":true}` or `{"ok":false,"error":"…"}` per line on stdout. The
WebSocket at `/simulators/<udid>/stream` accepts the same dialect.

## The coordinate convention (do not skip)

All `x`, `y`, `startX`, `startY`, `endX`, `endY`, `x1`, `y1`, `x2`, `y2`,
`cx`, `cy` are in **device points** — the same units as the `width` and
`height` you pass on the same line.

`width` and `height` come from `baguette chrome layout --udid <UDID>`'s
`screen.width` / `screen.height`. They are device-specific. Hardcoding
"438×954" only works for iPhone 17 Pro Max.

The wire format is **not normalized**. `x:0.5, y:0.5` will tap pixel
(0, 0) on the device. The HID adapter normalises internally on the
server side; clients always send points.

## Single-tap

```json
{"type":"tap","x":219,"y":478,"width":438,"height":954,"duration":0.05}
```

`duration` is the dwell time in seconds. Default ~0.05 if omitted.

## Swipe (one-shot, server interpolates)

```json
{"type":"swipe","startX":219,"startY":760,"endX":219,"endY":190,
                "width":438,"height":954,"duration":0.3}
```

`duration` is end-to-end. Server interpolates intermediate points; you
do not need to stream `move` events for a one-shot swipe.

## Streaming gestures (phase-driven)

Use these for real-time drags / multi-finger choreography where
intermediate samples come from a UI loop (mouse-move handler, etc.).

### One finger

```json
{"type":"touch1-down","x":219,"y":478,"width":438,"height":954}
{"type":"touch1-move","x":225,"y":485,"width":438,"height":954}
{"type":"touch1-move","x":230,"y":492,"width":438,"height":954}
{"type":"touch1-up",  "x":230,"y":492,"width":438,"height":954}
```

Pair every `down` with an `up`. `move` is optional but typically
streamed at ~60 Hz from the input source.

### Two fingers (the primary pinch / pan path)

```json
{"type":"touch2-down","x1":175,"y1":478,"x2":263,"y2":478,"width":438,"height":954}
{"type":"touch2-move","x1":150,"y1":478,"x2":288,"y2":478,"width":438,"height":954}
{"type":"touch2-up",  "x1":150,"y1":478,"x2":288,"y2":478,"width":438,"height":954}
```

`UIPinchGestureRecognizer` requires two fingers. Single-finger streaming
(`touch1-*`) routes correctly but iOS treats it as an interactive pan,
not a pinch — prefer `touch2-*` for any zoom / rotate scenario.

## One-shot pinch

```json
{"type":"pinch","cx":219,"cy":478,
                "startSpread":60,"endSpread":240,
                "width":438,"height":954,"duration":0.6}
```

`cx`/`cy` is the centre of the pinch in device points. `startSpread` /
`endSpread` are the finger separation in points (60 → 240 = zoom-in).
Server interpolates 10 intermediate two-finger samples over `duration`.

## One-shot parallel pan (two fingers)

```json
{"type":"pan","x1":175,"y1":478,"x2":263,"y2":478,
              "dx":0,"dy":200,
              "width":438,"height":954,"duration":0.5}
```

Both fingers translate by `(dx, dy)` in points over `duration`. Useful
for two-finger scrolling in apps that ignore single-finger pans
(e.g., Maps).

## Scroll wheel

```json
{"type":"scroll","deltaX":0,"deltaY":-50}
```

Negative `deltaY` scrolls content up (same convention as macOS). No
`width` / `height` needed — scroll is target-agnostic.

## Hardware buttons

```json
{"type":"button","button":"home"}
{"type":"button","button":"lock"}
```

Only `home` and `lock` reach a working target on iOS 26.4. Other
button names return `{"ok":false,"error":"…"}`. **Do not propose
`button:"siri"`** — it crashes `backboardd` via every known Indigo
path and is rejected by the CLI before reaching SimulatorHID.

## Not yet wired

- **`key`** (single keycode) — not on host-HID path. Will return
  `{"ok":false,"error":"key: not on Baguette's host-HID path"}`.
- **`type`** (text string) — same. If you need to type into a TextField,
  fall back to `xcrun simctl io <UDID> text "hello"` or use AXe.

If a task requires text input, do not try to use `key` / `type`
through baguette — use the fallback and tell the user about it.

## WebSocket-only verbs (during `baguette serve`)

When connected to `WS /simulators/<UDID>/stream?format=…`, the same
text channel that carries gestures also accepts stream-control verbs:

```json
{"type":"set_bitrate","bps":4000000}     // re-encode target bitrate
{"type":"set_fps","fps":60}              // re-target capture rate
{"type":"set_scale","scale":1}           // 1=full, 2=half, 3=third
{"type":"force_idr"}                     // request a keyframe now
{"type":"snapshot"}                      // request one snapshot frame
```

These do not exist for `baguette input` (no stream there).

## Debugging a "tap missed"

If a tap visibly happens on the wrong spot:

1. Did you pass `width` / `height` from `chrome layout --udid <SAME-UDID>`?
   A tap with the wrong device's dimensions normalises to the wrong fraction.
2. Are coordinates in points, not pixels? iPhone 17 Pro Max screen is
   438×954 points (×3 = 1206×2622 pixels). Pixels overshoot by 3×.
3. Did the app fully load? A tap during a launch animation hits whatever
   was underneath. `sleep 0.5` after navigation is cheap insurance.