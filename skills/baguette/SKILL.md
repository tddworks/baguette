---
name: baguette
description: |
  Drive iOS simulators AND native macOS applications programmatically via the
  `baguette` CLI — taps, swipes, multi-finger gestures, hardware buttons,
  keyboard, frame capture, accessibility tree dump. Use this skill when:
  (1) The agent needs to interact with a booted iOS simulator OR a running
      macOS app from a script (tap a coordinate, swipe between points,
      send Home / Lock / Volume / Action / Power on iOS, type ASCII text)
  (2) Building a smoke test, demo recording, or UI flow that drives a
      simulator OR a native Mac app end-to-end
  (3) Pairing iOS / macOS development with Claude Code, where the agent
      needs to verify on-screen state after a code change
  (4) User asks "tap the simulator from a script", "automate iPhone gestures",
      "drive a Mac app from CLI", "screenshot TextEdit", "type into Notes
      programmatically", "control iOS sim", "drive simulator without Xcode"
  (5) User mentions `baguette`, `baguette input`, `baguette tap`,
      `baguette serve`, `baguette stream`, `baguette mac` (any subcommand)
      by name
  (6) An iOS or macOS smoke-test / fixture / SwiftUI verification needs to
      actually *touch* the running app, not just inspect static code
  Avoid using this skill for plain "open the iOS Simulator" / "install Xcode"
  questions — those are about Xcode itself, not about driving a sim.
---

# baguette — programmatic iOS simulator AND native-macOS app control

`baguette` is a macOS CLI with two parallel target trees:

- **iOS simulators** (`baguette tap / swipe / press / screenshot / …`) —
  drive booted simulators directly via Apple's private `SimulatorHID`,
  the same path Xcode uses internally. Works on iOS 26.4 + Xcode 26 +
  Apple Silicon and is faster + more reliable than `idb` / `AXe` /
  `simctl io` for input.

- **Native macOS apps** (`baguette mac list / screenshot / describe-ui /
  input`) — drive ANY running macOS app via public APIs (ScreenCaptureKit,
  AXUIElement, CGEvent). Targets are addressed by **bundle ID** instead
  of UDID; everything else (wire protocol, gesture envelopes, screenshot
  output) is identical to the iOS path.

This skill is for **agents that need to interact with a running app**
(taps, swipes, screenshots, gesture sequences). Humans wanting a "play
the simulator / Mac app in a browser" UI should be pointed at
`baguette serve` (`http://localhost:8421/simulators/<udid>` for iOS,
`http://localhost:8421/mac/<bundleID>` for macOS) — but agents drive
the CLI.

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

## Driving native macOS apps (`baguette mac …`)

Same wire protocol, same gesture envelopes, same agent ergonomics —
but the target is a running macOS app addressed by **bundle ID**
(e.g. `com.apple.TextEdit`, `com.apple.finder`) instead of a simulator
UDID. Reuse this anywhere you'd reach for `osascript`, `cliclick`,
or AppleScript GUI scripting.

### Happy path (mirrors iOS one-for-one)

```bash
# 1. Find a running app.
baguette mac list                           # one JSON object per line
baguette mac list --json                    # {"active":[...], "inactive":[...]}

# 2. Capture a window snapshot.
baguette mac screenshot --bundle-id com.apple.TextEdit --output /tmp/te.jpg

# 3. Read the accessibility tree (frames in WINDOW-relative points).
baguette mac describe-ui --bundle-id com.apple.TextEdit
baguette mac describe-ui --bundle-id com.apple.TextEdit --x 50 --y 50    # hit-test

# 4. Drive it via stdin (same JSON envelopes as `baguette input`).
{ echo '{"type":"type","text":"hello from baguette"}'
  echo '{"type":"key","code":"Enter"}'
  echo '{"type":"tap","x":50,"y":50,"width":783,"height":914}'
} | baguette mac input --bundle-id com.apple.TextEdit
```

`baguette mac input` auto-activates the target app at session start
(via `NSRunningApplication.activate`), so you don't need
`osascript -e 'tell application X to activate'` chaining like with
raw `cliclick`.

### Coordinate convention — window-relative points

Wire `(x, y, width, height)` is in **window-relative points** with
the top-left of the target app's frontmost window content rect at
`(0, 0)`. This matches what `mac screenshot` shows you (the JPEG is
cropped to that same window), so frames returned by `mac describe-ui`
feed straight into `tap` envelopes without coordinate juggling. The
adapter resolves the window's screen-global origin per gesture so
the user dragging the window between calls stays correct.

To get the right `width` / `height`: read them from the AXWindow's
`frame` field — `baguette mac describe-ui` returns frame size for
the root `AXWindow` node.

### TCC — read this before you ship

The macOS path needs two grants in System Settings → Privacy &
Security:

| Capability                 | Pane            | Without it…                                       |
|---------------------------|------------------|---------------------------------------------------|
| `mac screenshot` / stream  | Screen Recording | `SCShareableContent.current` returns no windows |
| `mac describe-ui` / `mac input` | Accessibility | `MacAppError.tccDenied` thrown / events silently dropped |

The first call after a rebuild may prompt; subsequent unsigned
rebuilds may revoke the grant silently. The repo's
`macos-codesign` skill keeps grants persistent across rebuilds for
maintainer work.

