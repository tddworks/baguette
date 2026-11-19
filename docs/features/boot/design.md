---
description: How every boot entry point reaches one CoreSimulator call, and how focus mode reads device state without a new endpoint. Read before changing boot or adding a lifecycle control to focus mode.
---

# Booting a device: design

## Path

- CLI `baguette boot`, `POST /devices/<UDID>/boot` (or `/simulators/…`;
  `Server.applyPower`, which also serves `shutdown`), the list page, the farm
  and focus mode's Boot button → the device's `.power` → `Simulator.boot()`
- → CoreSimulator `bootWithOptions:error:` with `{"persist": true}` first
  (headless boot that survives the client disconnecting), falling back to
  `bootWithError:`.

## Focus mode reads state it already fetched

`sim-native.js` already fetched `/simulators.json` on load to resolve the
device's name and runtime; it reads `state` from the same response. No new
endpoint, no change to the definition payload.

```
GET /devices/<udid>             ← deep link
      │
      ▼
GET /simulators.json            ← name · runtime · state
      │
      ├── state == "Booted" ────▶ startSession() + reset to portrait
      │
      └── anything else ───────▶ power card on the device's glass
                                    │
                     ┌──────────────┴───────────────┐
                     │ off       Boot button        │◀── polls every 4 s
                     │ booting   POST /boot, poll   │    for a boot
                     │ starting  stream open,       │    started elsewhere
                     │           awaiting frame 1   │
                     │ gone      no such device     │
                     └──────────────┬───────────────┘
                                    ▼
                     first frame paints → card clears,
                     toolbar re-enables
```

- **gone** is detected by `definition.json` returning 404.
- **starting** has a 15 s fallback because `Screen` is pure pass-through and
  only emits when SimulatorKit composites, so a device on a static screen may
  not produce a frame promptly.
- The card lives inside the SDK bezel's `screenArea`, so it inherits the
  screen cutout's rounded clip and looks like a powered-off phone rather than a
  modal over the page. It is black in both light and dark themes for the same
  reason.
- While the card is up, `#simNativeView` carries `data-power="<phase>"`, which
  dims and disables `#nativeToolScroll` and `#nativeFormatPicker`.
- The portrait reset focus mode fires on load is gated the same way: an
  unbooted device has no `PurpleWorkspacePort` to receive the GSEvent.

## The state string

`/simulators.json` projects `SimulatorState.description` verbatim:
`"Creating"`, `"Shutdown"`, `"Booting"`, `"Booted"`, `"ShuttingDown"`. The
browser compares against `"Booted"` and treats everything else as not-ready, so
a new state added on the Swift side degrades to "show the Boot button" rather
than to a broken page.

## Adding a lifecycle control to focus mode

1. The route probably exists: `boot` and `shutdown` are both already registered
   via `Server.applyPower`.
2. Read whatever state you need from `fetchDeviceMeta` in `sim-native.js`;
   extend its return value rather than adding a fetch.
3. Render through `renderPowerCard(phase, detail)`: add a phase to the `copy`
   table and, if it needs a spinner, to the `SPIN_GLYPH` branch.
4. Style it in the `--- Power card ---` block of `sim-native.html`. The card is
   a container (`container-type: inline-size`), so type sizes use `cqw` and track
   the rendered bezel, not the viewport.
5. Keep the frontend a dumb sender: no state machine duplicated from Swift, no
   derived capability flags. It reads a state string and posts a verb.
