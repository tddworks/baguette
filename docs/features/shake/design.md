---
description: Why baguette's shake posts a Darwin notification from a guest-spawned notifyutil instead of Simulator.app's GSEvent path, and what would force a switch.
---

# Shake — design

## Path

- `baguette shake`, `POST /devices/<UDID>/shake` (or `/simulators/…`) and the `serve` toolbar
  button share one dispatch → the `Shake` domain role → a spawned
  `simctl spawn … notifyutil`.
- The spawn rides the shared `Subprocess` collaborator, so everything but the
  real spawn is unit-covered via `MockSubprocess`.

## Dispatch — `simctl spawn notifyutil`

```
xcrun simctl spawn <udid> notifyutil -p com.apple.UIKit.SimulatorShake
```

`com.apple.UIKit.SimulatorShake` is the private Darwin notification
UIKit's shake detection observes. A `notify_post` from the **host** Mac
lands in the host's `notifyd`, which the iOS guest never sees — so the
notification is posted by `notifyutil` spawned *inside* the simulator
runtime via `simctl spawn <udid>`, where its `notify_post` reaches the
**guest's** `notifyd` and UIKit fires the motion event on the frontmost
responder.

This mirrors the widely-used in-app UI-test trick
(`notify_post("com.apple.UIKit.SimulatorShake")`), but posts from a
guest-spawned helper so no code has to run inside the target app.

## Dead end: the GSEvent / PurpleWorkspacePort path

Simulator.app itself synthesises shake via `-[SimDevice
gsEventsSendShake]` — a `kGSEventMotionBegin` (1020) GSEvent over
`PurpleWorkspacePort`, the same transport baguette's `orientation` uses.
That path is more "native", but unlike the orientation type-50 layout
(documented and unit-tested in `OrientationEvent`), the shake body bytes
(motion subtype / shake-state) aren't documented — reverse-engineering
them risks a `backboardd` crash on a wrong byte. The `simctl spawn`
notification path is documented, carries zero mach byte-layout risk, and
is unit-testable end-to-end. If a future need demands the GSEvent path
(e.g. a runtime without `notifyutil`), add a `PurpleEventShake`
alongside `PurpleEventOrientation` and swap it in `CoreSimulator.shake()`.

## Known limits

- **Depends on `notifyutil` in the runtime.** If a future iOS runtime
  drops the host `notifyutil` from the guest-spawn path, the spawn exits
  non-zero and the call reports `simctlFailed`; switch to the GSEvent
  path above.
- **Browser button is a dumb sender.** Unlike rotate there's no visual state
  to mirror — the motion event lives entirely inside the guest — so the
  handler doesn't touch the bezel.
