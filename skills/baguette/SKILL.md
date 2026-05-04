---
name: baguette
description: |
  Drive iOS simulators programmatically via the `baguette` CLI — taps, swipes,
  multi-finger gestures, hardware buttons, frame capture, all without opening
  Xcode. Use this skill when:
  (1) The agent needs to interact with a booted iOS simulator from a script
      (tap a coordinate, swipe between points, send Home / Lock / Volume /
      Action / Power, type ASCII text via the keyboard)
  (2) Building a smoke test, demo recording, or UI flow that drives a
      simulator end-to-end
  (3) Pairing iOS development with Claude Code, where the agent needs to
      verify on-screen state after a code change
  (4) User asks "tap the simulator from a script", "automate iPhone gestures",
      "control iOS sim programmatically", "drive simulator without Xcode"
  (5) User mentions `baguette`, `baguette input`, `baguette tap`,
      `baguette serve`, or `baguette stream` by name
  (6) An iOS smoke-test / fixture / SwiftUI verification needs to actually
      *touch* the running app, not just inspect static code
  Avoid using this skill for plain "open the iOS Simulator" / "install Xcode"
  questions — those are about Xcode itself, not about driving a sim.
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

## What's wired vs what isn't

Wired (use freely):
- `tap`, `swipe`, `touch1-{down,move,up}`, `touch2-{down,move,up}`,
  `pinch`, `pan`, `scroll`
- `button`: `home`, `lock`, `power`, `volume-up`, `volume-down`,
  `action`. Optional `--duration` / `"duration"` for long-press
  semantics (action button "Hold for Ring", power → Siri / SOS, …).
- `key` (single keystroke) and `type` (US-ASCII string). CLI:
  `baguette key --code KeyA --modifiers shift,command --duration 0.2`
  and `baguette type --text "hello"`. `code` is a W3C
  `KeyboardEvent.code`; modifiers are `shift | control | option | command`.

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