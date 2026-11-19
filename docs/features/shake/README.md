---
description: Deliver a motion shake to a booted iOS simulator, like Simulator.app's Device → Shake. Use when testing shake-to-undo or a shake-to-report menu.
---

# Shake

The frontmost app gets `motionBegan(_:with:)` / `motionEnded(_:with:)` with
`UIEventSubtypeMotionShake` — the standard "shake to undo" / shake-to-report
trigger. Every flag: [commands.md#baguette-shake](../../commands.md#baguette-shake).

## Quick start

```bash
baguette shake --udid <UDID>
```

Or click the shake button in the `serve` toolbar, next to Home / App switcher.
It's a fire-and-forget request, dimmed until the guest is live like every other
toolbar control.

## HTTP

```
POST /devices/<UDID>/shake           → {"ok":true}
                                       404 unknown udid
                                       409 the device isn't running
                                       422 the device can't shake
                                       500 shake failed (simctl error)
```

A simulator answers under its old `/simulators/<UDID>/shake` too.

## Gotchas

- **iOS only.** watchOS / tvOS have no shake concept, and CarPlay is a display
  surface, not a motion target. It fails cleanly (device-not-booted /
  unknown-udid) rather than silently no-op'ing.
- **Not a gesture.** Shake is a device action (like `orientation`,
  `status-bar`, `location`): there's no gesture-WebSocket / `baguette input`
  verb for it.
- **Single shake per call.** No intensity or repeat count — one `motionShake`
  per invocation. Loop client-side if you need a burst.
- **Frontmost-responder only.** iOS delivers `motionShake` to the first
  responder chain; a backgrounded app won't see it.

## See also

- [design.md](design.md) — why it goes through `notifyutil` in the guest
- [buttons](../buttons/README.md)
