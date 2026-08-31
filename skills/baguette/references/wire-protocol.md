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

## Double-tap (4 lines, one connection)

There is no `{"type":"double-tap"}` envelope. UIKit's
`UITapGestureRecognizer(numberOfTapsRequired: 2)` and SwiftUI's
`TapGesture(count: 2)` both fire when two `touch1-down`/`touch1-up`
pairs arrive at the same coordinate within ~250 ms, so the existing
streaming primitives already cover this:

```json
{"type":"touch1-down","x":219,"y":478,"width":438,"height":954}
{"type":"touch1-up",  "x":219,"y":478,"width":438,"height":954}
{"type":"touch1-down","x":219,"y":478,"width":438,"height":954}
{"type":"touch1-up",  "x":219,"y":478,"width":438,"height":954}
```

Send all four on **one** connection (one `baguette input` process,
one WS); separate processes spend too long in startup for the
recognizer to aggregate. A known-good cadence is ~80 ms hold per
tap and ~50 ms gap between taps. For a one-shot CLI shape with the
same recipe baked in, use `baguette double-tap` — see
[`docs/features/double-tap.md`](../../../docs/features/double-tap.md).

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

#### Optional `edge` field — system gesture flag

```json
{"type":"touch1-down","x":219,"y":950,"width":438,"height":954,"edge":"bottom"}
{"type":"touch1-move","x":219,"y":700,"width":438,"height":954,"edge":"bottom"}
{"type":"touch1-move","x":219,"y":500,"width":438,"height":954,"edge":"bottom"}
{"type":"touch1-up",  "x":219,"y":500,"width":438,"height":954,"edge":"bottom"}
```

