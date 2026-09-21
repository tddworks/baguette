# Hinge (iPhone Duo)

iPhone Duo folds. `baguette hinge` moves its hinge — Device Hub's pose
picker from the CLI, the HTTP route and the page — and reads it back.

```bash
baguette hinge --udid <UDID>                    # {"ok":true,"angleDegrees":130.0}
baguette hinge --udid <UDID> --pose closed      # 0°   sweeps over 0.8 s
baguette hinge --udid <UDID> --pose open        # 130° Device Hub's book pose
baguette hinge --udid <UDID> --pose flat        # 180°
baguette hinge --udid <UDID> --angle 95 --duration 1.2
```

```http
POST /simulators/<udid>/hinge?pose=open
POST /simulators/<udid>/hinge?angle=95&duration=1.2
GET  /simulators/<udid>/hinge
```

The `POST` blocks for the sweep and answers `{"ok":true}`; `400` for a
pose that is not `closed`/`open`/`flat`, an angle off 0–180 or a
negative duration; `404` for an unknown udid; `500` when the device
could not be driven (no `HingeControl` shipped, guest refused). On
either socket — the flat stream or the 3D book — the page's pose bar
sends `{"type":"set_pose","hingeDegrees":130}` (the slider adds
`"duration":0` while it leads the hinge); a socket's requests play in
order and a burst skips what it has passed (`PoseQueue`). Both views
follow the hinge samples as the device folds — the 3D model, and the
flat view's book drawn from 2D frames (`iphone-duo.md`). A phone
answers the `GET` with `foldable:false` and has nothing to drive.

## How the hinge is driven

Nothing on the host sets the hinge: `devicectl device motion
hinge-angle` only reads it, `simctl` has no verb, and Device Hub's
window is opaque to accessibility. Device Hub itself speaks CoreDevice's
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

So baguette ships **`HingeControl`** (`Injected/HingeControl/`), an
iOS-Simulator *executable* — the first non-dylib under `Injected/`,
built and staged by the same loop — which `GuestHingeMotor` starts once
per device with `xcrun simctl spawn <udid> <HingeControl> serve` and
keeps: it registers a service of the same shape and plays each line it
is written on stdin (`sweep <from> <to> <ms>` at 60 Hz with Device
Hub's ease-out, `angle <deg>`, `orientation <name>`). The encoder
reproduces Device Hub's payload byte for byte. Sweeps queue behind one
another; a pose costs no spawn after the first (~0.9 s round trip for
Device Hub's 0.8 s sweep). `SharedHinge.fold(to:over:)` starts each
sweep from the angle last heard — or shut, as the device boots, when
nothing has been heard — and `DevicectlHinge` reads the sweep back like
any other, so the page, `litPanel` and the chrome all follow.

`orientation-picker-control` is Device Hub's rotate button by the same
route (`HingeMotor.turn(to:)`); the page's rotate button still sends
the Purple orientation event, which the guest honours or not per app.

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

`HingeControl` registers a second service of that shape and presses
them: `button <page> <usage> <ms>`. On the host, `DeviceKeys` is the
domain role (`GuestHingeMotor` plays it as well, one serving child per
device), and a foldable's `Input` is `FoldableInput`: touches go to the
lit panel's digitizer as before, and a `DeviceButton` with a Device Hub
key (`power`, `lock`, `volume-up`, `volume-down`, `action`) goes to the
guest, held `duration` seconds or Device Hub's 0.25 s. The CLI, the
`POST …/input` route and the stream sockets all press through it
without change; `home` and the edge gestures still take the legacy
path. Single-panel devices are untouched — `SimulatorKitDisplay` wraps
the input only when the device has several panels.

## Packaging

`HingeControl` follows the injected dylibs exactly — `Injected/
HingeControl/{build.sh,Sources/HingeControl.m}`, built fat by
`Injected/build.sh` (host-arch-only under `BAGUETTE_INJECTED_ARCHS`),
staged as `Sources/Baguette/Resources/HingeControl/HingeControl`,
`.copy`'d by `Package.swift`, resolved and installed by
`InjectedDylibInstaller` (`InjectedDylib.hingeControl`, kind
`.executable`, env override `BAGUETTE_HINGECONTROL_TOOL`) into the
content-hashed build directory with `0755`. The one difference is the
link: an executable, so no `-dynamiclib` / `-install_name`.

The homebrew-core formula rebuilds every injected product from source
for the host arch (`brew audit` rejects the committed universal
binaries), mirroring each `build.sh`; it needs one more entry for this
one:

```ruby
# Executable spawned in the guest, not a dylib: same sources layout, plain link.
tool = "Sources/Baguette/Resources/HingeControl/HingeControl"
rm tool
system "xcrun", "clang", "-arch", arch, "-isysroot", sdk,
       "-target", "#{arch}-apple-ios17.0-simulator", "-fobjc-arc",
       "-framework", "Foundation", "-Wl,-adhoc_codesign",
       "-o", tool, *Dir["Injected/HingeControl/Sources/*.m"]
```

## Known limits

- Device Hub and baguette both feed the same hinge; whoever sent last
  wins, and Device Hub's picker shows its own last pick, not the
  device's angle, until it next reads the hinge.
- `HingeControl` needs the iOS 27.1 simulator's private `HID.framework`
  to accept a virtual service from an unentitled process, which it does;
  a future runtime may not.
- The guest's hinge stream (`devicectl`) can go silent after a
  SpringBoard restart (`baguette heal`); driving still works, reading
  it back resumes once Device Hub or baguette moves the pose again.
