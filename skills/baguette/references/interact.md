# Interact — act on the screen as a user would

Read when: tapping, dragging, pinching, pressing hardware buttons, typing or
pasting text, or streaming many gestures. Every coordinate is in **device
points** with the screen's `width` / `height` alongside (see SKILL.md). The
full message spec is `wire.md`; flags: that command's `## baguette <cmd>` section of `commands.md`.

## Touches

```bash
baguette tap        --udid <X> --x 219 --y 478 --width 438 --height 954
baguette double-tap --udid <X> --x 219 --y 478 --width 438 --height 954
baguette swipe      --udid <X> --start-x 219 --start-y 760 --end-x 219 --end-y 190 \
                    --width 438 --height 954 --duration 0.3
baguette pinch / pan …                       # two-finger paths, see commands.md
```

Streamed touches (`input` / WebSocket): `touch1-{down,move,up}` for one
finger, `touch2-{down,move,up}` for two, plus `scroll`. A `touch1-*` chain can
carry `edge: "bottom" | "top" | "left" | "right"` to make it a screen-edge
system gesture: `bottom` drives the home indicator (live home / app switcher),
`top` the status bar (top-left drag → lock-screen cover, top-right →
Notification Center). Omit `edge` for ordinary touches. For pinches use
`touch2-*`; a `touch1-*` pinch reads as a pan.

## See what a tap did

`baguette tap … --describe-ui` waits for the screen to settle, then answers with
`changed` and the new tree. On a session, add `"describe_ui":true` to any gesture.
`changed:false` means the app's own tree didn't move: the tap may have hit blank
space, so tap the element's text or icon instead. A change inside a web page
may not count.

## Many gestures: stream them

`baguette input --udid <X>` reads one JSON gesture per stdin line and acks
each on stdout (`{"ok":true}` / `{"ok":false,"error":…}`): no per-gesture
process start, right for drags and choreography.

```bash
( echo '{"type":"tap","x":219,"y":478,"width":438,"height":954,"duration":0.05}'
  echo '{"type":"swipe","startX":219,"startY":760,"endX":219,"endY":190,"width":438,"height":954,"duration":0.3}'
) | baguette input --udid <X>
```

`ok:true` means sent, not that the screen reacted; verify with a screenshot.
`--expected-screen '<describe-ui screen JSON>'` refuses `down` / `move` once
the screen's size, rotation or lit panel no longer matches that observation.

## Hardware buttons

```bash
baguette press --udid <X> --button home
baguette press --udid <X> --button action --duration 2     # long press
```

`home`, `lock`, `power`, `volume-up`, `volume-down`, `action`,
`digital-crown`, `side-button`, `left-side-button`, plus gesture
shortcuts: `app-switcher` (two home presses ~150 ms apart),
`swipe-to-app-switcher` (slow drag and hold), `swipe-to-home` (fast edge
flick), `pull-down-to-lock-screen` (top-left), `pull-down-to-notification-center`
(top-right). `--duration` gives long-press semantics (action "Hold for Ring",
power → Siri / SOS). `siri` is refused: it crashes backboardd.

## Text

```bash
baguette type  --udid <X> --text "hello"                      # US-ASCII keystrokes
baguette key   --udid <X> --code KeyA --modifiers shift,command --duration 0.2
baguette paste --udid <X> --text "café 中文 🦄"                 # any unicode
```

- `type` / `key` press HID keys into the focused field: US layout only. `code`
  is a W3C `KeyboardEvent.code`; modifiers are `shift | control | option |
  command`. F-keys, Page Up/Down and Home/End are not supported.
- `paste` puts the text on the sim's pasteboard and presses Cmd+V
  (`--no-press` only sets the pasteboard). Use it for anything non-ASCII,
  and for long strings.
- Focus the field first (tap it). On iPhone Duo keys go through a helper in
  the guest; the first keystroke after a while costs most of a second.

### Software keyboard

Focus a text field, then run `baguette press --udid <X> --button software-keyboard`
to toggle the on-screen keyboard. The action does not report keyboard visibility
or change hardware-keyboard attachment. See
[Keyboard](https://github.com/tddworks/baguette/blob/main/docs/features/keyboard/README.md#software-keyboard).

## Clipboard

```bash
baguette clipboard get  --udid <X>   # print the sim's pasteboard
baguette clipboard sync --udid <X>   # host Mac pasteboard → sim, images included
baguette clipboard copy --udid <X>   # sim pasteboard → host Mac
```

On the stream WebSocket / `input`: `{"type":"paste","text":"…"}` (replies
`paste_result`) and `{"type":"copy"}` (presses Cmd+C, then ferries to the
host; replies `copy_result`); `{"type":"copy","press":false}` only ferries,
no keystroke. See
[paste](https://github.com/tddworks/baguette/blob/main/docs/features/paste/README.md).
