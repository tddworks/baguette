---
description: The devices design, reworked against SOLID so a new kind of device (Android first) is one new folder in `Devices/` and one line — stable roles each kind of device implements, small enough to implement fully, one list of kinds, every command and route through Devices. Evidence from today's code, the rule each principle becomes, a walkthrough of adding Android, and the refactor slices.
---

# Devices, by SOLID

**Status: DESIGN — not built.** The [devices design](design.md) gave every
device one model (`Devices` → `Device` → abilities). That core already obeys
the Open/Closed principle. This doc is about everything *around* it, which
still assumes a simulator and is why adding Android today means editing a
dozen places. The goal, stated as a test:

> **Adding a platform touches one new folder and one line.** No route, no
> command, no shared type, no `switch` changes.

| For | Read |
|---|---|
| the device model this builds on | [design.md](design.md) |
| every law's owner | [CANONICAL_MODEL](../../CANONICAL_MODEL.md) |

## 1 · What's wrong today (measured on `main`, fd0eefe5)

| Principle | Evidence | What it costs a new kind of device |
|---|---|---|
| **S** — one reason to change | `Input` has 8 members: touch, buttons, keys, scroll. `Server.swift` is 3,781 lines, 203 mentions of `simulators`. `Simulator` declares 37 members | a family that can touch but has no keys must still implement keys |
| **O** — open to extend, closed to change | the families are listed twice: `allDevices` in `SharedOptions.swift` and `physicalDevices` in `Server`. `DeviceButton` is a closed iOS set; 4 infrastructure `switch`es match its cases | Android's `back` edits the enum, its `allowed` list and every switch; a new family edits two composition roots |
| **L** — every implementation keeps the promise | `DigitizerInput` answers `button`, `key`, `scroll` with `false`; `ok:false` reads as *not sent*, not *can't* | callers can't tell "failed" from "this device has no keys" |
| **I** — small interfaces | `Input` (above); `Apps` holds `deliver(RemoteNotification)`, an iOS-only act, beside install/launch | an Android `Apps` would stub push notifications |
| **D** — depend on abstractions | the App and the server build concrete adapters in ~21 places (`CoreSimulators(…)` ×7, `SimctlInputSurface()` ×5, …); 6 commands still take a `Simulator`; 48 of 56 per-device routes live under `/simulators/…` and read `Simulators`; `StreamFormat.makeStream` (Domain) builds Infrastructure encoders | an Android device is unreachable from those commands and routes until each is rewritten |

## 2 · The shape — contexts, outside to inside

Read top to bottom, outside to inside: each context uses only the ones below
it, and the further in, the more stable. Names are the product's own words;
each context is a module, so the compiler holds the direction.

How a call travels — `baguette tap --device <id> …` or a click on the page:

```
          Commands (CLI)          Server (page, routes)         Plugins
                │                        │                         │  a plugin names a device by id
                └───────────┬────────────┴─────────────────────────┘
                            │  parse, then ask for an ability by device id
                            ▼
       Devices        devices.require(.touch, of: id)          ← which device is this id? (refuses: not found,
                            │                                     claimed twice); which kind drives it?
                            ▼
       Device ◆       id · kind · power · Chrome               ← can it do this, and is it ready?
                      abilities: one role per ability          (refuses by name: can't do touch,
                            │                                     is not booted)
                            ▼
       an ability     Touch ◆  tap(at: point on the Screen)    ← the role and its values; the same for
                            │                                     every kind of device
                            ▼  implemented by the device's kind (registered once, at its source)
          ┌─────────────────┬─────────────────┬─────────────────┬──────────────────┐
     Simulator/         iPhone/            Android/          CompanionPhone/     (next kind)
     simctl,            devicectl,         adb,              the companion
     SimulatorKit,      CoreDevice,        emulator          app
     IndigoHID          its services
          └─────────────────┴─────────────────┴─────────────────┴──────────────────┘
                            ▼
                      the real simulator, phone or emulator

     Devices/ holds the one list of kinds   ← the only place a kind is named outside its own folder
```

