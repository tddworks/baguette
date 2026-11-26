---
description: Why iPhone Duo's hinge and hardware keys are driven by guest-side programs (DeviceHubControls, HIDButtons, CoreMotionAngle) that reproduce dtuhidd's virtual HID events — the measured payloads, usages, reading path and packaging. Read before touching the hinge or foldable keys.
---

# Hinge — design

## Path

- **Drive:** `baguette hinge` / `POST /devices/<udid>/hinge` / 3D socket `set_pose` → `Hinge.fold(to:over:)` (`HingeMotor`) → `DeviceHubControls` → `xcrun simctl spawn <udid> <DeviceHubControls> serve` (one per device, kept by `SimctlSpawnSession`) → `HIDVirtualEventService` vendor event on an `avpCustom`-shaped service.
- **Keys:** `baguette press` / `key` / `type` / `POST …/input` / stream sockets → a foldable's `HID` is `FoldableInput` → `DeviceKeys` (`HIDButtonsKeys`) → `HIDButtons button <page> <usage> <ms> [<page> <usage>]…` on a `mainScreenButtons`-shaped service.
- **Read:** `CoreMotionHinge` → `xcrun simctl spawn <udid> <CoreMotionAngle> read-angle` (or `watch-angle`) → CoreMotion's `CMAngleManager` in the guest.

Each is its own program, one per Apple subsystem: [injected programs](../injected-programs/design.md).

## How the hinge is driven

Nothing on the host sets the hinge: `simctl` has no verb, `devicectl`
never had one (the Xcode 27.1 beta's `device motion hinge-angle` only
read it), and Device Hub's window is opaque to accessibility. Device Hub itself speaks CoreDevice's
`UniversalHIDService` — a Swift-only private API with no module
interface — to a daemon in the guest, `dtuhidd`
(`/usr/libexec/dtuhidd`, from CoreSimulator's iphoneos platform
support). That daemon owns a set of virtual HID services registered
with backboardd through the private `HID.framework`
(`HIDVirtualEventService`), one of which it names `avpCustom`: usage
page `0xFF61`, usage `0x5B`, transport `CoreDevice`. Every pose command
Device Hub sends is dispatched on it as a **vendor-defined
`IOHIDEvent`** (page `0xFF61`, usage `0x5B`, version 0) whose payload
is a small keyed record. Watched with a HID event monitor inside the
guest while Device Hub's picker ran:

```
{provider: "com.apple.Virtualization.VirtualMachines",
 source:   "hinge-slider-control",  type: "range", value: <degrees as double>}
{provider: "com.apple.Virtualization.VirtualMachines",
 source:   "orientation-picker-control", type: "enum", value: "portrait"}
```

