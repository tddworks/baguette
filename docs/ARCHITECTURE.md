# Baguette — Architecture

How a tap in a browser becomes a `UITouch` inside a booted iOS 26
simulator, and how the code is laid out to keep that path testable
and extensible.

If you just want to build and use Baguette, read [`../README.md`](../README.md).

## The problem

iOS 26 changed `SimulatorHID`'s wire format. Public tools like `idb`
and `AXe` call `IndigoHIDMessageForMouseNSEvent` with the old
5-argument signature; those messages now route to a pointer-service
target that silently drops them or crashes `backboardd`. For a while
nothing outside Simulator.app could inject touches into iOS 26 sims.

Xcode 26's SimulatorKit exposes a new 9-argument
`IndigoHIDMessageForMouseNSEvent` signature that routes touches to
digitizer target `0x32`. Tools that use the correct new signature can
inject from the host again — no in-process code, no app injection,
no `DYLD_INSERT_LIBRARIES`. Baguette ships that path.

## Two consumers

Baguette has two ways to drive a simulator: via stdin JSON (a
subprocess pipeline used by host plugins) and via WebSocket (the
standalone web UI it serves itself).

```
                Subprocess pipeline                 Standalone serve
                ───────────────────                 ────────────────
   Host plugin      JSON                Browser           text/binary WS
   (asc-pro etc.)  ──────► baguette     (sim.html)       ──────► baguette
                    stdin    input                         /simulators       serve
                                  │                              │
                                  ▼                              ▼
                          GestureDispatcher              GestureDispatcher
                                  │                              │
                                  ▼                              ▼
                              Simulator.input() → IndigoHIDInput
                                                       │
                                                       ▼
                                  IndigoHIDMessageForMouseNSEvent (9-arg)
                                  → SimDeviceLegacyHIDClient
                                  → digitizer target 0x32
                                  → booted iOS 26 simulator
```

Both paths share the same Domain + Infrastructure layers. The only
difference is the App-layer entry point: `InputCommand` reads stdin
and writes stdout; `Server` (under `baguette serve`) opens a
WebSocket and uses `WebSocketFrameSink` to push encoded frames back.

Subprocess consumers typically spawn one persistent `baguette input
--udid <UDID>` per booted device because spawning costs ~1.2 s
(framework resolution) and the IndigoHID pipeline has a ~40 ms
per-session warmup that should only happen once.

## Three-layer code split

Cross-layer imports flow strictly inward: App depends on Domain +
Infrastructure; Infrastructure depends on Domain; Domain depends on
nothing but Foundation / IOSurface (a public Apple type).

```
Sources/Baguette/
├── App/                CLI dispatch + use-case orchestration
├── Domain/             pure Swift, no private Apple APIs
├── Infrastructure/     @Mockable protocols + concrete impls
└── Resources/Web/      static HTML / JS / CSS for `serve`
```

`Domain/` and `Infrastructure/` are further split into bounded-context
subfolders (`Simulator/`, `Input/`, `Screen/`, `Stream/`, `Chrome/`)
that mirror across the two layers, so a feature lives in one place
across both. `Tests/BaguetteTests/` mirrors the same context split.

### Domain

Pure value types with rich behaviour, plus `@Mockable` aggregate
protocols at the boundaries the App layer wires up.

| Context | Type | Kind | Notes |
|---|---|---|---|
| Simulator | `Simulator` | value | identity (`udid`, `name`, `state`, `runtime`); rich verbs `boot()` / `shutdown()` / `screen()` / `input()` / `chrome(in:)` delegate to the injected aggregate |
| Simulator | `Simulators` | aggregate | `@Mockable` protocol — `all`, `find`, `boot`, `shutdown`, `screen(for:)`, `input(for:)`. Default-impl `running` / `available` / `listJSON` |
| Screen | `Screen` | port | `@Mockable` protocol — `start(onFrame:)` / `stop`. Emits `IOSurface` per frame |
| Input | `Input` | port | `@Mockable` protocol — `tap` / `swipe` / `touch1` / `touch2` / `button` / `scroll` |
| Input | `Gesture` | protocol | `Tap` / `Swipe` / `Touch1` / `Touch2` / `Press` / `Scroll` / `Pinch` / `Pan` value types |
| Input | `GestureRegistry` | strategy | maps wire `"type"` strings to per-gesture parsers |
| Stream | `Stream` | port | `@Mockable` protocol — `start(on:)` / `stop` / `apply(_:)` / `requestKeyframe` / `requestSnapshot` |
| Stream | `StreamConfig` / `StreamFormat` | value | runtime knobs + `mjpeg` / `avcc` enum |
| Chrome | `DeviceChrome` | value | bezel layout from `chrome.json` — insets, corner radius, button anchors |
| Chrome | `DeviceProfile` | value | `profile.plist` parse result (chromeIdentifier) |
| Chrome | `Chromes` | aggregate | `@Mockable` protocol — `assets(forDeviceName:)` returns `DeviceChromeAssets` |
| Common | `Point` / `Size` / `Insets` / `Rect` | value | coordinate primitives |

