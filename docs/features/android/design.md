---
description: The device domain from first principles — what a person does with any device (see it, read it, act on it, run apps on it, make it sense, power it), in words that belong to no platform; every hot spot of the Android storm answered from that, the laws and their owners, how iOS simulators, iPhones, Android emulators and Android phones each realize it, and the path from today's code. Read before adding Android or any new kind of device.
---

# Devices, from first principles — and Android in them

**Status: DESIGN — not built.** The domain here is platform-neutral; today's
code is one realization of it (iOS), and §8 says what moves. Android's facts
are hypotheses (§9): no Android SDK was on the Mac this was designed on. The
discovery behind it is [storm.md](storm.md); its ten hot spots are answered in §4.

| For | Read |
|---|---|
| the device list and abilities as built today | [devices design](../devices/design.md) |
| every law's owner in today's code | [CANONICAL_MODEL](../../CANONICAL_MODEL.md) |

## 1 · The one sentence

A **device** is something that shows a screen, takes a person's hands, runs
apps and senses the world — and baguette lets a person or an agent **see it,
read it, act on it, run apps on it, make it sense, and power it**, in words
that belong to no platform.

```
            see          read           act            run          sense         power
person ──▶  Screen ──▶   UI snapshot    Gesture ·      App ·        Location ·    on · off
agent       (frames)     (elements)     Key · Text ·   Link         Orientation · (virtual only)
                                        Navigation                  Motion
                                     ▲
                 one Display binds the frames you see to the surface you touch
```

## 2 · Words (the ubiquitous language)

