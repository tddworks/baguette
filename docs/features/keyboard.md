# Keyboard

Send keystrokes from the host Mac keyboard into the simulator, plus
explicit `key` / `type` verbs on the wire and CLI for scripting. Three
entry points share the same dispatch:

- `baguette key --code <KeyA…> [--modifiers shift,command] [--duration <s>]` — single keystroke.
- `baguette type --text "<string>"` — typed as a sequence of keystrokes.
- Wire JSON `{ "type": "key", "code": "KeyA", "modifiers": ["shift"] }` and
  `{ "type": "type", "text": "hello" }` on `baguette serve`'s WebSocket and
  `baguette input`'s stdin.
- Browser — when the device's screen surface has focus, every supported
  Mac keystroke is forwarded automatically.

This doc explains the wire surface, where the (page, usage) numbers
come from, and how the browser's focus-gated capture works. If you're
looking for the side buttons (volume / power / action), that's
[`buttons.md`](buttons.md) — same SimulatorKit symbol family
(`IndigoHIDMessageForHIDArbitrary`), different HID page.

## Supported surface (phase 1)

| Class               | Codes                                         |
|---------------------|-----------------------------------------------|
| Letters             | `KeyA` … `KeyZ`                                |
| Digits              | `Digit0` … `Digit9`                            |
| Named specials      | `Enter`, `Escape`, `Backspace`, `Tab`, `Space` |
| Arrows              | `ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight` |
| Punctuation (US)    | `Minus`, `Equal`, `BracketLeft`, `BracketRight`, `Backslash`, `Semicolon`, `Quote`, `Backquote`, `Comma`, `Period`, `Slash` |
| Modifiers           | `shift`, `control`, `option`, `command`        |

Codes are W3C `KeyboardEvent.code` strings so the browser can forward
events verbatim — no translation table on the JS side.

**Out of scope (phase 2):** IME / Pinyin / dead keys / emoji / non-Latin
scripts. Those need `IndigoHIDMessageForKeyboardNSEvent`, the 9-arg
MainActor cousin of the mouse symbol and unverified on iOS 26. F-keys,
Page Up/Down, and Home/End are also not in phase 1; they pass through
the host browser instead.

## Wire JSON

### Single keystroke

```json
{ "type": "key", "code": "KeyA", "modifiers": ["shift", "command"], "duration": 0 }
```

- `code` — required. One of the codes in the table above.
- `modifiers` — optional array of `shift | control | option | command`.
  Held around the keystroke (modifier-down → key-down → key-up →
  modifier-up). Order is normalised; duplicates are deduped.
- `duration` — optional, seconds. `0` (or absent) → ~100 ms tap;
  longer holds are clamped to a 20 ms floor (same rule as buttons).

Unknown codes / modifiers fail the parse with a clear `expected:` hint
rather than silently dropping the press.

### Typed text

```json
{ "type": "type", "text": "Hello, world!" }
```

- `text` — required. ASCII-printable on a US layout. Each character is
  decomposed into its `(KeyboardKey, modifiers)` pair at parse time
  (`'A'` → `(KeyA, [shift])`, `'!'` → `(Digit1, [shift])`, …) and
  dispatched in order at execute. Unsupported characters (non-ASCII,
  emoji, control characters) fail the parse — the alternative is
  silent data loss midway through a string, which is worse.

## Dispatch — one path

Both `Key` and `TypeText` route through `Input.key(_:modifiers:duration:)`
→ `IndigoHIDInput.key`, which uses the same
`IndigoHIDMessageForHIDArbitrary(target, page, usage, operation)`
recipe as the bezel buttons. iOS 26 signature:

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
- Specials: `Enter` = `0x28`, `Escape` = `0x29`, `Backspace` = `0x2A`,
  `Tab` = `0x2B`, `Space` = `0x2C`
- Arrows: `ArrowRight` = `0x4F`, `ArrowLeft` = `0x50`,
  `ArrowDown` = `0x51`, `ArrowUp` = `0x52`
- Modifiers: `Control` = `0xE0`, `Shift` = `0xE1`, `Option` = `0xE2`,
  `Command` = `0xE3` (left-side variants — iOS doesn't distinguish
  left/right at this surface)

## Browser overlay — focus-gated capture

`keyboard-capture.js` ships a single class:

```js
const cap = new KeyboardCapture({
  target: surface.screenArea,           // focusable element
  simInput: () => simInput,             // resolved lazily; survives session restarts
});
cap.start();   // bind keydown listener
cap.stop();    // unbind on teardown
```

The capture is **focus-gated**: while `document.activeElement` is the
device screen, every supported keystroke is forwarded as a `key`
envelope and `event.preventDefault`'d so host shortcuts (Cmd+R reload,
Cmd+T new tab, …) go to iOS instead of the browser. When focus moves
elsewhere, host shortcuts work normally. Mounted from both
`sim-native.js` (focus mode) and `farm-tile.js` (focused farm tile);
`mousedown` on the screen takes focus, so the gate opens automatically
when the user starts interacting with iOS.

Codes outside the supported set (F-keys, Page Up/Down, …) are dropped
**without** `preventDefault` so the host browser keeps handling them
— Cmd+Shift+I keeps opening DevTools, Cmd+L still focuses the
address bar, etc.

## Adding a new key

1. If the W3C code isn't in `KeyboardKey.wireCodeMap`, add the entry
   with its HID usage (`Domain/Input/Keyboard.swift`).
2. If the corresponding ASCII character is typeable, add it to
   `KeyboardKey.punctuationMap` (or extend the digits / letters
   branches in `decompose`).
3. Add the W3C code to `FORWARDED` in `keyboard-capture.js` so the
   browser actually forwards it (otherwise it stays a host shortcut).
4. Tests: extend `KeyboardKeyTests` (parse + decompose) and the
   `Key` / `TypeText` suites in `KeyboardTests.swift`.

## Known limits

- **No IME.** Pinyin / Korean / Japanese candidates can't be entered
  through the HID path. Phase 2 needs `KeyboardNSEvent` (MainActor +
  9-arg, like the mouse) to read `NSEvent.thread-local` state.
- **No emoji or accented characters.** US layout only; `é` / `中` /
  `🦄` are rejected by `decompose`.
- **No key repeat from CLI.** `baguette key` emits one keystroke; for
  held-key behaviour use `--duration`. Browser key repeat works via
  the OS firing repeated `keydown` events — each becomes its own
  press wire envelope.
- **No host-browser shortcut shadowing.** Cmd+W (close tab),
  Cmd+Shift+I (devtools), Cmd+L (address bar) can't be intercepted
  from a sandboxed page; they always go to the host browser.
