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
          Commands (CLI)          Serve (page, routes)          Plugins
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
├── Serve/               THE WAY IN — `baguette serve`: the page, its routes and sockets
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
        ├── Screen/  Touch/  Press/  Key/  Type/  UI/  Apps/
        ├── Location/  Orientation/  Motion/  Network/  Interface/  StatusBar/  Shake/
        └── Capture/  Clipboard/  Logs/  Camera/  Hinge/
```

| Context | Its question | Uses |
|---|---|---|
| `Commands` · `Serve` | how do people get in? | everything below |
| `Devices` | how is each kind of device really driven? | `Device` |
| `Plugins` | what extends baguette, and from where? | `Device` (a plugin names a device by its id) |
| `Device` | what is a device: how it looks, and what it can do? | nothing |

- **A value lives with the ability that gives it meaning**, never in a shared
  bucket: a point in `Screen/`, a tap in `Touch/` (a touch is at a place on the
  screen), an element in `UI/` (it sits on the screen), a coordinate in
  `Location/`. Abilities depend on each other only where the meaning does.
- **Each ability declares its own key** (`Ability.screen` in `Screen/`), so
  `Device` itself imports none of them and a new ability touches nothing else.
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
as data where a kind can do part of it (`navigations`, `buttons`), never by
answering `false`.

| Role ◆ | Members | Replaces |
|---|---|---|
| `Power` | `turnOn()` · `turnOff()` | `Lifecycle` |
| `Screen` | `start(onFrame:)` · `stop()` | — (already small) |
| `TouchSurface` | `tap` · `swipe` · `touch1` · `touch2` · `twoFingerPath` — in logical units | the touch half of `Input` |
| `Navigation` | `available: Set<NavigationAction>` · `go(_:)` — home, back, app switcher, notifications, lock | `DeviceButton`'s system half |
| `HardwareButtons` | `available: Set<HardwareButton>` · `press(_:duration:)` — power, volume, action, side | `DeviceButton`'s body half |
| `Keyboard` | `press(Key, modifiers:)` · `type(Text)` — keys as HID usages | `Input.key`, `TypeText` |
| `Scroll` | `scroll(deltaX:deltaY:)` | `Input.scroll` |
| `UI` | `snapshot()` · `press(element)` | `Accessibility` |
| `Apps` | `install(AppPackage)` · `launch` · `terminate` · `open(Link)` · `installed()` | `Apps` minus notifications |
| `Notifications` | `deliver(_:)` | `Apps.deliver` (iOS today) |
| `Location` · `Orientation` · `Motion` · `Clipboard` · `Log` · `Interface` · … | as today | — |

A capability the device lacks is **absent** (the ability isn't registered), or,
inside a role that lists its options, **not in `available`** — and asking for it
is refused by name: `Pixel 9 can't do hardwareButtons`, `iPhone 17 has no back`.

## 4 · Each principle, as a rule with an owner

| Principle | The rule | Owner — and how it's checked |
|---|---|---|
| **S** | a role changes for one reason; a kind's file changes only for its own toolchain | the role list (§3); a test per role uses only that role's mock |
| **O** | the kinds of device are listed once; a new ability, navigation or button is a new case **inside a kind's registration**, never a `switch` outside `Devices/` | `Devices/`' list of kinds — a test pins that `Commands` and `Serve` read the same list |
| **L** | an implementation does everything its role promises; what a device can't do is unregistered or not `available`, and refused by name — never `false` | `AbilityTable` · each role's `available`; a contract test per role, run against every kind's implementation |
| **I** | no kind implements a member it can't perform | §3's sizes; a kind's registration names only roles it fully implements |
| **D** | `Commands` and `Serve` reach a device only through `Devices.require(ability, of: id)`; they never construct a kind's code | the module graph: `Commands` and `Serve` see only a kind's device source |

## 5 · Adding Android, under this design

| Step | Touches |
|---|---|
| the kind | **new** `Devices/Android/` — its device source (registers the abilities it implements), its adb and emulator code, its pure parsing (adb's listing, the UI dump → elements, key codes), all internal |
| registering it | **one line** in `Devices/`' list of kinds |
| `Commands`, `Serve`, the page | **nothing** — they ask `Devices` for abilities; the page shows what `/devices.json` lists |
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
| `Commands` · `Serve` | `docs/commands.md` · `docs/serve.md` | the way in; they hold no rule |

## 7 · Build sequence — refactors, each green, no behaviour change

Each slice is test-first where it moves a rule, and leaves `swift test`,
`make test-web` and the CLI's output unchanged.

| # | Slice | Proves |
|---|---|---|
| 1 | **one list of kinds**, read by the CLI (`SharedOptions` today) and the server | "should list the same devices to the CLI and the server" |
| 2 | **commands through `Devices`**: the last 6 (`fill`, `launch`, `hinge`, `heal`, `network`, `motion`) ask `devices.require`; no command builds an adapter | each command's refusal test, for a device without the ability |
| 3 | **split `Input`**: `TouchSurface`, `Keyboard`, `Scroll` registered as abilities; `GestureDispatcher` asks for each; `DigitizerInput`'s stubs disappear | "should refuse a key for a device without a keyboard, naming it" |
| 4 | **`DeviceButton` → `NavigationAction` + `HardwareButton`**, each role listing `available`; the wire words stay | "should refuse a navigation the device doesn't have, naming it" |
| 5 | **routes through `Devices`**: one `/devices/:id/…` tree, ability by ability; `/simulators/:udid/…` stays as an alias of it | "should answer a simulator's screenshot under both trees" |
| 6 | **`Notifications` out of `Apps`**; `Lifecycle` → `Power` | each role's contract test |
| 7 | **`StreamFormat.makeStream` to Infrastructure**; Domain keeps the format | Domain builds nothing below it |
| 8 | the contexts as modules, outside to inside (§2) — `Device` first, then `Devices` and its kinds, `Plugins`, the way in | the compiler holds the direction; each module's tests move with it |
| 9 | Android, as §5 | its own design, built on this |

Slices 1–2 are the cheapest and remove most of the cost in §1; 3–4 are where
Android's `back` and an iPhone's missing keys stop being special.

## 8 · Open

- **The `/simulators/…` alias** — kept for plugins and bookmarks; for how long?
- **`Simulator`'s 37 members** — the role factories go once every caller asks
  `Devices` (slice 2); what remains is simulator-only domain (`SimulatorDefinition`,
  injection), which stays in `Devices/Simulator/`.
- **Server.swift's size** — splitting it by route tree follows slice 5; whether
  each ability's routes become their own file is decided then.
