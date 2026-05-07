# Wire protocol — `baguette input` / `baguette mac input` / WebSocket

Newline-delimited JSON. One gesture per line. `baguette input` /
`baguette mac input` writes `{"ok":true}` or `{"ok":false,"error":"…"}`
per line on stdout. The WebSockets at `/simulators/<udid>/stream` and
`/mac/<bundleID>/stream` accept the **same dialect**, so a single
`{"type":"tap","x":…}` envelope works against both targets.

Tree differences are explained in the "Wire protocol on macOS" section
near the bottom — the short version: gestures that only make sense on
iOS hardware (`button`, `touch1`, `touch2`, `pinch`, `pan`,
`twoFingerPath`) are rejected on the mac path with `{"ok":false}`, and
coordinates are window-relative on macOS instead of device-relative.

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
{"type":"button","button":"power"}
{"type":"button","button":"volume-up"}
{"type":"button","button":"volume-down"}
{"type":"button","button":"action","duration":1.2}
```

Allowed names: `home | lock | power | volume-up | volume-down | action`.
`duration` is the optional hold time in seconds — `0`/absent → ~100 ms
short tap; longer holds drive iOS long-press semantics ("Hold for
Ring" on `action`, Siri / SOS on `power`, etc.). The browser bezel
overlay measures real `mousedown` → `mouseup` and forwards the
elapsed time, so click-and-hold on a side button just works.

**Do not propose `button:"siri"`** — it crashes `backboardd` via
every known Indigo path and is rejected by the CLI before reaching
SimulatorHID.

## Keyboard

### Single keystroke

```json
{"type":"key","code":"KeyA"}
{"type":"key","code":"KeyA","modifiers":["shift"]}
{"type":"key","code":"KeyA","modifiers":["shift","command"],"duration":0.2}
{"type":"key","code":"Enter"}
```

`code` is a W3C `KeyboardEvent.code`. Supported set: `KeyA`–`KeyZ`,
`Digit0`–`Digit9`, `Enter`, `Escape`, `Backspace`, `Tab`, `Space`,
`ArrowUp`/`Down`/`Left`/`Right`, US punctuation (`Minus`, `Equal`,
`BracketLeft/Right`, `Backslash`, `Semicolon`, `Quote`, `Backquote`,
`Comma`, `Period`, `Slash`). Modifiers: `shift`, `control`, `option`,
`command`. Unknown codes / modifiers fail the parse with
`{"ok":false,"error":"…"}`.

### Typed text

```json
{"type":"type","text":"hello world"}
{"type":"type","text":"Login: alice@example.com"}
```

Decomposed at parse time into the same `(KeyboardKey, modifiers)`
pairs the wire `key` shape uses, then dispatched in order. **US ASCII
printable only** — non-ASCII (`é`, `中`, `🦄`) fails the parse rather
than silently dropping mid-string.

**Phase-1 limits:** no IME / Pinyin / dead keys / emoji / non-Latin
scripts — those need `IndigoHIDMessageForKeyboardNSEvent` (phase 2).
For non-ASCII text, fall back to `xcrun simctl io <UDID> text "…"`.

## WebSocket-only verbs (during `baguette serve`)

When connected to `WS /simulators/<UDID>/stream?format=…`, the same
text channel that carries gestures also accepts stream-control verbs:

```json
{"type":"set_bitrate","bps":4000000}     // re-encode target bitrate
{"type":"set_fps","fps":60}              // re-target capture rate
{"type":"set_scale","scale":1}           // 1=full, 2=half, 3=third
{"type":"force_idr"}                     // request a keyframe now
{"type":"snapshot"}                      // request one snapshot frame
{"type":"describe_ui"}                   // dump the AX tree (frontmost app)
{"type":"describe_ui","x":172,"y":880}   // hit-test the topmost AX node at a point
{"type":"stop"}                          // terminate a /logs subscription early (sent on the logs socket)
```

`describe_ui` replies on the same socket with one text frame:

```json
{ "type": "describe_ui_result", "ok": true, "tree": { /* AXNode */ } }
{ "type": "describe_ui_result", "ok": false, "error": "no accessibility data" }
```

Each `AXNode` carries `role`, `subrole`, `label`, `value`,
`identifier`, `title`, `help`, `frame` (in **device points**, same
units as `tap` / `swipe`), `enabled` / `focused` / `hidden`, and a
recursive `children` array. Use it as the structured-context
counterpart to `screenshot.jpg` — pair the screenshot with the
tree, or skip the image and act on the labels and frames directly.

These do not exist for `baguette input` (no stream there).

## Logs WebSocket — `WS /simulators/<UDID>/logs`

Dedicated socket for the live unified-log feed. Filter is fixed at
connect time via query string (`level`, `style`, `predicate`,
`bundleId`); restart the socket to change it.

Server → client text frames:

```json
{"type":"log_started"}
{"type":"log","line":"2026-05-06 11:56:13.835 Df locationd[5526:…] @ClxSimulated, Fix, …"}
{"type":"log_stopped","reason":"client closed"}
```

Client → server: `{"type":"stop"}` terminates early; otherwise the
socket runs until the simulator dies or the client closes. Levels:
**`default | info | debug` only** — the iOS-runtime `log` binary
rejects `notice / error / fault` (host macOS supports them; the
simulator's slimmer interface does not). For higher-severity-only
filtering, use `predicate=messageType == "error"`.

## Wire protocol on macOS — `baguette mac input` / `WS /mac/<bundleID>/stream`

Same envelopes — different coordinate space and different reject set.

### Coordinate space — window-relative, not device-relative

`x, y, startX, startY, endX, endY, x1, y1, x2, y2, cx, cy` are in
points **relative to the target app's frontmost window content rect**
(top-left = `(0, 0)`). `width` / `height` come from the AXWindow
root's `frame` field (read with `baguette mac describe-ui`).

The adapter resolves the window's screen-global origin via AX once
per gesture and adds it to the wire point before posting the
`CGEvent`, so the user dragging the window mid-session stays correct.

```bash
# Get target dimensions.
W=$(baguette mac describe-ui --bundle-id com.apple.TextEdit \
    | jq '.frame.width | floor')