### What works vs. what's rejected on the macOS path

Wired (works against any AppKit-based app):
- `tap`, `swipe`, `scroll`, `key`, `type` — every keyboard +
  pointer gesture from the iOS surface.
- The full `describe-ui` shape (role / label / value / frame /
  children), with frames in window-relative points.

**Rejected** with `{"ok":false}` (logged but not posted) — these
don't apply to macOS apps:
- `button` — hardware buttons (home / power / volume / action) are
  iOS-specific.
- `touch1`, `touch2`, `twoFingerPath`, `pinch`, `pan` — multi-touch
  via `CGEvent` isn't reliable on macOS. Map to `swipe` /
  `scroll` for the most common cases.

### Drag-select gotcha (real-world tested)

`swipe`'s default duration is tuned for iOS perceptual speed
(0.25 s, 30 samples). That's borderline too fast for macOS
drag-to-select. Pass `"duration": 0.5` (or higher) for reliable
drag-select. Also: start the swipe INSIDE the text region, not at
`x=0` (that's outside the textarea content).

```json
{"type":"swipe","startX":50,"startY":50,"endX":300,"endY":50,
 "width":1078,"height":679,"duration":0.5}
```

### Serve mode for macOS

`baguette serve` exposes the same surface for macOS apps at the
sibling URL tree:

```
GET /mac.json                          → {"active":[...], "inactive":[...]}
GET /mac                               → list page
GET /mac/<bundleID>                    → focus view (polling-screenshot)
GET /mac/<bundleID>/screen.jpg         → one-shot JPEG of frontmost window
GET /mac/<bundleID>/describe-ui[?x=&y=] → AX tree (full or hit-test)
WS  /mac/<bundleID>/stream?format=mjpeg|avcc → live frames + gestures + describe_ui
```

The WS dialect is identical to the iOS one — same `{"type":"tap"}`,
`{"type":"describe_ui"}`, `{"type":"snapshot"}` envelopes.

### Smoke harness

`scripts/smoke-mac.sh` (or `make smoke-mac`) drives the full mac
surface end-to-end against TextEdit and asserts on observable
outcomes — 28 tests in three tiers (read-only / input / serve).
Run it after any change to `Sources/Baguette/Infrastructure/MacApp/`
or the `MacRootCommand` tree.

## What's wired vs what isn't

Wired (use freely on iOS sims; macOS path is a subset — see above):
- `tap`, `swipe`, `touch1-{down,move,up}`, `touch2-{down,move,up}`,
  `pinch`, `pan`, `scroll`
- `button`: `home`, `lock`, `power`, `volume-up`, `volume-down`,
  `action`. Optional `--duration` / `"duration"` for long-press
  semantics (action button "Hold for Ring", power → Siri / SOS, …).
  **iOS only** — rejected on the mac path.
- `key` (single keystroke) and `type` (US-ASCII string). CLI:
  `baguette key --code KeyA --modifiers shift,command --duration 0.2`
  and `baguette type --text "hello"`. `code` is a W3C
  `KeyboardEvent.code`; modifiers are `shift | control | option | command`.
  Same shape on `baguette mac input`.
- `describe-ui` — dump the on-screen accessibility tree as JSON
  (per-node `role`, `label`, `value`, `identifier`, `frame` in
  device points, recursive `children`). CLI:
  `baguette describe-ui --udid <X>` (full tree) or
  `baguette describe-ui --udid <X> --x <px> --y <px>` (hit-test).
  macOS analogue: `baguette mac describe-ui --bundle-id <id> [--x --y]`.
  Frames are in the same units as `tap` / `swipe` wire fields, so
  reading `frame.x + frame.width/2`, `frame.y + frame.height/2`
  back into a `tap` envelope just works.
- `logs` — stream the booted simulator's unified log line-by-line
  to stdout. CLI: `baguette logs --udid <X> [--level info|debug|default]
  [--style default|compact|json|ndjson|syslog] [--predicate ...]
  [--bundle-id <id>]`. SIGINT (Ctrl-C) tears down cleanly. WS
  variant on `WS /simulators/<X>/logs?level=&style=&predicate=&bundleId=`
  emits `{"type":"log","line":"..."}` text frames per entry.
  Levels: only `default | info | debug` (iOS-runtime narrow — host
  `notice / error / fault` are rejected at the wire).
  **iOS only** — `mac` doesn't need a separate `logs` command;
  use macOS-host `log stream --predicate 'process == "..."'`.

NOT wired (skill should NOT propose these):
- **Non-ASCII text** through `type` — IME / Pinyin / accented / emoji
  isn't on the host-HID path yet. Fall back to
  `xcrun simctl io <UDID> text "…"` for those strings, or split the
  task so only ASCII goes through `baguette type`.
- **F-keys, Page Up/Down, Home/End** through `key` — outside the
  phase-1 supported code set. Most iOS apps don't use them anyway.
- `button: "siri"` — crashes `backboardd` via every known path.
  Refused by the CLI.

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
brew install tddworks/tap/baguette
baguette --version
```

Requires Xcode 26 + Apple Silicon. If `baguette` already works, skip
this — agents shouldn't reinstall on every invocation.