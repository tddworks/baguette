---
description: The programs baguette runs inside a simulator with `simctl spawn` — one per Apple subsystem it drives (CoreMotion's hinge angle, Device Hub's controls, the HID buttons service, AXPTranslator's frontmost app) — and the adapter that owns each. Read before adding a guest-side verb or touching how one is spawned.
---

# Injected programs — design

Some work can only be done from inside the simulator: reading the hinge
angle from CoreMotion, playing Device Hub's controls, pressing keys on the
guest's own buttons service, and asking the guest's accessibility server
which app is in front. baguette does each with a small iOS-Simulator
executable it spawns in the guest (`xcrun simctl spawn <udid> <program> …`),
built from `Injected/` beside the injected dylibs.

## One program per Apple subsystem

| Program (`Injected/…`) | Apple subsystem it drives | Verbs | Adapter | Domain port |
| --- | --- | --- | --- | --- |
| `CoreMotionAngle` | CoreMotion's `CMAngleManager` | `read-angle`, `watch-angle` | `CoreMotionHinge` | `Hinge` (`angle`, `watch`) |
| `DeviceHubControls` | Device Hub's controls: vendor IOHIDEvents on an `avpCustom`-shaped service (`hinge-slider-control`, `orientation-picker-control`) | `angle`, `sweep`, `orientation`, `serve` | `DeviceHubControls` | `HingeMotor`, the foldable's orientation |
| `HIDButtons` | keyboard IOHIDEvents on a `mainScreenButtons`-shaped HID service | `button`, `serve` | `HIDButtonsKeys` | `DeviceKeys` |
| `AXPFrontmost` | AccessibilityPlatformTranslation's `AXPTranslator` | `frontmost` | `AXPTranslatorFrontmost` | the frontmost app an `Accessibility` read walks |

Adapters are named `<Apple subsystem><port>`, as `AXPTranslatorAccessibility`,
`SimulatorKitScreen` and `IndigoHIDInput` already are.

The verbs and their output are unchanged from the one binary they came from
(`HingeControl`), so each program answers exactly what its adapter asked
before.

## Why four, not one

These were one program, `HingeControl`, named for the first of them. It
carried four responsibilities with four reasons to change — CoreMotion's
angle API, Device Hub's control payload, the buttons service's shape, and
AXPTranslator — and they shipped, built and broke together: an Apple Watch's
`describe-ui` failed because the binary it spawned for the frontmost app was
the hinge's, built for the iOS simulator. On the Swift side one type,
`GuestHingeMotor`, played both `HingeMotor` and `DeviceKeys`.

Reading the angle (CoreMotion) and moving the hinge (Device Hub) are separate
too: different Apple systems that change for different reasons. Device Hub's
hinge slider and orientation picker stay together: one payload format, one
reason to change.

## Not the injected dylibs

`Injected/` also holds dylibs, and one of them, `VirtualMotion`, is about
CoreMotion too. They are opposite jobs. `VirtualMotion` is loaded into the
app under test (`DYLD_INSERT_LIBRARIES`) and makes the public CoreMotion APIs
the app calls (`CMMotionActivityManager`, `CMPedometer`, `CMMotionManager`)
answer with motion baguette publishes: it fakes sensors for the app.
`CoreMotionAngle` is spawned on its own and reads the private
`CMAngleManager` for baguette: it observes the device. Neither hooks nor
reads what the other does.

## Running one

- **One-shot** (`CoreMotionAngle read-angle`, `AXPFrontmost frontmost`): a
  spawn per query; the program reads and exits.
- **Watching** (`CoreMotionAngle watch-angle`): one child per hinge watch,
  one `angle <degrees>` line per sample.
- **Serving** (`DeviceHubControls serve`, `HIDButtons serve`): one child per
  device and program, kept, fed one command per line and answering each with
  `done <status>` once played. `SimctlSpawnSession` owns that child — the
  spawn, the `--deadline`, the guest pid it prints, and stopping it when it
  goes silent — for both adapters, so a pose costs no spawn and a keystroke
  doesn't queue behind a sweep.

`Injected/Shared/` holds what the programs share: the deadline and serve
loop, and the virtual HID service the two serving programs register.

## Where each program runs

Each is built for the iOS simulator. `AXPTranslatorFrontmost` asks for the
frontmost app only in an iOS guest (a watchOS guest refuses the binary), and
a read keeps the host bridge's answer there; the foldable programs only ever
run on a foldable.

## Handing them to a library host

`CoreSimulators(injectedPrograms:)` takes an `InjectedPrograms`: one URL per
program, each nil to fall back to the copy baguette's CLI carries in its
resource bundle (or `BAGUETTE_<PROGRAM>_TOOL`). A host that embeds them
passes all four; nothing is configured behind its back.

`CoreSimulators(hingeControl:)` stays for one release, deprecated: it points
all four at that one binary, which still answers every verb.
