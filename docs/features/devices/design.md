---
description: Design of one Devices model for every kind of device baguette drives — iOS simulators, physical iPhones, Android emulators — where each device registers the abilities it has and Infrastructure is split by device family. Read before adding a device kind or an ability.
---

# Devices — "every device I can drive, and what each one can do"

**Status:** BUILT for the CLI and the `/devices/…` page; the `/simulators/…`
routes and the gesture commands still read `Simulators` (see §9). Slices 0–8
are on `feat/devices`: `Infrastructure/` split by family; the device model
(`DeviceState`, `Abilities`, `Device`, `Devices`, `CombinedDevices`); the
simulator, companion and CoreDevice families as sources; the device-level
commands, `baguette list`, `/devices.json`, and the device page's stream and
touches reading it. A physical iPhone on a cable takes touches (CoreDevice Universal
HID), shows its screen (devicectl screenshots, ~1 fps), shares its pasteboard; everything else is refused by name.

This document owns **which devices exist, what each one can do, and where
each device family's implementation lives**. Its neighbours own the rest,
and no law here repeats theirs:

| For | Read |
|---|---|
| what a simulator is made of — displays, panels, injection, heal | [CANONICAL_MODEL](../../CANONICAL_MODEL.md) |
| whether CoreDevice will give an unentitled process a physical iPhone's screen and touches | [real-devices](../real-devices/design.md) (spike) |
| the companion-app twin — ReplayKit pixels, CoreMotion pose | [device-twin](../device-twin/design.md) |
| how a gesture reaches the screen once there is a `Touch` (or `Press`, `Key`, `Scroll`) | [ARCHITECTURE](../../ARCHITECTURE.md), [touches](../touches/design.md) |

---

## What the product already says

```
  baguette list                 "udid · name · state · runtime"   ← a device is an identity and a state
  devicectl list devices        "… State · Model · Reality: physical"   ← Apple's word for sim vs phone
  adb devices                   "emulator-5554  device | offline | unauthorized"
  /simulators/:udid  and  /devices/:udid   two route trees, one page (sim.html)
  the page's cards              Location · Network · Defaults · Status bar · …
                                ← a card is something the device can do
```

The user already thinks of one list of devices, each showing the cards it
supports. The code has two lists, and assumes every simulator shows every card.

## The one sentence

**A device is an identity plus the abilities it registered; baguette asks
the device for an ability, and a device that never registered it refuses
by name.**

```
            Devices ◆  (one list for the CLI, the server and the page)
               │
     CombinedDevices ◆ ─── merges every source, one id names one device
     ┌──────────┼───────────────┬──────────────────┐
CoreSimulators  CoreDevicePhones  CompanionPhones   AndroidEmulators     ← one per device family
     │              │                 │                  │                 (Infrastructure)
CoreSimulator   CoreDevicePhone   CompanionPhone     AndroidEmulator   : Device
     └── abilities: Abilities ◇ ── .screen .input .location … (only what it can do)
                        │
             Screen ◆  Input ◆  Location ◆  Apps ◆ …   ← the roles that exist today, unchanged
```

## What is wrong today

| Cost | The evidence, in the shipped code |
|---|---|
| A device has to claim every ability, whether or not it has it | `Domain/Simulator/Simulator.swift` declares 21 role factories (`statusBar()`, `motion()`, `network()`, `hinge()`, `watchPairing()`, …). A physical iPhone or an Android emulator could only fake them or throw from them |
| Physical phones are a second, parallel world | the twin has its own `Devices` protocol and `Device` struct (`Domain/Device/Device.swift`) with `capabilities: [String]`, and its own route tree — 10 `/devices/:udid…` routes in `ServerDeviceTwinRoutes.swift` that copy `/simulators/:udid`'s `definition.json`, chrome, `3d-model.json` and stream |
| "No such device" is decided 85 times | `simulators.find(udid:)` appears 85 times across 27 commands and 8 server files, each unwrapping and failing in its own words |
| A device family has no home | `Infrastructure/` has 20 context folders, and almost every one holds a single simulator adapter (`SimctlLocation`, `IndigoHIDInput`, `GuestHinge`). An Xcode change breaks one family spread across 20 folders, and its shared plumbing (`DeviceHost`, the simctl runner) sits wherever it landed first. The twin sits in `Infrastructure/Device/` |
| The rule that ties them together | AGENTS.md: "`Domain/` and `Infrastructure/` split into the same bounded contexts" — correct for the *what*, wrong for the *how* once a second family arrives |

