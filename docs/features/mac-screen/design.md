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
  UTF-16 units (what one event carries), never splitting a character — so,
  unlike a simulator's `type`, any script works.
- **Scroll.** Pixel units, deltas negated: a browser's positive `deltaY` moves
  the view down, the window server's scrolls content up.
- **Trust.** `AXIsProcessTrustedWithOptions` with the prompt; untrusted, the
  window server would drop the events silently, so nothing is posted and the
  gesture answers false. The prompt key is spelled out because Swift 6 won't
  read the `kAXTrustedCheckOptionPrompt` global.

## Decided against

- **Windows as devices** — window ids change across launches; later, with an
  id scheme of their own.
- **Listed by default** — a display shows and drives the Mac itself; it's
  reached only through `serve --share-mac`, `list --mac` or its UUID.
- **Pinch as magnify** — `CGEvent` has no public gesture events; two-finger
  gestures answer false.
