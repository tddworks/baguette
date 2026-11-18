---
description: Boot a shutdown simulator from the CLI, HTTP, the list page, the farm, or focus mode's on-screen Boot button. Use when a device isn't running yet or a deep link lands on a powered-off device.
---

# Booting a device

Every baguette surface that shows a simulator can also start one, including
**focus mode** (`/simulators/<udid>`), where a deep link lands you. Every flag:
[commands.md#baguette-boot](../../commands.md#baguette-boot).

## Quick start

```bash
baguette boot --udid <UDID>          # headless boot that survives the client disconnecting
baguette shutdown --udid <UDID>
```

Or open `/simulators/<UDID>` in `baguette serve` on a shutdown device: its
screen shows a **Boot** button.

| Surface | How |
|---------|-----|
| CLI | `baguette boot --udid <UDID>` |
| Focus mode | Open `/simulators/<UDID>` on a shutdown device; the screen shows **Boot** |
| List page | `/simulators`: boot / shutdown buttons per row |
| Device farm | `/farm`: per-tile and bulk boot ([device farm](../device-farm/README.md)) |

## Focus mode

A tab on a device that isn't booted shows a black "power card" on the
device's own glass instead of a black rectangle. It moves through four phases:

- **off**: the device is `Shutdown` / `ShuttingDown` / `Creating`. Shows the
  Boot button, and polls every 4 s, so a boot started anywhere else
  (`baguette boot`, another tab, Xcode, `simctl`) is picked up without a click.
- **booting**: the boot was accepted, or the device was already `Booting` when
  the tab opened (no second boot is sent). Polls once a second for up to 3 minutes.
- **starting**: CoreSimulator reports `Booted`, which is earlier than
  SpringBoard being on screen. The stream opens, but the card stays up until a
  frame actually paints, or 15 s pass (a device on a static screen may not
  produce a frame promptly).
- **gone**: the udid isn't in the device set at all. Nothing to boot; the card
  says so.

While the card is up, the toolbar (rotate, camera, status bar, location, logs,
AX inspector, home, screenshot, app switcher) is dimmed and disabled, since they
all need a live guest. The back link, theme toggle and sidebar-view toggle stay
active: they're how you leave a device that won't boot.

## HTTP

| Method | Path | Returns |
|---|---|---|
| POST | `/devices/<UDID>/boot` | `{"ok":true}`, or `{"ok":false,"error":"…"}` with 404 (unknown udid) / 422 (a device that can't be turned on, like a phone on a cable) / 500 (boot refused) |
| POST | `/devices/<UDID>/shutdown` | same shape |

A simulator answers under its old `/simulators/<UDID>/boot` and `/shutdown` too.

```bash
curl -X POST http://127.0.0.1:8421/devices/<UDID>/boot
```

`GET /simulators.json` reports each device's `state`: `"Creating"`,
`"Shutdown"`, `"Booting"`, `"Booted"` or `"ShuttingDown"`. Treat anything other
than `"Booted"` as not ready.

## Gotchas

- **Boot progress is binary.** `Booted` arrives well before SpringBoard
  renders; there's no progress fraction, hence "Starting…" plus a first-frame
  wait.
- **The 3-minute timeout is a guess**, not a CoreSimulator limit. A slow cold
  boot on a loaded Mac can exceed it; the card then re-offers Boot rather than
  failing hard.
- **Focus mode has no Shutdown.** Closing the tab leaves the device running
  (the boot is deliberately persistent); use the list page, the farm, or
  `baguette shutdown`.
- **Focus mode stops watching once live.** The 4 s poll runs only while the Boot
  button shows; if the device goes away underneath a live stream, frames just stop.
- **Xcode 27:** `baguette boot` also repairs the input surface Device Hub
  shadows (it restarts backboardd in the guest); `--no-heal` skips that. See
  [device hub](../device-hub/README.md).

## See also

[design.md](design.md): the boot call and how focus mode reads state ·
[device farm](../device-farm/README.md) · [device hub](../device-hub/README.md)