| Term | Meaning | Not to be confused with |
|---|---|---|
| **device** | one thing baguette drives, with a stable identity | a *device type* (a model), or the family's tool that reaches it |
| **embodiment** | **virtual** (made by software on this Mac: a simulator, an emulator) or **physical** (on a cable) | a platform — an iPhone can be either |
| **platform** | the OS family: iOS, Android (watchOS, tvOS, visionOS later) | a family |
| **family** | how baguette reaches devices — its toolchain: CoreSimulator, CoreDevice, adb | a platform: one platform can have two families (iOS: simulators and CoreDevice) and one family two embodiments (adb: emulators and phones) |
| **device id** | the name that survives restarts and unplugging; what a URL, a script and a bookmark hold | an **address** — where the family reaches it *now* (adb's `emulator-5554`, a tunnel IP) |
| **ability** | one thing a device can be asked to do; registered by its family, absent otherwise | a feature flag |
| **display** | one screen of a device and the touch surface over it, bound together | a window on the Mac |
| **logical unit** | the display's device-independent unit: an iOS point, an Android dp. Every coordinate in the domain is one | a **pixel** — a frame's unit only |
| **gesture** | where fingers go on a display, in logical units, over time | a navigation |
| **navigation** | what the person means, not which part they press: **home, back, app switcher, notifications, lock** | a hardware button |
| **hardware button** | a part of the device's body: **power, volume up, volume down, action, side** | a navigation (on iOS the side button also locks — that is the realization, not the word) |
| **key** | one key of a keyboard, as a HID usage (the USB standard: platform-neutral already) | **text** — characters to enter, however the platform enters them |
| **UI snapshot** | what is on screen as **elements**, each with a role, a name, a value, an identifier, a frame and a state | a screenshot |
| **role** | what an element *is to a person*: button, text field, secure field, toggle, checkbox, radio, slider, link, image, text, header, container | a platform's class (`android.widget.Button`, `UIButton`) — kept beside it as the *platform role* |
| **name** | what assistive technology announces for an element first | its text, or its identifier — those are separate fields |
| **app** | named by its **app id** — the platform's own name (bundle id, package name) | an **app package** — the file it installs from (`.app`, `.ipa`, `.apk`) |
| **power state** | **off · starting · ready · stopping · unavailable(reason)** | a family's raw word (`Booted`, `device`, `offline`) |

## 3 · The model, from the root down

```
Devices ◆                              EVERY DEVICE baguette can reach, from every family
│                                      device(id) · require(ability, of: id) — refuses, never guesses
└── Device ◆                           id ◇ · name · kind ◇ (platform × embodiment × model) · power ◇
    └── abilities ◇                    only what it can do; each one a role below
        ├── power → Power ◆                    turn on · turn off             (virtual devices)
        ├── displays → Displays ◆              the main display, and any others
        │   └── Display ◆                      geometry ◇ (logical size · scale · orientation)
        │       ├── screen → Screen ◆          frames, in pixels
        │       └── touch → TouchSurface ◆     gestures, in logical units — bound to that screen
        ├── controls → Controls ◆              navigate(Navigation ◇) · press(HardwareButton ◇)
        │                                      · key(Key ◇) · enter(Text ◇)
        │                                      answers which navigations and buttons it has
        ├── ui → UI ◆                          snapshot() → UISnapshot ◇ · press(element)
        │   └── UISnapshot ◇                   elements ◇ (role · name · value · identifier ·
        │                                      frame in logical units · enabled · platform role),
        │                                      the display's geometry
        ├── apps → Apps ◆                      install(AppPackage ◇) · launch · terminate(AppID ◇)
        │                                      · open(Link ◇) · installed()
        ├── senses → Location ◆ · Orientation ◆ · Motion ◆
        ├── clipboard → Clipboard ◆            text in, text out
        └── log → Log ◆                        the device's log, filtered
```

Five things answer *every* question a person asks a device. Each is pointable:
the **screen** you look at, the **controls** your hands use, the **UI** a
screen reader reads, the **apps** on it, and its **senses**. A family's job is
only to realize the ones it can.

## 4 · The storm's hot spots, answered

| ⚡ | Answer | From the principle |
|---|---|---|
| **UDID** | A device's **id** is the stablest name its family can give: iOS's UDID; an Android emulator's **AVD name**; an Android phone's **serial**. adb's `emulator-5554` and a tunnel's IP are **addresses**, resolved by the family per call. The flag is `--device`; `--udid` stays as its alias | identity is what survives a restart; anything that changes on restart is where, not who |
| **boot** | **Power** is a state machine every family shares: off → starting → ready (→ stopping → off), or unavailable(reason). *Turn on* is a request; *ready* is a fact the family observes (iOS: booted; Android: adb `device` **and** Android booted). Only virtual devices have Power | a command asks; the device says when it happened. A physical device is powered by its owner |
| **Home · app switcher (Recents)** | They are **navigations**, not buttons: home, back, app switcher, notifications, lock. One word per act on the wire; a platform's own word (*Recents*) is a label, never a second word | the person means *where to go*, not *which part to press*; iOS reaches home by a swipe, Android by a key — same act |
| **Back** | A navigation like the others. A device lists the navigations it has; iOS has no system back, so it refuses `back` by name | absent, not faked — an ability never appears where it can't be performed |
| **point** | Every domain coordinate is in the **display's logical unit** (iOS point, Android dp). A display's **geometry** (logical size, scale, orientation) is the one place pixels and logical units meet; frames are pixels, everything else is logical | a person's finger and a screen reader's frame mean the same place on any density |
| **role** | The domain owns a **role** vocabulary of what an element *is to a person*. Each family maps its own classes onto it; the platform's class is kept beside it as the *platform role*. The JSON keeps today's `AXButton` spellings as its projection, so no client breaks | the affordance rules (what can be tapped, filled, dragged) are about the person, so they must read a word no platform owns |
| **label** | An element has a **name** (announced first), a **value**, and an **identifier**, separately. Android's name is its content description, else its text; iOS's is its accessibility label | three questions, three fields; a merged "label" made `tap --label` match on whichever came first |
| **an app's name** | **App id** (the platform's name: bundle id, package name) and **app package** (the file: `.app`, `.ipa`, `.apk`, each with its platform). Installing a package of another platform is refused by name | what runs and what installs it are two things |
| **a phone (one family?)** | A **family is a toolchain**, not a platform: adb reaches emulators and phones alike, so one family; **embodiment** decides what registers (a phone has no Power, no faked location, no forced rotation) | the code that reaches them is one; what they can do differs by embodiment, which is data |
| **the screen** | A device has **displays**; the main one is always there. Others (an emulator's second display, CarPlay, a foldable's panels) are more displays, each binding its own screen to its own touch surface | already true for iOS (CarPlay, iPhone Duo); Android adds no new idea, only more of one |

## 5 · The laws, each with one owner

