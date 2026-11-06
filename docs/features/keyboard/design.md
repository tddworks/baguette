---
description: How keystrokes reach the simulator — IndigoHIDMessageForHIDArbitrary on HID page 7, the usage numbers and their quirks, modifier bracketing, and why IME is out of reach. Read before adding a key or touching keyboard dispatch.
---

# Keyboard — design

## Path

`baguette key` / `baguette type` / wire `key` · `type` / browser
`KeyboardCapture` → `Key` and `TypeText` gestures →
`Input.key(_:modifiers:duration:)` → `IndigoHIDInput.key` →
`IndigoHIDMessageForHIDArbitrary(target, page 7, usage, operation)`.

`type` text is decomposed into `(KeyboardKey, modifiers)` pairs at
parse time (`KeyboardKey.decompose(character:)`) and dispatched in
order at execute.

## How long a typed key is held

`type` holds each key for 30 ms; a single `key` keeps the adapter's 100 ms unless it asks otherwise. `gary@example.com` on a fresh app, 20 runs per row, iPhone 17 Pro, iOS 27.0, Device Hub closed:

| Hold | Exact text | Time per character |
|---|---|---|
| 100 ms | 20 of 20 | 104 ms |
| 50 ms | 20 of 20 | 54 ms |
| 30 ms | 20 of 20 | 34 ms |
| 20 ms | 20 of 20 | 24 ms |

It stays above the floor because `type` has no read-back to catch a dropped key; [fill](../fill/README.md) has one. Each key's `[hid] key` line prints only with `BAGUETTE_VERBOSE=1`.

## Dispatch — one path

Both `Key` and `TypeText` route through the same
`IndigoHIDMessageForHIDArbitrary(target, page, usage, operation)`
recipe as the bezel buttons ([Buttons](../buttons/README.md) — same
SimulatorKit symbol family, different HID page). iOS 26 signature:

```c
IndigoHIDMessage* IndigoHIDMessageForHIDArbitrary(
    uint32_t target,    // 0x32 — touch digitizer
    uint32_t page,      // 7 for keyboard / keypad
    uint32_t usage,     // HID usage code (e.g. 0x04 = 'a')
    uint32_t operation  // 1 down / 2 up
);
```

For a key with modifiers held, the adapter brackets the keystroke:

```
modifier-down (sorted) → key-down → hold(duration) → key-up → modifier-up (reversed)
```

Sorting modifiers by `rawValue` keeps the down/up order deterministic
so logs / tests stay reproducible — iOS itself doesn't care which
modifier fires first.

## Where the (page, usage) numbers come from

USB HID Usage Tables, page 7 (Keyboard / Keypad). The mapping is
hardcoded in `KeyboardKey.from(wireCode:)` and
`KeyboardKey.decompose(character:)`:

- Letters: `KeyA` … `KeyZ` → `0x04` … `0x1D`
- Digits: HID quirk — `Digit1` … `Digit9` = `0x1E` … `0x26`, `Digit0` = `0x27` (last)
- Keypad: same last-place quirk — `Numpad1` … `Numpad9` = `0x59` … `0x61`,
  `Numpad0` = `0x62`, `NumpadDecimal` = `0x63`; `NumpadDivide` = `0x54`,
  `NumpadMultiply` = `0x55`, `NumpadSubtract` = `0x56`, `NumpadAdd` = `0x57`,
  `NumpadEnter` = `0x58`, `NumpadEqual` = `0x67`. These are the keypad
  section of page 7 — distinct usages from the top-row digits, so iOS
  can tell a numpad `5` from a main-row `5`. `NumLock` is omitted (iOS
  has no num-lock concept).
- Specials: `Enter` = `0x28`, `Escape` = `0x29`, `Backspace` = `0x2A`,
  `Tab` = `0x2B`, `Space` = `0x2C`
- Arrows: `ArrowRight` = `0x4F`, `ArrowLeft` = `0x50`,
  `ArrowDown` = `0x51`, `ArrowUp` = `0x52`
- Modifiers: `Control` = `0xE0`, `Shift` = `0xE1`, `Option` = `0xE2`,
  `Command` = `0xE3` (left-side variants — iOS doesn't distinguish
  left/right at this surface)

A new key needs both the Swift wire-code map and the page's forwarded
list (`FORWARDED` in `keyboard-capture.js`); without the latter the
browser never sends it and it stays a host shortcut.

## Browser capture

`keyboard-capture.js`'s `KeyboardCapture` binds `keydown` on the
device's screen element and gates on `document.activeElement`; a
forwarded key is `preventDefault`'d, an unsupported one is dropped
**without** `preventDefault` so the browser keeps it. `mousedown` on
the screen takes focus. Mounted from `sim-native.js` (focus mode) and
`farm-tile.js` (focused farm tile).

## Known limits

- **No IME (phase 2).** IME / Pinyin / dead keys / emoji / non-Latin
  scripts need `IndigoHIDMessageForKeyboardNSEvent`, the 9-arg
  MainActor cousin of the mouse symbol, to read `NSEvent` thread-local
  state — unverified on iOS 26.
- CLAUDE.md's "Known iOS 26 limits" once said `key` / `type` keyboard
  input was "not yet on the host-HID path; routed through external
  tooling". The dispatch above is the host-HID path; what still needs
  another route is text the page-7 path can't express, which goes
  through [Paste](../paste/README.md).
