# Device twin — a physical iPhone in baguette

Status: **design / not implemented**.

A real, cable-free iPhone appears in baguette the way a simulator
does: listed beside simulators, its live screen mirrored into the
browser, its screen tappable from the browser, and the existing 3D
stage driven by the phone's own gyroscope — the USDZ model on the
monitor rotates in physical lockstep with the phone in your hand, live
screen texture-mapped onto the model's display.

The sentence that defines done: hold the phone, turn it — the twin
turns with it, screen playing on its face — then click the twin's
screen and the real phone responds.

## Three pipes, not one feature

Mirror + control + gyro twin decomposes into three one-way pipes
between phone and host, and iOS's security model prices each pipe
differently:

| Pipe | Direction | Door iOS provides | Cost |
|------|-----------|-------------------|------|
| Pixels out | phone → host | ReplayKit broadcast extension (on-device) | app install, user starts broadcast |
| Sensors out | phone → host | CoreMotion — public, but only from an on-device process | app install |
| Input in | host → phone | XCTest event synthesis — the only door that exists | signing, Developer Mode, runner lifecycle |

The pipes share nothing but a transport, so each lands independently
and any one can be cut without breaking the other two. That
severability is the load-bearing property: mirror + twin ships as a
view-only mode even if control slips a release.

## Decision record

**Wireless is a requirement**, which forces most of the choices:

- **Pixels: ReplayKit broadcast upload extension** — the only
  wireless system-wide capture door on iOS 26, today's floor. The gyro
  pipe already puts a companion app on the phone; the broadcast
  extension lives inside that same install, so the extension's usual
  cost — shipping an app — is already paid. System-wide capture,
  works over Wi-Fi, keeps capturing after the user switches apps.
- **CoreMediaIO screen capture (the QuickTime path) — rejected: USB
  only.** Otherwise the best pipe (no install, public API,
  ~100–200 ms); it remains the tethered fallback. Its undocumented
  wireless sibling flag
  (`kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices`) is worth
  an experiment, not a foundation.
- **ScreenCaptureKit — the iOS 27+ successor, not the shipping
  path.** On macOS it only captures Mac displays; on iOS it arrives in
  **iOS 27 (beta)**: `SCContentSharingPicker.present()` captures the
  entire display with user consent, and the `screen-capture`
  `UIBackgroundModes` entry keeps the `SCStream` delivering while the
  companion is backgrounded — in-process, no extension memory
  ceiling. When iOS 27 is baguette's floor, the companion swaps its
  capture source to `SCStream`; the wire protocol doesn't change
  (both paths yield `CMSampleBuffer`s into the same encoder).
- **AirPlay receiver on the Mac — rejected.** Its one advantage is
  zero install, which the gyro requirement already forfeits. What
  remains is a reverse-engineered FairPlay handshake that breaks
  across iOS releases.
- **Control: a minimal XCUITest runner.** On real hardware, no
  off-device process can synthesize HID; the only privileged process a
  developer can run is an XCUITest runner, whose (private)
  event-synthesis APIs tap system-wide — not a convenience choice,
  the only door. The runner speaks baguette's own gesture envelope
  directly.
- **Gyro: `CMDeviceMotion` in the companion app.** Public API, 60–100
  Hz attitude quaternions, four floats a sample. The pleasing
  inversion of `Injected/VirtualMotion`: the simulator must be *fed*
  attitude because CoreMotion is gated off there; the real device
  *reports* it, because on hardware CoreMotion is the one thing that
  just works.

## Architecture

A new bounded context, `Device/`, mirrored across `Domain/` and
`Infrastructure/` like every other context, plus a phone-side
sub-project beside `Injected/`:

```text
Sources/Baguette/
├── Domain/Device/            Device, Devices, Attitude, envelope parsing
├── Infrastructure/Device/    companion listener, H.264 ingest, runner client
└── App/                      devices CLI + /devices/:udid/… routes

Companion/DeviceTwin/         phone-side: app + broadcast extension + runner
```