Adding a new gesture is one `Gesture`-conforming struct in
`Domain/Input/` + one line in `GestureRegistry.standard`. Adding a
new stream format is one `Stream` impl in `Infrastructure/Stream/` +
one case in `StreamFormat.makeStream`. Caller code stays unchanged
(OCP).

### Infrastructure

`@Mockable` ports + concrete impls. The concrete impls do the
ObjC-runtime / SimulatorKit / CoreGraphics work; tests substitute
mocks at the port boundary.

| Context | Port | Concrete impl | What it wraps |
|---|---|---|---|
| Simulator | `Simulators` | `CoreSimulators` | CoreSimulator + SimulatorKit private classes via the ObjC runtime |
| Screen | `Screen` | `SimulatorKitScreen` | `SimDevice.io` framebuffer callback registration |
| Input | `Input` | `IndigoHIDInput` | 9-arg `IndigoHIDMessageForMouseNSEvent` + `SimDeviceLegacyHIDClient` |
| Stream | `Stream` | `MJPEGStream` / `AVCCStream` | `JPEGEncoder` + `H264Encoder` (VideoToolbox), envelope formatting |
| Stream | `FrameSink` | `StdoutSink` / `WebSocketFrameSink` | per-process or per-WS sink for encoded bytes |
| Chrome | `Chromes` | `LiveChromes` | composes `ChromeStore` + `PDFRasterizer`; caches per chrome identifier |
| Chrome | `ChromeStore` | `FileSystemChromeStore` | reads `/Library/Developer/CoreSimulator/.../profile.plist` + `/Library/Developer/DeviceKit/Chrome/...` |
| Chrome | `PDFRasterizer` | `CoreGraphicsPDFRasterizer` | turns composite PDFs into RGBA PNG |
| Server | — | `Server` | Hummingbird HTTP + WebSocket server for `baguette serve` |
| Server | — | `WebRoot` | resolves `Resources/Web/` via env override → source tree → `Bundle.module` |

`StdoutSink` and `WebSocketFrameSink` both conform to `FrameSink`
(`func write(Data)`) so the encoders don't know or care which they're
feeding. The WS sink also parses the encoder's HTTP-shaped envelopes
(MJPEG multipart, AVCC length-prefix) into per-frame WS messages
before forwarding.

### App

Thin orchestration; ArgumentParser lives here.

- `RootCommand` — top-level `AsyncParsableCommand`, registers all
  subcommands.
- `Commands/` — one file per subcommand. `InputCommand` reads stdin
  and runs `GestureDispatcher`. `ServeCommand` boots a `Server` with
  real `CoreSimulators` + `LiveChromes`. `StreamCommand` writes
  encoder bytes to stdout via `StdoutSink`.
- `GestureDispatcher` — pure JSON-line-in → ack-JSON-out using
  `GestureRegistry` + `Input`. Used by both `InputCommand` (over stdin)
  and `Server.streamWS` (over WebSocket text frames).
- `ReconfigParser` — runtime stream-control parser (`set_bitrate` /
  `set_fps` / `set_scale`). Pure: takes a line + current config,
  returns a new config. Same parser used by stdin `ControlChannel`
  and by `Server.streamWS`.

## End-to-end flow: a tap in `baguette serve`

1. **Browser** — user taps inside the on-page simulator. `MouseGestureSource`
   computes the click's normalized coordinates and calls `SimInput.tap(...)`.
2. **`SimInput`** — emits a payload `{kind:"tap", x, y, duration, width, height}`
   in the host plugin's wire dialect, hands it to its `transport`
   callback.
3. **`sim-stream.js` orchestrator** — translates the dialect to
   Baguette's wire (`type:"tap"`, x/y multiplied to device-point
   space), serialises to JSON, sends as a text WS message.
4. **`Server.streamWS`** — receives the text frame, runs
   `applyStreamControl` first (returns `false` since this isn't a
   `set_*` / `force_idr` / `snapshot`), then hops to `MainActor` and
   calls `GestureDispatcher.dispatch`.
5. **`GestureDispatcher`** — parses the JSON via
   `GestureRegistry.standard.parse`, gets back a `Tap` value type,
   calls `tap.execute(on: input)`.
