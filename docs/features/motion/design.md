---
description: Why motion is injected rather than simulated — the CoreMotion/locationd capability gate, the per-simulator intent file, and the measured private-initialiser ABI traps VirtualMotion.dylib relies on. Read before touching motion or the dylib.
---

# Motion — design

## Why this needs a dylib at all

The platform refuses, at a level nothing on the host can reach. Measured
on iOS 26.5 and 27.0, from a real installed app with Motion permission
granted (`authorizationStatus == 3`):

| Call | Stock simulator |
| --- | --- |
| `CMMotionActivityManager.isActivityAvailable()` | `false` |
| `startActivityUpdates` | locationd: *"Cannot subscribe to motion activity updates, motion activity is not available"* |
| `queryActivityStartingFromDate:` | `CMErrorDomain 104`, no results |
| `CMPedometer.isStepCountingAvailable()` | `false` |
| `CMMotionManager.isAccelerometerAvailable` | `false` |

Both CoreMotion **and** locationd gate on bit 23 of a hardware-capability
word derived from the device's HW type, and a simulated device is an
"Unsupported HW type" — so every motion capability reads 0. The runtime
even ships a simulation hook for this
(`-[CMActivityManager simulateMotionState:withState:withHint:]` →
`kCLConnectionMessageMotionStateSim` → `CLMotionCoprocessor::setMotionStateSim`);
locationd accepts the message and it changes nothing, because the
availability gate sits upstream of it. The only override preference on
that path is `OverrideMotionCapEclipseService`, which controls the AOP
suppression service, not activity.

So the honest options were "document it as impossible" (as `CLHeading`
is — see [Location](../location/README.md)) or lie convincingly
*inside the app's own process*. baguette already injects
[`VirtualCamera.dylib`](../camera/README.md) for the same reason, so the channel
existed.

## Path

```
   Host (Swift, tested)                          iOS Simulator app
┌──────────────────────────┐                  ┌────────────────────────┐
│ MotionKind.from(speed:)  │                  │ CMMotionActivityManager│
│ MotionProfile(kind:speed:)│                 │ CMPedometer            │
│ MotionLedger.banking()   │                  │ CMMotionManager        │
│ MotionIntent.encoded()   │                  └───────────▲────────────┘
└───────────┬──────────────┘                              │ swizzled
            │  /tmp/BaguetteMotion-<udid>.json            │
            ▼  (shared /tmp, as the camera uses)          │
      ┌───────────┐        launchctl setenv        ┌──────┴───────────┐
      │  Motion   │  ───── DYLD_INSERT_LIBRARIES ─▶│ VirtualMotion    │
      │ @Mockable │                                │ .dylib           │
      └───────────┘                                │ (integrates the  │
            ▲                                      │  intent locally) │
  location walk/route ── drives when armed ──┘     └──────────────────┘
```

The intent file is **scoped per simulator** (`/tmp/BaguetteMotion-<udid>.json`).
Every simulator sees the host's `/tmp`, so one shared file would mean a
publish for one device replacing what an injected app on another is still
reading. The dylib derives the same path from its own `SIMULATOR_UDID`, which
the simulator sets in every process it launches; with no UDID it reports no
motion rather than guessing at another device's file.

## Why an intent, not a sample stream

A pedometer accumulates monotonically and `CMMotionManager` delivers at up
to 100 Hz. Neither can be fed sample-by-sample across a file boundary, so
the host publishes a **description** — *running at 3.6 m/s since T, with N
steps already accrued* — and the dylib integrates from it.

Every judgement call is resolved host-side and arrives pre-computed:
stride length, cadence, gait amplitude (`MotionProfile`), the raw
`CLMotionActivity.type` and confidence values (`MotionKind`), and the
running totals (`MotionLedger`). The dylib does arithmetic only. Same
division of labour the browser has with the Swift side.

`stepsBefore` / `distanceBefore` are what make the pedometer cumulative
across a walk → stop → walk sequence instead of resetting every time the
joystick moves.

## What the dylib fabricates, and the ABI notes worth preserving

CoreMotion's data classes have no public initialisers, so each is built
through its private designated initialiser. **Every detail below was
measured against booted iOS 26.5 / 27.0 runtimes, not read from a header**
— the failure mode for guessing is a crash or silent zeros. They live in
`Injected/VirtualMotion/Sources/VirtualMotionFactory.m`.

- **`CMAccelerometerData` / `CMGyroData` / `CMMagnetometerData` take their
  `{fff}` struct BY VALUE.** It's 12 bytes, so arm64 passes it in
  registers; handing over a pointer reads zeros *and* displaces the
  trailing `double` timestamp.