```
Sources/
├── Commands/            THE WAY IN — the CLI: `tap`, `screenshot`, `describe-ui` …
├── Server/              THE WAY IN — the server `baguette serve` runs: the page, its routes and sockets
│
├── Devices/             THE DEVICES BAGUETTE DRIVES — one kind each, all filling a Device
│   ├── Simulator/            an iOS simulator         (simctl, SimulatorKit, IndigoHID)
│   ├── iPhone/               an iPhone on a cable     (devicectl, CoreDevice, its services)
│   ├── Android/              an Android emulator or phone (adb, emulator)
│   └── CompanionPhone/       a phone running the companion app
│
├── Plugins/             WHAT EXTENDS BAGUETTE
│   ├── Plugin/               ◆ a plugin: its manifest, commands, grants
│   └── Bakery/               ◆ where plugins come from
│
└── Device/              ◆ WHAT A DEVICE IS
    ├── its id, its kind (platform · model), its power · Devices
    ├── Chrome/               how it looks — its bezel, the buttons on it, its 3D model (by its model)
    └── Abilities/            what it can do — one each, as the product prints it, values inside
        ├── Power/  Screen/  Touch/  Press/  Key/  Type/  Scroll/  UI/  Apps/  Notify/
        ├── Location/  Orientation/  Motion/  Network/  Interface/  StatusBar/  Shake/
        └── Capture/  Clipboard/  Logs/  Camera/  Hinge/
```

| Context | Its question | Uses |
|---|---|---|
| `Commands` · `Server` | how do people get in? | everything below — and `Commands` holds `serve`, the one command that starts the `Server`; most commands never touch it |
| `Devices` | how is each kind of device really driven? | `Device` |
| `Plugins` | what extends baguette, and from where? | `Device` (a plugin names a device by its id) |
| `Device` | what is a device: how it looks, and what it can do? | nothing |

- **A value lives with the ability that gives it meaning**, never in a shared
  bucket: a point in `Screen/`, a tap in `Touch/` (a touch is at a place on the
  screen), an element in `UI/` (it sits on the screen), a coordinate in
  `Location/`. Abilities depend on each other only where the meaning does.
- **Each ability declares its own key** (`Ability.screen` in `Screen/`), so
  `Device` itself imports none of them and a new ability touches nothing else.
- **Every context is a module: its public face at the top, its implementations
  in `Internal/`.** The top level holds what other modules may name — roles,
  values, the device source — and is `public`; `Internal/` holds how it works —
  simctl, SimulatorKit, devicectl, the HTTP plumbing — at Swift's default
  `internal`, so no other module can reach it. There is no `Infrastructure`
  folder: an adapter lives in `Internal/` of the context it implements.
- **A kind in `Devices/` exports one thing: its device source.** Everything
  else in it is internal. `Devices/` holds the laws that span every kind (one
  id names one device; a kind registers only what it can do) and the one list
  of kinds the way in reads.
- **Chrome is found from a device's kind.** What a chrome *is* lives in
  `Device/Chrome/`; where its art comes from (Xcode's device art, an SDK skin,
  a borrowed one) is the kind's business in `Devices/`.

## 3 · The roles — small enough to implement fully

