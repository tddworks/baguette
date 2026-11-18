---
description: Show and drive a physical iPhone on a cable the way you drive a simulator — screenshot, stream, record, rotate and use its pasteboard — through Xcode's devicectl. Use when an app must be checked on real hardware.
---

# Real devices

A paired iPhone (or iPad) on a cable is a device like any simulator: the same
`--udid`, the same commands. It does what Xcode's `devicectl` can do for it,
and refuses the rest by name. Every flag: [commands.md](../../commands.md).

## Quick start

```bash
baguette list                     # simulators, then physical devices:
# {"udid":"00008160-…","name":"han's iPhone","state":"ready","runtime":"","reality":"physical","model":"iPhone19,7"}

baguette screenshot --udid 00008160-… --output /tmp/phone.jpg
baguette stream     --udid 00008160-… > phone.mjpeg
baguette record     --udid 00008160-… --output phone.mp4 --duration 10
baguette orientation landscape-left --udid 00008160-…
baguette clipboard get --udid 00008160-…
```

In `baguette serve`, the phone appears under **Devices** on the list page;
its page (`/devices/<udid>`) asks for a borrowed bezel, then shows its screen.

## What a phone can do

| Ability | How | Note |
|---|---|---|
| screen (`screenshot`, `stream`, `record`) | `devicectl device capture screenshot` | about one frame a second, not a live stream |
| orientation | `devicectl device orientation set` | |
| pasteboard (`clipboard`, text in `paste`) | `devicectl device pasteboard` | |

Anything else answers with what's missing and exits 1:

```
$ baguette tap --udid 00008160-… --x 10 --y 10 --width 440 --height 956
[baguette] han's iPhone can't do input
$ baguette boot --udid 00008160-…
[baguette] han's iPhone can't do lifecycle
```

## HTTP and WebSocket

```
GET /devices.json                            → {"connected":[{"udid":…,"name":…,"model":…,"capabilities":["screen","orientation","pasteboard"]}]}
GET /devices/<udid>/definition.json?chrome=iPhone 17 Pro Max   → the page's bezel and screen geometry
WS  /devices/<udid>/stream?format=mjpeg|avcc → frames; a gesture answers {"ok":false,"error":"<udid> takes no input yet"}
```

## Gotchas

- **Ready means paired, Developer Mode on, and attached.** A phone off the
  cable lists as `unavailable` with the reason, and commands that show or
  move its screen say so: `Device han's iPhone is unavailable: not connected`.
- **A locked or dark phone shows black.** The screenshot is what the panel
  shows; wake and unlock the phone first.
- **No touches yet.** `devicectl` has no input verb. Input waits on
  CoreDevice's HID — see [design.md](design.md).
- **No apps, location, status bar or push.** `devicectl` covers part of each
  (install, a single location point), and a phone registers an ability only
  when it can do all of it.
- **The first frame takes a few seconds**: listing devices, then one
  screenshot, before anything streams.

## See also

- [devices design](../devices/design.md) — one device model, and what each family registers
- [design.md](design.md) — the CoreDevice spike for a live stream and input
- [device-twin](../device-twin/README.md) — a phone running the companion app, over Wi-Fi
