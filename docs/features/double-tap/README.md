---
description: Send two taps at one point fast enough that UITapGestureRecognizer(numberOfTapsRequired: 2) and SwiftUI TapGesture(count: 2) fire. Use when testing double-tap-to-like, zoom or any count-2 tap.
---

# Double-tap

Two taps at one coordinate, close enough together that
`UITapGestureRecognizer(numberOfTapsRequired: 2)` and SwiftUI
`TapGesture(count: 2)` both fire. Every flag:
[commands.md#baguette-double-tap](../../commands.md#baguette-double-tap).

Two back-to-back `baguette tap` calls **don't** do this: iOS aggregates taps
only when the inter-tap delay is under the recognizer's threshold (~0.25 s),
and each `baguette tap` spends ~150–300 ms in process startup before it even
opens the HID port. The whole four-event sequence has to happen inside one
process — `baguette double-tap`, or four `touch1-*` lines on one connection.

## Quick start

```bash
baguette double-tap --udid <UDID> \
  --x 220 --y 480 --width 402 --height 874

# Override timing for a recognizer with non-default tapDelay:
baguette double-tap --udid <UDID> \
  --x 220 --y 480 --width 402 --height 874 \
  --interval 0.08 --duration 0.05
```

`x` / `y` are device points; `width` / `height` are the device's point size,
the same units as every other gesture. `--interval` is the gap between
tap-1-up and tap-2-down; `--duration` is the hold per tap. The defaults
(`0.05` / `0.08`) match the cadence of working WebSocket traces from issue
[#11](https://github.com/tddworks/baguette/issues/11) (tap-1-down → tap-1-up
~118 ms, gap ~49 ms, tap-2-down → tap-2-up ~85 ms — well inside iOS's
~250 ms aggregation window).

Exit code `0` on success, `1` if the device isn't booted or the HID dispatch
fails on any of the four events. Output is one JSON ack line:

```json
{"ok":true,"action":"double-tap"}
```

In the browser, a user double-click on the `serve` page produces the same
four-event sequence through the existing dispatcher.

## Workflows

### Verify against a SwiftUI recognizer

```swift
Image(systemName: "heart")
    .onTapGesture(count: 2) { liked.toggle() }
```

With the app running on a booted iPhone 17 (402×874 points):

```bash
UDID=$(baguette list --json | jq -r '.running[0].udid')
baguette double-tap --udid "$UDID" --x 201 --y 437 --width 402 --height 874
```

The toggle should fire on the first invocation. If it doesn't,
`baguette logs --udid "$UDID" --predicate 'process == "SpringBoard" OR process == "<your-app>"'`
shows whether the recognizer thinks it received one or two taps.

## WebSocket / `baguette input`

There is no `{"type":"double-tap"}` envelope — the streaming primitives
already cover it. Send four lines on **one** connection (`baguette input`
stdin or the `serve` stream WebSocket; envelope shape in
[wire.md](../../wire.md)):

```json
{"type":"touch1-down","x":220,"y":480,"width":402,"height":874}
{"type":"touch1-up",  "x":220,"y":480,"width":402,"height":874}
{"type":"touch1-down","x":220,"y":480,"width":402,"height":874}
{"type":"touch1-up",  "x":220,"y":480,"width":402,"height":874}
```

Timing is wall-clock on the wire: each event lands on iOS as it arrives, so
the cadence you send is the cadence the recognizer sees. ~80 ms hold per tap
and ~50 ms gap is known-good; a trace from `baguette serve`:

```
11:59:16.217  touch1-down
11:59:16.335  touch1-up    (hold ≈ 118 ms)
11:59:16.384  touch1-down  (gap  ≈  49 ms)
11:59:16.469  touch1-up    (hold ≈  85 ms)
```

This is exactly what `baguette double-tap` produces internally, with sleeps
between events instead of relying on your stream timing.

## Gotchas

- **Wrong `--width` / `--height` is the usual cause of "only one tap fired".**
  Both taps land at the same wrong fraction of the screen, and the recognizer
  treats the second `down` as a no-op.
- **Two cycles only.** Triple-tap and N-tap recognizers aren't exposed; there
  is no `--count`.
- **Tight custom recognizers.** The 0.05 s default interval is comfortably
  inside UIKit's default `tapDelay`, but a recognizer with a tightened
  `maximumIntervalBetweenSuccessiveTaps` may need an explicit `--interval`.
- **Not for hardware double-presses.** Buttons that double-fire (e.g.
  double-press the side button on Apple Watch to confirm a payment) ride a
  different path — see [buttons](../buttons/README.md).

## See also

- [design.md](design.md) — why double-tap is a CLI composition, not a `Touch` method
- [buttons](../buttons/README.md)
- [wire.md](../../wire.md) — `touch1-*` envelopes
