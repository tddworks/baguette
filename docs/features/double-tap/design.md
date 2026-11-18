---
description: Why baguette's double-tap is four touch1 events sequenced in one process rather than a dedicated Input.doubleTap private-API call.
---

# Double-tap — design

## Path

- `baguette double-tap` → an App-layer sequencer (`DoubleTapCommand.dispatch`)
  → the `Touch1` act → `Touch` → `IndigoHIDInput`, four times, with
  `Thread.sleep` between events.
- The wire has no envelope of its own: `baguette input` and the stream
  WebSocket already carry `touch1-down` / `touch1-up`, and a browser
  double-click produces the same four events.

## Why one process

iOS aggregates taps into a double-tap when the inter-tap delay is below the
recognizer's threshold (~0.25 s). Two back-to-back `baguette tap` invocations
spend ~150–300 ms each in process startup before they even open the HID port,
which is already at or beyond the recognizer's budget. So the whole
four-event sequence runs inside one process.

The defaults `interval = 0.05` and `duration = 0.08` match the cadence
observed in working WebSocket traces from issue
[#11](https://github.com/tddworks/baguette/issues/11) (tap-1-down → tap-1-up:
~118 ms, gap: ~49 ms, tap-2-down → tap-2-up: ~85 ms — well inside iOS's
~250 ms aggregation window).

## Why not a separate `Touch.doubleTap` method?

We considered widening the `Touch` protocol with a dedicated `doubleTap(...)`
method (so a single private-API call could synthesize both taps). We didn't,
because:

- The existing `touch1-*` path already produces the right wire sequence. iOS
  doesn't distinguish "two taps" from "one double-tap gesture" at the HID
  level — it's the recognizer's job to aggregate.
- Adding a method to `Touch` would force every consumer (CLI, WS,
  `baguette input`) to grow a parallel envelope shape with no new behaviour
  underneath.
- The composition lives where it belongs: in the App-layer command, where
  `Thread.sleep` is allowed and the four-event recipe is a ~30-line sequencer
  easily covered by a unit test that injects a `MockTouch` and a no-op sleep.

A `--count` flag for triple / N-tap is deliberately absent until a real use
case appears; the sequencer is hard-coded to two cycles.
