---
description: The devices design, reworked against SOLID so a new kind of device (Android first) is one new family folder and one registration — stable roles each family implements, small enough to implement fully, one composition root, every command and route through Devices. Evidence from today's code, the rule each principle becomes, a walkthrough of adding Android, and the refactor slices.
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

| Principle | Evidence | What it costs a new family |
|---|---|---|
| **S** — one reason to change | `Input` has 8 members: touch, buttons, keys, scroll. `Server.swift` is 3,781 lines, 203 mentions of `simulators`. `Simulator` declares 37 members | a family that can touch but has no keys must still implement keys |
| **O** — open to extend, closed to change | the families are listed twice: `allDevices` in `SharedOptions.swift` and `physicalDevices` in `Server`. `DeviceButton` is a closed iOS set; 4 infrastructure `switch`es match its cases | Android's `back` edits the enum, its `allowed` list and every switch; a new family edits two composition roots |
| **L** — every implementation keeps the promise | `DigitizerInput` answers `button`, `key`, `scroll` with `false`; `ok:false` reads as *not sent*, not *can't* | callers can't tell "failed" from "this device has no keys" |
| **I** — small interfaces | `Input` (above); `Apps` holds `deliver(RemoteNotification)`, an iOS-only act, beside install/launch | an Android `Apps` would stub push notifications |
| **D** — depend on abstractions | the App and the server build concrete adapters in ~21 places (`CoreSimulators(…)` ×7, `SimctlInputSurface()` ×5, …); 6 commands still take a `Simulator`; 48 of 56 per-device routes live under `/simulators/…` and read `Simulators`; `StreamFormat.makeStream` (Domain) builds Infrastructure encoders | an Android device is unreachable from those commands and routes until each is rewritten |

## 2 · The shape

```
                        App (CLI)      Server (routes)        ← parse, then call a role
                              │              │
                              ▼              ▼
                        ┌──────────────────────────────┐
     Domain (stable)    │ Devices ◆ → Device ◆          │      depends on nothing below
                        │   abilities: role per ability │
                        │ roles ◆ (small, §3) · values ◇ │
                        └──────────────────────────────┘
                              ▲  implements, registers
          ┌───────────────────┼────────────────────┬───────────────────┐
     Simulator/          CoreDevice/          Android/            (next family)
     CoreSimulator       devicectl, CoreDevice adb, emulator
          └───────────────────┴──────── Host/ (encoders, decoder, subprocess, chrome) ┘

     Composition root (one): DeviceFamilies.all → CombinedDevices   ← the only list of families
```

## 3 · The roles — small enough to implement fully

Each role is one reason to change (S) and small enough that a family either
implements all of it or doesn't register it (I, L). A role says what it can do
as data where a family can do part of it (`navigations`, `buttons`), never by
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
| **S** | a role changes for one reason; a family's file changes only for its own toolchain | the role list (§3); a test per role uses only that role's mock |
| **O** | the families are listed once; a new ability, navigation or button is a new case **inside a family's registration**, never a `switch` above Infrastructure | `DeviceFamilies.all` — a test pins that the CLI and the server read the same list |
| **L** | an implementation does everything its role promises; what a device can't do is unregistered or not `available`, and refused by name — never `false` | `AbilityTable` · each role's `available`; a contract test per role, run against every family's implementation |
| **I** | no family implements a member it can't perform | §3's sizes; a family's registration names only roles it fully implements |
| **D** | the App and the server reach a device only through `Devices.require(ability, of: id)`; they never construct an adapter | the composition root; a check that `App/` and `Server/` import no family folder |

## 5 · Adding Android, under this design

| Step | Touches |
|---|---|
| the family | **new** `Infrastructure/Android/` — `AndroidDevices`, `AndroidDevice` (registers the roles it implements), its adapters |
| its pure parsing | **new** `Domain/Android/` — adb's listing, the UI dump → elements, key codes |
| registering it | **one line** in `DeviceFamilies.all` |
| the CLI, the routes, the page | **nothing** — they ask `Devices` for roles; the page shows what `/devices.json` lists |
| shared types | **nothing** — `back` already exists in `NavigationAction`; Android lists it in `available` |

Contrast with today: the two composition roots, `DeviceButton` and its four
switches, 48 routes, 6 commands and the `Input` stubs would all change.

## 6 · Build sequence — refactors, each green, no behaviour change

Each slice is test-first where it moves a rule, and leaves `swift test`,
`make test-web` and the CLI's output unchanged.

| # | Slice | Proves |
|---|---|---|
| 1 | **one composition root**: `DeviceFamilies.all`, read by `SharedOptions` and `Server` | "should list the same devices to the CLI and the server" |
| 2 | **commands through `Devices`**: the last 6 (`fill`, `launch`, `hinge`, `heal`, `network`, `motion`) ask `devices.require`; no command builds an adapter | each command's refusal test, for a device without the ability |
| 3 | **split `Input`**: `TouchSurface`, `Keyboard`, `Scroll` registered as abilities; `GestureDispatcher` asks for each; `DigitizerInput`'s stubs disappear | "should refuse a key for a device without a keyboard, naming it" |
| 4 | **`DeviceButton` → `NavigationAction` + `HardwareButton`**, each role listing `available`; the wire words stay | "should refuse a navigation the device doesn't have, naming it" |
| 5 | **routes through `Devices`**: one `/devices/:id/…` tree, ability by ability; `/simulators/:udid/…` stays as an alias of it | "should answer a simulator's screenshot under both trees" |
| 6 | **`Notifications` out of `Apps`**; `Lifecycle` → `Power` | each role's contract test |
| 7 | **`StreamFormat.makeStream` to Infrastructure**; Domain keeps the format | Domain builds nothing below it |
| 8 | Android, as §5 | its own design, built on this |

Slices 1–2 are the cheapest and remove most of the cost in §1; 3–4 are where
Android's `back` and an iPhone's missing keys stop being special.

## 7 · Open

- **The `/simulators/…` alias** — kept for plugins and bookmarks; for how long?
- **`Simulator`'s 37 members** — the role factories go once every caller asks
  `Devices` (slice 2); what remains is simulator-only domain (`SimulatorDefinition`,
  injection), which stays in the Simulator family.
- **Server.swift's size** — splitting it by route tree follows slice 5; whether
  each ability's routes become their own file is decided then.
