---
description: Send keystrokes and typed US-ASCII text to the simulator from the CLI, the input wire, or the host Mac keyboard on the serve page. Use when filling text fields, pressing Return / arrows / shortcuts, or scripting keyboard input.
---

# Keyboard

Send keystrokes into the simulator: `baguette key` for one key (with
modifiers), `baguette type` for a string, the same `key` / `type`
messages on the wire, and — on the `serve` page — the host Mac keyboard
whenever the device screen has focus. Every flag:
[commands.md#baguette-key](../../commands.md#baguette-key) ·
[commands.md#baguette-type](../../commands.md#baguette-type).

The side buttons (volume / power / action) are
[Buttons](../buttons/README.md).

## Quick start

```bash
baguette key  --udid <UDID> --code Enter
baguette key  --udid <UDID> --code KeyA --modifiers shift,command
baguette type --udid <UDID> --text "Hello, world!"
```

On the `serve` page, click the device screen and type.

## Software keyboard

Focus a text field in the simulator, then toggle its on-screen keyboard:

```bash
baguette press --udid <UDID> --button software-keyboard
```

Each press toggles the keyboard. The command does not report keyboard visibility
or force a keyboard to appear without a focused text field. Host typing uses the
existing `key` / `type` path. The [button envelope](../../wire.md#button) provides
the same action over stdin and WebSocket.

Verified on iPhone 17 with iOS 26.5 and Xcode 27.1. The software-keyboard toggle
has not been verified on iPhone Duo.

## Supported keys

| Class               | Codes                                         |
|---------------------|-----------------------------------------------|
| Letters             | `KeyA` … `KeyZ`                                |
| Digits              | `Digit0` … `Digit9`                            |
| Numpad              | `Numpad0` … `Numpad9`, `NumpadDecimal`, `NumpadAdd`, `NumpadSubtract`, `NumpadMultiply`, `NumpadDivide`, `NumpadEnter`, `NumpadEqual` |
| Named specials      | `Enter`, `Escape`, `Backspace`, `Tab`, `Space` |
| Arrows              | `ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight` |
| Punctuation (US)    | `Minus`, `Equal`, `BracketLeft`, `BracketRight`, `Backslash`, `Semicolon`, `Quote`, `Backquote`, `Comma`, `Period`, `Slash` |
| Modifiers           | `shift`, `control`, `option`, `command`        |

Codes are W3C `KeyboardEvent.code` strings, so the browser forwards
events verbatim. F-keys, Page Up/Down and Home/End aren't supported;
they pass through to the host browser instead.

## Wire (`baguette input` / stream WebSocket)

Envelope framing and acks: [wire.md](../../wire.md).

```json
{ "type": "key", "code": "KeyA", "modifiers": ["shift", "command"], "duration": 0 }
```

- `code` — required. One of the codes above.
- `modifiers` — optional array of `shift | control | option | command`.
  Held around the keystroke (modifier-down → key-down → key-up →
  modifier-up). Order is normalised; duplicates are deduped.
- `duration` — optional, seconds. `0` (or absent) → ~100 ms tap;
  longer holds are clamped to a 20 ms floor (same rule as buttons).

Unknown codes / modifiers fail the parse with a clear `expected:` hint
rather than silently dropping the press.

```json
{ "type": "type", "text": "Hello, world!" }
```

- `text` — required. ASCII-printable on a US layout; each character
  becomes its key plus modifiers (`'A'` → `KeyA` + shift, `'!'` →
  `Digit1` + shift), sent in order. Unsupported characters (non-ASCII,
  emoji, control characters) fail the parse — the alternative is
  silent data loss midway through a string, which is worse.

## Browser capture

The page's capture is **focus-gated**: while the device screen has
focus, every supported keystroke is forwarded as a `key` message and
kept from the browser, so host shortcuts (Cmd+R reload, Cmd+T new tab,
…) go to iOS instead. Clicking the screen takes focus, so the gate
opens as soon as you start interacting with iOS; when focus moves
elsewhere, host shortcuts work normally. Works in focus mode and on a
focused farm tile.

- The paste chord (Cmd+V / Ctrl+V) is left to the browser so its
  native `paste` event fires — the clipboard text then goes through the
  sim's pasteboard ([Paste](../paste/README.md)).
- Codes outside the supported set (F-keys, Page Up/Down, …) are left to
  the browser — Cmd+Shift+I keeps opening DevTools, Cmd+L still focuses
  the address bar.

## Gotchas

- **iPhone Duo types through the guest.** Its keys go through
  `HIDButtons` like its hardware keys ([iPhone Duo](../iphone-duo/README.md#gotchas));
  the first keystroke after a while costs the program's spawn.
- **No IME.** Pinyin / Korean / Japanese candidates can't be entered
  through this path.
- **No emoji or accented characters.** US layout only; `é` / `中` /
  `🦄` are rejected. For arbitrary unicode use
  [Paste](../paste/README.md) — it goes through the sim's pasteboard
  instead of keystrokes.
- **No key repeat from CLI.** `baguette key` emits one keystroke; for
  held-key behaviour use `--duration`. Browser key repeat works via
  the OS firing repeated `keydown` events — each becomes its own
  press.
- **No host-browser shortcut shadowing.** Cmd+W (close tab),
  Cmd+Shift+I (devtools), Cmd+L (address bar) can't be intercepted
  from a sandboxed page; they always go to the host browser.

## See also

- [design.md](design.md) — the HID dispatch recipe and where each usage number comes from
- [Paste](../paste/README.md) · [Buttons](../buttons/README.md)
