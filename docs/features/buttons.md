# Hardware buttons

Press-and-release of the physical side buttons on a simulated device:
home, lock, power, volume up / down, and the iPhone 15 Pro's action
button. Three entry points share the same dispatch:

- `baguette press --udid <UDID> --button <name> [--duration <sec>]` — CLI.
- Wire JSON `{ "type": "button", "button": "<name>", "duration": <sec> }`
  on `baguette serve`'s WebSocket and on `baguette input`'s stdin.
- Browser overlay — when `actionable` mode is on, each chrome button
  in the rendered bezel is a real DOM button. Click → tap; click and
  hold → real long-press.

This doc explains the wire surface, the two SimulatorKit code paths
the buttons travel through, and where the magic numbers come from. If
you're routing keyboard input or pointer touches, that's a different
pipeline — see `IndigoHIDInput.swift`'s commentary on the 9-arg mouse
recipe.

## Allowed buttons

| Wire name      | iOS effect                              | Dispatch path |
|----------------|-----------------------------------------|---------------|
| `home`         | Home / app switcher                     | `IndigoHIDMessageForButton` |
| `lock`         | Sleep / wake                            | `IndigoHIDMessageForButton` |
| `power`        | Sleep / wake (modern devices)           | `IndigoHIDMessageForHIDArbitrary` |
| `volume-up`    | Volume up                               | `IndigoHIDMessageForHIDArbitrary` |
| `volume-down`  | Volume down                             | `IndigoHIDMessageForHIDArbitrary` |
| `action`       | iPhone 15 Pro action button             | `IndigoHIDMessageForHIDArbitrary` |

`siri` is **explicitly rejected**: every Indigo path we tried crashes
`backboardd` on iOS 26.4. Don't add it back without a working recipe.

## Wire JSON

```json
{ "type": "button", "button": "action", "duration": 1.2 }
```

- `button` — required. One of the names in the table above.
- `duration` — optional, seconds. `0` (or absent) → ~100 ms tap.
  Non-zero is the down→up hold time; clamped to a 20 ms floor so a
  bogus `0.001` doesn't underrun the simulator's HID dispatch.

The CLI mirrors the wire field: `--duration 1.2` produces the same
effect.

## Why duration matters

iOS distinguishes tap vs long-press for almost every side button:

| Button         | Short tap                | Long hold (≥ ~0.8 s)        |
|----------------|--------------------------|------------------------------|
| `action`       | Fires the assigned shortcut | "Hold for Ring" / silent flip |
| `power`        | Sleep / wake             | Siri (≥ ~1.5 s) / Emergency SOS slider (≥ ~5 s) |
| `volume-up`    | Volume up                | Accessibility shortcut       |
| `volume-down`  | Volume down              | Accessibility shortcut       |
| `home`/`lock`  | n/a (already long-press unsafe at the legacy path) | n/a |

The browser overlay measures `mousedown` → `mouseup` and forwards the
elapsed time as `duration`, so holding the cap with the cursor "just
works." Programmatic clients have to pass `duration` themselves —
there's no implicit hold.

## Dispatch — the two paths

`IndigoHIDInput.button(_:duration:)` switches on the button enum:

### `home` / `lock` → `IndigoHIDMessageForButton`

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

### `power` / `volume-*` / `action` → `IndigoHIDMessageForHIDArbitrary`

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

Currently `IndigoHIDInput` hard-codes the same values in
`hidUsage(for:)`. They match the standard HID spec assignments and
agree across every iPhone chrome bundle we've inspected. If a future
device ships different codes we'll plumb them through chrome.json
parsing rather than chasing per-device branches.

## Browser overlay

`bezel-buttons.js` is the DOM-side renderer. It positions each
button image over the bare bezel using the offsets baked into
chrome.json, animates rollover / press states, and fires
`onPress(name, durationSeconds)` on `mouseup`. The wrapper in
`device-frame.js` forwards that to `simInput.button(name, duration)`,
which encodes the wire envelope.

Buttons that aren't in the `WIRE_BUTTON` table render but stay
inert with a tooltip explaining why — keeps the visual layout
honest without firing a no-op event.

## Adding a new button

1. Extend `DeviceButton` in `Domain/Common/CoordinateTypes.swift` with a
   case whose `rawValue` matches the wire / chrome.json name.
2. Update `Press.allowed` so error messages list it.
3. If it lives on a non-standard HID page, add an entry to
   `IndigoHIDInput.hidUsage(for:)`. If it needs the legacy
   `*ForButton` path instead, add to `buttonCodes(for:)` and the
   switch in `button(_:duration:)`.
4. Add a parse + execute test in `Tests/BaguetteTests/Input/GestureTests.swift`
   following the `parses <name> button` / `executes against the input
   surface` pattern.
5. Map the chrome.json `name` to the wire value in
   `Resources/Web/bezel-buttons.js`'s `WIRE_BUTTON` table so the
   overlay actually fires it.

## Known limits

- **`siri`** — every known Indigo path crashes `backboardd` on iOS
  26.4. The button is parseable in chrome.json but unmapped in
  `DeviceButton`; do not add a case until you have a tested recipe.
- **Holds beyond ~5 s** — the dispatch sleep blocks the calling
  thread. Streaming clients should split very long holds into separate
  `down` / `up` events through `touch1` if you need concurrent input
  during the hold.
- **Per-device usage codes** — currently hard-coded to the iPhone
  family's standard HID assignments. Devices with different chrome
  bundles (e.g. CarPlay accessory profiles) would need explicit
  parsing of `chrome.json`'s `usagePage` / `usage`.
