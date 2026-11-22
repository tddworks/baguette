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
  the view down, the window server's scrolls content up.
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
- **Pinch as magnify** — `CGEvent` has no public gesture events; two-finger
  gestures answer false.
