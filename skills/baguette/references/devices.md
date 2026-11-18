# Devices — get a simulator ready and know its shape

Read when: no device is booted, taps ack but nothing happens, you need the
screen size, or the device rotates or folds (iPhone Duo). Flags: that command's
`## baguette <cmd>` section of `commands.md`.

## Find, boot, shut down

```bash
baguette list                       # human-readable
baguette list --json                # {running, available}: pick a booted UDID
baguette boot --udid <UDID>         # waits for the boot to finish
baguette shutdown --udid <UDID>
baguette lifetime --detach          # keep devices booted when Simulator.app closes
```

`lifetime` is Simulator.app's setting: Device Hub ignores it, and quitting
Device Hub shuts every booted device down.

Every command takes `--device-set <path>` for a device in a custom set.

A paired iPhone on a cable lists after the simulators
(`"reality":"physical"`) and takes the same `--udid`: `screenshot`, `stream`,
`record` and `clipboard` work; `tap`, `swipe` and `input` touch it;
`describe-ui` reads its frontmost app's tree (about 2 s a read, one at a time
per phone), and `tap --label` presses an element by a touch at its centre.
Anything else answers `<name> can't do <ability>` and exits 1. Wake and unlock
the phone first: a touch doesn't wake a dark screen. See
[real devices](https://github.com/tddworks/baguette/blob/main/docs/features/real-devices/README.md).

## When input acks but lands nowhere: `heal`

Under Xcode 27, Device Hub can take over a device's input surface: every
gesture answers `{"ok":true}` and nothing happens on screen. `baguette boot`
repairs it on the way up; for a device booted some other way run
`baguette heal --udid <UDID>`. It restarts SpringBoard (running apps are
killed, the device is back in about four seconds). It comes back after Device
Hub is relaunched. See
[device hub](https://github.com/tddworks/baguette/blob/main/docs/features/device-hub/README.md).

## The screen's size — needed by every gesture

```bash
baguette describe-ui --udid <UDID> | jq '.screen | {width, height}'
# → {"width": 438, "height": 954}
```

The outer `screen` is in device points, the units every gesture's `width` /
`height` take. Read it per device and again after a rotation or a fold; never
hardcode. `chrome layout`'s `screen` is where the bezel image puts the screen,
in the image's units: right for drawing a frame, wrong for a gesture (on iPhone
Duo's unfolded panel it reads 626 × 890 for a 669 × 951 point screen).

## Rotate

```bash
baguette orientation --udid <UDID> landscape-left
# portrait | landscape-left | landscape-right | portrait-upside-down
```

## iPhone Duo (Xcode 27.1, iOS 27.1)

One device, two panels: a cover lit while folded and a larger unfolded panel.
The hinge decides which is lit, and `tap`, `type`, `screenshot`, `stream`,
`describe-ui` and `chrome layout` all follow the **lit** panel.

```bash
baguette hinge --udid <UDID>                 # read: {"angleDegrees": 130.0}
baguette hinge --udid <UDID> --pose open     # unfold: open (130°, as Device Hub does) | flat (180°) | closed (0°)
baguette hinge --udid <UDID> --angle 72      # any angle 0–180
baguette describe-ui --udid <UDID> | jq .screen   # now the unfolded panel's size
```

It boots folded. After a fold, read `describe-ui`'s `screen` again before tapping.
Exit code `3` means the guest helper timed out: the move may have landed, so
read the hinge before retrying. Never power a panel off with
`simctl io … screenConfig`; it crash-loops SpringBoard. See
[iPhone Duo](https://github.com/tddworks/baguette/blob/main/docs/features/iphone-duo/README.md).

## CarPlay

`baguette input --display carplay` and `baguette screenshot --display carplay`
target an attached CarPlay display; `input --require-existing-display` fails
rather than enable one. On the stream WebSocket it's `?display=carplay`, plus
`&requireExistingDisplay=1`; the `stream` CLI has no `--display`. See
[companion screens](https://github.com/tddworks/baguette/blob/main/docs/features/companion-screens/README.md).

## Not wired

A phone over Wi-Fi through the companion app (`/devices/:udid/companion/…`):
the host side exists but no companion app ships, so its gestures are rejected
with `device control is not wired yet`. A phone on a cable is wired (above).