| Law | Owner |
|---|---|
| one id names one device across every family; an id two families claim is refused, never picked | `Devices` |
| a device does only what it registered; anything else is refused naming the ability and the device | the device's abilities |
| what needs a running device is refused until power is **ready**, saying the state | `Device` (power) |
| an id survives restarts; an address never leaves its family | each family's device source |
| a display's frames and its touch surface come from one binding | `Display` |
| every coordinate is logical; only a display's geometry converts to pixels | `DisplayGeometry` |
| a navigation or hardware button the device doesn't have is refused by name, never mapped to another | `Controls` |
| keys are HID usages; text is characters; each family maps them to its own codes | `Controls` (the family's realization) |
| a platform's element class reaches the rest only as a role | each family's UI mapping |
| an app package installs only on its platform | `AppPackage` |
| the owner of a physical device grants access (trust, USB debugging); baguette never answers that prompt | the family's power state (`unavailable`) |

## 6 · The tells

```swift
let device  = try devices.device(id)                       // the list decides who
try device.require(.power).turnOn()                        // a request; ready comes later
let shot    = try device.require(.displays).main.screen    // pixels
let ui      = try device.require(.ui).snapshot()           // logical frames, roles
try device.require(.controls).navigate(.back)              // or: refused, naming it
try device.require(.apps).install(AppPackage(file: apk))   // refused if it isn't Android's
```

The App and the server only parse and call these. No caller asks a device's
platform to decide what to do: that question is the family's, once, where the
device is built.

## 7 · How each family realizes it

| | iOS simulator | iPhone (CoreDevice) | Android emulator | Android phone (adb) |
|---|---|---|---|---|
| id | UDID | UDID | AVD name | serial |
| power | simctl | — | `emulator` · `adb emu kill` | — |
| screen | SimulatorKit framebuffer | its H.264 stream | `screenrecord` H.264 (H1) | same |
| touch surface | IndigoHID | Universal HID | `adb input` (H2) | same |
| controls: navigations | home, app switcher, notifications, lock (gestures and buttons) | gestures | home, back, app switcher, notifications, lock (key events) | same |
| controls: hardware buttons | power, volume, action, side | — | power, volume | power, volume |
| UI | AXPTranslator | its accessibility service | the UI dump (H3) | same |
| apps | simctl | — | `adb install` · `am` | same |
| senses | location, orientation, motion | — | location, orientation (H4) | — |
| clipboard · log | ✓ · ✓ | ✓ · — | H6 · logcat | H6 · logcat |

## 8 · From today's code to this

The model above is the target; today's code already holds most of it under
iOS-shaped names. One change at a time, each test-first:

| Today | Moves to | Why |
|---|---|---|
| `DeviceButton` (home, lock, power, app-switcher, swipe-to-home, …) | `Navigation` (home, back, app switcher, notifications, lock) + `HardwareButton` (power, volume up/down, action, side) | two concepts in one enum; Android needs `back` in the first |
| `AXNode.role: String` (`"AXButton"`) | `role: Role` (the domain's vocabulary) + `platformRole`; the JSON still prints `AXButton` | affordances read a word no platform owns |
| `AXNode.label` | `name` (+ `value`, `identifier` as today) | one question per field |
| `Input` (taps, swipes, buttons, keys in one) | `TouchSurface` (gestures, on a display) + `Controls` (navigations, buttons, keys, text) | the hands on the glass and the hands on the body are two surfaces |
| `Lifecycle` (boot · shutdown) | `Power` (turn on · turn off; the state is the device's) | virtual devices only, and the state is shared |
| `--udid` | `--device` (alias `--udid`) | an id that isn't a UDID |
| `install(AppBundle)` · `--bundle-id` | `install(AppPackage)` · `--app` (alias `--bundle-id`) | `.apk` beside `.app` and `.ipa` |
| `DeviceKind.Reality` (simulated · physical · emulated) | `Embodiment` (virtual · physical) | simulated vs emulated is the family's business, not the domain's |

None of these needs Android to land; each is right for iOS alone, and each
makes Android a family rather than a fork.

## 9 · Android: hypotheses to measure first

| # | Hypothesis | Pass | Fail → |
|---|---|---|---|
| H1 | `adb exec-out screenrecord --output-format=h264 -` streams live, under ~300 ms behind | the screen ability streams it through the existing decoder | `screencap`, then an emulator's own stream as a spike |
| H2 | `adb shell input` lands a tap under ~150 ms and a drag as one gesture | the touch surface stays adb-only | a small on-device helper of our own — its own design |
| H3 | the UI dump returns the frontmost app's elements in under ~2 s | the UI ability registers | registered for emulators only, or waits for the helper |
| H4 | one adb read says Android has booted; the emulator's console sets location and rotation | power and senses register | poll for the launcher; senses wait |
| H5 | a headless emulator streams and takes input | baguette's page is its only window | start it windowed |
| H6 | clipboard and appearance are settable over adb on current Android | they register | they stay absent |
| H7 | the SDK's skins give a bezel image and a screen rectangle | bezels from skins | a generic frame |

## 10 · Build sequence

| # | Slice | Pins (test names) |
|---|---|---|
| 0 | the §8 renames, one per change, on iOS alone | each moved law keeps its test, renamed in the new words |
| 1 | **spike** H1–H5 on one emulator and one phone; numbers into §9 | the cells of §7 |
| 2 | the Android family lists its devices | "should name an emulator by its AVD, never its address"; "should list a phone whose owner hasn't allowed debugging as unavailable, saying so" |
| 3 | power for emulators | "should hold an emulator as starting until Android says it has booted" |
| 4 | the main display: screen and touch surface | "should touch at logical units, scaled by the display's geometry"; "should split an H.264 byte stream into whole pictures" |
| 5 | controls | "should refuse a navigation the device doesn't have, naming it"; "should go back on Android with its back key" |
| 6 | UI | "should read an editable field as a text field"; "should name an element by its content description, else its text" |
| 7 | apps, log, senses as measured; docs, skills, CHANGELOG | one test per refusal and mapping |

## 11 · Open

- **An on-device helper** for Android, if H2 or H3 fail: ours, small, pushed
  per session — a design of its own.
- **Foldables and second displays on Android** — more displays, no new idea;
  stormed when someone needs one.
- **3D and bezels for Android** — no models; skins or a generic frame (H7).