H=$(baguette mac describe-ui --bundle-id com.apple.TextEdit \
    | jq '.frame.height | floor')

# Tap window centre.
echo "{\"type\":\"tap\",\"x\":$((W/2)),\"y\":$((H/2)),\"width\":$W,\"height\":$H}" \
  | baguette mac input --bundle-id com.apple.TextEdit
```

### Rejected verbs (return `{"ok":false}` with a `[mac-input] rejecting:` log line)

These don't apply to macOS apps and the adapter explicitly refuses
them rather than silently mis-dispatching:

| Verb              | Why rejected                                          |
|-------------------|-------------------------------------------------------|
| `button`          | Hardware buttons (`home`, `power`, `volume-*`, `action`) are iOS-only |
| `touch1`          | Multi-touch via `CGEvent` isn't reliable on macOS     |
| `touch2`          | Same                                                  |
| `pinch`           | Implemented as `twoFingerPath` internally → rejected  |
| `pan`             | Same                                                  |
| `twoFingerPath`   | The underlying primitive                              |

`tap`, `swipe`, `scroll`, `key`, `type` work identically to the iOS path.

### Drag-select tuning (real-world tested)

`swipe`'s default duration of 0.25 s is borderline too fast for
macOS drag-to-select. Pass `"duration": 0.5` (or higher) for
reliable text-selection drags, and start the swipe **inside** the
text region:

```json
{"type":"swipe","startX":50,"startY":50,"endX":300,"endY":50,
 "width":1078,"height":679,"duration":0.5}
```

### TCC

`baguette mac input` requires the binary to be in System Settings →
Privacy & Security → **Accessibility**. First run logs:

```
[mac-input] AXIsProcessTrusted=true (events post to other apps require Accessibility grant ...)
```

If `AXIsProcessTrusted=false`, every gesture silently no-ops. Grant
in Privacy & Security and re-run.

## Debugging a "tap missed"

If a tap visibly happens on the wrong spot:

1. Did you pass `width` / `height` from `chrome layout --udid <SAME-UDID>`?
   A tap with the wrong device's dimensions normalises to the wrong fraction.
2. Are coordinates in points, not pixels? iPhone 17 Pro Max screen is
   438×954 points (×3 = 1206×2622 pixels). Pixels overshoot by 3×.
3. Did the app fully load? A tap during a launch animation hits whatever
   was underneath. `sleep 0.5` after navigation is cheap insurance.