---
name: baguette
description: |
  Drive iOS simulators programmatically via the `baguette` CLI — taps, swipes,
  multi-finger gestures, hardware buttons (Home / Lock / Volume / Action /
  Power), ASCII keyboard text, and frame capture, all without opening Xcode.
  Use when: (1) an agent needs to drive a booted iOS simulator from a script —
  tap a coordinate, swipe, type text; (2) building a smoke test, demo, or
  end-to-end UI flow on a simulator; (3) pairing iOS dev with Claude Code to
  verify on-screen state after a code change; (4) the user asks to "automate
  iPhone gestures", "control iOS sim programmatically", or "drive simulator
  without Xcode"; (5) the user names `baguette`, `baguette input`,
  `baguette tap`, `baguette serve`, or `baguette stream`; (6) a SwiftUI
  verification needs to touch the running app, not just inspect static code.
  Avoid for plain "open the iOS Simulator" / "install Xcode" questions — those
  are about Xcode itself, not driving a sim.
---

# baguette — programmatic iOS simulator control

`baguette` is a macOS CLI that drives iOS simulators directly via Apple's
private `SimulatorHID` (the same path Xcode uses internally). It works on
**iOS 26.4 + Xcode 26 + Apple Silicon** and is faster + more reliable than
`idb` / `AXe` / `simctl io` for input.

This skill is for **agents that need to interact with a running simulator**
(taps, swipes, screenshots, gesture sequences). Humans wanting a "play the
simulator in a browser" UI should be pointed at `baguette serve` and
`http://localhost:8421/simulators/<udid>` — but agents drive the CLI.

## The agent's happy path

Most automation jobs follow the same shape:

```bash
# 1. Find a booted device.
baguette list                              # human-readable
baguette list --json                       # machine-readable: {running, available}

# 2. Boot one if nothing is running.
baguette boot --udid <UDID>

# 3. Get the screen size — you need this for every gesture.
baguette chrome layout --udid <UDID>       # → {composite:{width,height}, screen:{width,height}, ...}

# 4. Drive it.
baguette tap --udid <UDID> --x 219 --y 478 --width 438 --height 954

# 5. Verify what happened (capture one JPEG of the framebuffer).
baguette screenshot --udid <UDID> --output /tmp/frame.jpg
```

Steps 3–4 are the part that bites — see "The coordinate footgun" below.

## The coordinate footgun (read this)

**All `x` / `y` / `startX` / `endX` / `x1` / `x2` / `cx` / `cy` are in
device points** — same units as the `width` / `height` you pass alongside.

A "tap at the centre of an iPhone 17 Pro Max" is `x:219, y:478` (half of
**438×954**). It is **not** `x:0.5, y:0.5` (normalized). It is **not**
`x:1206, y:2622` (raw pixels). The HID adapter normalises internally.

To get the right `width` / `height` for a UDID:

```bash
baguette chrome layout --udid <UDID> | jq '.screen | {width, height}'
# → {"width": 438, "height": 954}
```

Always use the values from `chrome layout` — different devices have
different point sizes, and hardcoding "438×954" only works for iPhone 17
Pro Max.

## One-shot vs streaming gestures

Two ways to send input. Pick by frequency:

- **One-shot** (`baguette tap / swipe / pinch / pan / press`) — separate
  process per gesture. Right for a handful of distinct interactions in a
  shell script. Each invocation pays the SimulatorHID setup cost
  (~50–100ms).

- **Streaming** (`baguette input --udid <UDID>`) — long-running process
  reading newline-delimited JSON from stdin, writing `{"ok":true}` /
  `{"ok":false,"error":…}` to stdout per line. Right for sequences of
  many gestures (drags, multi-finger choreography, demo playback) where
  per-gesture latency matters. Same wire format the WebSocket uses.

```bash
# One-shot.
baguette tap --udid X --x 219 --y 478 --width 438 --height 954

# Streaming (open the pipe once, send many).
( echo '{"type":"tap","x":219,"y":478,"width":438,"height":954,"duration":0.05}'
  echo '{"type":"swipe","startX":219,"startY":760,"endX":219,"endY":190,"width":438,"height":954,"duration":0.3}'
) | baguette input --udid X
```

For the full wire-format spec (every gesture type with examples), read
`references/wire-protocol.md`.

