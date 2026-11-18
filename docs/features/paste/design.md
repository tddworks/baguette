---
description: How paste and copy reach the simulator's pasteboard — the devicectl-then-simctl write, the set-then-press vs press-then-read ordering, the stdin pipe, and the browser capture carve-outs. Read before touching pasteboard dispatch.
---

# Paste & clipboard — design

## Path

```
{"type":"paste",…} ─► PasteDispatch ─► Paste.execute(pasteboard:input:)
                                          1. Pasteboard.setText(text)
                                             └► SimctlPasteboard ─► xcrun devicectl device pasteboard copy --device <udid>
                                                                    (non-zero → xcrun simctl pbcopy <udid>; text over stdin)
                                          2. press? KeyV + [command]
                                             └► Key.key ───► IndigoHIDMessageForHIDArbitrary     (page 7, usage 0x19)

{"type":"copy",…}   ─► CopyDispatch  ─► Copy.execute(pasteboard:input:)
                                          1. press? KeyC + [command]
                                             └► Key.key ───► IndigoHIDMessageForHIDArbitrary     (page 7, usage 0x06)
                                          2. settle ~200ms, then Pasteboard.syncToHost()
                                             └► SimctlPasteboard ─► xcrun simctl pbsync <udid> host
```

`clipboard get` → `simctl pbpaste <udid>`; `clipboard sync` →
`simctl pbsync host <udid>`; `clipboard copy` → `Copy` with
`press:false`.

## Not a gesture

`paste` is **not** a `Gesture` and is not in `GestureRegistry`:
setting the pasteboard is an async host call, out of reach of the
sync, role-only `Gesture.execute`. Both wire entry points
intercept `paste` lines ahead of the gesture pipeline (the
`describe_ui` shape) via one shared `App/PasteDispatch`.

`copy` is the interactive mirror of `paste`, so it gets its own
`Copy` value + `CopyDispatch`: press Cmd+C (the focused field copies
its selection into the sim's pasteboard), let the guest settle, then
`syncToHost`. The **order is reversed** from paste — paste sets the
pasteboard *before* the keystroke, copy reads it *after* — so a short
settle covers the guest's key-event → `UIPasteboard` round-trip before
the sync reads it back. The settle is a timing guess, not a
handshake; a poll-until-changed read would be the robust follow-up.

The Cmd+V half is the ordinary keyboard path (`KeyboardKey` +
`[.command]` → HID page 7) — see [Keyboard](../keyboard/design.md).

## Writing: devicectl first, then `pbcopy`

Under Xcode 27 `simctl pbcopy` exits 0 and writes nothing (measured on
iOS 26.5, 27.0 and 27.1 guests), while Core Device's `devicectl device
pasteboard copy` lands and `simctl pbpaste` reads it back. So
`setText` tries devicectl first and falls back to `pbcopy` when it
exits non-zero — an Xcode without the subcommand (usage error, 64), or
one that does not know the device. No version check: an Xcode 26 host
keeps the route that works there.

## The stdin pipe

The pasteboard adapter is a `simctl` / `devicectl` path, not
SimulatorHID, and runs through the existing `Subprocess` collaborator.
The write reads its payload from **stdin**, so `Subprocess` grew a
second, stdin-carrying `run` requirement. The no-stdin variant still
wires `standardInput = nullDevice` (the Ctrl-C/SIGINT detachment
`baguette logs` depends on); the stdin variant uses a write pipe — no
controlling tty, so the SIGINT concern doesn't apply — written and
closed off-thread so a >64 KB payload can't deadlock against a full
pipe buffer.

## Browser capture

`baguette/parts/keyboard.js` owns every half:

- The keydown forwarder **carves out the paste chord**: Cmd+V /
  Ctrl+V is not forwarded and not `preventDefault`'d, so the
  browser fires its native `paste` event.
- A **document-level `paste` listener** (focus-gated on the screen
  element, like keydown) reads `event.clipboardData` text and sends
  the `paste` envelope. Document-level because Safari may target
  `<body>` rather than the focused non-editable div; the focus gate
  keeps sidebar pastes with the browser.
- The keydown forwarder also **carves out the copy chord**: Cmd+C /
  Ctrl+C is `preventDefault`'d and sends a `{type:"copy"}` envelope
  instead of forwarding the raw chord. The server presses Cmd+C
  sim-side and lands the result on the **host Mac's** clipboard
  (`pbsync <udid> host`) — no native `copy` event or Clipboard API
  involved.

`clipboardData` inside a user-initiated paste event is readable
without the async Clipboard API (which needs a secure context +
permission — unavailable over plain LAN http).

## Known limits

- Pasting image *bytes* from the browser's clipboard needs an
  upload-then-sync path or a UI affordance that triggers
  clipboard-sync.
- If a Safari version won't fire `paste` with focus on the
  non-editable screen div, the fallback is a hidden contenteditable
  focus proxy (not `navigator.clipboard.readText` — permission +
  secure-context problems).
