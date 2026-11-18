---
description: Use Xcode 27.1's foldable iPhone Duo with baguette: create it, fold and unfold it, and have taps, screenshots, streams and the 3D page follow whichever panel the hinge lights. Use when testing an app on the Duo simulator.
---

# iPhone Duo (Xcode 27.1, iOS 27.1)

Xcode 27.1 beta ships the first foldable simulator, **iPhone Duo**: one device
with **two panels**, a cover (lit while folded) and a larger unfolded panel. The
hinge decides which is lit, and every baguette entry point (`tap` / `swipe` /
`input`, `screenshot`, `stream`, `serve`, `record`, `describe-ui`,
`chrome layout`) follows the **lit** panel. Fold it with
[`baguette hinge`](../../commands.md#baguette-hinge) ([hinge](../hinge/README.md)).

## Getting one

The device type needs an iOS 27.1 runtime: Xcode 27.0's `simctl` lists the type
but refuses to create it (`Incompatible device`), and 27.1's refuses until the
runtime lands (`Invalid runtime`).

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.1.0-Beta.app/Contents/Developer
xcodebuild -downloadPlatform iOS            # iOS 27.1 Simulator, 7.85 GB
xcrun simctl create 'iPhone Duo' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-Duo \
  com.apple.CoreSimulator.SimRuntime.iOS-27-1
```

Installing the runtime through `xcodebuild -downloadPlatform` also auto-creates
one Duo, so the explicit `create` is only needed when the runtime was added some
other way.

## Quick start

```bash
baguette boot  --udid <UDID>                 # boots folded: the cover is lit
baguette hinge --udid <UDID> --pose open     # unfold (130°); SpringBoard goes landscape
baguette describe-ui --udid <UDID> | jq .screen   # the lit panel's size, for --width / --height
baguette hinge --udid <UDID>                 # read the angle and lit panel
```

On the page (`/simulators/<UDID>`), a booted Duo is drawn in 3D as Device Hub
draws it: Apple's own model, posed live by the hinge. Under it sits the pose
picker (shut, open 130°, flat) and a **hinge slider**; beside it are the volume,
power and camera-control keys, shown while the pointer is over the stage.

| | Cover (`primary`) | Unfolded (`primary-1`) |
|---|---|---|
| Size in points | 466 × 678 | 669 × 951 |
| Lit when | folded (≈3°) — the boot state | open (≈130°); interface in landscape |

## Workflows

### Tap on the unfolded panel

```bash
baguette hinge --udid <UDID> --pose open
baguette describe-ui --udid <UDID> | jq .screen             # now reports 669 × 951
baguette tap --udid <UDID> --x 334 --y 475 --width 669 --height 951
```

Coordinates are device points in the **lit** panel's space, as everywhere else
([wire.md](../../wire.md)). While folded, `describe-ui`'s `screen` reports the
cover's 466 × 678, and that's what to pass as `--width` / `--height`; its
frames come back in the same space. Not `chrome layout`: its `screen` is the
bezel image's (626 × 890 for the unfolded panel).

### Read a panel's layout without folding

```bash
baguette chrome layout --device-name "iPhone Duo" --panel unfolded
```

Works for a device that's folded or not booted.

## HTTP / WebSocket

`GET /devices/<UDID>/hinge` reports the hinge and the lit panel:

```json
{"ok":true,"foldable":true,"angleDegrees":130.0,"litPanel":"secondary","orientation":"landscape-left"}
```

Moving it (`POST /devices/<UDID>/hinge`) is documented in
[hinge](../hinge/README.md). On the page's 3D socket, the pose picker and the
slider send `set_pose`:

```json
{"type":"set_pose","hingeDegrees":72,"duration":0}
```

`duration: 0` goes straight to the angle (the slider); without it the hinge is
swept over Device Hub's 0.8 s (the picker). Pose requests play in order and skip
what a burst has already passed. `screen_quad` carries `pose: {hingeDegrees}` so
the page can light the nearest pose; the hardware keys send the ordinary
`button` envelope. The 3D socket itself is covered in
[3D rendering](../3d-rendering/README.md).

## Gotchas

- **Xcode 27.1 beta only**, and the beta isn't `xcode-select`ed by default: set
  `DEVELOPER_DIR` as above.
- **It boots folded.** Unfold with `baguette hinge` or the page's pose picker.
- **The pose picker has three poses** (closed, open, flat); Apple's Duo guidance lists
  six (closed, tent, open landscape, book, open portrait, laptop).
  `baguette hinge --angle` sets any angle 0–180; what SpringBoard makes of the
  ones between is the runtime's business.
- **Leave screen power alone.** Powering the unfolded panel on with
  `simctl io … screenConfig` lights nothing (the pose decides), and powering it
  *off* crash-loops SpringBoard.
- **The hinge reading can go silent after a SpringBoard restart**
  (`baguette heal`) until Device Hub or `baguette hinge` moves the pose; baguette
  remembers the silence for three seconds rather than making every call wait.
- **Rotation isn't read back.** The page's rotate button turns the book and tells
  the guest; a rotation made in Device Hub is its own, and the button brings the
  two into step.
- **`describe-ui` in landscape** maps frames through a portrait point size, as
  for a rotated iPhone; the open pose is landscape, so expect the same skew.
- A **shut-down** Duo's page shows the flat chrome (for the Boot card); the 3D
  book appears once it's booted. The CLI's `chrome` verbs and `bezel.png` always
  serve the flat chromes.
- **Keys ride the guest.** The Duo drops Indigo's keyboard message on either
  panel, so `type`, `key` and the page's keyboard press keys through
  `HingeControl`, modifiers held around each, as its hardware keys go. The
  first keystroke after a while costs the helper's spawn (most of a second).
- The Device Hub input heal ([device hub](../device-hub/README.md)) applies to
  the Duo like any iOS 27 device.

## See also

[design.md](design.md): panels, digitizer targets, the hinge path, keys and the
3D model · [hinge](../hinge/README.md) · [3D rendering](../3d-rendering/README.md) ·
[companion screens](../companion-screens/README.md) ·
[chrome bezel](../chrome-bezel/README.md)
