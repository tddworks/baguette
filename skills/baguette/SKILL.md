---
name: baguette
description: |
  Drive and inspect iOS simulators with the `baguette` CLI: taps, swipes,
  buttons, typing, screenshots, the accessibility tree, logs, and the
  conditions an app runs under (location, network, appearance, push,
  UserDefaults), without opening Xcode. Use when an agent must act on or verify a
  running simulator — a UI flow, smoke test or demo, checking a code change on
  screen — or when the user names `baguette`. Not for installing Xcode or
  merely opening Simulator.app.
---

# baguette — programmatic iOS simulator control

`baguette` is a macOS CLI that drives iOS simulators through Apple's private
`SimulatorHID` (the path Xcode uses internally): faster and more reliable
than `idb` / `AXe` / `simctl io` for input. Agents drive the CLI; a human who
wants to watch or play along should be pointed at `baguette serve` and
`http://localhost:8421/simulators/<udid>`.

## The loop

Almost every job is: get a device, act, look, repeat.

```bash
baguette list --json                                    # 1. a booted UDID
baguette boot --udid <UDID>                             #    (if none is running)
baguette describe-ui --udid <UDID> | jq .screen        # 2. its size in points
baguette tap --udid <UDID> --x 219 --y 478 --width 438 --height 954   # 3. act
baguette screenshot --udid <UDID> --output /tmp/frame.jpg             # 4. look
```

Then `Read /tmp/frame.jpg`. If taps answer `{"ok":true}` but nothing
happens, run `baguette heal --udid <UDID>` (Xcode 27's Device Hub took the
input surface; see `references/devices.md`).

## Coordinates are device points (read this)

Every `x` / `y` / `startX` / `endX` / `x1` / `cx` … is in **device points**,
the same units as the `width` / `height` passed with it. The centre of a
438×954 screen is `x:219, y:478`: not `0.5, 0.5` (normalized), not
`1206, 2622` (pixels). Take `width` / `height` from `describe-ui`'s outer
`screen` per device, and read it again after a rotation or a fold; its frames
come back in the same units, so an element's centre goes straight into a tap.
Not `chrome layout`: its `screen` is the bezel image's, not the device's points.

## What do you need to do?

Read only the reference for the job at hand.

| You want to… | Read | Commands |
|---|---|---|
| get a device booted, sized, rotated, folded; fix input that lands nowhere | `references/devices.md` | `list` `boot` `shutdown` `heal` `orientation` `hinge` |
| act like a user: touch, drag, press buttons, type, paste | `references/interact.md` | `tap` `double-tap` `swipe` `pinch` `pan` `input` `press` `type` `key` `paste` `clipboard` |
| check what happened: see it, find an element, read logs, record | `references/observe.md` | `screenshot` `describe-ui` `logs` `record` `stream` `render-3d` |
| set the conditions the app runs under | `references/environment.md` | `location` `motion` `network` `interface` `status-bar` `notify` `shake`, camera (WebSocket only) |
| put an app and its data in place, launch it | `references/apps.md` | `install` `add-media` `openurl` `schemes` `defaults`, `simctl launch` |

Two more, generated from the binary by `make docs` (never edit them here).
`references/commands.md` has every subcommand, flag and exit code; it's long,
so read one command's section, not the file:
`grep -A25 '^## baguette swipe' references/commands.md` (subcommands are
`### baguette location set`). `references/wire.md` has every JSON gesture for
`input` and the WebSocket.

## One-shot or streamed

One command per gesture is right for a handful of steps; each pays the HID
setup (~50–100 ms). For drags, choreography or many steps, open
`baguette input --udid <UDID>` once and write one JSON gesture per line
(`references/interact.md`). It answers `{"type":"describe_ui"}` too, so one
session can look and act without paying startup on every call. Either way `ok:true` means *sent*, not that the
screen reacted: verify with a screenshot.

## Limits to state, not discover

- `type` / `key` are US-ASCII keystrokes. Anything else (accents, CJK, emoji)
  goes through `baguette paste --text "…"`.
- `press --button siri` is refused: every known path crashes backboardd.
- `motion`, `network` and camera reach only apps launched after they're
  armed; relaunch the app once (a later `network set` or `clear` needs none).
- An idle screen may emit no frame, so `screenshot` times out; nudge it with
  a tap first.
- Simulators only: physical-device control isn't wired.

## A smoke test

```bash
#!/usr/bin/env bash
set -euo pipefail
UDID="$1"
read W H < <(baguette describe-ui --udid "$UDID" | jq -r '.screen | "\(.width) \(.height)"')

baguette press --udid "$UDID" --button home
sleep 0.4
baguette tap --udid "$UDID" --x $((W * 75 / 100)) --y $((H * 55 / 100)) --width "$W" --height "$H"
sleep 0.5
baguette screenshot --udid "$UDID" --output /tmp/settings.jpg
```

Resolve the size once and pass it to every gesture. Better than a guessed
position: find the element with `baguette describe-ui` and tap its centre.

## Pairing with Claude Code

When editing a SwiftUI app: build and run → `press --button home` and `tap`
to the changed screen → `screenshot` and `Read` it → confirm the pixels
match intent. To let the human follow along, start `baguette serve` and give
them `http://localhost:8421/simulators/<udid>`; it also takes keyboard
typing, drag-and-drop installs and the feature cards. `baguette plugin` and
`baguette bakery` extend that page (see `commands.md`).

Per-feature guides: `https://github.com/tddworks/baguette/blob/main/docs/features/<feature>/README.md`.

## Install (only when missing)

```bash
brew install baguette
baguette --version
```

Requires Xcode 26 or later on Apple Silicon. If `baguette` already works, skip
this; don't reinstall on every invocation.
