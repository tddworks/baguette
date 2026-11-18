---
description: How the Android family implements baguette's stable domain — emulators and phones over adb as devices like any other. Which roles it realizes and how, its answers to the storm's hot spots, the laws only Android needs, the hypotheses to measure first, and the build sequence. Read before writing any Android code.
---

# Android

**Status: DESIGN — not built.** Android adds an **implementation**, not a
domain: the roles, values and words are the stable ones in
[CANONICAL_MODEL §1a](../../CANONICAL_MODEL.md#1a--the-stable-domain--the-same-for-every-device),
and this doc says only how the Android family realizes them. Its discovery is
[storm.md](storm.md). Android's facts are hypotheses (§5): no Android SDK was
on the Mac this was designed on.

| For | Read |
|---|---|
| the stable domain every family implements | [CANONICAL_MODEL §1a](../../CANONICAL_MODEL.md#1a--the-stable-domain--the-same-for-every-device) |
| the device list and abilities as built | [devices design](../devices/design.md) |
| the other non-simulator family | [real devices](../real-devices/design.md) |

## 1 · The one sentence

The Android family reaches emulators and phones through **adb**; each is a
device like any other, and it registers only what its **embodiment** lets it do.

```
Devices ◆
└── AndroidDevices        one family (one toolchain: adb), two embodiments
       ├── an emulator    virtual:  id = its AVD's name    — power, senses, everything below
       └── a phone        physical: id = its serial        — no power, no faked senses
```

## 2 · What it realizes

| Stable role (1a) | Emulator | Phone | How |
|---|---|---|---|
| `Power` | ✓ | — | `emulator -avd <name>` (headless, H5) · `adb emu kill` |
| `Display` (`Screen` · `TouchSurface`) | ✓ | ✓ | `adb exec-out screenrecord` H.264 → the host's existing decoder (H1) · `adb shell input` in pixels, from logical units by the display's geometry (H2) |
| `Controls` | ✓ | ✓ | navigations and hardware buttons as key events (home, back, app switcher, notifications, lock; power, volume); keys from HID usages to Android key codes; text as text |
| `UI` | ✓ | ✓ | the UI dump → elements: roles mapped (§3), bounds from pixels to dp (H3) |
| `Apps` | ✓ | ✓ | `adb install` (`.apk` only) · `am start` · `am force-stop` · a VIEW intent for a link |
| `Location` · `Orientation` | ✓ | — | the emulator console (H4); a phone senses for itself |
| `Motion` | later | — | the emulator's sensors |
| `Clipboard` | H6 | H6 | adb, where current Android allows |
| `Log` | ✓ | ✓ | logcat |
| `Chromes` | H7 | H7 | the SDK's device skins, else a generic frame |

## 3 · Android's words, mapped onto the stable ones

Inside the family only; none of these words reaches the domain.

| Android says | The domain says |
|---|---|
| `emulator-5554` | an **address**; the id is the AVD's name |
| adb `device` + booted · `device` not booted · `offline` · `unauthorized` · `no permissions` | **ready** · **starting** · **unavailable**(adb's word) |
| `KEYCODE_HOME` · `KEYCODE_BACK` · `KEYCODE_APP_SWITCH` · notification shade · `KEYCODE_POWER` (sleep) | navigations **home · back · app switcher · notifications · lock** |
| `KEYCODE_POWER` · `KEYCODE_VOLUME_UP/DOWN` | hardware buttons **power · volume up · volume down** |
| px | logical units (dp) through the display's density |
| `Button`, `ImageButton`, clickable | role **button** |
| `EditText` (password: secure) | **text field** · **secure field** |
| `CheckBox` · `Switch` · `RadioButton` · `SeekBar` | **checkbox** · **toggle** · **radio** · **slider** |
| `TextView` · `ImageView` (not clickable) | **text** · **image** |
| anything else | **container**; the class kept as the platform role |
| content description, else text · `resource-id` | **name** · **identifier** |
| package name · `.apk` | **app id** · **app package** |

## 4 · The storm's hot spots — Android's answers

Each follows from a stable word in 1a; here is only what Android adds.

| ⚡ | Android's answer |
|---|---|
| UDID | an emulator's id is its **AVD name**, a phone's its **serial**; `emulator-5554` is an address |
| boot | starting until adb says `device` **and** Android says it has booted (H4) |
| Home · app switcher · Recents | navigations; *Recents* is Android's label for the app switcher, never a second wire word |
| Back | the `back` navigation, realized by `KEYCODE_BACK` |
| point | dp; only this family converts to pixels |
| role · label | §3's tables |
| an app's name | package name; only `.apk` packages install |
| a phone | the same family; embodiment decides what registers (§2) |
| the screen | one display for now; more later, as more `Display`s |

## 5 · Laws only Android needs

| Law | Owner |
|---|---|
| an emulator is named by its AVD; adb's serial never leaves the family | `AndroidDevices` |
| ready is adb `device` and Android booted; before that, starting | the Android device's power state |
| power, location and orientation register for an emulator only | the Android device (its embodiment) |
| pixels exist only inside the family's display and UI adapters | the Android display · the UI mapping |
| a phone whose owner hasn't allowed USB debugging is unavailable, saying `unauthorized`; baguette never answers that prompt | the Android device's power state |

## 6 · Hypotheses to measure first

| # | Hypothesis | Pass | Fail → |
|---|---|---|---|
| H1 | `screenrecord` streams H.264 live, under ~300 ms behind | the display streams it | `screencap`, then the emulator's own stream as a spike |
| H2 | `adb shell input` lands a tap under ~150 ms, a drag as one gesture | the touch surface stays adb-only | a small on-device helper of our own — its own design |
| H3 | the UI dump returns the frontmost app in under ~2 s | `UI` registers | emulators only, or waits for the helper |
| H4 | one adb read says Android booted; the console sets location and rotation | power and senses register | poll the launcher; senses wait |
| H5 | a headless emulator streams and takes input | baguette's page is its window | start it windowed |
| H6 | clipboard and appearance are settable over adb | they register | they stay absent |
| H7 | the SDK's skins give a bezel and a screen rectangle | bezels from skins | a generic frame |

## 7 · Infrastructure

```
Infrastructure/Android/
├── AndroidDevices.swift  AndroidDevice.swift   ← the only files that register its roles
├── Kit/        Adb (a `Subprocess`-backed runner, tested with MockSubprocess),
│               Emulator (start, list AVDs), EmulatorConsole (through `adb emu`)
└── Display/ Controls/ UI/ Apps/ Senses/ Clipboard/ Log/
Domain/Android/  pure, tested: adb's device listing, the AVD list, the UI dump → elements,
                 HID usage → key code, an H.264 byte stream → whole pictures
```

## 8 · Build sequence

| # | Slice | Pins |
|---|---|---|
| 0 | the stable names land on iOS first ([CANONICAL §6](../../CANONICAL_MODEL.md#6--where-the-code-is-still-behind)'s renames), one at a time | every moved law keeps its test, in the new words |
| 1 | **spike** H1–H5 on one emulator and one phone; numbers into §6 | §2's cells |
| 2 | the family lists its devices | "should name an emulator by its AVD, never its address"; "should list a phone whose owner hasn't allowed debugging as unavailable, saying so" |
| 3 | power | "should hold an emulator as starting until Android says it has booted" |
| 4 | the display | "should touch at logical units, scaled by the display's density"; "should split an H.264 byte stream into whole pictures" |
| 5 | controls | "should go back with Android's back key"; "should refuse a hardware button the device doesn't have, naming it" |
| 6 | UI | "should read an editable field as a text field"; "should name an element by its content description, else its text" |
| 7 | apps, log, senses as measured; docs, skills, CHANGELOG | one test per mapping and refusal |

## 9 · Open

- **An on-device helper**, if H2 or H3 fail: ours, small, pushed per session —
  its own design.
- **Second displays and foldables** — more `Display`s, no new idea; stormed
  when someone needs one.
- **3D models** — none for Android.
