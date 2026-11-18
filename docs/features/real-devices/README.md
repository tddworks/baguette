---
description: Drive a physical iPhone on a cable the way you drive a simulator — tap, swipe, screenshot, stream, record, rotate, use its pasteboard — through Xcode's devicectl and CoreDevice. Use when an app must be checked on real hardware.
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
baguette orientation landscape-left --udid 00008160-…
baguette clipboard get --udid 00008160-…
```

`baguette input --udid 00008160-…` takes the same one-gesture-per-line JSON as
for a simulator ([wire.md](../../wire.md)); `"edge":"bottom"` on a
`touch1-*` swipe goes Home.

In `baguette serve`, the phone appears under **Devices** on the list page; its
page (`/devices/<udid>`) asks for a borrowed bezel, then shows its screen.

## What a phone can do

| Ability | How | Note |
|---|---|---|
| touches (`tap`, `swipe`, `pinch`, `pan`, `input`) | CoreDevice's Universal HID | edge swipes too; no buttons, keys or scroll yet |
| screen (`screenshot`, `stream`, `record`) | `devicectl device capture screenshot` | about one frame a second, not a live stream |
| orientation | `devicectl device orientation set` | |
| pasteboard (`clipboard`, text in `paste`) | `devicectl device pasteboard` | |

Anything else answers with what's missing and exits 1:

```
$ baguette describe-ui --udid 00008160-…
[baguette] han's iPhone can't do accessibility
$ baguette boot --udid 00008160-…
[baguette] han's iPhone can't do lifecycle
```

## HTTP and WebSocket

```
GET /devices.json                            → {"connected":[{"udid":…,"name":…,"model":…,"capabilities":["screen","input","orientation","pasteboard"]}]}
GET /devices/<udid>/definition.json?chrome=iPhone 17 Pro Max   → the page's bezel and screen geometry
WS  /devices/<udid>/stream?format=mjpeg|avcc → frames; stream controls only
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
- **`press`, `key`, `type` and scroll answer `"ok":false`.** They are other HID
  services; only the touchscreen is wired. Text goes through `paste`.
- **No apps, location, status bar or push.** `devicectl` covers part of each
  (install, a single location point); a phone registers an ability only when
  it can do all of it.
- **The first frame takes a few seconds**, and a screenshot can wait up to five.

## See also

- [design.md](design.md) — how a touch reaches the phone, and why the screen isn't live yet
- [devices design](../devices/design.md) — one device model, and what each family registers
- [device-twin](../device-twin/README.md) — a phone running the companion app, over Wi-Fi
