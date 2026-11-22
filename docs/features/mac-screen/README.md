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

Wire coordinates are the display's **points** (`width` / `height` as
`/devices.json` reports them), placed on the desktop where the display sits.

| Gesture | On the Mac |
|---|---|
| `tap` · `swipe` · `touch1-*` | a left click · a drag · press / drag / release |
| `scroll` | the scroll wheel, in pixels |
| `key` | the Mac's key, with its modifiers held around it |
| `type` | the text as it is — any script, not only US-ASCII |
| `touch2-*` · `pinch` · two-finger paths | `ok: false`: the Mac has one pointer |
| `button` | refused: a display has no buttons |

```json
{"type":"tap","x":640,"y":360,"width":2560,"height":1440}
```

## Gotchas

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
