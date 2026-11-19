---
description: How baguette's hardware-button presses reach SimulatorKit — the legacy IndigoHIDMessageForButton codes, the real IndigoHIDMessageForHIDArbitrary signature, and where each HID (page, usage) came from.
---

# Hardware buttons — design

## Path

- `baguette press`, the `button` envelope on `baguette input` / the stream
  WebSocket, and the page's bezel caps → `ButtonPress` act → `DeviceButton`,
  a `Navigation` (home, the app switcher, the edge pulls) or a `HardwareButton`
  (which knows its own standard `(page, usage)`) → refused by name unless the
  `Press` ability lists it `available` → `button(_:duration:)`.
- `IndigoHIDInput.button` (the simulator's `Press`) switches on the two kinds
  to one of two irreducible SimulatorKit calls, or an edge-flagged drag, each dispatched via `SimDeviceLegacyHIDClient.send`:

| Button         | Dispatch path |
|----------------|---------------|
| `home`         | `IndigoHIDMessageForButton` |
| `lock`         | `IndigoHIDMessageForButton` |
| `software-keyboard` | `IndigoHIDMessageForButton` |
| `power`        | `IndigoHIDMessageForHIDArbitrary` |
| `volume-up`    | `IndigoHIDMessageForHIDArbitrary` |
| `volume-down`  | `IndigoHIDMessageForHIDArbitrary` |
| `action`       | `IndigoHIDMessageForHIDArbitrary` |
| `app-switcher` | `IndigoHIDMessageForButton` × 2 (double home press, ~150 ms apart) |

## `home` / `lock` → `IndigoHIDMessageForButton`

Three-arg C function: `(buttonCode, operation, target)`. Codes are
hard-coded to what works on iOS 26.4:

```
home → (0x0, op, 0x33)
lock → (0x1, op, 0x33)
```

`op` is `1` for down, `2` for up — `0` crashes `backboardd`. The
`0x33` is the digitizer routing target. This recipe has been stable
through our test surface; don't generalize it without isolating each
button on a fresh sim.

`IndigoHIDMessageForButton` is pure C and thread-safe — useful as a sanity
check when input fails (unlike the mouse path, it doesn't need `MainActor`).

## `app-switcher` — a double home press

The dispatch fires two consecutive `home` `IndigoHIDMessageForButton`
messages ~150 ms apart. SpringBoard listens to that event source
independently of whether the device has home-button hardware, so this recipe
is rotation-agnostic and works across the iPhone X+ family.

## `software-keyboard` — on-screen keyboard toggle

`IndigoHIDMessageForButton(1008, operation, 0x33)` uses the same down/up chain
as `home` and `lock`. Xcode 27.1's SimulatorHID maps button `1008` (`0x3f0`)
to a keyboard event on HID consumer page `12`, usage `184` (`0xb8`). The SDK's
`IOHIDUsageTables.h` names that usage `kHIDUsage_Csmr_Eject`.

The mapping was inspected in `IOHIDEventFromIndigoHIDData`: the branch at image
offset `0x67e4` selects the page and usage, then reaches
`IOHIDEventCreateKeyboardEvent` at `0x6aa8`. The host function copies its three
arguments into the message without translating the button code.

This action toggles the software keyboard. Hardware-keyboard attachment is a
separate setting, exposed by CoreSimulator's
`setHardwareKeyboardEnabled:keyboardType:error:` selector. The toggle does not
change that setting or provide a keyboard-visibility query.

## `power` / `volume-*` / `action` → `IndigoHIDMessageForHIDArbitrary`

Four-arg C function. The signature is **not** what some open-source
loaders advertise. After reverse-engineering kittyfarm's typedef and
matching it against `nm` output of Xcode 26's `SimulatorKit`:

```c
IndigoHIDMessage* IndigoHIDMessageForHIDArbitrary(
    uint32_t target,    // 0x32 — same digitizer target the mouse path uses
    uint32_t page,      // HID usage page
    uint32_t usage,     // HID usage code
    uint32_t operation  // 1 down / 2 up
);
```

There is **no timestamp argument**. The `KeyboardArbitrary` variant
some loaders use is for HID page 7 (keyboard usages) only; the side
buttons live on pages 11 (telephony) and 12 (consumer), so they need
the generic `HIDArbitrary` symbol.

The pipeline is symmetrical to the legacy path: build a `down`
message, dispatch via `SimDeviceLegacyHIDClient.send`, sleep for the
hold window, build + dispatch an `up` message.

## Where the (page, usage) numbers come from

DeviceKit's `chrome.json` for each device declares the HID
`usagePage` / `usage` next to each button image. Example
(iPhone 12, abridged):

```json
{
  "name": "action",      "usagePage": 11, "usage": 45,
  "name": "volume-up",   "usagePage": 12, "usage": 233,
  "name": "volume-down", "usagePage": 12, "usage": 234,
  "name": "power",       "usagePage": 12, "usage": 48
}
```

`HardwareButton.standardHIDUsage` carries the same values, hardcoded.
chrome.json is consulted for *visual* button placement only — its
HID fields agree with the spec across every iPhone chrome bundle
we've inspected, so we don't read them at dispatch time. If a
future device ships non-standard codes, add a case to
`standardHIDUsage` rather than threading per-press overrides
through the wire.

## Browser overlay

The page positions each cap over the bare bezel from the pre-computed `box`
percentages `/simulators/<UDID>/definition.json` ships, and forwards
`mouseup` as a `{type:"button", button:<name>}` envelope with the real
`mousedown→mouseup` hold time. No HID codes, no chrome lookups, no geometry
math on the client — button identity, HID resolution and anchor-specific
placement live entirely in Swift; the JS sees four CSS-percent numbers and a
sprite URL per button. Chrome buttons whose `name` doesn't map to a known wire
button aren't emitted in the definition at all — keeps the visual layout
honest without rendering inert caps.

## Known limits

- **`siri`** — crashes `backboardd` via every known Indigo path (iOS 26.4);
  explicitly rejected. The button is parseable in chrome.json but unmapped in
  `HardwareButton`; do not add a case until you have a tested recipe.
- **Holds beyond ~5 s** — the dispatch sleep blocks the calling
  thread. Streaming clients should split very long holds into separate
  `down` / `up` events through `touch1` if you need concurrent input
  during the hold.
- **Per-device usage codes** — currently hard-coded to the iPhone
  family's standard HID assignments. Devices with different chrome
  bundles (e.g. CarPlay accessory profiles) would need explicit
  parsing of `chrome.json`'s `usagePage` / `usage`.
