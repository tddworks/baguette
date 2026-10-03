---
description: How the virtual camera works — a Mac-side frame producer writing a shared mmap buffer, the VirtualCamera.dylib hooks and capture-graph mock, dylib install and DYLD_INSERT_LIBRARIES sharing, and iOS 26 dylib gotchas. Read before touching the camera.
---

# Camera — design

Two halves cooperate:

- **Mac side** (Swift): a `CameraSession` orchestrator
  driven from the browser's camera panel. It selects one of three
  frame producers by `CameraSource` — `AVCameraCapture` (webcam, off
  an `AVCaptureSession`), `ImageFileCapture` (a decoded still re-emitted
  at ~30 fps), or `VideoFileCapture` (an `AVAssetReader` looped) — and
  writes their BGRA frames into a fixed-size mmap'd file
  (`/tmp/SimCam.bgra`). File sources are downscaled to fit the canvas
  via the pure `ScaleToFit`.
- **iOS-Simulator side** (`Injected/VirtualCamera/`, vendored from
  `asc-pro/SimCam`): a small ObjC dylib that hooks AVFoundation /
  UIImagePickerController inside every simulator-launched app and
  substitutes the shared-buffer frame for the (non-existent)
  hardware camera. Loaded via `DYLD_INSERT_LIBRARIES`.

The browser is the picker; baguette is the producer; the dylib is the
consumer — and the dylib is **source-agnostic**: image and video
frames are indistinguishable from webcam frames at the shared-buffer
boundary, so adding file sources needed no dylib change. A new source
is a new `CameraCapture` selected by `CameraSource`; the frame sink,
the injection and the dylib stay the same.

## Path

```
   Browser              Server (baguette)                         iOS Simulator
┌────────────┐  WS    ┌────────────────────────┐               ┌──────────────────┐
│ sim-camera │◀─────▶│ /simulators/:udid/camera │               │ AVCaptureVideo   │
│ .js (card) │  JSON  │  CameraSession (state) │               │ PreviewLayer .   │
└────────────┘        │   ├─ AVCameraCapture   │               │  setSession:     │
                      │   │   (BGRAConverter)  │               │  hook  ▲         │
                      │   ├─ SharedMemoryFrame │               │        │         │
                      │   │   Sink (mmap)     ─┼───────────────┼──▶ /tmp/SimCam   │
                      │   │                    │  24-byte hdr  │   .bgra (read)   │
                      │   └─ SimctlSimulator   │  + BGRA       │        │         │
                      │       Injection ──────▶│  launchctl    │  VirtualCamera   │
                      └────────────────────────┘  setenv       │    .dylib        │
                                                  DYLD_INSERT  │  (DisplayLink)   │
                                                  _LIBRARIES   └──────────────────┘
```

## The shared frame buffer

- A 24-byte little-endian header + tightly packed BGRA pixels, canvas
  capped at 1280×1280. The Mac side rewrites header + pixels and
  `msync(MS_SYNC)`s on every frame.
- Webcam frames arrive with row padding, which is stripped before the
  write.
- Fit/fill and mirror travel as a packed `UInt32` matching the dylib's
  `kSimCamFlag*` bit layout.
- The dylib's reader gates on an advancing sequence and shows "No camera
  signal" once stale (~1 s), which is why a still image is re-written
  under a fresh sequence on a ~30 fps timer.

## The dylib's hooks

Internal symbols retain the SimCam prefix to keep upstream re-syncs
diff-friendly; see `Injected/VirtualCamera/VENDORED_FROM.md`. The dylib:

- Hooks `-[AVCaptureVideoPreviewLayer setSession:]` and attaches a
  `CADisplayLink` driver that pushes the latest BGRA frame from
  `/tmp/SimCam.bgra` into the layer's `contents`.
- Hooks `-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]`
  and synthesises a delegate sequence from the latest shared frame
  (still capture works without a real camera).
- Hooks `+[UIImagePickerController isSourceTypeAvailable:]` to
  report `.camera` as available; walks the picker's view tree on
  `viewDidAppear:` and intercepts the disabled-shutter delegate so
  the simulator's picker actually delivers a photo on tap.

## Virtual camera device (camera-less simulators)