---

## 1 · Ubiquitous language

| Term | Meaning | Not to be confused with |
|---|---|---|
| **Device** | one thing baguette can drive: a simulator, a phone on a cable, a phone running the companion app, an emulator | the twin's `Device` struct today, which only meant "a companion-app phone" |
| **Devices** | the list of devices baguette can see right now, from every source | `Simulators`, which is one source |
| **source** | one device family's collection — `CoreSimulators`, `CoreDevicePhones`, `CompanionPhones`, `AndroidEmulators` | a stream's frame source |
| **device family** | the devices one technology reaches, and the Infrastructure folder that talks to it | a device *type* (iPhone 17 Pro) |
| **ability** | something a device can be told to do, named by the role that does it: `location`, `input`, `hinge` | the plugin grants (`PluginCapability`) and CoreDevice's own "capabilities" |
| **kind** | the platform (`iOS`, `android`) and reality (`simulated`, `physical`, `emulated`) of a device, plus its model | the device type a chrome is keyed by — that is the kind's `model` |
| **reality** | Apple's `devicectl` column: whether the device is a real phone | — |
| **ready** | on, reachable and accepting gestures: booted, paired with its developer disk mounted, or adb `device` | "available" in the page, which today means *not booted* |
| **refusal** | the answer when a device lacks an ability or an id names nothing: an error naming the ability and the device | a failure of an ability that exists (a `simctl` call that failed) |

**Ability, not capability.** "Capability" is already spent twice: on plugin
grants (`PluginCapability`) and inside CoreDevice, which this design calls into.
The user's own word for it is "ability". Don't rename it back.

**`Devices` is reused, not renamed away.** The twin's `Devices` protocol was
the right name for the wrong scope. It grows to cover every source, and the
twin's collection becomes one source, `CompanionPhones`.

## 2 · The aggregate — from the root down

```
Devices ◆                              every device baguette can see — all · find(id:)
 └─ CombinedDevices ◆                  the sources, merged      ONE ID NAMES ONE DEVICE
     └─ sources: [any Devices]         one per device family; order only breaks ties in nothing
         └─ Device ◆                   one device
             ├─ id : DeviceID ◇        sim UDID · iPhone UDID · adb serial
             ├─ name : String          what the user named it
             ├─ kind : DeviceKind ◇    platform × reality × model
             ├─ state : DeviceState ◇  off · starting · ready · unavailable(reason)
             │                         ONLY READY ACCEPTS GESTURES AND STREAMS
             └─ abilities : Abilities ◇
                                       what this device can do   ANYTHING ELSE IS REFUSED BY NAME
                 └─ Ability<Role> ◇ → Role ◆   e.g. .location → any Location
```

**What varies and what does not.** The roles (`Screen`, `Touch`, `Location`,
`Apps`, …) do not vary: they are the domain, and each knows only its own job.
What varies is *which* roles a device has and *who plays them*. That variation
is data, registered by the device, never a branch: there is no
`if kind.reality == .physical` anywhere above Infrastructure.

**No `Simulators: Devices`, no `Device & Locatable`.** A sub-protocol per
family or a marker protocol per ability both fail twice: Mockable does not
generate inherited requirements (its README lists protocol inheritance as
unsupported), and the page needs the abilities as a list it can render, which
protocol conformances cannot give it.

**Starting a device belongs to the device.** `boot` / `shutdown` is the
`power` ability. A physical phone does not register it, so `baguette boot`
on a phone is a refusal, not a special case.

## 3 · The rich types

### `Device` — one thing baguette can drive

> **Pointable as:** the phone on the desk, the simulator window, the emulator window.

| | |
|---|---|
| **Owns** | its identity, kind and state; the table of what it can do |
| **Tell it** | nothing directly. Its abilities are told (`abilities.require(.location).set(…)`) |
| **It answers** | `id`, `name`, `kind`, `state`, `abilities` |
| **Never** | a method for one ability (`func statusBar()`); a role it registers but cannot perform; knowledge of another family |

