---
description: Stream, record, screenshot and drive this Mac's own displays as baguette devices, through ScreenCaptureKit and CGEvent. Use to watch or control a Mac desktop from the serve page, or to record it from the CLI.
---

# Mac screen

Each display attached to this Mac is a device: listed by its own UUID (the
same across reboots), watched through ScreenCaptureKit, and driven through the
window server — a finger is the mouse, the keyboard and scroll are the Mac's.
Everything a device's screen feeds works unchanged: `stream` (MJPEG, AVCC),
`record`, `screenshot`, the `serve` page and its WebRTC view.

Mac displays are **opt-in**: they show and control the Mac itself.

## Quick start

```bash
baguette list --mac                    # each display: {"udid":"<UUID>",…,"model":"DELL UP2716D"}
baguette screenshot --udid <UUID> -o desktop.jpg
baguette record --udid <UUID> -o desktop.mp4
baguette serve --share-mac             # the displays appear on the page beside the simulators
```

Giving a display's UUID to `--udid` is itself the ask: `stream`, `record`,
`screenshot` and `input` reach it without `--mac`. Flags:
[commands.md#baguette-list](../../commands.md#baguette-list),
[commands.md#baguette-serve](../../commands.md#baguette-serve).

## Permissions

The app that launches baguette (Terminal, iTerm, your IDE) needs two:

| Permission | For | Without it |
|---|---|---|
| **Screen & System Audio Recording** | the screen | starting a stream fails with `Screen Recording is not allowed …`; macOS prompts once |
| **Accessibility** | input | every gesture answers `ok: false`; the log says `[mac] input refused …`; macOS prompts once |

Listing asks for neither.

## Input

Wire coordinates are device points beside the `width` / `height` they were
measured in; a point lands at the same fraction of the display, wherever it
sits on the desktop — so the display's points (`baguette list --mac` shows
none; `CGDisplayBounds` has them) or the stream's frame size both work.

| Gesture | On the Mac |
|---|---|
| `tap` · `swipe` · `touch1-*` | a left click · a drag · press / drag / release |
| `hover` | the pointer moves with no button down — hover effects, tooltips, an auto-hidden Dock |
| `scroll` | the scroll wheel, in pixels, on the window under the pointer (the envelope has no point) |
| `key` | the Mac's key, with its modifiers held around it |
| `type` | the text, typed as it is; the wire takes US-ASCII only, as on every device ([keyboard](../keyboard/design.md)) |
| `touch2-*` · `pan` · two-finger paths | a trackpad's two-finger scroll, on the window under the fingers — what the page's mouse wheel sends; a pinch scrolls nothing |
| `button` | refused: a display has no buttons |

```json
{"type":"tap","x":640,"y":360,"width":2560,"height":1440}
```

**The pointer is drawn by the page**, never streamed: on the stream it would
trail the hand by the whole round trip. It takes the Mac's real shape — an
I-beam over text, a hand over a link — as the browser's own pointer for a
mouse or trackpad, and drawn where a finger touches. A pointer move still
waiting to reach the Mac is replaced by a newer one, so it never falls behind;
clicks, keys and scrolls keep their order. A mouse moving over the picture
moves the Mac's pointer too (hover) — so watch a display from another device:
from this Mac, hovering over a display's picture moves your own pointer there.

## Share to your device

With `serve --share-mac`, open **/mac/share** on a phone, tablet or another
Mac. This Mac makes a display **the shape of that screen** and shows it there,
full size, over WebRTC:

| Choice | Means |
|---|---|
| **Room** — Larger text · Standard · More space | the Mac's points are 1×, 1.5× or 2× the viewer's; Standard is the viewer's own pixels on a 3× phone |
| **Use as** — Main display · Extended display | main moves the menu bar, the Dock and new windows onto it, and gives main back when the share ends |

Turning the device remakes the display in the new shape (about 2 s); leaving
the page removes it. From a Home Screen icon the page has no browser bars, so
the display is the whole screen. Every display is 2× (HiDPI), at most 4096
pixels on its long side.

It streams in H.265 when the device's browser offers it (an iPhone's does), H.264
otherwise; **/mac/share?codec=h264** forces H.264. The server's log says which
each viewer got and what its browser offered (`[webrtc] viewer … sends …`) →
[hevc](../webrtc/hevc.md).

```
POST   /mac/shares        {"viewer":"iPhone","width":440,"height":956,"scale":3,"room":"standard","use":"main"} → 201 {"id"}
PUT    /mac/shares/<id>   {"width":956,"height":440,"scale":3}   ← the device turned
DELETE /mac/shares/<id>                                          ← it left
```

## Frames

A display shows with **no frame** until you pick one: the page's **Frame**
button, beside the device badge, offers the Mac frames that fit it, and No
frame. The pick is remembered per display.

A frame fits only a display of its screen's shape (within 2%), so the picture
is never stretched: a 16:9 display fits the iMacs, a MacBook's built-in panel
its MacBooks, a portrait display none. Install the frames that come with
baguette once — **MacBook Pro 14-inch (M4)** and **iMac 27-inch**:

```bash
scripts/install-mac-frames.sh                    # into ~/Library/Application Support/baguette/Frames
baguette serve --share-mac                       # reads that folder
baguette serve --share-mac --mac-frames ~/frames # or another folder, as <frame name>.png
```

Every frame baguette knows where the screen sits in is listed in
`MacFrame.measured`; a picture for any of them, named `<frame name>.png`, can be
dropped into the folder by hand.

```
GET /mac-frames.json?width=2560&height=1440          → {"frames":["iMac 24-inch","iMac 27-inch"]}
GET /devices/<UUID>/definition.json?chrome=iMac%2027-inch
GET /devices/<UUID>/screenshot-bezel.png?chrome=iMac%2027-inch   → the screen in the frame, as PNG
```

## Gotchas

- **The server must run from an app with the permissions.** Screen Recording
  and Accessibility belong to the app that starts `baguette serve` (iTerm,
  Terminal, …); started from one without them it can list, but not watch or drive.

- **Anyone who reaches the port controls this Mac.** `serve` binds
  `127.0.0.1`; with `--host 0.0.0.0 --share-mac` the desktop is on the network.
- **Large displays are scaled at the source** to 4096 pixels on the long side
  (the H.264 encoder's limit); a 5K display streams at 4096 × 2304.
- **A watched display shows the page watching it.** Watching the display the
  browser is on mirrors itself; watch another display, or from another machine.
- **An unchanged screen sends no new pictures**; the stream repeats the last.

## See also

- [design.md](design.md) — the ScreenCaptureKit and CGEvent paths, and what was decided
- [stream](../stream/README.md) · [webrtc](../webrtc/README.md) · [recording](../recording/README.md)
- [devices](../devices/design.md) — how a family registers its abilities