Each role is one reason to change (S) and small enough that a kind either
implements all of it or doesn't register it (I, L). A role says what it can do
as data where a kind can do part of it (`Press`'s navigations and buttons),
never by answering `false`. Each is named for what the person types or sees,
and is the folder of the same name in §2.

| Role ◆ | Members | Replaces |
|---|---|---|
| `Power` | `turnOn()` · `turnOff()` | `Lifecycle` |
| `Screen` | `start(onFrame:)` · `stop()` | — (already small) |
| `Touch` | `tap` · `swipe` · `touch1` · `touch2` · `twoFingerPath` — `tap`, `swipe`, `pinch`, `pan`, `double-tap` | the touch half of `Input` |
| `Press` | `available` — `Navigation`s (home, app switcher, the edge pulls, the on-screen keyboard; Android's back) and `HardwareButton`s (lock, power, volume, action, the watch's crown and sides) · `button(_:duration:)` — `press --button` | `Input.button`, and `DeviceButton` split in two |
| `Key` | `key(_:modifiers:duration:)` — keys as HID usages — `key` | `Input.key` |
| `Type` | `type(Text)` — `type` | `TypeText`, which rides `Key` until a device types without keys (Android's `input text`) |
| `Scroll` | `scroll(deltaX:deltaY:)` — the page's wheel | `Input.scroll` |
| `UI` | `snapshot()` · `press(element)` | `Accessibility` |
| `Apps` | `install(AppPackage)` · `launch` · `terminate` · `open(Link)` · `installed()` | `Apps` minus notifications |
| `Notify` | `deliver(_:)` — `notify` | `Apps.deliver` (iOS today) |
| `Location` · `Orientation` · `Motion` · `Clipboard` · `Log` · `Interface` · … | as today | — |

**A role's acts are values inside its folder, named for what they are.**
The ability takes the product's verb; an act is one use of it, so it never
borrows the ability's name. Where a role has many acts they already had
their own names; where it had one, the act had taken the role's:

| Role | Its acts (the wire `type`) |
|---|---|
| `Touch` | `Tap` · `Swipe` · `Touch1` · `Touch2` · `Pinch` · `Pan` |
| `Press` | `ButtonPress` (`button`) — UIKit's `UIPress`: one press of a navigation or a hardware button |
| `Key` | `Keystroke` (`key`) · `TypeText` (`type`), a sequence of keystrokes |
| `Scroll` | `WheelEvent` (`scroll`) — the W3C name; its `deltaX` / `deltaY` are the browser's |

A screen's input is its `Abilities` — the roles it has, each made once.
A simulator plays all four on one Indigo surface, its `HID`: a name for the
four together, not a protocol, since it asks nothing the roles don't (and
`@Mockable` can't generate a protocol's inherited requirements).

A capability the device lacks is **absent** (the ability isn't registered), or,
inside a role that lists its options, **not in `available`** — and asking for it
is refused by name: `han's iPhone can't do key`, `iPhone 17 has no back`.

## 4 · Each principle, as a rule with an owner

| Principle | The rule | Owner — and how it's checked |
|---|---|---|
| **S** | a role changes for one reason; a kind's file changes only for its own toolchain | the role list (§3); a test per role uses only that role's mock |
| **O** | the kinds of device are listed once; a new ability, navigation or button is a new case **inside a kind's registration**, never a `switch` outside `Devices/` | `Devices/`' list of kinds — a test pins that `Commands` and `Serve` read the same list |
| **L** | an implementation does everything its role promises; what a device can't do is unregistered or not `available`, and refused by name — never `false` | `Abilities` · each role's `available`; a contract test per role, run against every kind's implementation |
| **I** | no kind implements a member it can't perform | §3's sizes; a kind's registration names only roles it fully implements |
| **D** | `Commands` and `Server` reach a device only through `Devices.require(ability, of: id)`; they never construct a kind's code | the module graph: `Commands` and `Serve` see only a kind's device source |

## 5 · Adding Android, under this design

| Step | Touches |
|---|---|
| the kind | **new** `Devices/Android/` — its device source (registers the abilities it implements), its adb and emulator code, its pure parsing (adb's listing, the UI dump → elements, key codes), all internal |
| registering it | **one line** in `Devices/`' list of kinds |
| `Commands`, `Server`, the page | **nothing** — they ask `Devices` for abilities; the page shows what `/devices.json` lists |
| `Device/` and its abilities | **nothing** — `back` already exists among `Press`'s navigations; Android lists it as available |

Contrast with today: the two composition roots, `DeviceButton` and its four
switches, 48 routes, 6 commands and the `Input` stubs would all change.

## 6 · Each context gets its own design

This doc is the map. Each context then has a design of its own, in the
feature-doc form (words, aggregate, tells, laws with one owner, open
questions), written before its slice is built:

| Context | Design | Holds |
|---|---|---|
| `Device` | `docs/features/device/design.md` | the aggregate: id, kind, power, Chrome, the ability table and its laws |
| each ability | `docs/features/<ability>/design.md` (many exist: touches, keyboard, location, hinge, …) | the ability's role, its values, its rules |
| `Devices` | `docs/features/devices/design.md` (this folder) | the kinds, their list, the laws across them; one section per kind, or a design per kind (`real-devices`, `android`) |
| `Plugins` | `docs/features/plugins/design.md` | plugin and bakery |
| `Commands` · `Server` | `docs/commands.md` · `docs/serve.md` | the way in; they hold no rule |

## 7 · The refactor, step by step

Each step is one PR: green (`swift test`, `make test-web`, the build without
CoreDevice, `make check-docs`), no behaviour a user or a plugin can see
changed, test-first where a rule moves. A step that lands removes its row
from [CANONICAL §6](../../CANONICAL_MODEL.md#6--where-the-code-is-still-behind).

| # | Step | Today (on `main`) | Change | Test first |
|---|---|---|---|---|
| 0 | **the names** | the roles and the tree disagreed | one list (§2, §3), the product's words | — (this doc) |
| 1 | **one list of kinds** ✓ | three: `SharedOptions.swift:33`, `Server.swift:107` and `:110` | one list in `Devices`, read by the CLI and the server | "should list the same devices to the CLI and the server" |
| 2 | **every command through `Devices`** ✓ | `fill`, `launch`, `hinge`, `heal`, `network`, `motion`, `defaults` take a `Simulator`; commands build `CoreSimulators(…)` and `SimctlInputSurface()`; `Network`, `Motion` and `InputSurface` take `on simulator:` | each asks `options.require(.x)`; every role is bound to its device when registered, so none takes a device; the input surface's repair is `.inputSurface`, an ability only a simulator registers; `options.simulator(for:)` is gone. `CoreSimulators(…)` stays only where the kinds are listed (`DeviceKinds`, `serve`, `list`, `chrome`, `render-3d`, `diag`) | "should register every simulator role as an ability"; the roles' tests, bound |
| 3 | **split `Input`** ✓ | `IndigoHIDInput`, `DigitizerInput` (3 × `false`), `LitPanelInput`, `FoldableInput`; `GestureDispatcher` built in 5 places; acts named `Press`, `Key`, `Scroll` after their abilities | `Touch`, `Press`, `Key`, `Scroll` registered as abilities; each act names the one it needs (`Gesture.ability`); the iPhone registers `Touch` only (`DigitizerTouch`); the acts are `ButtonPress`, `Keystroke`, `WheelEvent`; `AbilityTable` is `Abilities`; a simulator's four share one `HID` per screen; the wire doesn't change. `Type` stays on `Key` until a device types without keys | "should refuse a key for a device without one, naming it"; "should play every input role on a screen with one HID…" |
| 4 | **split `DeviceButton`** ✓ | 4 `switch`es, all in `IndigoHIDInput.swift` (250, 256, 285, 425) | `DeviceButton` is a `Navigation` or a `HardwareButton`; `Press` lists what's `available`, and `ButtonPress` is refused by name for anything else (`Gesture.missing(from:)`); the switches are inside the simulator's `Press`, the `(0, 0)` sentinel gone; `standardHIDUsage` is the hardware button's; `press --button` keeps its words (`back` comes with Android) | "should refuse a navigation the device doesn't have, naming it"; "should read every wire button name as a navigation or a hardware button" |
| 5 | **routes through `Devices`** ✓ (several PRs) | 48 routes under `/simulators/:udid/…`, 8 under `/devices/…`; `Server.swift` 3,781 lines | one route group per PR into `/devices/:id/…` through `Devices`; `/simulators/:udid/…` as its alias; `Server.swift` split by group as each moves. Shared: `Server.deviceRoutes(_:)` (both spellings), `Server.role(_:of:in:)`, a refusal answering `422` (can't) or `409` (not running). Groups: **screen state** (orientation · shake · status bar) ✓ · **power** (boot · shutdown) ✓ · **place and motion** (location · motion · network) ✓ · **files and apps** (files · apps · media · camera-source · openurl · schemes · defaults · relaunch · notify) ✓ · **hinge** ✓ · **chrome** (chrome · definition · bezel · mask · chrome-button · 3D model · render) ✓ · **screenshots** ✓ · **interface** ✓ · **companion screens** ✓ · **logs** ✓ · **input and describe-ui** ✓ · **the 2D stream** ✓ (one `Server.deviceStream` for every device, gestures on its `GestureQueues` lane; `IndigoHIDInput` hops to the main thread for each message build alone) · **the 3D stream** ✓ (one `Server.deviceLive3D`; a phone running the companion app keeps its motion-posed twin). The page: one `/devices/<id>` page for every device, each control shown by the device's abilities (`device-abilities.js`, `/devices/<id>/device.json`); `/simulators/<id>/…` answers with `Deprecation: true` until a later release; **the camera socket** ✓ (a `Camera` role, bound to its simulator, that `CameraSession` connects) | "should answer a device under the devices tree and a simulator under its old one", per group |
| 6 | **`Notify` out of `Apps`; `Lifecycle` → `Power`** ✓ | `Apps.deliver`; `SimulatorLifecycle` | `Notify` (`deliver`), registered by a simulator beside `Apps`; `Power` (`turnOn` · `turnOff`), `SimulatorPower`; the `.power` and `.notify` abilities | "should be delivered by the device's notifications"; "should boot the simulator when it is turned on" |
| 7 | **encoders built outside `Device`** ✓ | `StreamFormat.makeStream` (Domain) builds Infrastructure encoders | the format stays in the Domain; `makeStream` lives beside the encoders; no other Domain file builds an Infrastructure type | Domain builds nothing outside it |
| 8 | **contexts as modules, outside to inside** (one per PR) | one target, 407 files | `Device` (Chrome, abilities) → the kinds (Simulator, iPhone, CompanionPhone) → `Plugins` → `Commands`, `Server`; roles and values `public`, the rest internal | the compiler holds the direction Spike (measured): the `Device` module's dependency closure is 97 of the Domain's 250 files and ~1,950 declarations to make `public`. Fixed on the way: `SimulatorState.deviceState`, `SimulatorCamera` and `Attitude` pointed outward and moved. Moved inward: `Displays`, `ExternalDisplays`, `WatchPairing`, `InputSurface`, `HID`; `PairedWatch` reads a `DeviceState`. **Module 1, `BaguetteDevice` (`Sources/Device/`) ✓** — 95 files, made `public`; it builds alone, and the release build carries no mock. **The tree ✓** — no `App/`, `Domain/` or `Infrastructure/`: `Sources/{Commands, Server, Devices/{Simulator, iPhone, CompanionPhone}, Plugins/{Plugin, Bakery}, Device/{Chrome, Abilities/<ability>}}`, each implementation in its folder's `Internal/`, and `Tests/BaguetteTests/` mirrors it. `BaguetteDevice` now holds every device-wide ability with its host side (246 files); `Commands`, `Server`, `Devices` and `Plugins` still build as the one `Baguette` target until each becomes its own module |
| 9 | **Android** | — | its own storm and design, then `Devices/Android/` and one line | §5 |

Steps 1–2 are the cheapest and remove most of §1's cost; 3–4 end the
`false` answers and make `back` an ordinary value; 8 makes the shape
permanent.

## 8 · Open

- **The `/simulators/…` alias** — kept for plugins and bookmarks; for how long?
- **`Simulator`'s 37 members** — the role factories go once every caller asks
  `Devices` (slice 2); what remains is simulator-only domain (`SimulatorDefinition`,
  injection), which stays in `Devices/Simulator/`.
- **Server.swift's size** — splitting it by route tree follows slice 5; whether
  each ability's routes become their own file is decided then.
