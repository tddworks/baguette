---
description: Drive an Android emulator like a simulator — boot and shut down an AVD, stream and record its screen, tap, swipe, two-finger gestures, buttons (back too), keys and typing. Use when an app must be checked on Android.
---

# Android emulators

An Android Virtual Device (AVD) is a device like any simulator: its AVD name is
its `--udid`, and the same commands drive it. Screen and touches go through the
emulator's own control API (what Android Studio's embedded emulator uses);
buttons, keys and typing through `adb`. What it can't do yet, it refuses by
name. Every flag: [commands.md](../../commands.md). How it works:
[design.md](design.md).

## Before you start

- The Android SDK's `adb` and `emulator`, found in `$ANDROID_HOME`,
  `$ANDROID_SDK_ROOT` or Android Studio's `~/Library/Android/sdk`.
- An AVD, made in Android Studio's Device Manager or with `avdmanager`.

## Quick start

```bash
baguette list                     # AVDs beside the simulators:
# {"udid":"baguette_pixel","name":"baguette_pixel","state":"off","reality":"emulated",…}

baguette boot       --udid baguette_pixel        # headless; outlives baguette
baguette screenshot --udid baguette_pixel --output pixel.png
baguette record     --udid baguette_pixel --output pixel.mp4 --duration 10
baguette stream     --udid baguette_pixel --format mjpeg > pixel.mjpeg

baguette tap   --udid baguette_pixel --x 206 --y 458 --width 412 --height 915
baguette swipe --udid baguette_pixel --start-x 206 --start-y 800 --end-x 206 --end-y 200 --width 412 --height 915
baguette press --udid baguette_pixel --button back          # home, app-switcher too
baguette type  --udid baguette_pixel --text "hello world"
baguette key   --udid baguette_pixel --code KeyA

baguette shutdown --udid baguette_pixel
```

Coordinates are in dp, the units of `--width` / `--height`: a 1080 × 2400
screen at density 420 is 411 × 914 dp (`adb shell wm size`, `wm density`).
Any width and height in the same proportion land in the same place.

In `baguette serve`, the emulator is a row on the device list; its page shows
its screen and turns clicks, drags and scrolls into touches.
`/devices.json` lists it with what it can do:

```
{"id":"baguette_pixel","name":"sdk gphone64 arm64","state":"ready",
 "kind":{"platform":"android","reality":"emulated","model":"sdk_gphone64_arm64"},
 "abilities":["power","screen","touch","press","key","scroll","type"]}
```

## What an emulator can do

| Ability | Commands | How |
|---|---|---|
| power | `boot`, `shutdown` | `emulator -avd <name> -no-window -no-audio` · `adb emu kill` |
| screen | `screenshot`, `stream`, `record`, the page | the control API draws each picture into memory baguette shares, then H.264 as for a simulator |
| touch, scroll | `tap`, `swipe`, `pinch`, `pan`, the page | the control API's multi-touch: two fingers are real |
| press | `press back` · `home` · `app-switcher` | `adb shell input keyevent` |
| key, type | `key`, `type` | `adb shell input`; `type` sends the whole string at once |

Anything else answers with what's missing and exits 1:

```
$ baguette describe-ui --udid baguette_pixel
[baguette] sdk gphone64 arm64 can't do accessibility
```

## Gotchas

- **The `--udid` is the AVD name, always.** adb's serial (`emulator-5554`)
  changes between boots; baguette maps it. Once running, the list shows the
  model's name (`sdk gphone64 arm64`), not the AVD's.
- **Not yet:** accessibility (`describe-ui`, `tap --label`), apps, orientation,
  location, clipboard and logs. Each is planned ([design.md](design.md#whats-left)).
- **`baguette input` refuses an emulator** for now: it asks for a pasteboard up
  front. Use the one-shot commands, or the page's WebSocket.
- **An emulator started without gRPC** (`-port`, or an old emulator) has no
  screen or touch: boot it with `baguette boot`, or from Android Studio.
- **Real Android phones** are listed but can't be driven yet.
- **The page's bezel is borrowed** from an Apple frame until there's an
  Android one.