```text
        iPhone (no cable)                                Mac host (baguette serve)
 ┌─────────────────────────────────┐        ┌─────────────────────────────────────┐
 │ Companion app                   │        │                                     │
 │  ├─ CMDeviceMotion 60–100 Hz ───┼──WS───►│ attitude ──► 3D stage model pose    │
 │  ├─ broadcast picker button     │        │                                     │
 │  └─ Broadcast upload extension  │        │                                     │
 │      capture → VideoToolbox ────┼──WS───►│ decode ──► Screen ──► MJPEG/AVCC,   │
 │      H.264, encode-and-forward  │        │            recording, 3D stage      │
 │                                 │        │                                     │
 │ Twin runner (XCUITest) ◄────────┼──HTTP──┼── GestureDispatcher ──► Input       │
 └─────────────────────────────────┘        └─────────────────────────────────────┘
```

Two structural rules:

1. **Motion and video ride separate sockets.** Video bursts and Wi-Fi
   jitter must never delay 16-byte pose samples. Degraded looks like
   "the twin stays buttery while the screen texture hiccups"; the two
   freezing together looks broken.
2. **One envelope dialect, two speakers.** The app (motion) and the
   extension (video) speak the same framing to the same listener, so
   the two phone-side processes share transport code.

### Everything downstream already exists

The feature is new sources and sinks behind existing roles, not a new
pipeline:

- The decoded mirror is another `Screen` — "a stream of surfaces".
  `MJPEGStream`, `AVCCStream`, recording, capture, and the 3D
  `RenderedScreen` decorator consume that role today and don't change.
- Control is another `Input` implementation behind the existing
  `GestureDispatcher`. The browser's gesture envelopes, the wire
  dialects in `GestureRegistry`, and the web UI don't change.
- The twin **is** the existing 3D stage. `RealityKitDeviceScene`
  already maps live frames onto the screen material, already pushes
  `screen_quad` after every camera change for pose-accurate click
  inversion, and already accepts live pose updates over the stream
  socket. The phone's attitude becomes a `set_3d_camera`-shaped update
  with a real gyroscope behind it instead of a mouse drag; model
  matching reuses `DeviceModels` definitions.

## Domain

New value types and abstractions in `Domain/Device/`, all named for
their role:

- `Device` — identity of a paired physical phone (udid, name, model).
- `Devices` — the aggregate, plural like `Simulators` and `Chromes`:
  known devices, which are connected, which have an active companion.
- `Attitude` — a quaternion value type owning the math that must be
  exact: shortest-path slerp (`q` and `-q` encode the same attitude
  and a sender may flip sign between samples; naive interpolation
  swings the model the long way round), re-zero calibration (the
  inverse of the current attitude becomes neutral, applied on the
  model pivot, never mutated into the sensor stream), and the single
  documented device-frame → model-frame transform. Quaternion order on
  the wire is **`[x, y, z, w]`, CoreMotion's own** — declared once,
  because ordering and handedness disagreements are the classic bug of
  this feature class (`VirtualMotionFactory.m` already paid for that
  lesson against a private `w,x,y,z` initialiser).
- Envelope parsing for the companion's frames — pure, like every
  parser in `Domain/`.

Conversational boundaries get one small `@Mockable` collaborator each,
domain nouns as always: `Companion` (the phone-side sender session —
attitude and video frames in, lifecycle out) and `Runner` (the
on-device XCUITest process — gestures in, health out). Orchestrators
depend on the nouns; tests drive `MockCompanion` / `MockRunner`
deterministically.

## Infrastructure

`Infrastructure/Device/` holds the irreducible I/O, split per the
adapter rules:

- The companion listener — accepts the two WebSockets, associates them
  with a `Device`. Socket accept/read/write is integration-only; frame
  parsing and session state live in Domain.
- H.264 ingest — VideoToolbox decode of the extension's stream into
  IOSurfaces published through `Screen`. Decode-session calls are
  integration-only; everything around them is unit-covered.
- The runner client — an `Input` implementation that serializes
  dispatched gestures to the runner's HTTP endpoint. Mapping from
  `Input` verbs to runner requests is unit-covered against
  `MockRunner`.

## Companion (phone-side)

`Companion/DeviceTwin/` parallels `Injected/VirtualMotion` as a
sub-project that ships to the device, with three targets:

