# Device twin — a physical iPhone in baguette

Status: **in progress**. The mirror pipeline is implemented, verified
end-to-end against real hardware, and integrated into the web UI: the
unified page at `/devices/:udid` (same `sim.html`, reduced surface),
the DEVICES list section, and the 3D twin stage with hardware-id model
matching plus a user-pick fallback. The companion app + broadcast
extension live under `Companion/DeviceTwin/` (Tuist) and stream from a
real iPhone. The gyro twin is live: attitude flows from the broadcast
extension over the motion socket into `TwinPoses`, and
`TwinGyroState` drives the 3D stage's pose the way PhoneTwin proved
out: the QUATERNION goes straight to the entity (never decomposed to
euler — the axis order wouldn't match the scene's), the displayed pose
slerps toward the latest target (0.35 per apply at 30/s) so motion is
butter rather than steps, auto-zero on connect, quad re-pushes for
Interact accuracy, browser Re-zero chip. Not started: the control pipe (Twin runner).

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
- **Gyro: `CMDeviceMotion` in the broadcast extension** — not the
  app, which suspends when backgrounded; the extension lives exactly
  as long as the mirror, so attitude flows whenever the twin is on
  screen. Public API, 60–100 Hz attitude quaternions, four floats a
  sample. The pleasing
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
 │ Companion app (pairing UI)      │        │                                     │
 │ Broadcast upload extension      │        │                                     │
 │  ├─ CMDeviceMotion 60 Hz ───────┼──WS───►│ attitude ─► TwinPoses ─► 3D pose    │
 │  └─ capture → VideoToolbox ─────┼──WS───►│ decode ──► Screen ──► MJPEG/AVCC,   │
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
2. **One envelope dialect, two sockets, one speaker.** Both sockets
   speak the same framing from the extension, sharing the `TwinWire`
   transport code.

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
  model pivot, never mutated into the sensor stream), and
  `rotate(_:)` — the one transform both the RealityKit entity and the
  screen-quad projection go through, so the rendered pose and Interact
  clicks can never disagree. Attitudes are NEVER decomposed into euler
  angles for display. Quaternion order on
  the wire is **`[x, y, z, w]`, CoreMotion's own** — declared once,
  because ordering and handedness disagreements are the classic bug of
  this feature class (`VirtualMotionFactory.m` already paid for that
  lesson against a private `w,x,y,z` initialiser).
- `TwinEnvelope` — the three text frames a companion sends
  (`hello` / `attitude` / `format`), parsed with the same `Field`
  extractors every gesture parser uses. Malformed lines throw; a
  silent drop would leave the twin frozen with no explanation.
- `TwinSession` — the ordered conversation one companion socket
  holds: hello first, attitude only after hello, binary video only
  after a `format` declaration. A **pure state machine** fed
  text/binary and returning typed events — deliberately *not* a
  `@Mockable` collaborator, because the WebSocket it rides is already
  owned by `Server`; this is the one-shot-factory pattern, covered
  directly.

Exactly one conversational `@Mockable` collaborator exists, on the
video path: `H264Decoder` — configure from the stream's avcC
description, feed encoded chunks, receive decoded IOSurfaces. `Runner`
(the on-device XCUITest process — gestures in, health out) joins it in
the control phase. Orchestrators depend on the nouns; tests drive
`MockH264Decoder` / `MockRunner` deterministically.

## Infrastructure

`Infrastructure/Device/` holds the irreducible I/O, split per the
adapter rules:

- `LiveDevices` — the in-memory `Devices` implementation, membership
  driven by companion sessions registering and unregistering.
- The companion listener — accepts the two WebSockets, feeds
  `TwinSession`, forwards its events. Socket accept/read/write is
  integration-only; every protocol decision lives in the Domain state
  machine.
- `TwinScreen` — the ingest hub, one per connected device: feeds
  chunks to `any H264Decoder` (description → configure, key/delta →
  decode) and fans decoded surfaces out through `view() -> any Screen`,
  one view per stream socket — decode once, no matter how many tabs
  watch. Everything downstream binds through the existing
  `Stream.start(on: any Screen)`, so `MJPEGStream`, `AVCCStream`,
  recording, and the 3D `RenderedScreen` decorator consume the mirror
  with no changes. The orchestration is unit-covered via
  `MockH264Decoder`; `VTH264Decoder` (the irreducible
  `VTDecompressionSession` calls) is the only integration-only file.