## Visual verification — let the agent see what happened

After driving a UI flow, the agent usually needs to confirm state.
The right tool is `baguette screenshot` — a one-shot JPEG of the
simulator's framebuffer with no streaming session involved:

```bash
baguette screenshot --udid <UDID> --output /tmp/frame.jpg
baguette screenshot --udid <UDID> > /tmp/frame.jpg          # stdout works too
baguette screenshot --udid <UDID> --quality 0.6 --scale 2 > thumb.jpg
```

Defaults: `--quality 0.85`, `--scale 1` (native). `--scale 2` halves
each dimension; useful when you only need a quick visual check.

Equivalent HTTP route during `baguette serve`:
`GET http://localhost:8421/simulators/<UDID>/screenshot.jpg[?quality=][?scale=]`.

Important: SimulatorKit only emits a frame when something on screen
changes. A booted-but-idle simulator (lock screen with no second hand)
may not produce one within the 2 s timeout — `baguette screenshot`
exits non-zero and prints `Failure.timeout`. Wake the device with a
gesture first if you're capturing a static state:

```bash
baguette tap --udid <UDID> --x 1 --y 1 --width "$W" --height "$H"  # nudge
sleep 0.2
baguette screenshot --udid <UDID> --output /tmp/frame.jpg
```

Then `Read /tmp/frame.jpg` to inspect (Claude Code's Read tool handles
images).

For a snapshot while a `baguette serve` WebSocket is already open,
send `{"type":"snapshot"}` on that channel — the server emits a
keyframe immediately. Use this only when the WS is already live; for
fresh captures `baguette screenshot` is one HTTP-free command.

For a presentation image on a 3D device model, use `render-3d`:

```bash
baguette render-3d --udid <UDID> \
  --variant finish=deep-blue --rotation=-8,18,0 \
  --size 1200x1200 --output /tmp/device.png
```

An existing image can be rendered with
`--screen <image> --device <model-id>`. The HTTP equivalents are
`GET /simulators/<UDID>/3d-model.json` for public model/variant metadata and
`POST /simulators/<UDID>/render-3d.png` for the PNG. This is a one-shot
presentation surface; gestures still target the live 2D stream.

## What's wired vs what isn't

Wired (use freely):
- `tap`, `swipe`, `touch1-{down,move,up}`, `touch2-{down,move,up}`,
  `pinch`, `pan`, `scroll`. `touch1-*` events accept an optional
  `edge: "bottom" | "top" | "left" | "right"` field that flags every
  event in the chain as a screen-edge system gesture; `bottom`
  engages iOS's home-indicator recognizer (live home / app-switcher
  preview as the touches stream); `top` engages the status-bar
  recognizer (live lock-screen cover sheet from a top-left drag,
  Notification Center from a top-right drag). Omit `edge` for
  ordinary interior touches.