`edge` accepts `bottom` / `top` / `left` / `right`. When set, every
event in the chain is flagged as an `IndigoHIDEdge` system gesture.
`bottom` engages iOS's home-indicator gesture recognizer — fast
swipe → Home, slow drag-and-hold near midpoint → App Switcher,
with iOS animating the live preview as the events stream. Omit
`edge` for ordinary interior touches. See
[`docs/features/touches.md`](../../../docs/features/touches.md) for
the full dispatch recipe.

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
{"type":"button","button":"app-switcher"}
{"type":"button","button":"swipe-to-app-switcher"}
{"type":"button","button":"swipe-to-home"}
{"type":"button","button":"pull-down-to-lock-screen"}
{"type":"button","button":"pull-down-to-notification-center"}
```

Allowed names: `home | lock | power | volume-up | volume-down | action | app-switcher | swipe-to-app-switcher | swipe-to-home | pull-down-to-lock-screen | pull-down-to-notification-center`.
`duration` is the optional hold time in seconds — `0`/absent → ~100 ms
short tap; longer holds drive iOS long-press semantics ("Hold for
Ring" on `action`, Siri / SOS on `power`, etc.). The browser bezel
overlay measures real `mousedown` → `mouseup` and forwards the
elapsed time, so click-and-hold on a side button just works.

`app-switcher`, `swipe-to-app-switcher`, `swipe-to-home`,
`pull-down-to-lock-screen`, and `pull-down-to-notification-center`
are *virtual* buttons. `app-switcher` rides the home-button event
source (two `IndigoHIDMessageForButton` presses ~150 ms apart —
SpringBoard's own multitasking trigger, works on Face ID iPhones);
the other four synthesize canned system-gesture shapes
(slow drag-with-dwell up; fast edge-swipe up; slow drag down from
top-left; slow drag down from top-right). Use them when the agent
wants the gesture vocabulary without managing a streaming
`touch1-*` chain manually.
For live-preview UX, stream `touch1-*` with `edge: "bottom"` (drag
from canvas bottom — iOS animates home / app-switcher preview) or
`edge: "top"` (drag from canvas top — iOS pulls the lock-screen /
notification-center cover sheet) instead — see "One finger" above.

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
For non-ASCII text, use `paste` below.

### Paste (arbitrary unicode via the pasteboard)

```json
{"type":"paste","text":"héllo 🥖 — any unicode"}
{"type":"paste","text":"clipboard only","press":false}
```

Sets the simulator's pasteboard (`simctl pbcopy`, text over stdin),
then presses Cmd+V — the path around `type`'s US-ASCII limit.
`press` (optional, default `true`) — `false` stops after the
pasteboard set, for apps that read `UIPasteboard` directly. Works on
both the stream WS and `baguette input` stdin. On the WS the reply
is a typed text frame:

```json
{ "type": "paste_result", "ok": true }
{ "type": "paste_result", "ok": false, "error": "xcrun simctl pasteboard command exited 1" }
```

On stdin it's the usual one-line `{"ok":…}` ack. Needs a booted
device — a shutdown sim surfaces as a non-zero simctl exit in the
ack.

### Copy (sim selection → host Mac clipboard)

```json
{"type":"copy"}
{"type":"copy","press":false}
```

The interactive mirror of `paste`: presses Cmd+C sim-side (so the
focused field copies its selection into the pasteboard), then ferries
that pasteboard onto the host Mac's clipboard, full-fidelity — images
included (`simctl pbsync <udid> host`). `press` (optional, default
`true`) — `false` skips the keystroke for a pure ferry of whatever the
sim already holds. Works on both the stream WS and `baguette input`
stdin. On the WS the reply is a typed text frame:

```json
{ "type": "copy_result", "ok": true }
{ "type": "copy_result", "ok": false, "error": "xcrun simctl pasteboard command exited 1" }
```

On stdin it's the usual one-line `{"ok":…}` ack. Browser Cmd+C sends
this verb; it targets the clipboard of the machine running baguette
(local-dev happy path — a remote browser lands it on the server's
Mac). A fixed ~200 ms settle sits between the Cmd+C and the pasteboard
read. Needs a booted device.

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

## Interface settings HTTP routes

Appearance / contrast / text size are HTTP, not gesture verbs:

```http
GET  /simulators/<UDID>/interface.json
POST /simulators/<UDID>/interface
Content-Type: application/json
```

```json
{"appearance": "dark", "increaseContrast": "enabled", "contentSize": "increment"}
```

Every field is optional — set one without restating the others. Both the
GET and the POST answer the **resulting** state:

```json
{"appearance": "dark", "contentSize": "extra-large", "increaseContrast": "enabled"}
```

`appearance` is `light | dark`, `increaseContrast` is `enabled |
disabled`, `contentSize` is `increment | decrement` or one of the 12
categories (`extra-small` … `extra-extra-extra-large`, then
`accessibility-medium` … `accessibility-extra-extra-extra-large`).

A **read** may also answer `unknown` (device not booted) or
`unsupported`. Those are states, not errors — and they can't be sent
back as a setting; a body naming one is refused with `400` rather than
half-applied. Plugins need the `interface` capability.

Each setting is its own spawn with no rollback, so a `POST` that breaks
partway says which ones landed rather than implying none did:

```json
{"ok": false, "applied": ["appearance"], "error": "simctlFailed(status: 3)"}
```

`500`; application stops at the first failure. The same `applied` shape
comes back with `200` and `"ok": true` when every setter succeeded but
the read-back afterwards didn't — the change stuck, the resulting state
is just unavailable. A normal success returns the settings themselves
and never an `applied` list.

## Shake HTTP route

Device action, not a gesture verb — fires a UIKit `motionShake` on the
booted simulator's frontmost app:

```http
POST /simulators/<UDID>/shake
```

Response: `{"ok":true}`; `404` unknown udid; `500 shake failed (simctl
error)`. iOS-only. See [`docs/features/shake.md`](../../../docs/features/shake.md).

## Motion HTTP routes

Not a gesture verb, and not a simctl path — CoreMotion reports
unavailable in a stock simulator, so these arm an injected dylib:

```http
POST /simulators/<UDID>/motion
Content-Type: application/json
```

Name the kind outright:

```json
{ "activity": "running", "speed": 3.6, "confidence": "high" }
```

…or send only a speed and let the server classify it:

```json
{ "speed": 6 }
```

Either spelling works: `activity` names the kind
(`stationary|walking|running|cycling|automotive`), or a bare `speed` is
classified server-side — which is what the browser sends, so the activity
bands live in Swift rather than in JS. Response is the current state, the
same shape `GET` returns:

```json
{ "ok": true, "active": true, "activity": "cycling",
  "steps": 24, "metres": 18.0, "speed": 6.00 }
