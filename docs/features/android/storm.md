---
description: The event storm of driving an Android device with baguette — what becomes true, the commands that cause it, the refusals quoted word for word, the policies, who decides, and the hot spots left open. Read before designing the Android family.
---

# Android: the storm

> Step 1 of the domain flow, stormed 2026-11-18 from: the person's ask ("a high
> level design that can support Android, a good abstraction domain"); the
> words baguette already prints for every device (its commands and refusals,
> which an Android device answers in the same words); and Android's own
> documented words (`adb`, `emulator`, the phone's dialogs) — marked *(docs)*.
> No Android SDK is on the Mac this was stormed on, so nothing here was seen
> running; what no source shows is `[unconfirmed: …]` with how to confirm it.
> No type names: those come with the plan. The design it led to is
> [design.md](design.md).

## The timeline (level 1)

What becomes true, in the order a person meets it. The commands are the ones
baguette already has for a simulator; the person's ask is that they mean the
same on Android.

| # | Event | Cluster (its question) |
|---|---|---|
| 1 | **an Android device was listed** | *which devices are there?* |
| 2 | **USB debugging was allowed** (on a phone, by its owner) | *may this Mac drive it?* |
| 3 | **an emulator was started** | *is it running?* |
| 4 | **the emulator finished booting** | *is it running?* |
| 5 | **the screen was shown** (the page's live view, `stream`) | *what is on screen?* |
| 6 | **a screenshot was taken** · **a recording was saved** | *what is on screen?* |
| 7 | **the screen was described** (`describe-ui`) | *what is on screen?* |
| 8 | **a tap landed** · **a swipe was sent** · **a touch moved** | *what did the person do to it?* |
| 9 | **a button was pressed** (Back, Home, Recents, power, volume) | *what did the person do to it?* |
| 10 | **text was typed** · **a key was pressed** | *what did the person do to it?* |
| 11 | **an element was pressed by name** (`tap --label`) · **a field was filled** | *what did the person do to it?* |
| 12 | **an app was installed** · **launched** · **terminated** · **a link was opened** | *what runs on it?* |
| 13 | **the location was set** · **a route was started** | *what does it sense?* |
| 14 | **the device was rotated** | *what does it sense?* |
| 15 | **the clipboard was read** · **set** | *what does it hold?* |
| 16 | **the log was streamed** | *what is it saying?* |
| 17 | **the appearance was set** (dark mode, text size) | *how does it look?* |
| 18 | **the emulator was shut down** · **a phone was unplugged** | *is it running?* |

## Process (level 2)

Actors: **the person** (at the CLI or the page), **an agent** (driving through
the baguette skill), **the phone's owner** (holding the phone), **the clock**
(the page re-reading the list).

| Command | Read before it | Event | Refusal / policy | External |
|---|---|---|---|---|
| `baguette list` · the page's device list | — | **an Android device was listed** | adb's own word for a device that isn't usable: `offline`, `unauthorized`, `no permissions` *(docs: adb)* | adb |
| — (on the phone: *Allow USB debugging?*) | the computer's RSA key fingerprint *(docs)* | **USB debugging was allowed** | only the owner answers it; until then adb says `unauthorized` *(docs)* | the phone |
| `baguette boot --udid …` | the list: the device is off | **an emulator was started** | `<name> can't do lifecycle` — a phone has no boot | `emulator` |
| — | the list: *starting* | **the emulator finished booting** | **Policy:** whenever an emulator is starting, it is not ready, and `Device <name> is still starting` answers what needs a ready one `[unconfirmed: which Android signal says "booted" — boot animation done, home screen up]` | the emulator |
| open the page · `stream` | the device list | **the screen was shown** | `Device <name> is not booted` | adb |
| `screenshot` · `record` | — | **a screenshot was taken** · **a recording was saved** | `[unconfirmed: whether Android's own recorder stops after a time limit — *(docs)* says three minutes]` | adb |
| `describe-ui` | — | **the screen was described** | *no accessibility data* `[unconfirmed: what Android answers on a secure screen or mid-animation]` | the device's UI dump |
| `tap` · `swipe` · `input` (a drag on the page) | a screenshot or the description | **a tap landed** · **a swipe was sent** | `ok:true` means *sent*, not *reacted* (the product's own words) | adb |
| `press --button …` · the page's buttons | the device's bezel | **a button was pressed** | `Unknown button: <x> (allowed: …)`; an iOS-only button on Android `[unconfirmed: refused or mapped]` | adb |
| `type --text` · `key` | the focused field | **text was typed** · **a key was pressed** | `type` / `key` are US-ASCII; anything else goes through `paste` (the product's rule today) | adb |
| `tap --label …` · `fill` | `describe-ui --short` | **an element was pressed by name** · **a field was filled** | `nothing matches <name>` · `couldn't press <name>: it may have moved, so read the screen again` | — |
| `install` · `launch` · `terminate` · `openurl` | the installed apps | **an app was installed** · **launched** · **terminated** · **a link was opened** | `[unconfirmed: Android's words for a failed install — *(docs)* INSTALL_FAILED_…]` | the package manager |
| `location set` · `location route` | — | **the location was set** · **a route was started** | `<name> can't do location` on a phone `[unconfirmed: a phone can take a mock location only from an app chosen in Developer options]` | the emulator |
| `orientation --value …` | — | **the device was rotated** | `<name> can't do orientation` on a phone (as a physical iPhone answers today) | the emulator |
| `clipboard get · set` | — | **the clipboard was read** · **set** | `[unconfirmed: recent Android limits clipboard reads to the focused app]` | adb |
| `logs` | — | **the log was streamed** | — | adb (the device log) |
| `interface …` | the current appearance | **the appearance was set** | `[unconfirmed]` | adb |
| `shutdown` · unplugging | — | **the emulator was shut down** · **a phone was unplugged** | `Device <name> is unavailable: <reason>` for a phone off the cable | the emulator · the cable |

> **Policy:** whenever a device is refused, the refusal names the device and
> what it can't do (`<name> can't do <ability>`), never a fallback — the
> product's rule for every device today.
>
> **Policy:** whenever input is sent, its coordinates are in the units of the
> `width` / `height` it carries — the product's wire rule today.
>
> **Policy:** whenever the phone's owner hasn't allowed USB debugging, nothing
> is sent to the phone; baguette never answers the phone's dialog.

## Who decided (level 3)

Group the commands by the one thing that could have said no:

| Who decided | Commands it accepts or refuses | Its refusals (its laws) |
|---|---|---|
| **the device list** | which device an id names, for every command | `Device <id> not found` · `Device <id> is claimed by two sources` |
| **the device** | everything else: whether it can do the ability, and whether it is ready for it | `<name> can't do <ability>` · `is not booted` · `is still starting` · `is unavailable: <reason>` (adb's `offline` / `unauthorized` land here) |
| **the emulator** (an Android Virtual Device) | `boot` · `shutdown` — and what only an emulator has: location, rotation, sensors, network | `<name> can't do lifecycle` for a phone; `[unconfirmed: an emulator that won't start]` |
| **the screen's description** | `tap --label` · `fill` | `nothing matches <name>` · `couldn't press <name>: …` |
| **the device's buttons and keys** | `press` · `key` · `type` | `Unknown button: …` · US-ASCII only |
| **the phone's owner** (outside) | whether this Mac may drive the phone at all | adb's `unauthorized` |

Every row but the emulator's already exists for iOS, with the same words. The
emulator is the one new thing that decides — and it decides only what a
running Android emulator can be told and a phone can't.

## Crossings: events in code?

| Event | From → to | Test # (or none) | Who must hear it |
|---|---|---|---|
| *the emulator finished booting* | the emulator → the page's list | none: the page re-reads the list; the device's state changes | the page, by reading |
| *USB debugging was allowed* | the phone → the device list | none: the next list read finds adb's state changed | the list, by reading |
| *a phone was unplugged* | the cable → a running stream | none: the stream ends, as a simulator's does on shutdown | the open page, by its socket closing |

A table of *none*: no event type earns its place, as with iOS today.

## Hot spots

Left open here, as a storm leaves them; the stable domain
([CANONICAL_MODEL §1a](../../CANONICAL_MODEL.md#1a--the-stable-domain--the-same-for-every-device))
answers each from first principles, and [design.md](design.md) §4 says what Android adds.

| ⚡ | Meaning A | Meaning B | Who can decide |
|---|---|---|---|
| **UDID** | the flag `--udid` and the route `/devices/:udid` — an iOS word | an Android device's id: adb's serial for a phone (`R5CT…`), and for an emulator either its serial (`emulator-5554`, new on every start) or its AVD's name (stable) | the person |
| **boot** | a simulator boots in seconds, and *booted* is one state | an emulator *starts* (a process) and then *boots* Android (minutes on a cold start, seconds from a snapshot) — two events, and *starting* lasts | the person |
| **Home · app switcher** | iOS's Home button and app switcher | Android's Home key and **Recents** — one act, two words | the person (which word the product prints) |
| **Back** | — (iOS has none; an edge swipe goes back in an app) | Android's Back key, the most used button | the person |
| **point** | an iOS point (the wire's unit today) | Android's dp — and adb takes pixels | measure, then the person |
| **role** | `describe-ui`'s role words: `AXButton`, `AXTextField` | Android's own: a widget class (`android.widget.Button`) plus flags (clickable, checkable) | the person |
| **label** | the element's accessibility label | Android has two: its content description and its text | the person |
| **an app's name** | a bundle id, an `.app` | a package name, an `.apk` | the person (the flag's word) |
| **a phone** | an emulator and a phone are one family: both speak adb | they differ in most abilities (no boot, no location, no rotation) | the person |
| **the screen** | one screen per device | an emulator can have more than one display, and a foldable folds `[unconfirmed]` | later |

---

1 context · 18 events · 14 refusals · 5 policies · 10 hot spots open · 11 unconfirmed