The record's wire form: `d3 00 00 00`, then items of `[u24 aux][u8
type]` with the top bit of `type` marking a container's last entry —
`0x01` dictionary (aux = entry count), `0x08` key (NUL-terminated, aux
= length incl NUL), `0x09` string (aux = length), `0x04` double (aux =
`0x3f`, 8 bytes little-endian) — every item padded to 4 bytes. The
`provider` names the VM-based device stack these controls were built
for; the simulator's consumer accepts them from any service of that
shape.

So baguette ships **`DeviceHubControls`** (`Injected/DeviceHubControls/`), an
iOS-Simulator *executable* built and staged by the same loop as the
dylibs, which `SimctlSpawnSession` starts once per device with `xcrun
simctl spawn <udid> <DeviceHubControls> --deadline <t> serve` and keeps: it
registers a service of the same shape and plays each line it is written on
stdin (`sweep <from> <to> <ms>` at 60 Hz with Device Hub's ease-out, `angle
<deg>`, `orientation <native-value>`), answering each with `done <status>`
once played — 0 success, 1 rejected HID dispatch, 2 invalid line. The keys
below are `HIDButtons`, its own program and its own kept child. Every hinge, rotation and
key call waits for that answer, so it returns once the guest has acted and a
short-lived CLI cannot exit with its command still queued. The encoder
reproduces Device Hub's payload byte for byte. Commands queue behind one
another; a pose costs no spawn after the first (~0.9 s round trip for
Device Hub's 0.8 s sweep). `SharedHinge.fold(to:over:)` starts each
sweep from the angle last heard — or, when nothing has been heard (no
`CoreMotionAngle`, or a silent guest), at the angle asked for, so the hinge
moves straight there — and `CoreMotionHinge` reads the sweep back like any
other, so the page, `litPanel` and the chrome all follow. Unless the last
sample is the angle asked for (a socket's watch heard the fold land), the
fold then forgets it, delivered or not, so the next `GET /hinge` or stream
bind reads the guest rather than the hinge as it was before the fold.

Folds on one device play one at a time. Each one tells its sweep watchers
(`Hinge.watchSweeps`) the sweep (`HingeSweep`, the same from, to and
60 Hz ease-out samples `DeviceHubControls` sends) as it goes to the motor, and
`PoseDelivery` once it returns. A live 3D book plays that sweep as
commanded (`PosedHinge`). The readings can lag: on a loaded EC2 Mac, every
sample of a 0.8 s sweep arrived, in order, over about 5 s. When the sweep is
delivered, the book stands at the target until a reading lands within
0.5°. If a reading turns back or leaves the sweep's range first, the book
follows it, because that is a fold made elsewhere. If the sweep was
refused or timed out, the book follows the readings at once. The readings
themselves (`angle()`, `watch`) never carry commanded angles.

A background `simctl spawn` of the tool (`&` in a subshell) once
delivered nothing — run it in the foreground / keep `serve` alive.
Spawned guest tools need `codesign -s -` and the iphonesimulator SDK
target. To inspect such events again, a guest HID monitor is
`HIDEventSystemClient initWithType:1` (monitor) +
`IOHIDEventGetDataValue` with field base `1<<16`.

`orientation-picker-control` is Device Hub's rotate button by the same
route (`HingeMotor.turn(to:)`). Its native values are `portrait`, `pud`,
`landscape-left`, and `landscape-right`; camel-case names such as
`landscapeLeft` are silently ignored. The public CLI and HTTP route detect
multiple integrated panels and use this guest route; single-panel devices
retain the Purple event. Native landscape labels are opposite the public
home-button convention: public `landscape-left` sends native `landscape-right`
(physical UIDevice value 4), and public `landscape-right` sends native
`landscape-left` (value 3). Portrait values are unchanged.

The host allows eight seconds beyond a command's own playing time, plus one
second for the helper's startup line. Killing the host's `simctl spawn` child
does not stop the guest process, which belongs to the simulator's
`launchd_sim` and would still dispatch, so the helper prints `pid <n>` before
it starts and a host that stops waiting kills that guest process. A helper not
ready to act by its `--deadline` — the spawn time plus eight seconds — exits 3
without acting, which covers one that had not started when the host gave up.
A timeout therefore means the command was delivered before the deadline or
never will be: read the device state once, then decide; do not retry blindly.
Diagnostic output alone is not failure. Failure to read the device's panel
configuration is also an error; it must not select the legacy path by default.

Physical orientation can differ from an app's interface orientation. The
browser's model roll is a separate presentation transform. Rotation queues
behind a sweep in progress on the same helper.

## Reading the hinge back

Device Hub streams the angle into the guest as HID reports
(`UniversalHID` → `dtuhidd` → `kIOHIDEventTypeHingeAngle` → CoreMotion
→ SpringBoard's pose provider), and SpringBoard decides which panel to
light. baguette reads it where SpringBoard does, in the guest:
`CoreMotionAngle read-angle` prints the current angle and exits, and
`watch-angle` prints every sample until stopped, each as one `angle
<degrees>` line (`CoreMotionHinge` spawns them with `xcrun simctl spawn`, so
a custom device set works too). Only a device with several integrated
panels (`IntegratedPanels.several`) ever asks. Device Hub's closed pose
reads ≈3°, its open pose ≈130°; SpringBoard goes landscape on its own
when open. By hand:

```bash
xcrun simctl spawn <UDID> <CoreMotionAngle> watch-angle
```

Both verbs use CoreMotion's private `CMAngleManager`, the reader behind
the guest's own `dtdeviceinfod` (`HingeAngleManager`), which served the
beta's `devicectl device motion hinge-angle`. It needs no entitlement:
`+isAvailable`, then `startAngleUpdatesToQueue:handler:` delivers
`CMAngle`s (`angleDegrees`, `isAngleValid`). The handler's second
argument is not an object, so a block that retains it crashes. The
first sample is the current angle, ~16 ms after the start (~0.6 s with
the spawn), then one arrives per change, every 60 Hz frame of a sweep.
An invalid sample is not printed. Like `frontmost`, the read verbs run
before HID.framework loads or any service registers. `simctl spawn`
forwards SIGTERM to its guest child, so stopping a watch stops the
reader. Measured on Xcode 27.1 (27A9275) / iOS 27.1.

The reading goes silent after a SpringBoard restart (`baguette heal`'s
backboardd kickstart) until the next pose change, as the beta's
`devicectl` stream did, so the shared hinge remembers such silence for
three seconds rather than making every caller wait it out.

What the lit panel binds (framebuffer, digitizer, chrome, tap
space, AX point size, rotation) is in
[iPhone Duo](../iphone-duo/README.md).

## The hardware keys go the same way

On iPhone Duo the legacy button press does not work. `baguette press
--button volume-up` builds its `IndigoHIDMessageForHIDArbitrary` for
the lit panel's digitizer target, and the guest *does* get it — a HID
monitor sees consumer page `0x0C` usage `0xE9` down and up — but on a
**touchscreen** service (usage page `0x0D` usage `0x04`), and
SpringBoard's volume, sleep/wake and camera-control handling ignores a
key from there. Device Hub's buttons arrive on another of `dtuhidd`'s
services, `mainScreenButtons` (usage page `0x0B` usage `0x01`, built-in,
transport `CoreDevice`), as plain keyboard `IOHIDEvent`s held a quarter
second. Measured with the same monitor, one click each in Device Hub:

| Device Hub button | page | usage |
|---|---|---|
| volume up | `0x0C` | `0xE9` |
| volume down | `0x0C` | `0xEA` |
| power (sleep/wake) | `0x0C` | `0x30` |
| camera control | `0xFF00` | `0x66` |

`HIDButtons` registers a service of that shape and presses them:
`button <page> <usage> <ms>`. On the host, `DeviceKeys` is the domain
role (`HIDButtonsKeys` plays it, one serving child per device), and a foldable's `HID` is `FoldableInput`: touches go to the
lit panel's digitizer as before, and a `DeviceButton` with a Device Hub
key (`power`, `lock`, `volume-up`, `volume-down`, `action`) goes to the
guest, held `duration` seconds or Device Hub's 0.25 s. The CLI, the
`POST …/input` route and the stream sockets all press through it
without change; `home` and the edge gestures still take the legacy
path.

Keyboard keys go the same way. The Duo drops Indigo's keyboard
message (HID page 7) whichever target it names — each panel's
`0x40000001` / `0x40000003` and the `0x32` slot all ack and type
nothing — while the same usages on this service type. So
`FoldableInput.key` presses through `DeviceKeys` too, held 100 ms (the
panel's tap) unless the caller names a hold. Trailing `<page> <usage>`
pairs on the `button` line are modifiers: down in order before the key,
up in reverse after it, and released even when a press is refused. Single-panel devices are untouched — `SimulatorKitDisplay` wraps
the input only when the device has several panels.

## Packaging

The programs follow the injected dylibs exactly: each built fat by
`Injected/build.sh` (host-arch-only under `BAGUETTE_INJECTED_ARCHS`),
staged under `Sources/Baguette/Resources/<Program>/`, `.copy`'d by
`Package.swift`, and installed by `InjectedDylibInstaller` (kind
`.executable`, env override `BAGUETTE_<PROGRAM>_TOOL`) into the
content-hashed build directory with `0755`. The one difference is the
link: an executable, so no `-dynamiclib` / `-install_name`; and each
includes `Injected/Shared/`.

The homebrew-core formula rebuilds every injected product from source
for the host arch (`brew audit` rejects the committed universal
binaries), mirroring each `build.sh`; the programs spawned in the guest
take one entry each:

```ruby
# Executables spawned in the guest, not dylibs: same sources layout, plain link.
%w[CoreMotionAngle DeviceHubControls HIDButtons AXPFrontmost].each do |program|
  tool = "Sources/Baguette/Resources/#{program}/#{program}"
  rm tool
  system "xcrun", "clang", "-arch", arch, "-isysroot", sdk,
         "-target", "#{arch}-apple-ios17.0-simulator", "-fobjc-arc",
         "-I", "Injected/Shared",
         "-framework", "Foundation", "-Wl,-adhoc_codesign",
         "-o", tool, *Dir["Injected/#{program}/Sources/*.m"]
end
```

## Dead ends

- `xcrun devicectl device motion hinge-angle` read the hinge on the
  Xcode 27.1 beta only. The release (27A9275, CoreDevice 651.13.5) has
  no `device motion` verb (`Unknown option '--device'`, exit 64), though
  CoreDevice.framework still carries the Swift-only capability.
- CoreDevice's `UniversalHIDService` is Swift-only with no swiftmodule
  anywhere — not callable from baguette.
- A SpringBoard shim (swizzling `CMAngleManager` to feed fabricated
  `CMAngle`s) worked too, but needed an injected dylib and a SpringBoard
  restart; it is not shipped.
- The legacy Indigo button press reaches the Duo's guest on a
  touchscreen service and is ignored (above).