The preview-layer painting above shows frames only in apps that already
got a working `AVCaptureSession` — which needs a real `AVCaptureDevice`.
A simulator on a Mac **without a camera** has none, so `AVCaptureDevice`
discovery returns nil and real camera apps (expo-camera, VisionCamera,
straight AVFoundation) never start — they show a permission/loading
state, and there's nothing for the preview hook to paint.

`SimCamVirtualCamera.m` fixes that by **mocking the entire capture graph**
at the public AVFoundation boundary (the approach
[swmansion/SimCam](https://simcam.swmansion.com/) uses; baguette feeds
from the shared buffer instead of a socket). It's app-free — the app
sees a normal camera:

- `+[AVCaptureDevice defaultDeviceWithMediaType:]` and
  `-[AVCaptureDeviceDiscoverySession devices]` → a fabricated
  `AVCaptureDevice` subclass.
- `-[AVCaptureDeviceInput initWithDevice:error:]` → a **dummy input**
  for the fake device, so the real initializer (which dereferences the
  device format's private `FigCaptureSource`) never runs.
- `-[AVCaptureSession canAddInput:/addInput:/canAddOutput:/addOutput:]`
  → accept the dummy graph without wiring real hardware.
- `-[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]` → capture
  the delegate; a 30 fps timer builds `CVPixelBuffer` → `CMSampleBuffer`
  from `/tmp/SimCam.bgra` and calls
  `captureOutput:didOutputSampleBuffer:fromConnection:` directly.
- The fake `AVCaptureDeviceFormat` shims the private accessors
  AVFoundation reads during setup (`figCaptureSourceVideoFormat` → NULL,
  `videoSupportedFrameRateRanges` → `@[]`) plus
  `+[AVCapturePhotoSettings photoSettings]`, so `AVCapturePhotoOutput`
  init doesn't crash on the fabricated format.

With this, an unmodified app gets a device, `AVCaptureSession` "runs",
`onCameraReady`-style callbacks fire, and the preview + data-output show
baguette's image/video — no app edits.

**Injection is automatic (all apps), and armed only while streaming.**
`camera_start` arms the sim's launchd domain
(`SimctlSimulatorInjection`: `launchctl setenv DYLD_INSERT_LIBRARIES`),
so **every app launched afterward** loads the dylib — SimCam-style, no
per-app configuration. `stop` (and the WS `defer`) **disarms**, so the
dylib does *not* stay injected into every future launch until reboot (the
bug SimCam is known for). `CameraSession` owns this: it records the armed
simulator **and dylib path** on `start`, and removes that entry on
`stop` / failed-start.

## Sharing `DYLD_INSERT_LIBRARIES`

That variable is a single string for the simulator's whole launchd
domain, and baguette has more than one feature that injects into apps
(the virtual camera, and motion). So arming never writes a bare path:
it reads the current value, adds or removes **its own** entry, and writes
the join back. `InjectedDylibs` is the pure value that does the merge.

The `launchctl` that reads the value also loads the injected dylibs. On an
iOS 26 simulator its stdout carries the environment value while the camera
constructor writes its hook diagnostics to stderr; combining the two streams
drops the first library during parsing. The injection adapter therefore
captures them separately, waits for process exit and both EOFs, and parses
only stdout. Only an exit status of 1 with both streams empty means the
variable is unset; any other read failure aborts the update instead of
writing a guessed value back. Capture and the simulator lock run off the
main actor so a slow query does not freeze camera controls.

Three consequences worth knowing:

- Starting the camera while motion is armed keeps both loaded; stopping
  either leaves the other alone.
- Entries are matched by **dylib filename**, not full path — every
  release installs under a fresh sha-keyed directory (see
  [Per-hash install dir](#ios-26-gotchas-worth-preserving)), so the same
  dylib legitimately arrives under a new path, and two copies of one
  dylib in dyld's list is a load error rather than a merge.
- A dylib you armed by hand is preserved, not clobbered. The last
  baguette entry leaving takes the whole variable with it (`unsetenv`)
  rather than setting an empty string, which dyld reports as a library it
  failed to load.


## Dylib installation flow

1. `build.sh` runs `Injected/build.sh` first, which loops over every
   `Injected/*/build.sh` — here `Injected/VirtualCamera/build.sh` → produces
   `Injected/VirtualCamera/VirtualCamera.dylib` (fat: arm64 + x86_64,
   linker-signed adhoc, install-name `@rpath/VirtualCamera.dylib`).
   `BAGUETTE_INJECTED_ARCHS` narrows the slices for packagers that reject a
   universal binary; Homebrew sets it to the host arch alone.
2. The same loop copies the artifact into
   `Sources/Baguette/Resources/VirtualCamera/VirtualCamera.dylib` so
   SPM bundles it as a `.copy` resource, and fails the build if the dylib
   exports no symbols — `clang` exits 0 on an empty source list, and the
   symbol-less stub that produces once shipped in Homebrew for months.
3. First time `camera_start` lands on the WS,
   `VirtualCameraInstaller.installIfNeeded()` reads the bundled
   bytes, computes `sha256(bytes).prefix(12)`, and copies into
   `~/Library/Application Support/Baguette/builds/<sha12>/VirtualCamera.dylib`.
   Idempotent — if the file already exists at that path we trust
   its contents (the path itself is sha-keyed).
4. `SimctlSimulatorInjection.arm(...)` reads the simulator's current
   `DYLD_INSERT_LIBRARIES` (`launchctl getenv`), adds this dylib to it,
   and writes the join back (`launchctl setenv`). The env var survives
   until the simulator reboots; apps launched after the arming load the
   dylib via dyld.
5. Frames pump through `/tmp/SimCam.bgra`; the dylib's display-link
   driver picks them up on the next tick.

## iOS-26 gotchas worth preserving

- **Per-hash install dir.** iOS 26's simulator dyld page-hash cache
  rejects a *replaced* dylib at the same path with
  `code:codesigning(3) invalid-page(2)`. Every release ships a
  different sha and lands at a different path, dodging the cache.
- **Linker adhoc sign only.** The `clang -Wl,-adhoc_codesign`
  flag in `Injected/VirtualCamera/build.sh` sets the `linker-signed` flag the
  simulator's dyld accepts. A post-build `codesign --force --sign -`
  strips that flag and the dylib stops loading.
- **`setSourceType: .camera` throws without the hook.** Without
  swizzling `+isSourceTypeAvailable:`,
  `UIImagePickerController().sourceType = .camera` raises
  `NSInvalidArgumentException('Source type 1 not available')` in the
  simulator. The hook lies and returns `YES` for `.camera`.
- **Apps launched *before* arming don't load the dylib.** dyld
  honours `DYLD_INSERT_LIBRARIES` only at exec time. After arming, a
  fresh launch (or terminate + relaunch) picks the dylib up.
  Baguette doesn't reopen apps for the user; the camera card surfaces
  this when the captured frame doesn't appear in the live preview.


## Known limits

- **One camera at a time per host.** All simulators write
  `/tmp/SimCam.bgra`; to scope per-sim we'd patch the dylib to accept a
  path override.
- **No CLI yet.** `baguette camera --udid … --device <UID>` would
  be a thin layer over the same WS handler; the wire path is
  already there for agents that need it.
- **No "apps needing reopen" diagnostic.** SimCamMac surfaces a list
  of running apps that started before the dylib was armed. Baguette
  defers that to a v2; users who don't see frames should
  terminate-and-relaunch the iOS app.
- **Mac-only producer.** A future browser `getUserMedia` source
  (sketched in the design phase) would let the page's webcam feed
  the iOS app without going through AVFoundation on the host.
- **Virtual-camera format shims are AVFoundation-version-specific.**
  The graph mock neutralises the specific private `AVCaptureDeviceFormat`
  accessors AVFoundation reads on iOS 26 during capture setup
  (`figCaptureSourceVideoFormat`, `videoSupportedFrameRateRanges`). A
  future iOS may read a different accessor and crash the target app
  until that one is shimmed too — the trade-off of mocking private
  internals. Verified on iOS 26 with expo-camera 57.
- **No metadata/barcode delivery.** Feeding
  `AVCaptureMetadataOutput` (e.g. Vision QR detection over the frames)
  is a follow-up.