```

`GET /simulators/<UDID>/motion` reads it back (`{"ok":true,"active":false}`
when off); `DELETE` parks the device stationary and disarms. `400` for a
body naming neither activity nor speed, `404` unknown udid, `500` when the
build carries no `VirtualMotion.dylib`.

**Only apps launched after the POST see anything** — dyld inserts at exec
time. Once armed, `POST …/location` drives the activity from the speed it
carries (walk vector, route `speed`, or a bare point → stationary); a
location request never arms motion on its own. See
[`docs/features/motion.md`](../../../docs/features/motion.md).

## 3D render HTTP routes

3D rendering is HTTP, not a WebSocket gesture verb:

```http
GET /simulators/<UDID>/3d-model.json
POST /simulators/<UDID>/render-3d.png
Content-Type: application/json
```

```json
{
  "rotation": {"x": -8, "y": 18, "z": 0},
  "variants": {"finish": "deep-blue"},
  "size": {"width": 1200, "height": 1200},
  "fit": "cover",
  "background": "#eef1f5",
  "screenGlass": false
}
```

The POST response is `image/png`. The GET response exposes only public model
and variant IDs; filesystem paths, download URLs, material names, and USD prim
paths remain server-side.

## Live 3D WebSocket — `WS /simulators/<UDID>/stream.3d.<mjpeg|avcc>`

Same binary-frame stream as `stream.<mjpeg|avcc>`, plus a camera-control text
verb and gestures (dispatched exactly like the 2D stream — same
`GestureDispatcher`/`Input`, device points, no new HID dialect):

```json
{"type":"set_3d_camera","rotation":{"x":-8,"y":32,"z":0},"zoom":1.2}
```
`rotation.x` clamps to `-80…80`, `rotation.y`/`.z` to `-180…180`, `zoom` to
`0.5…3`.

Server → client, sent once on connect and again after every
`set_3d_camera`:

```json
{"type":"screen_quad","corners":[[0.32,0.11],[0.71,0.09],[0.74,0.88],[0.29,0.91]]}
```
`corners` is `[topLeft, topRight, bottomRight, bottomLeft]`, each an
`[x, y]` pair normalized to the rendered output image — where the device
screen mesh lands for the active camera pose. Interact-mode gestures
originating from the browser use this to map a canvas click onto the
correct simulator device point at any rotation, not just Front. See
[`docs/features/3d-rendering.md`](../../../docs/features/3d-rendering.md).

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

## Camera WebSocket — `WS /simulators/<UDID>/camera`

Dedicated socket that drives the virtual-camera feature: baguette
pumps BGRA frames into `/tmp/SimCam.bgra`, where `VirtualCamera.dylib`
(loaded inside the simulator via `DYLD_INSERT_LIBRARIES`) picks them up
and substitutes them for the iOS app's `AVCaptureVideoPreviewLayer` /
`AVCapturePhotoOutput` / `UIImagePickerController` contents. The frame
source is a live Mac webcam, an uploaded still image, or a looping
uploaded video.

Client → server text frames:

```json
{"type":"camera_list"}
{"type":"camera_start","source":"webcam","deviceUID":"0x14600000046d0825","fit":"fit","mirror":false}
{"type":"camera_start","source":"image","fit":"fit","mirror":false}
{"type":"camera_start","source":"video","fit":"fill","mirror":false}
{"type":"camera_stop"}
{"type":"camera_set_flags","fit":"fill","mirror":true}
```

`source` is `"webcam"` (default if omitted) | `"image"` | `"video"`.
`deviceUID` is required for `webcam` and ignored otherwise. For
`image` / `video` there is **no path on the wire** — upload the file
first:

```
POST /simulators/<UDID>/camera-source?name=<filename>   (raw bytes)
  → {"ok":true,"kind":"image"}     # or "video"
```

Accepts `png jpg jpeg gif heic heif` (image) and `mov mp4 m4v`
(video); anything else is `415`, and an unknown `<UDID>` is `404`. The
upload is staged per-udid and replaces any previous one;
`camera_start` then resolves it by `source` kind.

Server → client text frames:

```json
{"type":"camera_devices","devices":[{"uid":"…","name":"FaceTime HD Camera","isDefault":true}]}
{"type":"camera_state","ok":true,"phase":"streaming","fps":29.97,"source":"webcam","device":"0x14600000046d0825"}
{"type":"camera_state","ok":false,"phase":"idle","fps":0,"error":"…"}
```

`camera_devices` lands once on connect, again after every
`camera_list`. `camera_state` lands after every start/stop/set_flags;
`source` names the active producer and `device` is present only for a
webcam. `fit` is one of `"fit"` (letterbox) | `"fill"` (cover with
center-crop). The browser exposes this as the "Camera" card under
`/simulators/<UDID>`'s sidebar. iOS apps launched *before* arming
won't see frames — relaunch them. See
[`docs/features/camera.md`](../../../docs/features/camera.md) for
the full pipeline.

## Debugging a "tap missed"

If a tap visibly happens on the wrong spot:

1. Did you pass `width` / `height` from `chrome layout --udid <SAME-UDID>`?
   A tap with the wrong device's dimensions normalises to the wrong fraction.
2. Are coordinates in points, not pixels? iPhone 17 Pro Max screen is
   438×954 points (×3 = 1206×2622 pixels). Pixels overshoot by 3×.
3. Did the app fully load? A tap during a launch animation hits whatever
   was underneath. `sleep 0.5` after navigation is cheap insurance.

## Device-twin routes — host side only (preview)

`baguette serve` also exposes a physical-device tree, mirroring the
simulator conventions. **No companion app ships yet**, so these routes
answer but nothing populates them — do not propose them for driving a
device today:

- `GET /devices.json` → `{"connected":[{"udid":…,"name":…,"model":…,"capabilities":[…]}]}`
- `WS /devices/companion/video` — the phone-side ingest socket:
  `{"type":"hello","udid":…,"name":…,"model":…,"capabilities":[…]}`,
  then `{"type":"format","width":…,"height":…,"codec":"avcc"}`, then
  binary AVCC-envelope chunks (same 4-byte-length + tag framing as the
  sim AVCC stream).
- `WS /devices/<UDID>/stream?format=mjpeg|avcc` — browser-facing
  mirror; accepts `set_fps` / `set_scale` / `set_bitrate` /
  `force_idr` / `snapshot`; gestures answer
  `{"ok":false,"error":"device control is not wired yet"}`.

See `docs/features/device-twin.md` for the full design.
