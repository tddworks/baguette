# Android: design

> Status: **proposed**, 2026-11-19. Not built; three decisions are open ([Open decisions](#open-decisions)). The family plan it follows: [devices/solid.md §5](../devices/solid.md#5--adding-android-under-this-design).

## Question

**Can baguette drive an Android emulator or phone the way it drives a simulator — listed, its screen streamed, touched, typed into, and its UI described — as one more device family, with nothing above `Devices/` changing?**

## What the kernel already has

- `DeviceKind.Platform.android` and `Reality.emulated` exist; `DeviceID` already means "a UDID or an adb serial".
- The families are listed once, in `Sources/Devices/DeviceKinds.swift`: Android is one line there.
- `Commands`, `Server` and the page reach a device only through `Devices.require(ability, of: id)`; the page shows what `/devices.json` says the device can do.
- **Missing:** `Navigation.back`. The comment on `Navigation` already reserves it. Android lists it among `Press`'s available navigations; iOS devices don't, so asking an iPhone for `back` is refused by name.

## The family

```
Sources/Devices/Android/                    Android emulators and phones, through adb
├── AndroidDevice.swift (+ AndroidDevices)  the source: adb's listing → Device; registers the abilities it performs
├── AdbListing.swift  ◇                     pure: `adb devices -l` + getprop → serial, model, emulated or physical, state
├── KeyEventCode.swift ◇                    pure: KeyboardKey and Navigation → Android KEYCODE_*
├── UIHierarchy.swift ◇                     pure: `uiautomator dump` XML → AXNode (slice 3)
└── Internal/
    ├── Kit/Adb.swift                       like Devicectl: `adb -s <serial> …` over Subprocess, unit-tested
    ├── Screen/ · Input/                    each session's decisions, tested through a @Mockable role
    └── System/                             the bare socket / process calls, ≤100 lines a file
```

| Word | Means |
|---|---|
| **serial** | adb's name for a device (`emulator-5554`, a phone's serial); it is the device's `DeviceID` |
| **emulator** | an AVD running in Google's emulator; `reality: .emulated`; it can be powered off and on |
| **phone** | a physical device with USB debugging on; `reality: .physical`; never powered by baguette |

Model: `ro.product.model`. An emulator's AVD name (`adb -s <serial> emu avd name`) is its display name.

## The abilities

| Ability | Role | How | Slice |
|---|---|---|---|
| `power` | `Power` | emulators only: `emulator -avd <name>` · `adb -s <serial> emu kill` | 1 |
| `screen` | `Screen` | see [Transport](#transport-the-open-decision) | 2 |
| `touch` · `press` · `key` | `Touch` · `Press` · `Key` | see [Transport](#transport-the-open-decision); `back`, `home`, `app-switcher` (recents) are `Press` navigations | 2 |
| `accessibility` | `Accessibility` | `uiautomator dump` → `AXNode`; bounds are pixels, divided by density to device points | 3 |
| `apps` | `Apps` | `pm list packages` · `install` · `am start` · `am force-stop` · `am start -a VIEW -d <link>` | 3 |
| `orientation` | `Orientation` | `settings put system user_rotation` with auto-rotate off | 3 |
| `location` | `Location` | emulators only: `adb emu geo fix <lon> <lat>` | 3 |
| `pasteboard` | `Pasteboard` | through the transport's clipboard if it has one; else not registered | 3 |
| `logs` | `LogStream` | `adb logcat`, line by line through the existing `LineBuffer` | 3 |
| `notify` · `hinge` · `motion` · `network` · `statusBar` · `defaults` · `photos` · `camera` | — | not registered | — |

A role is registered only when the family performs all of it ([solid.md §4, L](../devices/solid.md#4--each-principle-as-a-rule-with-an-owner)).

## Transport: the open decision

`Touch` promises `touch1`, `touch2` and `twoFingerPath` as well as `tap` and `swipe`. `adb shell input` has no second finger, and each call starts a JVM on the device (~0.3 s), so live drags from the page lag. That makes the transport the decision that shapes the family:

| | A. scrcpy's server (recommended) | B. adb only |
|---|---|---|
| Screen | H.264 up to 60 fps over one socket, into the existing `VTStreamDecoder` | `screenrecord --output-format=h264`, restarted every 3 min (its limit); or `screencap` at ~3 fps |
| Touch | multi-touch with pointer ids: all of `Touch` | tap and swipe only; `touch2` impossible, so `Touch` can't be registered |
| Keys, text, back, home, clipboard | one control socket | `input keyevent` / `input text`, ~0.3 s each; no clipboard |
| Cost | ship scrcpy's server jar (~90 KB, Apache-2.0 like baguette), pinned to one version, and speak its protocol | nothing shipped; a device that can't take baguette's gestures |

Under A, the session is conversational I/O: one `@Mockable` collaborator named for what it is (`ScrcpySession`: start, video bytes, control messages, end), the orchestrator tested through `MockScrcpySession`, and the socket and `adb forward` in `Internal/System/`. The video and control messages are pure values, tested byte for byte.

## Slices

One PR each, test-first:

1. **List and power.** `AndroidDevices` in `DeviceKinds`; `baguette list` shows emulators and phones; emulators boot and shut down.
2. **Screen and input.** The transport; `Navigation.back`; the page streams and touches an Android device.
3. **The rest.** Accessibility, apps, orientation, location, pasteboard, logs.

## Open decisions

1. **Transport** — scrcpy's server (A) or adb only (B). Recommended: A.
2. **Scope** — emulators and phones (the same adb path; power only for emulators), or emulators first. Recommended: both.
3. **Tooling on the development Mac** — none is installed (no `adb`, emulator or AVD as of 2026-11-19). Until there is one, slices are built test-first against captured fixtures, with no end-to-end check.

## Risks

- **adb resolution.** `adb` may not be on `PATH`; look in `$ANDROID_HOME`, `$ANDROID_SDK_ROOT` and `~/Library/Android/sdk/platform-tools` before giving up, and say where it was looked for.
- **scrcpy protocol drift.** The server and its client protocol change between versions; the jar and the protocol are pinned together, and a mismatch is refused by name.
- **Accessibility vocabulary.** `AXNode` roles are iOS's; a uiautomator `class` maps onto them where one fits and stays as the raw class otherwise — decided in slice 3.
- **Chrome.** No Android bezels ship; the page shows the bare screen until one does.