6. **`Tap.execute`** — calls `input.tap(at:size:duration:)`.
7. **`IndigoHIDInput.tap`** — first call lazily warms by opening
   `SimDeviceLegacyHIDClient` and emitting pointer + mouse service
   primers. Builds two `IndigoMessage`s with the 9-arg
   `IndigoHIDMessageForMouseNSEvent` (down, sleep, up), sends each via
   `SimDeviceLegacyHIDClient.send(message:wait:true)`.
8. **SimulatorKit** — routes the messages to digitizer target `0x32`
   inside the sim. `backboardd` delivers a touch event through the
   normal iOS HID stack.
9. **UIKit** — gesture recognizers fire as if a finger touched the
   screen.

Total latency on warm services: a few milliseconds per gesture.

The `MainActor` hop in step 4 matters: `IndigoHIDMessageForMouseNSEvent`
reads AppKit / NSEvent thread-local state, so calling it from a NIO
event-loop thread builds a malformed message that the simulator
silently drops. Buttons (`IndigoHIDMessageForButton` — pure C, no
AppKit dep) work from any thread, which was the diagnostic that
isolated the issue.

## Coordinate conventions

All wire-level coordinates — `x`, `y`, `startX`, `endX`, `x1`, `x2`,
`cx`, `cy` — are **device points**, same units as the `width` and
`height` carried in every gesture envelope. `IndigoHIDInput.sendMouse`
divides by `size.width` / `size.height` to produce the normalized
[0, 1] CGPoint the C function expects.

The browser-side IIFE (`SimInput`) speaks normalized [0, 1] internally
and multiplies by `width` / `height` in `sim-stream.js`'s translator
before serialising. Documenting this once: **the wire is in points,
not normalized**.

Pinch/pan one-shots (`pinch`, `pan` subcommands) take radii / deltas
in points too — same unit system end to end.

## Streaming pipeline

```
SimulatorKitScreen (IOSurface)        Stream impl                        FrameSink
─────────────────────────────         ───────────                        ─────────
  framebuffer callbacks      ──►      MJPEG / AVCC encode loop  ──►     StdoutSink
  (queue: baguette.screen)            keepalive timer (H.264)            WebSocketFrameSink
                                      JPEG seed emitter                       │
                                      runtime reconfig                        ▼
                                                                     stdout (CLI)
                                                                     binary WS frames
```

`Stream.start(on: screen)` subscribes the encoder to the screen's
`onFrame:` callback. The encoder writes envelope bytes to its
`FrameSink` — for the CLI that's `StdoutSink` (raw); for the server
that's `WebSocketFrameSink`, which parses the envelope back into
per-frame chunks and emits them as WS binary messages.

Format-specific envelopes live in `Domain/Stream/Envelope.swift`:

- `MJPEGEnvelope.header` / `framed(jpeg:)` — multipart MIME prologue
  + per-frame `--frame` boundary (so an HTTP `<img src=…/stream.mjpeg>`
  renders directly).
- `AVCCEnvelope.description / keyframe / delta / seed` —
  `[4-byte BE length][1-byte tag][payload]`. WS clients drop the
  length prefix; CLI consumers (e.g. `ffplay`) read it.

Runtime control: while a stream is live, JSON commands over the same
channel (stdin for `baguette stream`, WS text frames for `serve`)
retune scale / fps / bitrate without restarting. `ReconfigParser`
turns one line into a new `StreamConfig` and `Stream.apply(_:)` does
the deltas (VideoToolbox bitrate retune, etc.).

## Chrome / bezel pipeline

```
Simulator name ──► profile.plist ──► chromeIdentifier ──► chrome.json
                   (DeviceProfile.parsing)                  (DeviceChrome.parsing)
                                                                 │
                                                                 ▼
                                                       composite PDF asset
                                                                 │
                                                                 ▼
                                              CoreGraphicsPDFRasterizer
                                                                 │
                                                                 ▼
                                          DeviceChromeAssets { chrome, composite }
                                          (cached per chromeIdentifier)
```

`LiveChromes.assets(forDeviceName:)` reads
`/Library/Developer/CoreSimulator/Profiles/DeviceTypes/<name>.simdevicetype/Contents/Resources/profile.plist`
to get the chrome identifier, loads
`/Library/Developer/DeviceKit/Chrome/<id>.devicechrome/Contents/Resources/chrome.json`
for the layout, rasterizes the composite PDF to RGBA PNG, and caches
the result.

The `serve` page consumes this via two endpoints:

- `GET /simulators/:udid/chrome.json` — `DeviceChrome.layoutJSON`
  (composite size, screen rect, inner corner radius, buttons).
- `GET /simulators/:udid/bezel.png` — the rasterized composite.