- **`CMGyroData`'s initialiser takes degrees per second**, while the public
  `rotationRate` property returns radians — feed it 0.25 and it reads back
  0.004. `CMDeviceMotion`'s `rotationRate` is *already* radians. Two
  conventions in one framework.
- **`CMDeviceMotion`'s quaternion is stored `w,x,y,z`** while the public
  `CMQuaternion` is `x,y,z,w`. Its `userAcceleration` triple is at `+32`
  and `rotationRate` at `+44`.
- **`gravity` is derived from attitude and cannot be set.** An identity
  attitude yields `(0,0,-1)`; a 90° rotation about x yields `(0,-1,0)`. A
  level attitude is what makes gravity look like an upright phone.
- **`CMDeviceMotion` ignores its own `timestamp:` argument.** The value
  lives in `CMLogItemInternal.fTimestamp`, reachable through `CMLogItem`'s
  `_internalLogItem` ivar.
- **`CMMotionActivity` must go through `-initWithMotionActivity:`.** Poking
  ivars after a bare `+alloc` *looks* fine — the boolean getters read back
  correctly — then crashes in `-description`, `-copy`, `-timestamp` and
  `NSKeyedArchiver`, because `CMLogItem`'s own state is never initialised.
  Any app doing `NSLog(@"%@", activity)` would take the app down.
  Its `CLMotionActivity` field offsets: type `+0`, confidence `+4`,
  timestamp `+40`, startTime `+80` (seconds since the 2001 reference date);
  the struct's size is derived at runtime from the `fState`/`fEndTime` ivar
  gap rather than hardcoded.
- **`CLMotionActivity.type` values are measured, and the enum is not
  dense:** `0` unknown, `1` stationary, `4` walking, `5` automotive,
  `6` cycling, `8` running. `2` also reads as stationary and `3`/`7`/`9`
  read as no flags at all, so only those six are trusted.
- **`CMPedometerData` is a plain `NSObject`** with object-typed ivars, so
  KVC on them is enough — no superclass to trip over.

## The self-check

`VMFactorySelfCheck` builds one of each object at load and verifies the
values through the public API. **A surface that fails verification is not
hooked**, so a future iOS layout change leaves apps seeing the platform's
honest "unavailable" rather than fabricated garbage. The result is logged:

```bash
xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.baguette.motion"'
# [VirtualMotion] activity hooks installed
# [VirtualMotion] pedometer hooks installed
# [VirtualMotion] motion-manager hooks installed (accelerometer=1 deviceMotion=1)
```

That's also the fastest way to confirm injection is live: launch anything,
even Settings, and look for those lines.

The dylib logs through `os_log`, never `NSLog`. It is loaded into *every*
process launched while motion is armed — including the `launchctl` baguette
spawns to read `DYLD_INSERT_LIBRARIES`. Diagnostics belong in the unified
log rather than a command's output streams.

## Sharing `DYLD_INSERT_LIBRARIES`

That variable is one string for the whole simulator, and baguette now
injects two dylibs (this and the [virtual camera](../camera/design.md#sharing-dyld_insert_libraries)).
Arming is a read-modify-write through the pure `InjectedDylibs`, matching
entries by **dylib filename** because every release installs under a fresh
sha-keyed directory. Starting motion while the camera is armed keeps both;
stopping either leaves the other alone.

Environment reads keep stdout separate from guest diagnostics and abort on
unknown failures; see the [shared injection boundary](../camera/design.md#sharing-dyld_insert_libraries).

## Two capabilities refused on purpose

- **Floor counting** (`isFloorCountingAvailable`) — needs barometric
  altitude, which no published intent carries. Reporting a fabricated
  storey count would be worse than saying no.
- **The magnetometer** (`isMagnetometerAvailable`) — a magnetic-field
  vector implies a compass heading, and `CLHeading` is
  [documented as impossible](../location/README.md) in the
  simulator. Gait acceleration follows from walking; a bearing doesn't.

## Adding a new motion surface

`CMAltimeter` (relative altitude / pressure) is the obvious next one.
**Probe first.** Dump the data class's ivars and initialisers inside a
booted sim and verify a fabricated instance reads back through the
public API — including `-description`. Guessing an ABI here crashes the
app under test. The dylib side is a factory function in
`VirtualMotionFactory.m` with its measured ABI notes, a `VMFactoryHealth`
flag, and hooks installed only when that flag verified; record what you
measured here, and be explicit about anything you refuse to fabricate.

## Known limits

- **Only apps launched after arming see anything** — dyld inserts at
  exec time.
- **Private-layout dependency.** The fabrication relies on measured ivar
  layouts. The self-check turns a future iOS change into "unavailable"
  rather than a crash, but that *is* the trade-off of mocking private
  internals — the same one the [virtual camera](../camera/design.md) makes.
