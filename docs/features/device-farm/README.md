---
description: One browser tab showing every booted simulator in Grid, Wall or List view, with filters, bulk boot/shutdown and a focus pane to drive one device. Use for multi-device QA sweeps or sharing one URL for reviewers to pick and drive a device.
---

# Device Farm

A multi-device dashboard at `GET /farm` under `baguette serve`: every booted
simulator in one tab, click a tile to focus it, drive the focused device with
gestures, and switch between Grid, Wall and List views. It's a thin client over
the same per-device stream WebSocket the single-device page uses: N concurrent
sessions, one focused at a time.

## Quick start

```bash
baguette serve
open http://127.0.0.1:8421/farm
```

Click a tile to focus it; the focus pane on the right shows a full-quality
preview you can tap, swipe and pinch. Clear focus to return it to a thumbnail.

## The page

```
┌─ HEADER ──────────────────────────────────────────────────────────┐
│ Baguette / DEVICE FARM   FLEET · FPS · BANDWIDTH · LATENCY · CLOCK│
├──────────┬───────────────────────────────────────────┬─┬──────────┤
│  RAIL    │  GRID / WALL / LIST                       │↔│FOCUS PANE│
│ Platform │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐      │big preview│
│ Runtime  │  │  📱  │ │  📱  │ │  📱  │ │  ⌚  │      │ TELEMETRY │
│ Status   │  └──────┘ └──────┘ └──────┘ └──────┘      │ CONTROLS  │
│ Display  │                                           │ GESTURE   │
│ Bulk     │                                           │           │
└──────────┴───────────────────────────────────────────┴───────────┘
└─ CLI MIRROR ──────────────────────────────────────────────────────┘
```

- **Views.** **Grid**: cards with bezel, status pip and readout, in a
  fixed-height (320 px) screen container so rows align across mixed device
  shapes. **Wall**: uniform 3:4 monitor-wall panels (status pip + channel on
  top, name + FPS below). **List**: a dense table with click-to-sort columns and
  hover-revealed quick actions. Switching views doesn't interrupt the streams.
- **Filters** (rail): platform (`iphone` / `ipad` / `watch` / `tv`, inferred
  from the device name), runtime (discovered from the device list), status
  (`live` / `boot` / `idle` / `off` / `error`), and free-text search over name,
  UDID, runtime and platform. Each option shows a count.
- **Show bezels** (rail): wraps every tile in its device bezel. Clicking a
  bezelled tile's screen selects the tile rather than tapping the device; the
  focus pane keeps full input.
- **Bulk actions** (rail): Boot Filtered, Snapshot All, Reset Streams, Shutdown
  Filtered. Tiles start and stop to match once a boot / shutdown finishes.
- **Focus pane width**: starts at 420 px; drag its left divider (bounded to
  260–720 px, always leaving at least 320 px for the fleet when the viewport
  permits). With the divider focused, arrow keys resize, Home/End jump to the
  bounds, double-click restores 420 px. The width is remembered per browser.
  Narrowing it also shortens portrait previews, which keeps the whole screen
  visible on displays with large OS scaling.
- **CLI mirror** (footer): reflects the current filter / focus state as a
  baguette-style invocation.

### Driving the focused device

Input goes to the preview in the focus pane, never to grid tiles.

| Input | Gesture |
|---|---|
| click / drag | 1-finger tap / swipe |
| ⌥ + drag | 2-finger pinch (mirrored through screen centre) |
| ⌥ + ⇧ + drag | 2-finger parallel pan |
| ⌃ + wheel, or Safari trackpad pinch | pinch stream |

### Streaming profiles

| Profile | Used for | fps | scale | bitrate |
|---|---|---:|---:|---:|
| THUMB | every unfocused tile | 8 | 4 | 600 kbps |
| FULL | the focused device | 60 | 1 | 6 Mbps |

Selecting a tile sends the FULL config over that device's stream socket;
clearing focus drops it back to THUMB.

### Catalog identity

`baguette list --json` and `/simulators.json` include stable catalog metadata
next to the editable `name`: `deviceTypeIdentifier`, `productFamily`,
`runtimeIdentifier` and `runtimeVersion`. The values come from the installed
CoreSimulator device type and runtime, so filtering by family or runtime keeps
working after a device is renamed; unavailable metadata is `null`.

## HTTP / WebSocket

| Method | Path | Returns |
|---|---|---|
| GET | `/farm` | The farm page |
| GET | `/farm/<file>` | The page's CSS / JS |

Everything else is shared with the single-device page: each tile opens the
per-device stream WebSocket, and profile changes are ordinary `set_fps` /
`set_scale` / `set_bitrate` messages ([wire.md](../../wire.md)). Bulk actions
fan out one `POST /devices/<UDID>/boot` or `/shutdown` per device
([boot](../boot/README.md)); there are no bulk endpoints.

## Gotchas

- **Past ~16 simultaneous thumbnails**, lower-end Macs start dropping animation
  frames. There's no automatic backpressure.
- **Bulk boot is a client-side fan-out.** Booting 30 devices at once serialises
  through the framework warm-up.
- **Only Home and Lock work** in the focus pane's button row; Vol +, Vol −,
  Snap UI and Rotate are shown but not wired to a device button yet.
- **Telemetry is partial.** Per-tile and aggregate FPS are real; header
  bandwidth / P50 latency and the focus pane's Latency P95, Bitrate and Memory
  gauges are placeholders until the server reports them.
- **The CLI mirror isn't runnable as-is**: `baguette serve` has no
  `--platform`, `--runtime` or `--focus` flags
  ([commands.md#baguette-serve](../../commands.md#baguette-serve)).
- **Saved layouts / groups aren't built**; the rail's "Groups" section is a
  static placeholder.
- **Drag-and-drop file upload isn't mounted on farm tiles**; use focus mode
  ([file upload](../file-upload/README.md)).

## See also

[design.md](design.md): why tiles mirror instead of move ·
[boot](../boot/README.md) · [recording](../recording/README.md) ·
[docs/ARCHITECTURE.md](../../ARCHITECTURE.md) for the tap-to-`UITouch` path ·
[serve.md](../../serve.md#editing-the-ui-without-rebuilding): `BAGUETTE_WEB_DIR` to edit the farm UI without rebuilding