`DeviceFrame` (`device-frame.js`) overlays the screen `<canvas>` on
top of the bezel `<img>` (z-index 2 vs 1), positioned by `screen.{x,y,width,height}`
percentages and clipped to `innerCornerRadius` via the elliptical
`H% / V%` border-radius form so a tall phone screen gets a circular
corner instead of an oval.

## Server route surface

```
GET  /                                      302 → /simulators
GET  /simulators                            sim.html
GET  /simulators.json                       Simulators.listJSON
GET  /simulators/:udid                      sim.html (same shell)
POST /simulators/:udid/boot                 simulator.boot()
POST /simulators/:udid/shutdown             simulator.shutdown()
GET  /simulators/:udid/chrome.json          DeviceChromeAssets.layoutJSON()
GET  /simulators/:udid/bezel.png            composite.data
WS   /simulators/:udid/stream?format=…      Stream + GestureDispatcher
GET  /<file>.{html,js,css,…}                Resources/Web/<file>
```

No `/api/` prefix; UDID always in the path; format distinguished by
file extension. Static UI siblings live at the root so
`<script src="sim-list.js">` resolves naturally from a page served at
`/simulators` — no conflict with `/simulators/:udid` (UDIDs don't end
in `.js`).

`Server` is intentionally **dumb**: each route handler is a thin
binding from HTTP request to domain call + projection. Zero HTML
manipulation, no template extraction, no script inlining. Anything
UI-shaped lives in `Resources/Web/`.

## Web UI internals

`Resources/Web/` ships seven self-contained IIFE modules; each owns
one responsibility:

| File | Job |
|---|---|
| `sim.html` | entry — loads the IIFEs in dependency order |
| `sim-input.js` | `SimInput` / `MouseGestureSource` / `PinchOverlay` / `TouchGestureSource` |
| `frame-decoder.js` | `FrameDecoder.create(format, callbacks)` — MJPEG / AVCC strategy |
| `device-frame.js` | `DeviceFrame` — bezel + screen-area DOM construction |
| `capture-gallery.js` | `CaptureGallery` — screenshot fetch + composite + thumbs |
| `stream-session.js` | `StreamSession` — WS lifetime + paint loop |
| `sim-list.js` | list page renderer + boot/shutdown buttons |
| `sim-stream.js` | orchestrator — wires the above on Stream click |

Each file is a single-purpose IIFE that exposes one class or factory
on `window`. Adding a new format is one new file in
`frame-decoder.js`'s strategy and one entry in the factory; adding a
new sidebar action is one orchestrator binding. No bundler, no module
graph; vanilla `<script>` tags loaded in order.

## Testing

Chicago-school state-based tests throughout. 110+ tests; every
external boundary is `@Mockable`, so tests substitute auto-generated
fakes and assert on returned values rather than recorded calls.
`Tests/BaguetteTests/` mirrors the same context split as `Sources/`
(`Simulator/`, `Input/`, `Stream/`, `Chrome/`, plus `App/` for the
App-layer dispatchers).

- **Pure parsers** (`DeviceChrome`, `DeviceProfile`, `ReconfigParser`,
  `GestureRegistry`) — feed JSON / plist data, assert on the parsed
  value.
- **Per-gesture parse + execute** — verify the wire dialect parses
  to the expected value type and that `execute(on: input)` calls the
  right `Input` method with the right args.
- **Aggregate semantics** — drive `MockSimulators` / `MockChromes`
  through their default-impl computed properties (`running`,
  `available`, `listJSON`). State, not interactions.
- **Live impl orchestration** (`LiveChromes`) — mock `ChromeStore` +
  `PDFRasterizer`, exercise cache hits / misses / failure paths.
- **Stream startup handshake** — verify the three-step
  screen-attach + sink-write contract.

Swift Testing only (`@Suite`, `@Test`, `#expect`); no XCTest. The
`MOCKING` flag is `.debug`-only so release builds carry no mock
code. The `Tests` scheme runs in a few seconds without a booted sim.

## iOS 26 limits

- **`key` / `type`** — keyboard isn't on Baguette's host-HID path
  yet (preview-kit recipe still WIP). The `serve` UI logs and drops
  these; subprocess consumers route them through external tooling.
- **`siri` button** — crashes `backboardd` via every known Indigo
  path. Explicitly rejected.
- **Single-finger streaming** — routed correctly but
  `UIPinchGestureRecognizer` and friends treat `touch1-*` as an
  interactive pan. 2-finger streaming (`touch2-*`) is more reliable
  for pinch / multi-finger gestures.

## Further reading

- [`../README.md`](../README.md) — quickstart, CLI reference, wire
  protocol.
- `../Sources/Baguette/Infrastructure/Input/IndigoHIDInput.swift` —
  the 9-arg `IndigoHIDMessageForMouseNSEvent` recipe, heavily
  commented.