- The runner client — an `Input` implementation that serializes
  dispatched gestures to the runner's HTTP endpoint. Mapping from
  `Input` verbs to runner requests is unit-covered against
  `MockRunner`.

## Companion (phone-side)

`Companion/DeviceTwin/` parallels `Injected/VirtualMotion` as a
sub-project that ships to the device. It is a **Tuist** project —
`tuist generate` in that directory produces the workspace, signing is
left to Xcode's automatic management (pick a team once under Signing &
Capabilities), and generated artifacts are git-ignored. Targets:

- **`TwinWire`** (static framework, shared) — the envelope framing
  (`hello` / `format` JSON lines, `[length][tag][payload]` chunks,
  byte-identical to the host's `TwinEnvelope` / `AVCCEnvelope`) and
  `TwinTransport`, the WebSocket with the latest-frame-drop send path.
  Static so the extension pays no dylib cost against its memory
  ceiling.
- **`DeviceTwinCompanion`** (app) — pairing only: the Mac's
  `host:port` saved into the shared App Group
  (`group.com.tddworks.baguette.twin`) where the extension reads it,
  plus the `RPSystemBroadcastPickerView` pinned to our extension. The
  device id is `identifierForVendor` (a real UDID is not readable
  from app code).
- **`DeviceTwinBroadcast`** (broadcast upload extension) —
  `SampleHandler` connects to `/devices/:udid/companion/video`, sends the
  hello, and hands video buffers to `H264Sender`:
  `VTCompressionSession` (realtime, 4 Mbit/s, keyframe every 60
  frames, 30 fps throttle), avcC extracted from the first sample's
  format description into a description chunk, then key/delta chunks
  whose payloads are already AVCC length-prefixed. Orientation comes
  from `RPVideoSampleOrientationKey` per buffer.

- **`MotionSender`** (in the broadcast extension, deliberately not
  the app: the app suspends when backgrounded, the extension lives
  exactly as long as the mirror) — `CMDeviceMotion` at 60 Hz,
  reference frame `.xArbitraryZVertical`, on its own socket per the
  separate-sockets rule.

Still to come in the sub-project:

- **Twin runner** (control phase) — the XCUITest target. Launched over
  wireless development pairing; serves the gesture endpoint;
  synthesizes system-wide events through XCTest.

## Route surface

Same resource-tree conventions as everywhere else — no `/api/` prefix,
**UDID always in the path** (the companion sockets included: the path
is the address, the hello is the introduction, and a hello claiming a
different udid is rejected loudly) — under a sibling root. Format
rides `?format=` exactly as it does on `/simulators/:udid/stream`:

```text
GET  /devices.json                     connected companions        (implemented)
GET  /devices/:udid                    the unified page (sim.html) (implemented)
GET  /devices/:udid/3d-model.json      matched model, or choices   (implemented)
GET  /devices/:udid/definition.json    SDK bootstrap, ?chrome=name (implemented)
GET  /devices/:udid/chrome/:name/…     borrowed bezel + button PNGs (implemented)
WS   /devices/:udid/companion/video    that device's video ingest  (implemented)
WS   /devices/:udid/companion/motion   its attitude ingest         (implemented)
WS   /devices/:udid/stream?format=     mirror stream, mjpeg|avcc   (implemented)
WS   /devices/:udid/stream.3d.<fmt>    3D twin stage, mjpeg|avcc   (implemented)
```

The web UI is the **same page** as `/simulators/:udid` — `target.js`
is the one seam that knows the base path, `stream-session.js` builds
its socket URL through it, and `sim-native.js` reduces the surface in
device mode (control / simulate / inspect clusters hidden, a
"DEVICE · view-only" badge beside the runtime, no boot or orientation
calls). The list page shows connected companions in a DEVICES section
between RUNNING and AVAILABLE.

**The 2D page's bezel is borrowed, the same way**: real hardware has
no DeviceKit chrome bundle on the Mac, so the SDK bootstrap
(`definition.json`) requires `?chrome=<device name>` — the page offers
a picker (simulator device names plus an evergreen set), the pick is
stored per device, and the bezel/button image URLs carry the chosen
name in their path so those routes stay stateless.

**3D model resolution for physical hardware**: definitions gain a
third match key, `"deviceModels": ["iPhone14,3"]` (`utsname.machine`
identifiers; the companion sends its own in the hello). When nothing
matches, baguette does not substitute a look-alike — the
`3d-model.json` route answers with the installed models as choices,
the browser renders a picker, and the pick rides `?model=<id>` on the
3D socket (remembered per device in `localStorage`). The bundled
definitions declare no hardware ids yet — guessed mappings would be
worse than none.

The stream socket is bidirectional exactly like the simulator's:
encoded frames server→browser, JSON control lines browser→server
(`set_fps` / `set_scale` / `set_bitrate` / `force_idr` / `snapshot`).
Gestures on a device stream are rejected with
`{"ok":false,"error":"device control is not wired yet"}` — loud, not
dropped — until the Twin runner lands. On the `.3d` socket the server
will push the same `screen_quad` messages the simulator's 3D stream
pushes, after every attitude update, so interact-mode clicks stay
pose-accurate while the phone moves.

Attitude rides the companion's motion socket phone→host as:

```json
{"type":"attitude","q":[0.012,-0.221,0.003,0.975],"t":163412.041}
```

The video socket carries one JSON `format` frame (dimensions,
orientation, codec) then binary AVCC — the shape baguette's stream
envelopes already speak, so `.avcc` mirroring can pass encoded frames
through without re-encoding.

## Implemented so far

The host-side mirror pipeline, all TDD-first
(`Tests/BaguetteTests/Device/`):

| Piece | File | What it owns |
|-------|------|--------------|
| `Attitude` | `Domain/Device/Attitude.swift` | wire parse, shortest-path slerp, re-zero |
| `TwinEnvelope` | `Domain/Device/TwinEnvelope.swift` | hello / attitude / format parsing |
| `TwinSession` | `Domain/Device/TwinSession.swift` | socket conversation ordering, pure state machine |
| `AVCCParameterSets` | `Domain/Device/AVCCParameterSets.swift` | avcC blob → SPS/PPS byte parser |
| `Device`, `Devices` | `Domain/Device/Device.swift` | the aggregate + `/devices.json` projection |
| `H264Decoder` | `Domain/Device/H264Decoder.swift` | the one `@Mockable` collaborator |
| `TwinScreen` | `Infrastructure/Device/TwinScreen.swift` | ingest hub: decode once, fan out `view()` screens |
| `TwinScreens` | `Infrastructure/Device/TwinScreens.swift` | per-udid hub registry held by `Server` |
| `LiveDevices` | `Infrastructure/Device/LiveDevices.swift` | in-memory aggregate |
| `VTH264Decoder` | `Infrastructure/Device/VTH264Decoder.swift` | irreducible VideoToolbox calls, integration-only |
| routes | `Infrastructure/Server/ServerDeviceTwinRoutes.swift` | the three implemented routes |

Naming note: the types are `Twin*`, not `Companion*` — "companion
screens" already means CarPlay/external displays in this codebase
(`ServerCompanionScreenRoutes.swift`), and one word cannot serve two
features. Prose still calls the phone-side app "the companion app".

## Testing approach

Standard for the codebase — TDD, Chicago-school, ~100% of Domain:

- `Attitude`, `TwinEnvelope`, `TwinSession`, and `AVCCParameterSets`
  are pure values and state machines: feed samples, assert values —
  no mocks.
- `Devices` aggregate semantics via `MockDevices` default-impl
  properties; `LiveDevices` driven directly.
- `TwinScreen` and `TwinScreens` are unit-tested against
  `MockH264Decoder` (the control plane later adds `MockRunner`); only
  the irreducible socket, VideoToolbox, and HTTP call sites stay
  integration-only.
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
