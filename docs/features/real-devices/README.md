---
description: Drive a physical iPhone on a cable the way you drive a simulator — tap, swipe, screenshot, stream, record, use its pasteboard — through Xcode's devicectl and CoreDevice. Use when an app must be checked on real hardware.
---

# Real devices

A paired iPhone (or iPad) on a cable is a device like any simulator: the same
`--udid`, the same commands. It takes touches through CoreDevice (the path
Device Hub uses), does what Xcode's `devicectl` can do for it, and refuses the
rest by name. Every flag: [commands.md](../../commands.md).

## Quick start

```bash
baguette list                     # simulators, then physical devices:
# {"udid":"00008160-…","name":"han's iPhone","state":"ready","runtime":"","reality":"physical","model":"iPhone19,7"}

baguette tap        --udid 00008160-… --x 220 --y 478 --width 440 --height 956
baguette swipe      --udid 00008160-… --start-x 380 --start-y 478 --end-x 60 --end-y 478 --width 440 --height 956
baguette screenshot --udid 00008160-… --output /tmp/phone.jpg
baguette stream     --udid 00008160-… > phone.mjpeg
baguette record     --udid 00008160-… --output phone.mp4 --duration 10
baguette clipboard get --udid 00008160-…
baguette describe-ui --udid 00008160-…   # the frontmost app's accessibility tree, as for a simulator
```

`baguette input --udid 00008160-…` takes the same one-gesture-per-line JSON as
for a simulator ([wire.md](../../wire.md)); `"edge":"bottom"` on a
`touch1-*` swipe goes Home.

In `baguette serve`, the phone appears under **Devices** on the list page; its
page (`/devices/<udid>`) asks for a borrowed bezel, then shows its screen and
turns clicks and drags into touches. Its badge says `DEVICE · touch`; the
crosshair opens the accessibility inspector over the phone's screen.

## What a phone can do

| Ability | How | Note |
|---|---|---|
| touches (`tap`, `swipe`, `pinch`, `pan`, `input`) | CoreDevice's Universal HID | edge swipes too; no buttons, keys or scroll yet |
| screen (`screenshot`, `stream`, `record`) | the phone's own H.264 stream, started through CoreDevice and received by baguette (`BAGUETTE_PHONE_SCREEN=avconference` for AVConference's own receiver, HEVC) | live, up to 60 fps; a start that fails reports why. A Mac without CoreDevice shows screenshots instead, about 5 a second |
| pasteboard (`clipboard`, text in `paste`) | `devicectl device pasteboard` | |
| accessibility (`describe-ui`, `tap --label`) | the phone's own accessibility service, over the tunnel | the frontmost app's tree, ~2 s; `tap --label` lands as a touch on the element |

Anything else answers with what's missing and exits 1:

```
$ baguette boot --udid 00008160-…
[baguette] han's iPhone can't do lifecycle
```

## HTTP and WebSocket

```
GET /devices.json                            → {"connected":[{"udid":…,"name":…,"model":…,"capabilities":["screen","input","pasteboard"]}]}
GET /devices/<udid>/definition.json?chrome=iPhone 17 Pro Max   → the page's bezel and screen geometry
GET /devices/<udid>/screenshot.jpg|png       → a still of any device's screen (a simulator's too); the /simulators knobs (?size= ?fit= ?background= ?scale=)
WS  /devices/<udid>/stream?format=mjpeg|avcc → frames down; stream controls and gestures up (the wire.md envelopes)
```

## Gotchas

- **Wake and unlock the phone first.** A touch doesn't wake a dark screen, a
  locked phone shows black, and a swipe in from the right on the Lock Screen
  opens the Camera.
- **The developer disk image must be mounted** for touches to land. Xcode
  mounts it; so does `xcrun devicectl device info ddiServices --device <udid>`.
- **Ready means paired, Developer Mode on, and attached.** A phone off the
  cable lists as `unavailable` with the reason: `Device han's iPhone is
  unavailable: not connected`.
- **`press`, `key`, `type` and scroll are refused, naming what's missing**
  (`han's iPhone can't do key`). They are other HID services; the phone has
  only its touchscreen. `paste --no-press` puts text on its pasteboard.
- **No orientation.** `devicectl device orientation set` exits 0 on a phone
  and leaves it as its sensors hold it, so a phone doesn't claim it: turn the
  phone by hand.
- **No apps, location, status bar or push.** `devicectl` covers part of each
  (install, a single location point); a phone registers an ability only when
  it can do all of it.
- **Two receivers for the live screen.** By default baguette receives and decodes it (H.264); `BAGUETTE_PHONE_SCREEN=avconference` has AVConference do it (HEVC), in baguette's own process. Compared in [screen-routes.md](screen-routes.md).
- **The first frame takes a second or two** while CoreDevice brings the tunnel up and the phone sends its first keyframe. While a stream runs, the phone shows that the Mac is viewing its screen.

## See also

- [design.md](design.md) — how a touch reaches the phone, and how its live screen is received
- [screen-routes.md](screen-routes.md) — the two receivers for its live screen, side by side and measured
- [devices design](../devices/design.md) — one device model, and what each family registers
- [device-twin](../device-twin/README.md) — a phone running the companion app, over Wi-Fi