`@Mockable protocol Device: Sendable`. Each family's adapter is one concrete
type (`CoreSimulator`, `CoreDevicePhone`, `CompanionPhone`, `AndroidEmulator`)
and is the **only** place that decides what that family can do.

### `Abilities` — what a device can do

> **Pointable as:** the cards the page shows for a device.

| | |
|---|---|
| **Owns** | the registered abilities, each mapped to the role that plays it |
| **Tell it** | `register(.location) { SimctlLocation(…) }` — once, when the device is built |
| **It answers** | `require(.location) throws -> any Location`; `names` (in registration order) |
| **Never** | a fallback role; a default "unsupported" role that pretends; a registration after the device is built |

A value (`struct`), not `@Mockable`: tests build a real one. `Ability<Role>` is
a typed key (`struct Ability<Role>: Sendable { let name: String }`), so
`require(.location)` is checked by the compiler and the table's internal
erasure never leaks out. A role that is "a fresh handle per call" today
(`screen()`) is registered as a factory, and `require` calls it.

The abilities, from today's `Simulator` methods plus one new one:

| Ability | Role | iOS simulator | physical iPhone (CoreDevice) | companion phone | Android emulator |
|---|---|---|---|---|---|
| `power` | `Power` (turnOn · turnOff) | ✓ | — | — | ✓ |
| `screen` | `Screen` | ✓ | ✓ (devicectl screenshots, ~1 fps) | ✓ once its video arrives | ✓ |
| `touch` | `Touch` | ✓ | ✓ (CoreDevice Universal HID) | later (runner) | ✓ |
| `press` · `key` · `scroll` | `Press` · `Key` · `Scroll` | ✓ (one Indigo surface plays all four) | — (the digitizer sends only touches) | — | ✓ |
| `displays` | `Displays` (phone · panels · CarPlay) | ✓ | — | — | — |
| `accessibility` | `Accessibility` | ✓ | ✓ (its own accessibility service, over the tunnel) | — | ✓ |
| `apps` · `logs` | `Apps` · `LogStream` | ✓ | — (devicectl can't push a notification; no syslog verb) | — | ✓ |
| `orientation` | as today | ✓ | — (devicectl's `set` exits 0 and leaves a phone as its sensors hold it) | — | ✓ |
| `pasteboard` | as today | ✓ | ✓ (devicectl) | — | ✓ |
| `location` | as today | ✓ | — (devicectl sets one point, no route) | — | ✓ |
| `interface` · `defaults` · `photos` · `shake` | as today | ✓ | — | — | ? |
| `statusBar` · `motion` · `network` · `hinge` · `externalDisplays` · `watchPairing` | as today | ✓ | — | — | — |

`?` is decided by that family's own research, not here. `screen` and `input`
are the device's main screen and its gestures; on a simulator they are
`displays.phone`'s, so the binding law in CANONICAL §3 still holds. They are
separate abilities because a view-only device (the spike's *Partial* outcome,
the twin today) has one without the other.

### `Devices` and `CombinedDevices` — every device, from every source

> **Pointable as:** the device list on the page; the output of `baguette list`.

```swift
@Mockable
protocol Devices: AnyObject, Sendable {
    var all: [any Device] { get }                   // a fresh snapshot per read
    func find(id: DeviceID) throws -> (any Device)?   // throws only rather than guess
}
```

| | |
|---|---|
| **Owns** (`CombinedDevices`) | that one id names one device across all sources |
| **Tell it** | nothing; it is read |
| **It answers** | `all`, `find(id:)`; and in an extension, `require(_:of:) throws -> Role`, `ready`, `listJSON` (with `kind` and `abilities`) |
| **Never** | `boot` / `connect` (those are abilities); a filter per family on the protocol; a guess between two devices claiming one id |

`all` is a snapshot because the page already re-reads the list
(`sim-list.js` fetches it; `sim-native.js` polls while a boot runs). A
`watch(onChange:)` earns its place only when the page moves to push.

### `DeviceKind` · `DeviceState` · `DeviceID` — values

```swift
struct DeviceKind: Equatable, Sendable {
    enum Platform: String { case iOS, watchOS, tvOS, visionOS, android }
    enum Reality: String  { case simulated, physical, emulated }
    let platform: Platform, reality: Reality
    let model: String         // "iPhone 17 Pro Max" · "iPhone19,7" · "Pixel 9" — the bezel / 3D key
}

enum DeviceState: Equatable, Sendable {
    case off, starting, ready
    case unavailable(reason: String)   // locked, unpaired, no developer disk, adb "unauthorized"
}
```

Each family maps its own states onto these: `SimulatorState.booted` → `ready`;
`devicectl` "available (paired)" → `ready`; adb `offline` → `unavailable`.
`canAcceptInput` moves from `Simulator` to `DeviceState`.

## 4 · The tells

The App and `Server` parse and call. They never unwrap a device, never
check a kind, and never word a refusal themselves:

```swift
// baguette location set --udid X --lat … --lon …
try devices.require(.location, of: id).set(coordinate)

// baguette boot --udid X         (a phone refuses: "iPhone 18 Pro Max can't do lifecycle")
try devices.require(.power, of: id).turnOn()

// baguette tap / the stream socket
Gesture.execute(on: try devices.require(.input, of: id))

// the stream route
try devices.require(.screen, of: id).start(onFrame: pump.push)

// baguette list · GET /devices.json — kind and abilities per device; the page shows those cards
devices.listJSON

// DeviceKinds (App) — the one list of kinds, read by the CLI and by `serve`;
// a new kind (Android) is one more source here
let devices = DeviceKinds(simulators: CoreSimulators(deviceSetPath: path),
                          companions: serving ? companionDevices : nil).devices
let connected = devices.physical    // the device page's list: a view, not a second list
```

A foldable keeps its own tell: `displays` and `hinge` are simulator abilities,
and `litPanelInput()` is built from them, as it is today.

## 5 · Invariants — each law, one owner

| Law | Owner |
|---|---|
| a device does only what it registered; asking for anything else is a refusal naming the ability and the device, never a fallback | `Abilities` |
| an id that no source knows is a refusal naming the id | `Devices.require(_:of:)` |
| one id names one device across every source; asking for an id two sources claim is a refusal, never a pick (the list shows both, so the clash is visible) | `CombinedDevices` |
| an ability that drives the running screen (screen, input, displays, hinge, orientation, shake, accessibility) is refused while the device isn't ready; the key says whether it needs one | `Device.require` (the key: `Ability.needsReady`) |
| what a family can do is decided once, where the device is built, and nowhere else | each family's device (`CoreSimulator`, `CoreDevicePhone`, …) |
| the list a client sees names each device's abilities, and the page shows only those | `Devices.listJSON` |

Laws that stay where CANONICAL §3 puts them, now for every family: coordinates
are device points and each family's `Touch` converts to its own units (Indigo
divides by size; adb scales to pixels); a screen and its input come from one
binding (`Display`).

## 6 · Infrastructure — split by what it talks to

`Domain/` answers *what*, so it is split by context (the question), as now.
`Infrastructure/` answers *how*, so it is split by what it talks to: one
folder per device family, each sorted inside by the Domain's context names,
plus `Host/` for the Mac itself.

```
Infrastructure/
├── Simulator/   CoreSimulator · SimulatorKit · simctl · IndigoHID · AXPTranslator · guest helpers
│   ├── CoreSimulators.swift  CoreSimulator.swift   ← the only files that register its abilities
│   ├── Kit/     DeviceHost, framework loading, the simctl runner — shared inside the family
│   └── Input/ Screen/ Accessibility/ Hinge/ Orientation/ Logs/ Location/ Apps/ Defaults/
│       Pasteboard/ Photos/ StatusBar/ Interface/ Shake/ Motion/ Network/ Camera/ Injection/ …
├── Companion/   the twin: LiveCompanionPhones, TwinScreen(s), TwinPoses, VTH264Decoder
├── CoreDevice/  physical iPhone: devicectl, and CoreDevice.framework for touch
│   └── Kit/     Devicectl; CoreDeviceFramework (RemoteDevice, CapabilityKind) and
│                DigitizerReport, bound to the weak-linked framework in Swift; one C call
│                (CoreDeviceABI) for the typed-throws send
├── Android/     adb + emulator   (later, same shape)
├── Host/        the Mac, shared by every family: Stream/ Recording/ Render/ Camera/ (AV capture)
│                Chrome/ Bakery/ Plugin/ Subprocess/
└── Server/      HTTP / WebSocket transport
```

| From | May import | Never |
|---|---|---|
| a family (`Simulator/`, `Companion/`, `CoreDevice/`, `Android/`) | Domain, `Host/` | another family |
| `Host/` | Domain | any family — encoders take `IOSurface` or bytes, never a `SimDevice` |
| `Server/` | Domain, `Host/` | a family (it reaches devices through `Devices`) |
| App | everything — it is the composition root | — |

The host half is already platform-neutral in code. Of the stream, recording,
screen and render files that mention SimulatorKit, the stream, recording and
subprocess ones do so only in comments ("SimulatorKit recycles the IOSurface").
Those comments now state the `Screen` contract instead ("a `Screen` may
recycle the IOSurface"). `CaptureCanvas`, `ScreenSnapshot` and
`RenderedScreen` turned out to be host code. One reach across the fence
remains: `Host/Render/VerifiedDeviceAssets` defaults to
`CoreSimulators.developerDir()`. Which Xcode is installed is a fact about the
Mac, not the simulator family, so that lookup moves to `Host/` when a second
family needs it (CoreDevice will).

AGENTS.md's layering sentence changes to:

> `Domain/` splits by bounded context (the question). `Infrastructure/` splits
> by what it talks to: one folder per device family, each sorted inside by the
> Domain's context names, plus `Host/` for the Mac itself. A family never
> imports another family; only its `Devices` source and its `Device` decide
> what abilities it has.

## 7 · What dies

- `Simulator`'s 21 role factories and `canStream` / `canAcceptInput`. They
  become registrations in `CoreSimulator`'s table and `DeviceState`.
  `Simulator` itself remains only as long as simulator-only domain types
  (`SimulatorDefinition`, injection) need it.
- the `Simulators` protocol → `Devices`. `SimulatorDevices` wraps it while
  callers move; once `Simulator` loses its role factories, `CoreSimulator`
  and `CoreSimulators` conform directly and the two adapters go.
- the twin's `Devices` protocol, `Device` struct and its `capabilities: [String]`.
  `CompanionPhones` / `CompanionPhone` replace them.
- the twin's copies of the per-device routes (`definition.json`, chrome,
  `3d-model.json`, stream) — one per-device route tree serves every family.
- the 85 hand-written `simulators.find(udid:)` unwraps → `devices.require(_:of:)`.
- AGENTS.md's "Infrastructure splits into the same contexts" sentence.

## 8 · Open questions

- **One phone, two sources.** A phone on a cable *and* running the companion
  app: one device with both families' abilities, or two? Today the companion's
  id comes from its own hello, so they would list as two. Merging is out of
  scope until the CoreDevice spike lands.
- **The flag and the route for a non-UDID id.** An adb serial is not a UDID.
  Keep `--udid` and accept any `DeviceID`, or add `--device` and keep `--udid`
  as an alias? Same for `/simulators/:udid` vs `/devices/:id`: plugins
  (`PluginRoute`) and the page use `/simulators/`, so the old tree stays as an
  alias for at least one release.
- **Platform-shaped words in the shared kernel.** `DeviceButton` (Common) is
  iOS's buttons; Android has back and recents. A family not registering `Press`
  when it lacks iOS's buttons is the first answer, but the kernel may need a platform-neutral
  set.
- **Accessibility across platforms.** Can `AXNode` hold a uiautomator tree
  without iOS-only roles leaking into it? Decided when Android arrives.
- **Chrome and 3D by `kind.model`.** A phone's model is a product type
  (`iPhone19,7`), not a device-type name. The twin already matches 3D models by
  hardware id; chrome lookup has to learn the same.
- **Enforce the import rules with SwiftPM targets?** Folders first. One target
  per family would make §6 a compile error, but every Domain type would need
  `public`. Revisit after Android.
- **Should every simulator register `hinge`?** Today it does, as
  `Simulator.hinge()` exists on every one; a non-foldable's hinge reads as
  folded. Registering it only where `Chromes` lists two panels would make the
  page's hinge card honest. Decided when the page renders cards from
  abilities (slice 7).
- ~~devicectl's orientation names~~ Moot: on a physical phone
  `devicectl device orientation set` exits 0 and the phone stays as its
  sensors hold it ("New Device Orientation: portrait"), so a phone registers
  no `orientation`. Checked 2026-11-18 on an iPhone 18 Pro Max.
- **The camera.** `CameraSessions` stays per server; the simulator's guest
  side (`SimctlCameraGuest`) likely becomes a `camera` ability. Decided when it
  moves.
- ~~One protocol per ability (`Device & Locatable`)?~~ No: Mockable does not
  generate inherited requirements, and the page needs abilities as a list.
  Settled 2026-11-18 for a registration table, like `GestureRegistry`.
- ~~Can an unentitled process touch a physical iPhone?~~ Yes, through
  CoreDevice's Universal HID capability. Measured 2026-11-18; the research is
  in [real-devices](../real-devices/design.md#decision).
- ~~Is a generic method on a `@Mockable` protocol a problem?~~ Avoided:
  `require` lives on the `Abilities` value and in a `Devices` extension,
  so neither protocol has a generic member. `.location` resolves as an
  implicit member of `Ability<Role>` (keys are constrained extensions in
  `Domain/Device/EveryAbility.swift`). Settled by slice 3's tests.
- ~~Should two sources claiming one id hide the device from the list?~~ No:
  `all` lists both so the clash is visible, and `find(id:)` throws
  `claimedTwice` rather than pick. Settled in slice 4.

## 9 · Build sequence

Each slice is green on its own. Test names are the `should …` sentences.

| # | Slice | Pins |
|---|---|---|
| 0 | CANONICAL_MODEL (tree root, the §5 laws, the Device context), AGENTS.md's layering sentence, ARCHITECTURE.md | the design, before code |
| 1 | Move only: `Infrastructure/` → `Simulator/`, `Companion/`, `Host/`; rewrite simulator-only comments in `Host/` | `swift build` and the whole `swift test` stay green; no new test (no behaviour) |
| 2 | `DeviceID`, `DeviceKind`, `DeviceState` | "should accept gestures only when the device is ready"; "should read a booted simulator as ready" |
| 3 | `Ability`, `Abilities` | "should refuse an ability the device never registered"; "should hand back the role registered for an ability"; "should name the abilities in the order they were registered" |
| 4 | `Devices`, `CombinedDevices`, `require(_:of:)`, `listJSON` | "should list every device from every source when sources are combined"; "should refuse to combine two devices that claim one id"; "should refuse a device id no source knows"; "should list each device's kind and abilities" |
| 5 | `SimulatorDevice` / `SimulatorDevices` present any `Simulator` / `Simulators` as a `Device` / `Devices` — adapters, because `Simulator.state` and `Device.state` (and both `all`s) are different types under one name | "should register every simulator role as an ability"; "should boot the simulator when its lifecycle is told to boot" |
| 6 | the twin renamed `CompanionPhones`; `CompanionDevices` makes it a source; `/devices.json`, `definition.json`, `3d-model.json` and `/stream` read every physical device | "should show a companion's screen once its video has arrived"; "should list each ready physical device as connected, with what it can do" — **done** |
| 7 | readiness on the key (`Ability.needsReady`), device-level commands through `Devices`, display plans bound to any device, simulator-only commands refusing other families by ability | "should refuse an ability that needs a running device while the device is off"; "should show a device's own screen when the plan is the phone plane" — **done**; the `/simulators/…` routes and the page's cards from `abilities` remain |
| 8 | delete what §7 names | `RecordingError.deviceNotBooted` gone (a second owner of readiness); the rest waits on slice 7's remainder |
| 9 | `CoreDevicePhones`: screen and pasteboard through `devicectl`, touches through CoreDevice's Universal HID | "should list a paired phone on a cable as ready"; "should register what a physical phone can do, and nothing it can't"; "should land a tap as a finger down then up at the same spot" — **done**; a live stream waits on H2 |
| 10 | `AndroidEmulators` | its own design |
