# Android: design

> Status: **slices 1 and 2 built**, 2026-11-19 — emulators listed, turned on and off, streamed and driven (screen, touch, scroll, buttons, keys, typing), checked on a running AVD. Phones (through scrcpy's server) and slice 3 next. The family plan it follows: [devices/solid.md §5](../devices/solid.md#5--adding-android-under-this-design).

## Question

**Can baguette drive an Android emulator or phone the way it drives a simulator — listed, its screen streamed, touched, typed into, and its UI described — as one more device family, with nothing above `Devices/` changing?**

## What the kernel already has

- `DeviceKind.Platform.android` and `Reality.emulated` exist; `DeviceID` already means "a UDID or an adb serial".
- The families are listed once, in `Sources/Devices/DeviceKinds.swift`: Android is one line there.
- `Commands`, `Server` and the page reach a device only through `Devices.require(ability, of: id)`; the page shows what `/devices.json` says the device can do.
- **Missing:** `Navigation.back`. The comment on `Navigation` already reserves it. Android lists it among `Press`'s available navigations; iOS devices don't, so asking an iPhone for `back` is refused by name.

## The family

Laid out as the iPhone family is: pure values the whole family shares at the top; in `Internal/`, the family's source, then one folder per ability — the mechanism one level down, so an adb screen for phones lands beside `EmulatorScreen` as `DevicectlScreen` sits beside `CoreDevice/` — what abilities share in `Kit/`, and the bare calls in one `System/`.

```
Sources/Devices/Android/
├── AdbListing · AVDListing ◇        what adb lists; the AVDs installed
├── AndroidKeyCode · AndroidScreenSize ◇   buttons and keys as key codes; wm size / density
└── Internal/
    ├── AndroidDevices.swift         the family's source, and AndroidDevice: what one can do
    ├── Screen/  EmulatorScreen      pictures drawn into shared memory, a notice each over streamScreenshot
    │            SharedPicture       the role: the memory emulator and baguette share
    ├── Input/   EmulatorInput       touches and scroll through sendTouch (its screen asked of adb once)
    │            AdbKeys             buttons, keys and typing through adb — every Android device
    ├── Power/   EmulatorPower       launch the AVD; `adb emu kill`
    ├── Kit/     AndroidTool · AndroidSDKLocation      an SDK tool, found
    │            RunningEmulator ◇   a running emulator's .ini → serial, gRPC port, token
    │            EmulatorControl ◇ · GRPCCall ◇        the control API's messages, as HTTP/2 bytes
    │            EmulatorConnection · EmulatorLink      one connection to the control API, screen and input each their own
    └── System/  TCPLink · DetachedLaunch · MappedSharedPicture
                                     the socket to 127.0.0.1:<grpc.port>; a process left running; an mmap'd file
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
| `Screen` | the control API's `streamScreenshot`, its pictures drawn into shared memory (`ImageTransport` MMAP: a file both map) | pushed on each change; only a 149-byte notice crosses the socket, where a raw 1080 × 2400 picture is 10 MB. vImage swaps RGBA → BGRA from the mapped memory into the surface VideoToolbox encodes, as a simulator's `IOSurface` is: ~40 fps of H.264 measured |
| `Touch` · `Scroll` | the control API's `sendTouch`; a scroll is a finger drag | real multi-touch; a phone-shaped AVD has no mouse, so `injectWheel` (it exists) reaches nothing |
| `Press` · `Key` | `adb shell input keyevent` / `keycombination`, by Android key codes | an AVD booted with `hw.keyboard=no` (phone profiles' default) drops the control API's key events; adb reaches every device |
| `Typing` | `adb shell input text`, the whole string (space as `%s`, the shell's characters escaped) | one command instead of a keystroke a character; an iOS simulator types by keystrokes (`KeystrokeTyping`) |

**Identity.** An emulator's `DeviceID` is its AVD name (`baguette_pixel`) — the same across boots, as a simulator's UDID; adb's serial (`emulator-5554`) only exists while it runs and can change, so it is mapped from the discovery file. An installed AVD that isn't running lists as `off`, with `power` alone. A phone is its serial.

**The screen, as a simulator's.** A simulator hands baguette its framebuffer as an `IOSurface`, shared memory. An emulator does the same through its control API, given a file to draw into:

```
 iOS Simulator:  framebuffer ──IOSurface (shared)───────────────────────────▶ VideoToolbox H.264 ──▶ page
 Emulator:       framebuffer ──mmap'd file (shared)──┐
                             ──149 B notice (gRPC)───┴▶ vImage RGBA→BGRA ──▶ IOSurface ──▶ VideoToolbox H.264 ──▶ page

 start:  SharedPicture (w × h × 4, from `wm size`) ─▶ streamScreenshot(RGBA, MMAP, file://…)
 each:   notice (width, height) ─▶ surface from the shared memory ─▶ onFrame
 ended by the emulator ─▶ the feed again in 1 s, same memory  ·  stop ─▶ close, unmap, delete the file
```

Measured on the Pixel 7 AVD, the same swipes: raw pictures were 10,368,037 bytes a message; shared memory, 149. Before either, the 64 KB HTTP/2 window held raw pictures to 23 fps and a Swift byte loop to 4 fps in a debug build; the 16 MB window and vImage stay.

**The page.** `/devices.json` lists every device attached beside the simulators (`reality != .simulated`): phones and emulators alike.

## Slices

One PR each, test-first:

1. **List** — built. `AndroidDevices` in `DeviceKinds`; `baguette list` shows emulators and phones from `adb devices -l` (`AdbListing`), adb found by `AdbLocation`. No abilities yet. Power (boot and shut down an emulator) moves to slice 2: booting needs the `emulator` binary, not installed here.
2. **An emulator's screen and input** over its gRPC API; `Navigation.back`; emulators power on and off (`emulator -avd`, `adb emu kill`). The page streams and touches an emulator.
3. **The rest.** Accessibility, apps, orientation, location, pasteboard, logs.

## What's left

As of 2026-11-19 (PR #141). There's no real Android phone to test against; everything below that needs one waits for it, and its emulator half is marked.

**Phones** — listed today (`baguette list`, the page), with no abilities.

- [ ] **Buttons, keys, typing.** Already built for emulators through adb (`AdbKeys`), and adb reaches a phone the same way: register them for a phone too. Testable with a fake adb; needs a phone only to confirm.
- [ ] **Screen, touch, scroll — through scrcpy's server, pinned** (Decision 1). Build and verify it on the emulator first (scrcpy runs on one), then confirm on a phone. Downloading the server jar needs the user's go-ahead.
- [ ] **No power.** A real phone can't be turned on or off from the Mac; it never registers `power`.
- [ ] **`unauthorized` phones** list as unavailable ("accept the USB debugging prompt"); untested on a real phone.

**Slice 3 — the rest, emulators first** (each also reaches a phone through adb or the scrcpy server):

- [ ] Accessibility: uiautomator's dump as `AXNode`s, by the class-to-role table (Decision 3).
- [ ] Apps: install, launch, terminate, list (`adb install`, `am start`, `am force-stop`, `pm list`).
- [ ] Location: the control API's `setGps` (emulators); a phone has no simulated GPS without a mock-location app.
- [ ] Clipboard: the control API's `setClipboard` / `getClipboard` (emulators).
- [ ] Logs: `adb logcat`.
- [ ] Orientation: the control API's `setPhysicalModel` (emulators).

**Smaller**

- [ ] `baguette input` (stdin, used by plugins) refuses an emulator: it requires a pasteboard up front, which an emulator doesn't have. It should require one only for `paste` / `copy`.
- [ ] An Android frame: the page borrows a DeviceKit (Apple) frame for an emulator (Decision 4).
- [ ] An emulator's OS in the list ("Android 15"): one more adb call per emulator (`getprop ro.build.version.release`) or the AVD's config.
- [ ] Watch for tearing in shared memory (Risks).

## Decisions

1. **Transport.**
   - **Emulators:** their own gRPC control API, through a minimal client of our own. Built: screen at ~45 fps; touch, scroll; power through the emulator binary and `adb emu kill`.
   - **Phones: scrcpy's server, pinned to one version.** From first principles, a phone has no control API. What adb gives us is a shell and `app_process`, which runs code of ours on the phone. Video at speed needs MediaCodec (the phone's hardware H.264 of its display), and touch at speed needs InputManager (injecting events directly); only code running on the phone can use either. `screencap` (a PNG per call) and `input` (one process per tap) are too slow to drive a phone live, and they aren't a fallback either. scrcpy's server is exactly that program: Apache-2.0, maintained, with its protocol versioned alongside it. It runs on an emulator too, so it can be built and verified before a phone is at hand.
   - **Buttons, keys and typing** stay on adb for every Android device (`AdbKeys`): the control API's `sendKey` is dropped when an AVD has no hardware keyboard.
2. **Scope.** Both. Every emulator and phone is listed; emulators are driven now; phones get abilities through (1).
3. **Accessibility vocabulary (slice 3).** uiautomator's dump becomes `AXNode`s. A widget class maps onto the iOS role it plays: `Button`; `EditText` → text field; `TextView` → static text; `ImageView` → image; `CheckBox`, `Switch`, `ScrollView`, … onto their own roles. A class with no counterpart keeps its own name as the role, never a guess.
4. **Frame.** Anything that isn't a simulator borrows a DeviceKit frame the viewer picks (`?chrome=`). No Android frame ships: Android Studio's device art comes with Android Studio, not the SDK. One is bundled when baguette ships its own.

## Risks

- **scrcpy protocol drift** (phones). The server and its protocol change together between versions, so the jar's version and the protocol are pinned as one value. A server that answers with another version is refused by name, never half-understood.
- **Tearing.** The emulator may start drawing the next picture while baguette reads the last from shared memory. The read is one vImage pass (~1 ms) as the notice arrives, so none has been seen; a torn picture would last one frame.
- **Gboard's stylus tutorial.** On an emulator with stylus handwriting on (the default), tapping a text field can open Gboard's "Try out your stylus" about a second later; typed text lands there. `back` closes it. It's the emulator's setting, not something baguette changes.

Resolved while building:

- **adb not on `PATH`** — `AndroidSDKLocation` looks in `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, `~/Library/Android/sdk` and Homebrew's paths.
- **The emulator closing a connection** — the socket sets `SO_NOSIGPIPE`, so a write after the emulator closed its end fails instead of ending the server. A call that fails goes once more on a fresh link. The screen starts its feed again, a second later, for as long as it's started.
- **A finger off the screen** — kept on its edge, and a negative `int32` is written as protobuf does, never a trap.
- **Slow pictures** — the connection opens with a 16 MB window, and vImage swaps the channels: 4 fps → ~45 fps.
- **Screen bandwidth** — 10 MB a picture through loopback (~450 MB/s at 45 fps) is gone: the emulator draws into shared memory and sends a 149-byte notice.

## Development setup

`adb` 37.0.1 (Homebrew's `android-platform-tools`), the emulator 37.2.13 and an Android 15 arm64 image in `~/Library/Android/sdk`, AVD `baguette_pixel`, since 2026-11-19. `baguette list` shows it by its AVD name, emulated. `baguette boot` starts it headless. For its own window, run `emulator -avd baguette_pixel`; baguette finds a running emulator either way.
