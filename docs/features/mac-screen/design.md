# Mac screen — design

A Mac display is one more device family (`Sources/Devices/Mac/`). It adds no
role and no format: it plays `Screen`, `Touch`, `Scroll`, `Key` and `Typing`,
and every consumer of those works unchanged.

```
MacDisplays (Devices) ── HostDisplayList (CoreGraphics; no permission)
└── MacDisplay (Device, .macOS / .physical)
    ├── .screen  → MacScreen ── any DisplayFeed ── ScreenCaptureKitFeed (System/)
    └── .touch · .scroll · .key · .typing
                 → MacInput ── DisplayEvents ◇ ── any HostEvents ── CGEventHostEvents (System/)
```

## Listing

`CGGetActiveDisplayList` + `CGDisplayBounds` + `CGDisplayCopyDisplayMode`
(pixels per point) + `NSScreen.localizedName`. None of it asks for Screen
Recording, so `list --mac` never prompts. A display is named by
`CGDisplayCreateUUIDFromDisplayID`: the `CGDirectDisplayID` changes across
reboots and reconnects, the UUID doesn't.

## Screen

`SCStream` over `SCContentFilter(display:excludingWindows: [])`, BGRA, up to
60 fps, the cursor shown, queue depth 6. Each sample buffer's
`SCStreamFrameInfo.status` decides: only `.complete` is handed on — `.idle`
repeats the last picture and `.blank` / `.suspended` carry none. The surface
is the pixel buffer's `IOSurface`, as a simulator's framebuffer is.

