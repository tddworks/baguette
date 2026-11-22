---
description: Design of the Mac family — this Mac's displays as devices, watched through ScreenCaptureKit and driven through CGEvent, shared to a viewer's device through a virtual display of its shape, with a pointer the page draws. Read before touching Sources/Devices/Mac or the share, pointer or hover paths.
---

# Mac screen — "this Mac, watched and driven from any browser, in the viewer's shape"

**Status:** BUILT on `feat/mac-screen`, and measured on macOS 27 (two Dell
displays, an iPhone 17 Pro Max over Wi-Fi and Tailscale): listing, watching,
input, frames, sharing to a viewer's shape (main or extended, turning), the
local pointer with the Mac's real shape, hover. Not built: sign-in (dropped for
now, §8). A shared display streams H.265 when the viewer's browser offers it,
H.264 otherwise ([hevc](../webrtc/hevc.md)). Turning on a real iPhone is not yet confirmed (§8).

This document owns **what a Mac display is, how it is watched and driven, how
this Mac is shared to a viewer's device, and how the pointer reaches the page**.
Its neighbours own the rest:

| For | Read |
|---|---|
| using it — flags, routes, the page's choices | [README](README.md) |
| how any device registers what it can do | [devices](../devices/design.md) |
| how frames are encoded and leave — MJPEG, AVCC, WebRTC | [stream](../stream/README.md), [webrtc](../webrtc/design.md) |
| how a gesture travels from the page to a device | [ARCHITECTURE](../../ARCHITECTURE.md) |
| every law across baguette, one line each | [CANONICAL_MODEL](../../CANONICAL_MODEL.md) |

---

## What the product already says

```
  baguette list --mac              {"udid":"<display UUID>", …, "model":"DELL UP2716D"}   ← a display is a device
  baguette serve --share-mac       "Also show this Mac's displays … Anyone who can reach --host:--port sees and controls this Mac."
  the device page                  [DEVICE · touch] [Frame]   ← a frame is a look, picked, never guessed
  /mac/share                       "Share this Mac" · Room: Larger text / Standard / More space
                                   · Use as: Main display / Extended display   ← macOS's own "Use as" words
  System Settings › Displays       "baguette – iPhone"   ← macOS lists a share as a real display
```

The user thinks of their Mac's screens as devices like any other, and of
sharing as "make my Mac fit my phone" — the words Apple's own Screen Sharing
taught them.

## The one sentence

**A Mac display is a device that plays `Screen`, `Touch`, `Pointer`, `Scroll`,
`Key` and `Typing`; sharing makes one more — a virtual display the viewer's
shape — and the page draws the pointer itself, so it never waits for the
picture.**

```
                         Devices ◆  (simulators · phones · Androids · this Mac)
                            │
                   MacDisplays ◆  (with --share-mac, or a display's UUID)
                            │                                         ScreenShares ◆
                   MacDisplay : Device ── one per attached display  ◀── makes virtual displays
                            │              and per share                the viewer's shape
        ┌───────────────────┼────────────────────────┐
     .screen             .touch .pointer .scroll .key .typing
     MacScreen ◆         MacInput ◆ ── DisplayEvents ◇ → HostEvents ◆ (CGEvent)
       │
     DisplayFeed ◆ (ScreenCaptureKit, no pointer in the picture)
                                                      PointerShapes ◆ ── the Mac's pointer shape,
                                                                         for the page to draw
```

---

## 1 · Ubiquitous language

