---
description: Make apps in a simulator read CoreMotion — activity (walking, running, driving…), pedometer counts and accelerometer / gyro samples — from the CLI, HTTP or the Location card. Use when testing fitness, activity or motion-driven features.
---

# Motion

Make a simulator's apps read motion — `CMMotionActivity` (walking,
running, cycling, automotive), `CMPedometer` counters (steps, distance,
pace, cadence), and `CMMotionManager` samples (accelerometer, gyro,
device motion). Every flag:
[commands.md#baguette-motion](../../commands.md#baguette-motion).

Unlike [location](../location/README.md), **there is no `simctl` verb
behind this**: all three CoreMotion surfaces report unavailable in a
stock simulator, so baguette injects `VirtualMotion.dylib` into apps.
That has one consequence worth putting first:

> **Only apps launched _after_ motion starts see anything.** dyld inserts
> libraries at exec time. Relaunch the target app, or
> `xcrun simctl launch --terminate-running-process <udid> <bundle-id>`.

## Quick start

```bash
baguette motion start --udid <UDID> --activity running    # arm; then relaunch the app
baguette motion set   --udid <UDID> --activity cycling    # change it; no relaunch needed
baguette motion stop  --udid <UDID>                       # park as stationary, disarm
```

`--activity` is `stationary | walking | running | cycling | automotive`.
An unknown one is a parse error, never a silent `unknown` — that would
look like the feature was working. `--speed` is optional: each kind has
a representative pace (the same presets the browser's Walk mode
offers), so `--activity running` alone means a plausible run rather
than a run at 0 m/s. Plain `motion start` means walking.

`start` and `set` do the same publish; they're separate verbs because
"change what it's doing" reads differently from "turn this on", and only
`start` mentions the relaunch.

On the `serve` page: the focus-mode **Location** card's **Drive motion
sensors** toggle. Once it's on, the walk joystick and route speeds the
card already posts classify the activity — no second control surface.

## Workflow: drive it from a walk

Motion is **opt-in**. Arming rewrites a simulator-wide
`DYLD_INSERT_LIBRARIES` that only takes effect on the next app launch, so
it never happens as a side effect of moving the device. Once it *is* on,
the location routes drive it:

| Location request | Motion becomes |
| --- | --- |
| walk vector at 1.4 m/s | `walking` |
| walk vector at 6 m/s | `cycling` |
| route with `speed: 20` (or untuned — simctl's default) | `automotive` |
| bare `{latitude,longitude}` point | `stationary` |
| `DELETE …/location` | `stationary` |

Pinning a point parks it because that's exactly the moment the device
stops travelling — locationd drops `course` to `-1` — so an app shouldn't
keep reading a walk. The totals already walked survive.

Thresholds are pinned to the browser's own speed presets (`Walk 1.4 ·
Run 3.5 · Cycle 6 · Drive 13.4 · Highway 29`), so the preset a user picked
is the activity their app observes. A republish is skipped when the kind
is unchanged and the speed moved less than 0.1 m/s — the same epsilon
`sim-location.js` throttles its own sends with — but a kind change always
republishes, however small the speed step.

The pedometer is cumulative across a walk → stop → walk sequence
instead of resetting every time the joystick moves.

## HTTP

`POST /simulators/:udid/motion` accepts two spellings:

```json
{ "activity": "running", "speed": 3.6, "confidence": "high" }
{ "speed": 6 }
```

The first names the kind outright, as the CLI does. The second names only
how fast the device is moving and **the kind is classified server-side** —
that's what keeps `MotionKind`'s thresholds out of the frontend. The
browser uses the second, exactly as it already posts walk vectors.

Both return the current state, which is also what `GET` answers:

```json
{ "ok": true, "active": true, "activity": "walking",
  "steps": 24, "metres": 18.0, "speed": 1.40 }
```

`DELETE /simulators/:udid/motion` parks the device as stationary and
disarms, including after the server restarts: it resumes the published
pedometer totals, and a failed park or disarm returns an error and keeps the
cleanup pending until the next explicit stop. Restarting the server alone
does not stop guest injection. A body naming no activity and carrying no
speed returns `400`; an unknown udid `404`; a build with no bundled dylib
`500`.

Unlike location — which has no `GET`, because `simctl` can't report the
active position — motion **can** be read back: the state is baguette's own.

## Gotchas

- **Apps must be launched after arming.** dyld inserts at exec time; a
  running app sees nothing until it's relaunched. `motion set` reaches an
  already-running app fine — only the initial arm needs the relaunch.
- **Confirm injection is live** by launching anything, even Settings,
  and looking for the dylib's log lines:

  ```bash
  xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.baguette.motion"'
  # [VirtualMotion] activity hooks installed
  # [VirtualMotion] pedometer hooks installed
  # [VirtualMotion] motion-manager hooks installed (accelerometer=1 deviceMotion=1)
  ```

  A surface missing from that list failed its load-time self-check and
  reports the platform's honest "unavailable".
- **Injected, not simulated.** This lies to the app's own process. Nothing
  outside it (SpringBoard's own step tracking, Health) sees any of it, and
  a device that isn't running an injected app has no motion at all.
- **No floors, no magnetometer.** Floor counting needs barometric
  altitude, and a magnetic-field vector implies a compass heading, which
  the simulator can't have — refused rather than fabricated
  ([design.md](design.md#two-capabilities-refused-on-purpose)).
- **Gait is plausible, not physical.** A sine at the profile's cadence with
  a level attitude: enough for "is the device moving, how fast, in what
  mode". It won't satisfy an app doing real dead-reckoning or step
  detection from raw accelerometer peaks.
- **`CMMotionActivityManager`'s lite/periodic variants aren't hooked** —
  `startActivityLiteUpdates` and `startPeriodicActivityUpdates` still
  report unavailable.
- **Shares `DYLD_INSERT_LIBRARIES` with the [virtual camera](../camera/README.md).**
  Starting motion while the camera is armed keeps both; stopping either
  leaves the other alone.

## See also

- [design.md](design.md) — why it needs a dylib, the intent file, the measured CoreMotion ABI, the self-check
- [Location](../location/README.md) · [Camera](../camera/README.md)

A first publish may write the shared motion intent and arm the dylib before
it fails. The session keeps the cleanup responsibility: stopping still parks
the device and disarms injection, and a failed cleanup stays available for
retry. A retry banks what the guest actually read: a park that wrote
"stationary" before failing adds no steps for the time the device then stood
still, and a failed change of kind banks the kind that was published.