- **Size.** `DisplayCaptureSize`: pixels, scaled so the long side is at most
  4096 (VideoToolbox's hardware H.264 refuses larger), both sides even.
  ScreenCaptureKit scales at the source — cheaper than `VideoFrameScaler`.
- **Sync over async.** `Screen.start` is synchronous; the feed waits at most
  5 s on `getExcludingDesktopWindows` and `startCapture`'s completion handlers.
  The async forms don't compile under Swift 6: `SCShareableContent` and
  `SCStream` aren't `Sendable`.
- **Ending.** `didStopWithError` (sleep, display removed) ends the feed;
  `MacScreen` starts it again a second later while started, as
  `EmulatorScreen` does.
- **Permission.** `CGPreflightScreenCaptureAccess` first; refused, it asks once
  (`CGRequestScreenCaptureAccess`) and throws `ScreenRecordingRefused`.

## Input

`DisplayEvents` turns each gesture into `[HostEvent]` values — global points,
key codes, pauses — so every decision is a value test. `CGEventHostEvents`
posts them at `.cghidEventTap` and sleeps on each pause.

- **Placement.** A point at `x / width` of the display lands at that fraction
  of `CGDisplayBounds`: global points, the main display's top-left at 0,0.
- **Keys.** `MacKeyCode`: HID page 7 → `kVK_ANSI_*`. The ANSI codes follow the
  physical layout, so the table is by hand. Modifiers go down in
  `KeyModifier.allCases` order and up in reverse, each event flagged with what
  is held.
- **Typing.** `CGEventKeyboardSetUnicodeString`, in pieces of at most 20
  UTF-16 units (what one event carries), never splitting a character. The
  role would type any script, but `TypeText.parse` still holds the wire to
  US-ASCII for every device; lifting that for the Mac is a change to that law,
  not to this family.
- **Scroll.** Pixel units, deltas negated: a browser's positive `deltaY` moves
  the view down, the window server's scrolls content up. A scroll event has no
  target of its own: the window server gives it to the window under the
  pointer. A two-finger move (`touch2-*`, a pan path — what the page turns the
  wheel into) scrolls by its midpoint's travel and carries the midpoint as the
  event's `location`, which routes it there and moves the pointer there, as a
  click does. Measured: posted with a location at `.cghidEventTap`, the
  pointer jumped from (649, 1003) to the location. A wire `scroll` has no
  point and lands under the pointer.
- **Trust.** `AXIsProcessTrustedWithOptions` with the prompt; untrusted, the
  window server would drop the events silently, so nothing is posted and the
  gesture answers false. The prompt key is spelled out because Swift 6 won't
  read the `kAXTrustedCheckOptionPrompt` global.

## Frames

`MacFrame` (`Sources/Device/Chrome/`) is a picture's size and its screen's
opening, measured once from each frame's picture: scanning out from inside the
screen for the first opaque pixel, horizontally through the middle and
vertically at a quarter of the width — the middle column runs into a
MacBook's notch. Each opening matches its panel within a pixel of
anti-aliasing (MacBook Pro 14" measures 3022 × 1962 of 3024 × 1964).
Centring the screen in the picture would be wrong for a MacBook (the base
below) and an iMac (chin and stand), so each opening is measured, not computed.

`MacFrames` is a `Chromes` that answers a measured name with the picture from
the frames folder; `CombinedChromes` asks DeviceKit first, then it, then — with
`--share-mac` — `MacDisplayLooks`, each display's own look: a clear PNG its
size in points, the screen filling it. So with no pick the page draws the
stream alone at the display's shape through the same bezel path, and a pick
rides `?chrome=` exactly as a phone's borrowed DeviceKit chrome does. Two
pictures ship in `scripts/mac-frames/` (MacBook Pro 14-inch (M4), iMac
27-inch; ~4.4 MB each) and `scripts/install-mac-frames.sh` copies them into the
folder; the rest of the measured frames are known by geometry only.

## Sharing to a viewer's shape

A share is a virtual display made to the viewer's screen (`SharedScreenShape`:
its points × the room, drawn at 2×, the long side ≤ 4096 px), streamed as any
Mac display. What macOS 27 does, measured, and what it made us build:

| Measured | So |
|---|---|
| A process can choose the mode of only the **first** virtual display it makes; later ones are invisible to its own CoreGraphics | each display lives in a `baguette virtual-display` process of its own (`ChildVirtualDisplays`); ending the share ends the process, and the display goes within ½ s |
| A display starts on its **1×** mode though offered a 2× one | the process chooses the 2× mode by name (`SharedScreenShape.isMode`) |
| A display takes its modes **once**; neither new settings nor `rotation` change it | turning makes it again in the new shape, under the same serial, so its UUID — its device id — holds |
| Once a process **changes the arrangement**, displays added later never appear in its own list | `baguette main-display` makes a display main; the server only reads |
| Removing the **main** display is slow: macOS picks another and moves everything first | a turned main display hands main back before it goes |
| A long-running process reads a just-made display **stale** (1×) — CoreGraphics, AppKit and ScreenCaptureKit alike | a display baguette made is captured at the pixels it made it with (`MacScreen.madePixels`) |
| The UUID follows from vendor `0xBA6E`, product and serial | two viewers get two serials |

## The pointer

What makes a native remote desktop feel instant, and what baguette took from
Apple's Screen Sharing (as an open client reads its protocol): the pointer is
not in the picture — the viewer draws it at once — and pointer moves are
latest-wins. `showsCursor` is off for Mac displays and the page draws the arrow
(`local-pointer.js`); a stream socket posts a move rather than awaiting it, and
`PendingGestures` replaces a waiting move with a newer one (clicks, keys and
scrolls keep their order). Measured: 200 moves 2 ms apart reach the Mac's
pointer as the last is sent, before and after — the lag you feel is the picture's
round trip, which the local pointer takes out.

The pointer's shape comes from `NSCursor.currentSystem` — but a long-running
process reads it once and never again, and one whose run loop runs follows it
(measured over TextEdit: all 8 crossings between text and title bar read
right). So `baguette pointer-shapes` — its main thread running the run loop,
since baguette's async entry point runs a command elsewhere — reads it 20 times
a second and says each change (`PointerShape`); `PointerShapes` runs it while
anyone watches and keeps each image by id. The image is drawn at 2×: its TIFF
holds up to 10×, and a browser ignores a cursor over 128 px a side. A page
hears shapes on `WS /mac/pointer` and fetches each image once from
`/mac/pointer/<id>.png`.

## Measured

On a 2560 × 1440 display at 1× (an external Dell beside a portrait one, so at
global x 1440, y 595): MJPEG ~55 frames / 4 s over the stream socket, AVCC
streaming without encoder errors at 1440 × 2560; a tap landed in a TextEdit
window; `type`, a held key and ⌘A + Delete reached it; a browser `deltaY` of
+400 scrolled ~29 lines down — the negation is right.

## Decided against

- **Guessing a frame** — a built-in panel's size names its MacBook, but no
  frame is shown until picked, as for a phone.
- **Windows as devices** — window ids change across launches; later, with an
  id scheme of their own.
- **Listed by default** — a display shows and drives the Mac itself; it's
  reached only through `serve --share-mac`, `list --mac` or its UUID.
- **Pinch as magnify** — `CGEvent` has no public gesture events; a pinch
  (fingers spreading about a still midpoint) scrolls nothing.