- `button`: `home`, `lock`, `power`, `volume-up`, `volume-down`,
  `action`, `app-switcher`, `swipe-to-app-switcher`, `swipe-to-home`,
  `pull-down-to-lock-screen`, `pull-down-to-notification-center`.
  Optional `--duration` / `"duration"` for long-press semantics
  (action button "Hold for Ring", power → Siri / SOS, …). The five
  virtual buttons land iOS gesture recognition without any
  client-side stream management. `app-switcher` fires two home
  presses ~150 ms apart (SpringBoard's own multitasking recipe);
  `swipe-to-app-switcher` is the slow drag-and-hold variant on
  the gesture path; `swipe-to-home` is the fast edge-flick → Home;
  `pull-down-to-lock-screen` and `pull-down-to-notification-center`
  drag down from top-left and top-right respectively.
- `key` (single keystroke) and `type` (US-ASCII string). CLI:
  `baguette key --code KeyA --modifiers shift,command --duration 0.2`
  and `baguette type --text "hello"`. `code` is a W3C
  `KeyboardEvent.code`; modifiers are `shift | control | option | command`.
- `paste` — arbitrary unicode into the focused field via the sim's
  pasteboard + Cmd+V (the path around `type`'s US-ASCII limit; not a
  HID-only path — shells out to `xcrun simctl pbcopy`). Wire:
  `{"type":"paste","text":"…","press":false?}` on the stream WS
  (replies `paste_result`) and `input` stdin. CLI: `baguette paste
  --udid <X> --text "…" [--no-press]`; plus `baguette clipboard get`
  (print the sim's pasteboard raw) and `baguette clipboard sync`
  (host Mac pasteboard → sim, full-fidelity — images included).
  Needs a booted device. See
  [`docs/features/paste.md`](../../docs/features/paste.md).
- `copy` — the sim→host interactive mirror of `paste`: press Cmd+C
  sim-side (focused field copies its selection), then ferry the
  pasteboard onto the host Mac's clipboard, full-fidelity — images
  included (`xcrun simctl pbsync <udid> host`). Wire:
  `{"type":"copy","press":false?}` on the stream WS (replies
  `copy_result`) and `input` stdin — `press:false` skips the
  keystroke for a pure ferry. Browser **Cmd+C / Ctrl+C** while the
  screen has focus sends it. CLI: `baguette clipboard copy --udid <X>`
  is a pure ferry (no keystroke). Browser copy targets the machine
  running baguette (local-dev happy path). Needs a booted device.
  See [`docs/features/paste.md`](../../docs/features/paste.md).
- `describe-ui` — dump the on-screen accessibility tree as JSON
  (per-node `role`, `label`, `value`, `identifier`, `frame` in
  device points, recursive `children`). CLI:
  `baguette describe-ui --udid <X>` (full tree) or
  `baguette describe-ui --udid <X> --x <px> --y <px>` (hit-test).
  Frames are in the same units as `tap` / `swipe` wire fields, so
  reading `frame.x + frame.width/2`, `frame.y + frame.height/2`
  back into a `tap` envelope just works.
- `interface` — the accessibility-display family: light / dark
  appearance, Increase Contrast, and content size (Dynamic Type,
  including the five accessibility sizes). CLI: `baguette interface
  appearance|contrast|text-size --udid <X> [<value>]` — no value reads,
  a value sets. HTTP: `GET /simulators/<X>/interface.json` and
  `POST /simulators/<X>/interface` (any subset, answers the resulting
  state). Backed by `xcrun simctl ui` (not a HID path). **A read on a
  device that isn't booted answers `unknown` and exits 0** — a state to
  check for, not a failure; `unsupported` means the runtime lacks the
  setting. Neither can be set. Pairs with `describe-ui`: change the
  conditions, re-dump the tree, compare. See
  [`docs/features/interface.md`](../../docs/features/interface.md).
- `logs` — stream the booted simulator's unified log line-by-line
  to stdout. CLI: `baguette logs --udid <X> [--level info|debug|default]
  [--style default|compact|json|ndjson|syslog] [--predicate ...]
  [--bundle-id <id>]`. SIGINT (Ctrl-C) tears down cleanly. WS
  variant on `WS /simulators/<X>/logs?level=&style=&predicate=&bundleId=`
  emits `{"type":"log","line":"..."}` text frames per entry.
  Levels: only `default | info | debug` (iOS-runtime narrow — host
  `notice / error / fault` are rejected at the wire).
- `camera` — pipe a camera source (a live Mac webcam, an uploaded
  still image, or a looping uploaded video) into the iOS app's
  `AVCaptureVideoPreviewLayer` / `AVCapturePhotoOutput` /
  `UIImagePickerController`. No CLI; use the WS at
  `WS /simulators/<UDID>/camera` — `camera_list` / `camera_start`
  (with `source: webcam | image | video`) / `camera_stop` /
  `camera_set_flags` upstream, `camera_devices` / `camera_state`
  downstream (phase = `idle | streaming`, plus live `fps` and active
  `source`). Image/video files upload first via
  `POST /simulators/<UDID>/camera-source?name=<file>`. Frames flow
  through `/tmp/SimCam.bgra`
  (24-byte LE header + BGRA pixels) into `VirtualCamera.dylib`
  loaded inside the simulator via `DYLD_INSERT_LIBRARIES`. Apps
  launched *before* arming don't load the dylib — relaunch them.
  Browser UI lives under the Camera card on `/simulators/<UDID>`.
- `install` / `add-media` — add a file to the device. `baguette install
  --udid <X> <path>` installs an `.ipa` / `.app`; `baguette add-media
  --udid <X> <path>` adds an image / video (`png jpg jpeg gif heic heif
  mov mp4 m4v`) to Photos. Both shell out to `xcrun simctl install` /
  `addmedia` (not a HID path). `serve` exposes one entry point —
  `POST /simulators/<X>/files?name=<filename>` with the raw bytes as the
  body — and routes by extension (app → install, `.zip` carrying one
  top-level `.app` → extract via `ditto -x -k` + install, media →
  Photos); a file with no home on a simulator returns `415`. The
  browser focus page accepts drag-and-drop onto the device, including
  a bare `.app` **directory** — it's packed into a stored zip in-page
  and posted as `<Name>.app.zip`. See
  [`docs/features/file-upload.md`](../../docs/features/file-upload.md).
- `location` — set the device's simulated GPS position (not a HID path;
  shells out to `xcrun simctl location`). `baguette location set --udid
  <X> <lat,lon>` pins a point; `baguette location start --udid <X>
  [--speed <m/s>] [--distance <m>] [--interval <s>] <lat,lon> <lat,lon>…`
  runs a moving route; `baguette location walk --udid <X> --bearing <deg>
  --speed <m/s> <lat,lon>` heads off along a compass bearing (driving
  `CLLocation.course`); `baguette location clear --udid <X>` restores live
  location. Position/waypoints are `lat,lon` **tokens** (e.g.
  `37.3318,-122.0312`); a token whose latitude starts with `-` must
  follow a `--` separator. `serve`: `POST /simulators/<X>/location` with a
  `{latitude,longitude}` point, `{waypoints:[…],speed?}` route, or
  `{latitude,longitude,bearing,speed}` walk body, and `DELETE` to clear.
  Out-of-range, <2-waypoint, or speed-less-walk bodies return `400`.
  Browser focus page has a **Location** card (map-pin toolbar button) with
  a Leaflet map and a **Walk** joystick — the stick steers absolute, while
  `W`/`S` drive along the current heading and `A`/`D` turn it (tank
  controls); **Replay** retraces the walked trail as a route.
  **Two iOS-26 limits:** `CLHeading` (compass) is unavailable in the
  simulator entirely (`headingAvailable() == false`), and `course` is
  derived on a flat lat/lon grid so diagonal bearings skew by
  `1/cos(latitude)` (~6.5° at lat 37; cardinals are exact). See
  [`docs/features/location.md`](../../docs/features/location.md).
- `motion` — make the device's apps read CoreMotion: `CMMotionActivity`
  (walking / running / cycling / automotive), `CMPedometer` counters, and
  `CMMotionManager` samples. **Not a simctl path** — all three are
  unavailable in a stock simulator, so baguette injects
  `VirtualMotion.dylib`. `baguette motion start --udid <X> [--activity
  <kind>] [--speed <m/s>]` arms it (plain `start` = walking);
  `baguette motion set --udid <X> --activity <kind>` changes it;
  `baguette motion stop --udid <X>` parks it stationary and disarms.
  `serve`: `POST /simulators/<X>/motion` with `{"activity":"running"}` or
  just `{"speed":6}` (classified server-side), `GET` to read back
  `{ok,active,activity,steps,metres,speed}` — an inactive device answers
  `{"ok":true,"active":false}` and nothing more — `DELETE` to stop. An
  unknown udid is `404` on every one of them. Browser: a **Drive
  motion sensors** toggle on the Location card — once on, the walk
  joystick and route speeds already being posted drive the activity.
  **The one thing that surprises people: only apps launched _after_
  arming see anything** (dyld inserts at exec time) — relaunch with
  `xcrun simctl launch --terminate-running-process <X> <bundle-id>`.
  Floor counting and the magnetometer are deliberately still unavailable.
  See [`docs/features/motion.md`](../../docs/features/motion.md).
- `network` — condition what the device's apps see of the network:
  latency, downlink bandwidth, request loss, hard offline. **Not a simctl
  path** — Network Link Conditioner and the `dnctl`/`pfctl` rules under it
  are system-wide, so baguette injects `VirtualNetwork.dylib` to scope it
  to one simulator. `baguette network set --udid <X> --profile 3g` (or
  `--latency <ms> --bandwidth <kbps> --loss <percent>`, or `--offline`) —
  **exactly one** of those three per invocation; `network clear --udid <X>`
  stops it, including for apps already running; plain
  `baguette network --udid <X>` reports what's applied.
  Presets are NLC's: `wifi | dsl | lte | 3g | edge | very-bad-network |
  100-loss`. `serve`: `POST /simulators/<X>/network` with
  `{"profile":"3g"}` / `{"latencyMs":300,"bandwidthKbps":400,"lossPercent":5}`
  / `{"offline":true}`, `GET` to read back, `DELETE` to clear. Browser: a
  **Network** card, with an amber toolbar dot whenever conditioning is on.
  **Same relaunch rule as motion** — only apps launched after `network set`
  are conditioned; changing it afterwards needs no relaunch.
  **Three limits to state rather than discover:** only URLSession-shaped
  traffic is conditioned — `URLSessionWebSocketTask` is (latency, loss,
  offline; not bandwidth), but an SDK that opens its own socket is not, so
  Ably's ably-cocoa and Starscream are unreached and `--offline` will not
  feel offline to them; **`WKWebView` / Safari page loads are not
  conditioned**, since WebKit loads them in its own networking process, so
  a hybrid app is throttled natively but not in its web content; and loss
  is request-level rather than packet-level. See
  [`docs/features/network.md`](../../docs/features/network.md).

NOT wired (skill should NOT propose these):
- **Non-ASCII text** through `type` — IME / Pinyin / accented / emoji
  isn't on the host-HID keystroke path. Use `baguette paste --udid
  <X> --text "…"` (or the `paste` wire verb) for those strings — it
  rides the pasteboard instead of keystrokes.
- **F-keys, Page Up/Down, Home/End** through `key` — outside the
  phase-1 supported code set. Most iOS apps don't use them anyway.
- `button: "siri"` — crashes `backboardd` via every known path.
  Refused by the CLI.
- **Physical-device routes** (`/devices.json`,
  `WS /devices/:udid/stream`) — the host side exists but no companion
  app ships yet, so nothing ever connects; gestures on a device stream
  are rejected with `device control is not wired yet`. Simulators
  only for now. See `docs/features/device-twin.md`.

## Composing flows — the smoke-test pattern

```bash
#!/usr/bin/env bash
set -euo pipefail
UDID="$1"

# Resolve screen size once; reuse for every gesture.
read W H < <(baguette chrome layout --udid "$UDID" \
  | jq -r '.screen | "\(.width) \(.height)"')

# Wake / unlock.
baguette press --udid "$UDID" --button lock      # toggle (sleep if awake)
sleep 0.5
baguette press --udid "$UDID" --button lock      # back on

# Home → tap Settings.
baguette press --udid "$UDID" --button home
sleep 0.4
baguette tap --udid "$UDID" --x $((W * 75 / 100)) --y $((H * 55 / 100)) \
              --width "$W" --height "$H"

# Capture proof.
baguette stream --udid "$UDID" --format mjpeg --fps 1 \
  | head -c 200000 > /tmp/settings.jpg
```

Note `width`/`height` reuse: every gesture pays the same coordinate
convention, so resolving once and re-passing avoids the footgun.

## Pairing with Claude Code

The natural loop when an agent edits a SwiftUI app:

1. Edit code → ⌘B in Xcode (or `xcodebuild`) → app reloads on the sim.
2. Agent uses `baguette press --button home` then `baguette tap …` to
   navigate to the screen it just changed.
3. Agent captures a frame (above), `Read`s the JPEG, and confirms the
   pixels match intent.

If the human wants to follow along visually, also point them at
`http://localhost:8421/simulators/<udid>` (after starting `baguette serve`)
— that's a focused single-tab view of the sim, no Xcode window juggling.

## Reference files

- `references/wire-protocol.md` — every gesture type with copy-pasteable
  JSON examples + the coordinate convention restated.
- `references/cli.md` — full subcommand list, flags, and exit/output
  format for each `baguette` command.

Read these on demand — don't pull both into context unless the task
actually needs the breadth (e.g., authoring a long input pipeline →
read `wire-protocol.md`; debugging which subcommand to use → read
`cli.md`).

## Install (only when missing)

```bash
brew install baguette
baguette --version
```

Requires Xcode 26 + Apple Silicon. If `baguette` already works, skip
this — agents shouldn't reinstall on every invocation.
