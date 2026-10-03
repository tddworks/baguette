---
description: View and drive a device's CarPlay / external display and its paired Apple Watch next to the phone, in the page's screens rail or from the CLI. Use when testing a CarPlay scene, an external-display window or a watch app.
---

# Companion screens

A simulator can drive more than its own glass. Two extra screens are worth
looking at next to the phone:

- **CarPlay** — an external display the host attaches to the *same* device. It
  is a second framebuffer plane on the same udid, reached with
  `?display=carplay` (or `--display carplay` on the CLI).
- **Apple Watch** — not a plane at all. A paired watch is a device of its own,
  with its own udid, boot state and framebuffer, so it streams down the
  ordinary phone-display route against that udid.

CLI: [`baguette screenshot`](../../commands.md#baguette-screenshot) and
[`baguette input`](../../commands.md#baguette-input) take `--display phone|carplay`.

## Quick start

In focus mode (`/simulators/<udid>`) both screens are offered from the
**screens rail** on the right edge, above the plugins rail. Every screen keeps
a slot whether or not it is there:

| State | Slot | Click |
| --- | --- | --- |
| attached / booted | lit | opens the pane |
| paired watch, not booted | dimmed | **Boot** button, then opens the pane |
| not there | dimmed | how to attach one, plus **Check again** |

To get one:

- **CarPlay** — Simulator.app → I/O → External Displays → CarPlay.
- **Apple Watch** — create a watch simulator in Xcode, then
  `xcrun simctl pair <watch-udid> <phone-udid>`.

The rail looks again whenever the page comes back to the foreground (exactly
the moment you return from Simulator.app), and on **Check again**. Which panes
you had open is remembered; a remembered pane whose screen has since gone away
is skipped rather than opened onto a dead socket.

From a terminal:

```sh
# one frame from the CarPlay plane (enables the display first)
baguette screenshot --udid <UDID> --display carplay -o carplay.png

# gestures against the CarPlay digitizer, over the stdin pipe
baguette input --udid <UDID> --display carplay < gestures.jsonl

# require an already attached display, without opening Simulator menus
baguette input --udid <UDID> --display carplay --require-existing-display < gestures.jsonl
```

The watch needs no flag: it is its own udid, so the ordinary commands point at it.

## Workflows

### Tap a CarPlay map template's nav-bar button

`CPMapTemplate`'s nav-bar `CPBarButton`s sit in the top band of the head unit
and can swallow a plain wire `tap` ([#75](https://github.com/tddworks/baguette/issues/75))
— the handler never fires and the app only sees the bar auto-hiding — while a
finger on the browser canvas at the same point presses the button. Everything
else on the plane (home-screen icons, the map itself, a presented
`CPListTemplate` / `CPGridTemplate` / `CPTripPreviewTemplate`) takes the
unflagged tap fine, which makes it look like wrong coordinates when it isn't.
Send the tap with the top-edge flag, which makes it byte-for-byte what the
browser sends:

```sh
printf '{"type":"tap","x":742,"y":44,"width":800,"height":480,"edge":"top"}\n' \
  | baguette input --udid <UDID> --display carplay
```

The bar auto-hides, so expect the first tap to wake it and a second ~700 ms
later to land. Whether the flag is what CarPlay keys on has not been confirmed
on a head unit — it is the measured difference, not a measured cause. See
[touches](../touches/README.md) for the `edge` field.

### Drive the watch

A watch pane has no bezel, so its two hardware buttons sit in a pill under it.
Both ride the ordinary `button` envelope ([wire.md](../../wire.md)) down the
watch's own socket as `digital-crown` / `side-button` / `left-side-button`.

| You want | Do this |
| --- | --- |
| tap something | click it |
| scroll a list | **drag** on the face |
| back to the watch face / app grid | **Crown** (press again for the grid) |
| Control Centre | **Side** |
| Siri, Wallet, power menu | not reachable — those are hold and double-press |

Verified against a real paired Series 11: tap launches an app, Crown walks
face → grid, Side opens Control Centre, drag scrolls Settings.

## HTTP

```
GET  /simulators/:udid/companion-screens.json   what's attached
POST /simulators/:udid/carplay-display          attach one, answer what it can do
```

```json
{
  "external": { "available": true, "width": 800, "height": 480 },
  "watch": {
    "available": true,
    "udid": "…",
    "name": "Apple Watch Series 11 (46mm)",
    "state": "Booted"
  }
}
```

The key is `external`, not `carplay`, and it carries the bound display's size:
the plane binds *the best external display*, whatever the I/O → External
Displays menu attached (CarPlay or a plain resolution). `available` means a
framebuffer actually binds, not just that a screen is listed — the same check
the stream performs, so the rail and the stream can't disagree. Absence is an
answer, not an error; only an unknown udid is a failure (404). Both probes fail
closed. Browser-facing only: these routes are not plugin-reachable.

For an already attached display, add `requireExistingDisplay=1` to the stream
WebSocket query. A missing display then fails the stream instead of attaching
one; any value other than a single `0` or `1` is rejected.

When a stream can't bind anyway, the socket gets `{"ok":false,"error":…}` and
closes; the pane shows the instructions plus the server's verbatim error
(`noMatchingPort(carPlay)`).

## Gotchas

- **Display enumeration respects `--device-set`.** The resolved custom
  directory is passed to `simctl`; an unavailable custom set does not select
  the default set. Enumeration waits up to 5 seconds for process exit and
  output, then requests termination and waits up to 1 more second. Throwing
  display resolution retains the exit status and diagnostic output on failure;
  availability probes keep their existing failure-handling behavior. On timeout
  or launch failure, output reads are cancelled and the pipe closes after
  pending I/O stops.
- **Blank is usually not baguette.** iOS does not mirror the phone onto an
  external display — an app has to put a scene or window on it — so a freshly
  attached plain-resolution display is black, in Simulator.app's window as
  much as in baguette's pane. CarPlay's dashboard is system UI and should
  appear on its own; a blank *CarPlay* display is a real runtime problem —
  see [design.md](design.md#why-an-external-display-is-usually-blank) for the
  log to check. If CarPlay is wedged, cold-boot the device rather than cycling
  the menu again.
- **The CarPlay menu entry may attach nothing while the plain resolutions
  work.** Observed on an iOS 27.0 beta: I/O → External Displays → CarPlay
  registers a screen with no framebuffer and no window appears. Pick a
  resolution instead; the rail reports either as an "External display" with
  its size (CarPlay's brand chrome may then be dressing a screen that isn't
  CarPlay).
- **Simulator.app hosts the display; baguette only streams it.** Quit
  Simulator.app and the guest tears the display down, and the pane goes with
  it. A screen still listed with no framebuffer (`simctl io <udid> screenshot
  --display <id>` fails with *"Timeout waiting for screen surfaces"*) is one
  whose host window has gone.
- **`--display` never falls back.** CarPlay with no framebuffer exits with
  `noMatchingPort(carPlay)` rather than showing the phone. An unrecognized value
  (`--display carply`) or an empty one (`--display "$PLANE"` with nothing in
  `$PLANE`) is a validation error, reported before the device is looked up.
  Omit the flag for the default.
- **Portrait externals are rejected.** The external plane must be landscape —
  strictly wider than tall, so a square surface is out too — and ≥ 50,000 px².
  There is no upper size bound — 1080p and 4K externals bind fine.
- **`POST /carplay-display` needs Automation + Accessibility permission** for
  whatever launched `baguette serve`, since it drives Simulator.app's menus.
  Without it the route answers 500 with that instruction. It is granted
  per-terminal, so a baguette started from a different shell may need it again.
- **CarPlay streams MJPEG regardless of the format picker.** H.264 starves on a
  mostly static screen without an IDR cadence the guest doesn't produce.
- **Watch:** the crown presses but doesn't turn (rotation is a HID axis baguette
  doesn't drive) — drag on the face to scroll. The scroll wheel does nothing
  over a watch pane (it emits a two-finger pan, which watchOS ignores in a
  list). Only a plain press is sent: double-press (Wallet) and holds (Siri on
  the crown, power menu on the side button) aren't offered yet.
- **Nothing is pushed from the host.** Attaching a display raises no event the
  browser can see; the rail asks on page load, on focus, and on **Check again**.

## See also

- [design.md](design.md) — the CarPlay HID service and target, why the rail probes the way it does, pane layout
- [touches](../touches/README.md) · [buttons](../buttons/README.md) · [iphone-duo](../iphone-duo/README.md)