| Term | Meaning | Not to be confused with |
|---|---|---|
| **Mac display** | one display attached to this Mac — physical or virtual — as a device, named by its own UUID | a window (not a device, §8) |
| **share** | this Mac shown on a viewer's device through a display made for it; ends when the viewer leaves | macOS Screen Sharing (VNC), which baguette doesn't speak |
| **viewer** | the device a share is shown on — its screen in its own points and pixel ratio | the person; a Mac display can have several pages open |
| **shape** | a shared display's size: the viewer's points × the room, drawn at 2× | the display's *mode*, macOS's word for one size it offers |
| **room** | how much of the Mac fits the viewer: Larger text (1×), Standard (1.5×), More space (2×) | the stream's `scale`, which shrinks the picture, not the desktop |
| **main / extended** | whether the shared display carries the menu bar, Dock and new windows (macOS's "Use as") | mirrored, which baguette doesn't offer (§9) |
| **local pointer** | the pointer the page draws — instant — instead of the one in the picture | the Mac's pointer, which still moves (clicks land there) |
| **pointer shape** | what the Mac's pointer looks like now (arrow, I-beam, hand), its image and hotspot | the cursor CSS the page builds from it |
| **hover** | the pointer moving with no button down | a drag (`touch1-move`), which has one down |
| **frame** | a picture of a MacBook or iMac a display can be shown in | a stream frame; chrome (DeviceKit's word for a simulator's bezel) |

---

## 2 · The aggregate — from the root down

```
MacDisplays ◆                      the displays CoreGraphics lists now; listing asks no permission
└── MacDisplay : Device            one display: UUID, name, .macOS · .physical, always .ready
    ├── MacDisplayInfo ◇           id (this boot) · uuid (for good) · name · bounds on the desktop (global points)
    ├── .screen  → MacScreen ◆     hands on complete pictures only; restarts a feed that ends;
    │                              captures a display baguette made at the pixels it made it with
    │   └── DisplayFeed ◆          ScreenCaptureKit, started with a sizing rule, no pointer in the picture
    │       └── DisplayCaptureSize ◇   pixels, long side ≤ 4096, both sides even
    └── .touch .pointer .scroll .key .typing → MacInput ◆
        ├── DisplayEvents ◇        what each gesture becomes, placed on the desktop: [HostEvent]
        │   └── MacKeyCode ◇       HID page 7 → kVK_ANSI_*
        └── HostEvents ◆           the window server, told events; refuses while untrusted (WindowServerEvents)
            └── WindowServer ◆     one event posted (CGEvent); whether this process is trusted

ScreenShares ◆                     this Mac shared to viewers, by the shared display's UUID
├── SharedScreenShape ◇            the viewer's points × room, drawn at 2×; which mode is its own
├── VirtualDisplays ◆              makes a display of a shape, under a serial → the same UUID again
│   └── VirtualDisplay ◆           id · uuid · remove() — returns once the Mac lists it no more
└── DisplayArrangement ◆           which display is main; making another main (a child process)
    └── DisplayConfiguration ◆     the session's: main · origins · place (MainDisplayMove, in the child)

PointerShapes ◆                    the Mac's pointer shape while anyone views; each image by id
└── PointerShape ◇                 id (from its image) · hotspot · size · png

MacFrame ◇ (Device/Chrome)         a frame picture's size and its measured screen opening; fits(display)
```

---

## 3 · How it works

### 3.1 · Watching a display

```
 ScreenCaptureKit                      MacScreen                         Stream (unchanged)
 ┌─────────────────────┐  FeedPicture  ┌──────────────────────────┐ IOSurface ┌──────────────────┐
 │ SCStream on one     │ ────────────▶ │ .complete only; .idle /  │ ────────▶ │ MJPEG · AVCC ·   │──▶ page
 │ display, BGRA,      │               │ .blank carry nothing new │           │ WebRTC (H.264)   │
 │ ≤ 60 fps,           │ ◀── sizing ── │ size: madePixels (a share│           │ LatestFrame      │
 │ showsCursor = false │   rule at     │ it made) else Display-   │           │ refreshes a still│
 └─────────────────────┘   start       │ CaptureSize(SCK points × │           │ screen           │
         ▲                             │ pointPixelScale)         │           └──────────────────┘
         │ ends (sleep, display gone)  │ ended → start again in 1s│
         └─────────────────────────────┴──────────────────────────┘
```

A Mac display adds no format: everything a simulator's screen feeds works on
it. ScreenCaptureKit scales at the source, so a 5K display is never copied at 5K.

### 3.2 · Sharing to a viewer's shape

```
 Viewer (/mac/share)              Server                                   Child processes
 ┌──────────────────────┐ POST    ┌───────────────────────────────┐ spawn  ┌─────────────────────────────┐
 │ visible size, pixel  │ /mac/   │ ShareRequest ◇ → Shared-      │ ─────▶ │ baguette virtual-display    │
 │ ratio, room, use     │ shares  │ ScreenShape ◇                 │ ready  │  makes ONE display, chooses │
 └──────────────────────┘ ──────▶ │ ScreenShares.start            │ ◀───── │  its 2× mode, holds it while│
            ▲                     │  1 read main (before: a new   │ id uuid│  it lives                   │
            │ 201 {id}            │    display reads as main)     │        └─────────────────────────────┘
            │                     │  2 VirtualDisplays.create     │ spawn  ┌─────────────────────────────┐
            │                     │  3 main? → makeMain(new)      │ ─────▶ │ baguette main-display --id  │
 /devices/<id>?share=…  ◀──────── │ log "[mac] share … started"   │ exit 0 │  shifts every origin so the │
 WebRTC, the viewer's shape       └───────────────────────────────┘ ◀───── │  display sits at 0,0        │
                                                                           └─────────────────────────────┘
 turn (resize ≥ 8% or flip) → PUT /mac/shares/<id>:  main back → remove old → create new (same serial, same id) → main
 leave (pagehide)           → DELETE /mac/shares/<id>: main back → remove → the process ends, the display goes in ½ s
```

Why child processes, and why in that order, is §7: each step is a measured
macOS behaviour. The server stays a reader — it never makes a display and never
changes the arrangement — because a process that does either stops seeing
displays added later, and the server must see them to list and stream them.

### 3.3 · Input

```
 page ── WS (stream / WebRTC control) ──▶ Server.handleInbound
                                             │ move(line:)? (touch1-move · touch2-move · hover)
                          ┌──────────────────┴───────────────────┐
                          ▼ post — read on at once               ▼ run — wait, in order
                ┌──────────────────────────────────────────────────────────┐
                │ GestureQueues lane (one per device)                      │
                │   PendingGestures ◇:  [down] [move→move→move] [up]       │
                │   a newer move REPLACES a waiting move; down, up, tap,   │
                │   key, scroll keep their place and are never dropped     │
                └─────────────────────────────┬────────────────────────────┘
                                              ▼
              MacInput → DisplayEvents ◇ → [HostEvent] → WindowServerEvents → CGEventWindowServer
              (placed at x/width of the display's desktop bounds;    trust asked once,
               a two-finger move scrolls where its midpoint is)      one event source
```

### 3.4 · The pointer

```
 Viewer                                             Mac (baguette serve)
 ┌──────────────────────────────────┐             ┌────────────────────────────────────────────────┐
 │ finger / trackpad moves          │             │                                                │
 │   ├─▶ LocalPointer draws it NOW  │  hover/move │  GestureQueues lane — latest wins (3.3)        │
 │   │   (mouse: the browser's own  │ ──────────▶ │    └─▶ MacInput → CGEvent → the Mac's pointer  │
 │   │   cursor; finger: drawn at   │             │                         │            │         │
 │   │   its hotspot)               │             │                         ▼            ▼         │
 │   └─▶ HoverGestureSource: no     │  picture    │  ScreenCaptureKit             baguette          │
 │       button → hover, newest,    │ ◀────────── │  showsCursor = false          pointer-shapes   │
 │       once a frame               │  WebRTC     │  → encode → send              (run loop, 20 Hz) │
 │ ┌──────────────────────────────┐ │             │                                     │ "shape …"  │
 │ │ canvas: picture, no pointer  │ │ {"type":    │                               PointerShapes ◆   │
 │ │  + LocalPointer on top, in   │ │◀─"pointer",…│                               while anyone      │
 │ │  the Mac's shape             │ │ WS /mac/    │                               watches; image   │
 │ └──────────────────────────────┘ │ pointer     │                               by id            │
 │   GET /mac/pointer/<id>.png once │ ◀────────── │                                                │
 └──────────────────────────────────┘             └────────────────────────────────────────────────┘
   The pointer follows the hand at once; only what is under it (menus, highlights) waits for the round trip.
```

Taken from Apple's Screen Sharing, as an open client
([open-screen-sharing](https://github.com/nekohasekai/open-screen-sharing))
reads its protocol: the pointer travels apart from the picture — its shape,
cached by id, and its position — and pointer moves are latest-wins.

### 3.5 · Frames

```
 definition.json?chrome=<frame>          CombinedChromes ◆  — the first that answers
 ───────────────────────────────▶ ┌── LiveChromes      (DeviceKit: simulators, borrowed by phones)
                                  ├── MacFrames        (a measured MacFrame + <frames folder>/<name>.png)
                                  └── MacDisplayLooks  (with --share-mac: a display's own look — a clear
                                                        PNG its size, the screen filling it: "No frame")
```

---

## 4 · The tells

```swift
// The family decides what a display can do, once.
abilities.register(.screen)  { MacScreen(display: info, feed: feed(), madePixels: madePixels(info.uuid)) }
abilities.register(.pointer) { input }

// A gesture is told what it becomes; the window server is told the events.
events.post(display.hover(at: point, size: size))
events.post(display.twoFingerScroll(from: last, to: (first, second), size: size))

// A share is told what to do, never asked how.
shares.start(viewer: request.viewer, shape: request.shape, use: request.use)
shares.reshape(id, to: request.shape)
shares.end(id)

// The lane is told a move and its kind; it decides what a newer one replaces.
gestureQueues.post(on: udid, move: move) { _ = dispatcher.dispatch(line: line) }

// A viewer is told each shape; the page tells its pointer.
let watch = shapes.watch { saying.yield($0.json) }
pointer.setShape({ ...shape, cursor: PointerShape.cursor(shape, density) })
```

---

## 5 · Invariants — each law, one owner

| Law | Owner |
|---|---|
| a Mac display is reached only when asked for — `serve --share-mac`, `list --mac`, or its UUID; listing asks no permission | `MacDisplays` · `DeviceKinds` |
| a display is named by its UUID, the same across reboots; its `CGDirectDisplayID` isn't | `MacDisplayInfo` |
| a picture is handed on only when complete; an unchanged one repeats the last | `MacScreen` |
| a capture is the display's pixels, long side ≤ 4096, both sides even | `DisplayCaptureSize` |
| a display baguette made is captured at the pixels it made it with | `MacScreen` (`madePixels`) |
| a gesture lands at the same fraction of the display, wherever it sits on the desktop | `DisplayEvents` |
| a key's modifiers are held around it and released in reverse | `DisplayEvents` |
| two fingers moving together scroll where their midpoint is; a pinch scrolls nothing | `DisplayEvents` · `MacInput` |
| a pointer move still waiting is replaced by a newer one; nothing else is dropped or reordered | `PendingGestures` |
| only a device with a pointer of its own takes a hover; a page draws the pointer and sends hovers for any device that can `pointer` | each family's `Abilities` · the page's `mountPointer` |
| a shared display is the viewer's shape — its points × room, drawn at 2×, long side ≤ 4096 px | `SharedScreenShape` |
| a share's display keeps its id through a turn; main is given back, before the old display goes | `ScreenShares` |
| the server never makes a display nor changes the arrangement; child processes of `serve` do | `ChildVirtualDisplays` · `ChildDisplayArrangement` |
| removing a display finishes when the Mac no longer lists it | `ChildVirtualDisplays` |
| the pointer shape is read only by a process whose run loop runs, while anyone watches; each image is fetched once by id | `PointerShapes` · `PointerShape` |
| a frame fits a display only of its screen's shape, within 2%; a display shows with none until one is picked | `MacFrame` · `MacDisplayLooks` |

---

## 6 · The tree — outside in

```
Commands/       list --mac · serve --share-mac · virtual-display · main-display · pointer-shapes (hidden)
Server/         ServerMacShareRoutes (/mac/share, /mac/shares) · ServerMacPointerRoutes (/mac/pointer)
                · handleInbound (moves posted, the rest awaited)
Devices/Mac/    roles the server holds: ScreenShares · PointerShapes
                values: MacDisplayInfo · DisplayCaptureSize · DisplayEvents · MacKeyCode · SharedScreenShape
                        · ShareRequest · ShareUse · DisplayOrigins · VirtualDisplayAnnouncement · PointerShape
  Internal/     MacDisplays · MacDisplayLooks · Screen/MacScreen (FeedEnd) · Input/MacInput · WindowServerEvents
                · Sharing/VirtualDisplayShares · ChildVirtualDisplays · ChildDisplayArrangement · MainDisplayMove
                · Pointer/ChildPointerShapes · PointerShapeChanges
  Internal/System/   the bare calls to the outside, no decisions, ≤ 100 lines each: ScreenCaptureKitFeed
                     · CGEventWindowServer · HostDisplayList · VirtualDisplayHold (CGVirtualDisplay, private)
                     · CoreGraphicsDisplayConfiguration · PointerShapeWatch · ClearPicture
Device/         Abilities/Pointer (Pointer role, Hover) · Abilities/Touch/PendingGestures · Chrome/MacFrame
Resources/Web/  local-pointer.js · pointer-shape.js · baguette/gestures/hover-gesture-source.js
                · families/mac/share.js (an ES module) + mac-share.html · mac-frame-choices.js
```

---

## 7 · What macOS 27 does — measured

### Listing and screen

- `CGGetActiveDisplayList` + `CGDisplayBounds` + `NSScreen.localizedName` ask
  for no permission, so `list --mac` never prompts.
- `SCStream`: BGRA, ≤ 60 fps, queue depth 6. `SCStreamFrameInfo.status`:
  `.complete` carries a new picture, `.idle` repeats, `.blank` / `.suspended`
  carry none. A still screen may deliver no first complete picture at all.
- Sync over async: `Screen.start` is synchronous; the feed waits ≤ 5 s on
  `getExcludingDesktopWindows` and `startCapture`'s completion handlers. The
  async forms don't compile under Swift 6 (`SCShareableContent`, `SCStream`
  aren't `Sendable`).
- `didStopWithError` (sleep, display removed) ends a feed.
- Permission: `CGPreflightScreenCaptureAccess`; refused, asked once, then
  `ScreenRecordingRefused`. It belongs to the app that launched baguette —
  started from one without it, the server lists but can't watch.

### Input

- `CGEvent` at `.cghidEventTap`, global points (the main display's top-left at
  0,0). Untrusted for Accessibility, the window server drops events silently —
  so nothing is posted and the gesture answers false.
- `kVK_ANSI_*` codes follow the physical layout: the table is by hand.
- `CGEventKeyboardSetUnicodeString` carries ≤ 20 UTF-16 units an event.
  The wire is still US-ASCII (`TypeText.parse`), for every device.
- Scroll in pixels, deltas negated (a browser's +`deltaY` moves the view down;
  the window server's scrolls content up). A scroll goes to the window under the
  pointer; given a `location`, it goes there — and the pointer moves there
  (from (649, 1003) to the location).
- Costs: asking trust with the prompt 1.15 ms, without 0.001 ms; an event
  source 0.02 ms; a mouse event 0.17 ms. 200 moves 2 ms apart reach the pointer
  as the last is sent — the lag a viewer feels is the picture's round trip.

### Sharing

| Measured | So |
|---|---|
| `CGVirtualDisplay` (private; what DeskPad and BetterDisplay use) makes a display of any size; its mode is in **points** | `SharedScreenShape` asks for its points, `maxPixels` its pixels |
| it starts on the **1×** mode though offered a 2× one | the `virtual-display` process chooses the 2× mode by name (`SharedScreenShape.isMode`) |
| a process can choose the mode of only the **first** virtual display it makes; later ones are invisible to its own CoreGraphics | one `baguette virtual-display` process per display |
| a display takes its modes **once**; new settings and `rotation` change nothing, and a display set up twice isn't freed on release | turning makes a new display; each is set up once |
| a display goes within ½ s of its last reference — from an autorelease pool, or its process ending | removing ends its process and waits until it's unlisted |
| the UUID follows from vendor `0xBA6E`, product and serial | the same serial on a turn keeps the id; two viewers, two serials |
| once a process **changes the arrangement**, displays added later never appear in its own list (others see them in ½ s) | `baguette main-display` changes it; the server only reads |
| a just-made display reads as **main** for a moment | the previous main is read before the display is made |
| removing the **main** display takes seconds: macOS picks another and moves everything | main goes back before the old display does |
| a long-running process reads a just-made display **stale** (1×) — CoreGraphics, AppKit and ScreenCaptureKit alike | a display baguette made is captured at the pixels it made |
| a share at 660 × 1149 pt (an iPhone 17 Pro Max in Safari) vs 660 × 1434 from a Home Screen icon | the page asks for its visible area; a Home Screen launch has no bars |

### The pointer

- `NSCursor.currentSystem`: a long-running process reads it once and never
  again; one whose **run loop runs** follows it (over TextEdit: all 8
  crossings between text and title bar right — I-beam 23 × 22 at (12, 11),
  arrow 28 × 40 at (5, 5)).
- baguette's async entry point runs a command off the main thread, so
  `pointer-shapes` hands the main thread the run loop.
- Its TIFF holds up to 10× (280 × 400 for the arrow); a browser ignores a cursor
  image over 128 px a side, so it is drawn at 2× (56 × 80).

### Frames

Each opening was measured from its picture: scanning out from inside the screen
for the first opaque pixel, through the middle horizontally and at a quarter of
the width vertically (the middle runs into a MacBook's notch). Each matches its
panel within a pixel (MacBook Pro 14": 3022 × 1962 of 3024 × 1964). Centring
would be wrong — a MacBook's base, an iMac's chin and stand. Two pictures ship
in `scripts/mac-frames/` (~4.4 MB each); the rest are known by geometry only.

### End to end

A 2560 × 1440 display at 1×: H.264 ~60 fps, gaps p50 16.7 / p99 22 ms, 1.3 Mbit/s
with motion; a shared 603 × 1311 pt display the same at 0.5 Mbit/s. A tap,
typing, ⌘A + Delete reached TextEdit; a browser `deltaY` of +400 scrolled
~29 lines down. A main share: made 0.9 s, turned 1.7 s, ended 0.5 s, the
arrangement restored exactly.

---

## 8 · Open questions

- **Does a real iPhone's turn reach the server?** The emulated turn works; on an
  iPhone the display once stayed portrait. Each share now logs `started`,
  `reshaped`, `ended` — the next try says whether the `PUT` arrived.
- ~~**HEVC over WebRTC?**~~ Built: a share streams H.265 when the viewer's
  browser offers it (an iPhone's does). Measured, it costs nothing and is a
  little smoother on a slow link: [webrtc/hevc.md](../webrtc/hevc.md).
- **Sign-in.** Today anyone who reaches the port controls this Mac.
  ~~Built with OpenDirectory, sessions and a throttle~~ — dropped before it was
  wired: on a Tailscale-only bind, the tailnet is the gate. Back if the server
  is shared beyond one's own devices.
- **A locked Mac.** ScreenCaptureKit shows no lock screen and secure input drops
  synthetic keys — not measured; Screen Sharing (VNC) is the way to unlock.
- ~~**Can a background process read the pointer shape?**~~ Only with its run
  loop running — measured, built as `pointer-shapes`.
- ~~**Is the pointer lag a queue backlog?**~~ No — measured: moves keep up; it
  was the picture's round trip, removed by the local pointer.
- ~~**Why is a shared display soft?**~~ Captured at half its pixels from a stale
  1× reading; captured now at the pixels it was made with.

## 9 · Decided against

- **Guessing a frame** — a built-in panel's size names its MacBook, but no
  frame shows until picked, as for a phone.
- **Windows as devices** — window ids change across launches; later, with an
  id scheme of their own.
- **Listed by default** — a display shows and drives the Mac itself.
- **Mirror** (macOS's third "Use as") — macOS shrinks a mirrored desktop to fit,
  the opposite of a display the viewer's shape.
- **Pinch as magnify** — `CGEvent` has no public gesture events.
- **The pointer in the picture** — it trails the hand by the round trip.
- **Speaking VNC** — a VNC server can't make a display the viewer's shape; that
  needs code on the Mac, which baguette is.