- **App** — pairs with the host, streams
  `CMDeviceMotion.attitude.quaternion` (reference frame
  `.xArbitraryZVertical`; no compass dependency, slow yaw drift
  corrected by re-zero), and hosts an `RPSystemBroadcastPickerView`
  button so starting the mirror is one tap in our own UI.
- **Broadcast upload extension** — `RPBroadcastSampleHandler` under
  the ~50 MB extension memory ceiling, which dictates all three of its
  rules: encode immediately (hardware H.264), forward each
  `CMSampleBuffer`'s orientation attachment in the envelope so the
  host never guesses rotation, and on backpressure replace the pending
  frame rather than queue — the mirror is a live view, not a
  recording.
- **Twin runner** — the XCUITest target. Launched over wireless
  development pairing; serves the gesture endpoint; synthesizes
  system-wide events through XCTest.

## Route surface

Same resource-tree conventions as everywhere else — no `/api/` prefix,
UDID in the path, format by extension — under a sibling root:

```text
GET  /devices                          list paired physical devices
WS   /devices/:udid/stream.mjpeg       mirror stream (browser)
WS   /devices/:udid/stream.avcc        mirror stream, H.264 passthrough
WS   /devices/:udid/stream.3d.<fmt>    the twin: 3D stage + live attitude
```

The stream sockets are bidirectional exactly like the simulator's:
encoded frames server→browser, JSON envelopes browser→server for
gestures and stream control. On the `.3d` socket the server pushes the
same `screen_quad` messages the simulator's 3D stream pushes, now
after every attitude update, so interact-mode clicks stay pose-accurate
while the phone moves.

Attitude rides the companion's motion socket phone→host as:

```json
{"type":"attitude","q":[0.012,-0.221,0.003,0.975],"t":163412.041}
```

The video socket carries one JSON `format` frame (dimensions,
orientation, codec) then binary AVCC — the shape baguette's stream
envelopes already speak, so `.avcc` mirroring can pass encoded frames
through without re-encoding.

## Testing approach

Standard for the codebase — TDD, Chicago-school, ~100% of Domain:

- `Attitude` (slerp, sign-flip continuity, re-zero, the frame
  transform) and every envelope parser are pure value types: feed
  samples, assert values.
- `Devices` aggregate semantics via `MockCompanion`-backed state.
- The ingest and control orchestrators are unit-tested against
  `MockCompanion` / `MockRunner`; only the irreducible socket,
  VideoToolbox, and HTTP call sites stay integration-only.
- The companion app and runner are phone-side and integration-only,
  like `Injected/VirtualMotion` — the host-side contract they speak is
  what the unit suite pins.

## Rollout

Each phase is independently shippable, matching pipe severability:

1. **Mirror** — `Devices`, the companion listener, H.264 ingest behind
   `Screen`, `/devices/:udid/stream.*`. View-only; no runner, no
   signing burden on users beyond installing the companion.
2. **Twin** — attitude on the motion socket driving the existing 3D
   stage; re-zero in the browser UI.
3. **Control** — the runner target, `Input` implementation, gestures
   live on both 2D and 3D sockets.

## Known limits

- **Broadcast lifecycle is user-held.** The host cannot start or
  restart the broadcast. The UI must say "mirror stopped — restart on
  the phone" rather than showing a frozen frame. iOS shows the red
  recording indicator throughout; both are facts, not bugs.
- **Glass-to-glass mirror latency** is capture → encode → Wi-Fi →
  decode → texture → render ≈ 150–300 ms. Fine for a mirror; control
  feedback must not wait on the video path — taps go direct to the
  runner.
- **Runner fragility** — signing, certificate expiry (weekly on a free
  team), death on reboot, ~50–150 ms per gesture, streamed drags
  clunkier than discrete gestures. All quarantined in the one
  severable pipe.
- **The extension memory ceiling** (~50 MB) bounds capture quality at
  ProMotion rates; downscale-before-encode is the release valve.
- **Yaw drifts** on the compass-free reference frame — measured in
  minutes, corrected by re-zero; move to
  `.xArbitraryCorrectedZVertical` only if drift proves annoying in
  practice.
- **DRM'd content blanks** in ReplayKit captures; nothing to do about
  it.
- The farm view is out of scope for physical devices initially, as it
  is for the simulator 3D stage.
