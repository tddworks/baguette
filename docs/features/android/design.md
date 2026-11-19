# Android: design

> Status: **slices 1 and 2 built**, 2026-11-19 — emulators listed, turned on and off, streamed and driven (screen, touch, scroll, buttons, keys), checked on a running AVD. Phones and slice 3 open. The family plan it follows: [devices/solid.md §5](../devices/solid.md#5--adding-android-under-this-design).

## Question

**Can baguette drive an Android emulator or phone the way it drives a simulator — listed, its screen streamed, touched, typed into, and its UI described — as one more device family, with nothing above `Devices/` changing?**

## What the kernel already has

- `DeviceKind.Platform.android` and `Reality.emulated` exist; `DeviceID` already means "a UDID or an adb serial".
- The families are listed once, in `Sources/Devices/DeviceKinds.swift`: Android is one line there.
- `Commands`, `Server` and the page reach a device only through `Devices.require(ability, of: id)`; the page shows what `/devices.json` says the device can do.
- **Missing:** `Navigation.back`. The comment on `Navigation` already reserves it. Android lists it among `Press`'s available navigations; iOS devices don't, so asking an iPhone for `back` is refused by name.

## The family

Pure values the whole family shares sit at the top; everything else in `Internal/`: the family's source, adb in `Kit/`, and one folder per mechanism with the values and code only it uses — an emulator does everything through its control API, so `Emulator/` holds all of it, its socket in its own `Internal/System/`.

```
Sources/Devices/Android/
├── AdbListing.swift ◇               what adb lists — the family's own listing, for every Android device
└── Internal/
    ├── AndroidDevices.swift         the family's source, and AndroidDevice: what one can do
    ├── Kit/                         Adb · AdbLocation — adb, shared by everything Android
    └── Emulator/                    the emulator's control API: everything an emulator does through it
        ├── RunningEmulator.swift ◇   a running emulator's .ini → serial, gRPC port, token
        ├── EmulatorControl.swift ◇        its protobuf messages
        ├── GRPCCall.swift ◇            one call as HTTP/2 bytes; replies and flow control back
        ├── EmulatorConnection.swift    the role screen and input share (next)
        ├── EmulatorScreen.swift · EmulatorTouch.swift   frames from streamScreenshot; sendTouch, sendKey (next)
        └── Internal/System/EmulatorSocket.swift          the one HTTP/2 connection to 127.0.0.1:<grpc.port>
```

Phones, when they come, take `Internal/Phone/` beside `Emulator/`, with whatever their mechanism turns out to be.

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

## Transport: the emulator's own gRPC API (decided 2026-11-19)

`Touch` promises `touch1`, `touch2` and `twoFingerPath` as well as `tap` and `swipe`; `adb shell input` has no second finger and starts a JVM per call (~0.3 s). An **emulator** has a better door: the Android Emulator serves Google's own control API, `android.emulation.control.EmulatorController`, over gRPC on loopback — what Android Studio's embedded emulator uses — and needs nothing installed on the device:

| Need | Call | Measured on `baguette_pixel` (Pixel 7, Android 15 arm64, emulator 37.2.13) |
|---|---|---|
| the screen | `streamScreenshot(ImageFormat)` — a frame pushed on each change; `getScreenshot` for one | `getScreenshot` returned a 1080 × 2400 PNG |
| touch, multi-finger | `sendTouch(TouchEvent)` — a list of `Touch`es, each `identifier` a Linux multitouch slot; `pressure` 0 lifts | a 13-move one-finger swipe opened the app drawer |
| keys and buttons | `sendKey(KeyboardEvent)` | — |

**Reaching it.** A running emulator writes `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`: `port.serial` (5554 → `emulator-5554`, the adb serial), `grpc.port` (8554) and `grpc.token`, sent as `authorization: Bearer <token>`. An emulator started with `-port` or without gRPC has no endpoint and no screen or touch.

**A minimal client of our own, no gRPC packages.** A call is HTTP/2 over cleartext TCP (prior knowledge): the preface and a SETTINGS frame, a HEADERS frame of HPACK literals (`:method POST`, `:path /android.emulation.control.EmulatorController/<call>`, `content-type application/grpc`, `te trailers`, the bearer token), and DATA frames each carrying a gRPC message (`0` + a 4-byte length + protobuf). baguette already frames HTTP/2 (`HTTP2Frame`, for the iPhone's RemoteXPC); the handful of messages are encoded by hand as tested values. Proved by a by-hand spike before any Swift. Offsider ([michael-palmes/offsider](https://github.com/michael-palmes/offsider)) takes the same API through grpc-swift and swift-protobuf; simvyn ([pranshuchittora/simvyn](https://github.com/pranshuchittora/simvyn)) uses adb only.

**Phones** have no such API; their screen and input wait on a phone to test with — scrcpy's server (video, multi-touch) or adb only, decided then.

## How an emulator plays the kernel's roles (built)

| Role | Through | Why |
|---|---|---|
| `Power` | `emulator -avd <name> -no-window -no-audio`, detached · `adb emu kill` | headless, like `baguette boot`; outlives baguette |
| `Screen` | the control API's `streamScreenshot` (RGBA → BGRA surfaces) | pushed on each change |
| `Touch` · `Scroll` | the control API's `sendTouch`; a scroll is a finger drag | real multi-touch; a phone-shaped AVD has no mouse, so `injectWheel` (it exists) reaches nothing |
| `Press` · `Key` | `adb shell input keyevent` / `keycombination`, by Android key codes | an AVD booted with `hw.keyboard=no` (phone profiles' default) drops the control API's key events; adb reaches every device |

**Identity.** An emulator's `DeviceID` is its AVD name (`baguette_pixel`) — the same across boots, as a simulator's UDID; adb's serial (`emulator-5554`) only exists while it runs and can change, so it is mapped from the discovery file. An installed AVD that isn't running lists as `off`, with `power` alone. A phone is its serial.

**The page.** `/devices.json` lists every device attached beside the simulators (`reality != .simulated`): phones and emulators alike.

## Slices

One PR each, test-first:

1. **List** — built. `AndroidDevices` in `DeviceKinds`; `baguette list` shows emulators and phones from `adb devices -l` (`AdbListing`), adb found by `AdbLocation`. No abilities yet. Power (boot and shut down an emulator) moves to slice 2: booting needs the `emulator` binary, not installed here.
2. **An emulator's screen and input** over its gRPC API; `Navigation.back`; emulators power on and off (`emulator -avd`, `adb emu kill`). The page streams and touches an emulator.
3. **The rest.** Accessibility, apps, orientation, location, pasteboard, logs.

## Open decisions

1. **Transport** — decided for emulators: their own gRPC API, through a minimal client of our own. For phones: open until there is one to test.
2. **Scope** — emulators and phones (the same adb path; power only for emulators), or emulators first. Recommended: both.
3. **Tooling on the development Mac** — `adb` 37.0.1 (Homebrew's `android-platform-tools`), the emulator 37.2.13 and an Android 15 arm64 image in `~/Library/Android/sdk`, AVD `baguette_pixel`, since 2026-11-19. `baguette list` shows it as `emulator-5554`, emulated.

## Risks

- **adb resolution.** `adb` may not be on `PATH`; look in `$ANDROID_HOME`, `$ANDROID_SDK_ROOT` and `~/Library/Android/sdk/platform-tools` before giving up, and say where it was looked for.
- **scrcpy protocol drift.** The server and its client protocol change between versions; the jar and the protocol are pinned together, and a mismatch is refused by name.
- **Accessibility vocabulary.** `AXNode` roles are iOS's; a uiautomator `class` maps onto them where one fits and stays as the raw class otherwise — decided in slice 3.
- **Chrome.** No Android bezels ship; the page shows the bare screen until one does.
