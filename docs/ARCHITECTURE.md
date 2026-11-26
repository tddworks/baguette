# Baguette — Architecture

How a tap in a browser becomes a `UITouch` inside a booted iOS 26
simulator — or on an iPhone on a cable — and how the code is laid out
to keep that path testable and extensible.

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

## Why this works on iOS 26.4 when older tools don't

Three calling-convention changes in iOS 26 / Xcode 26 broke every
public simulator-control tool. The 9-argument signature above is the
first; the other two:

1. **Streaming touches and edge gestures need a real `IOHIDEvent`.**
   For these, the Xcode 26 `IndigoHIDMessageForMouseNSEvent` either
   misroutes to the home gesture or silently drops. Baguette builds an
   `IOHIDEventCreateDigitizerEvent` parent +
   `IOHIDEventCreateDigitizerFingerEvent` child, runs it through
   `IndigoHIDMessageForTrackpadEventFromHIDEventRef`, then patches the
   byte slots the wrapper leaves uninitialised (`IndigoHIDTouchTarget`
   + the `IndigoHIDEdge` bitmask). That recipe is behind the
   home-indicator swipe, the app-switcher drag and the Lock Screen /
   Notification Center pull-downs.
2. **Camera substitution needs a per-app dylib.** No SimulatorKit
   symbol fakes the camera, so `VirtualCamera.dylib` is loaded into
   every simulator-launched app via `DYLD_INSERT_LIBRARIES`. It hooks
   `AVCaptureVideoPreviewLayer.setSession:`, `AVCapturePhotoOutput`
   and `UIImagePickerController`, and reads BGRA frames from a mmap'd
   buffer baguette fills from a Mac webcam. Installing it under a
   per-hash path dodges iOS 26's simulator dyld page-hash cache, which
   rejects a replaced dylib at the same path.

The HID recipe is commented in
`Sources/Devices/Simulator/Internal/Input/IndigoHIDInput.swift`; the
camera pipeline lives in `Sources/Device/Abilities/Camera/` and
`Injected/VirtualCamera/` (see [`features/camera/README.md`](features/camera/README.md)).

## Two consumers

Baguette has two ways to drive a simulator: via stdin JSON (a
subprocess pipeline used by host plugins) and via WebSocket (the
standalone web UI it serves itself).

```
                Subprocess pipeline                 Standalone serve
                ───────────────────                 ────────────────
   Host plugin      JSON                Browser           text/binary WS
   (asc-pro etc.)  ──────► baguette     (sim.html)       ──────► baguette
                    stdin    input                         /devices          serve
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

Both paths share everything under `Devices/` and `Device/`. The only
difference is the way in: `InputCommand` reads stdin
and writes stdout; `Server` (under `baguette serve`) opens a
WebSocket and uses `WebSocketFrameSink` to push encoded frames back.

Subprocess consumers typically spawn one persistent `baguette input
--udid <UDID>` per booted device because spawning costs ~1.2 s
(framework resolution) and the IndigoHID pipeline has a ~40 ms
per-session warmup that should only happen once.

> **"Host plugin" here means a program that embeds baguette** — an
> editor or agent host driving it over stdin. That's the opposite
> direction from a **baguette plugin**, which baguette spawns and which
> calls *back* into a running `serve` over HTTP. Same word, opposite
> arrow; see [`features/plugins/README.md`](features/plugins/README.md) for the
> second one.

## Layout, outside in

Imports flow strictly inward. The two ways in depend on the device
families and the plugins; they depend on `BaguetteDevice`, which
depends on nothing of baguette's — only Foundation / IOSurface (public
Apple types) and Mockable.

The package ships three products. `baguette` is the CLI: Commands, Server
and Plugins around `@main`. `BaguetteKit` is the library for a host that
drives devices itself (SimKit): it re-exports `BaguetteDevice` and
`BaguetteDeviceFamilies`, so it carries every device family and none of
the CLI, the HTTP server or the plugins.
[`examples/ListSimulators`](../examples/ListSimulators) depends on it,
and CI builds it. `BaguetteCoreDevice` adds a phone on a cable live —
its screen, touch and tunnel through Xcode's CoreDevice — as
`CoreDeviceAccess.live`, which a host passes to `DeviceKinds`. It is its
own product because CoreDevice is weak-linked with linker flags SwiftPM
accepts only from a dependency pinned by revision, branch or path: kept
out of `BaguetteKit`, they leave that one pinnable by version. Without
it, a phone's screen is devicectl stills and it takes no touch.

The files baguette ships beside its binary — the 3D models, the dylibs it
injects, the hinge helper — sit in `Baguette_Baguette.bundle` for the CLI.
A library host has no such bundle: it copies those folders from
`Sources/Baguette/Resources/` and names the copy with
`BaguetteResources.use(folder:)`, which both lookups try before the bundle.

```
Sources/
├── Commands/           the CLI: one file per `baguette` subcommand
├── Server/             what `baguette serve` runs: routes, WebSocket, WebRoot
├── Devices/            module BaguetteDeviceFamilies — the device families,
│   │                   each with its own Internal/
│   ├── Simulator/          CoreSimulator, SimulatorKit, simctl
│   ├── iPhone/             a phone on a cable: CoreDevice, its tunnel services
│   ├── CompanionPhone/     the companion-app twin
│   ├── Android/            emulators and phones, through adb
│   └── Mac/                this Mac's displays
├── Plugins/
│   ├── Plugin/             manifests, grants, routes a plugin may reach
│   └── Bakery/             where plugins come from: repos, menus, trust
├── Device/             module BaguetteDevice — what a device is: id, kind,
│   │                   power, Device, Devices, Abilities
│   ├── Chrome/             how it looks: bezel, 3D model, renderers
│   ├── Abilities/<ability>/  one role and its values (Touch, Press, Key,
│   │                       Screen, Capture, UI, Apps, Location, …)
│   └── Internal/           host I/O every family shares (subprocess, Xcode, log)
├── CoreDevice/         module BaguetteCoreDevice — Xcode's CoreDevice bound
│                       with @_silgen_name, weak-linked: CoreDeviceAccess.live
├── CoreDeviceABI/      the one CoreDevice call Swift can't spell, in C
├── BaguetteKit/        module BaguetteKit — the library product: re-exports
│                       BaguetteDevice and BaguetteDeviceFamilies
└── Baguette/           `@main` (RootCommand) and Resources/Web/ for `serve`
```

Every folder keeps its public face at the top and its implementations
— private APIs, host I/O — in `Internal/`
([solid](features/devices/solid.md)). The irreducible call to the outside
world (a private symbol, VideoToolbox, a socket, a process) sits apart in
`Internal/System/`, at most 100 lines a file: the only code unit coverage
leaves out (`codecov.yml`, `make check-coverage`). A family never imports another
family. Why: [devices](features/devices/design.md).
`Tests/BaguetteTests/` mirrors `Sources/` folder for folder: a test
sits in the folder of the source it covers.

### Device: values and roles

Pure value types with rich behaviour, plus `@Mockable` role and
aggregate protocols at the boundaries the ways in wire up.

| Context | Type | Kind | Notes |
|---|---|---|---|
| Device | `Devices` / `Device` | aggregate | every device of every family in one list; a device is identity + kind + state + an `Abilities`. `devices.require(.input, of: id)` hands back the role, or refuses naming the ability ([devices](features/devices/design.md)) |
| Device | `Abilities` / `Ability` | value | what one device can do, registered by its family only when it can do it |
| CoreDevice | `PhysicalPhone` · `MediaStreamOffer` · `ReceiverFeedback` · `DTXMessage` · `XPCObject` · `ServiceDirectory` · `AXTreeDump` | value | a phone on a cable, and the wire formats of its screen stream and its services — pure, tested byte for byte ([real devices](features/real-devices/design.md)) |
| Simulator | `Simulator` | value | identity (`udid`, `name`, `state`, `runtime`); rich verbs `boot()` / `shutdown()` / `screen()` / `input()` / `chrome(in:)` delegate to the injected aggregate |
| Simulator | `Simulators` | aggregate | `@Mockable` protocol — `all`, `find`, `boot`, `shutdown`, `screen(for:)`, `input(for:)`. Default-impl `running` / `available` / `listJSON` |
| Screen | `Screen` | port | `@Mockable` protocol — `start(onFrame:)` / `stop`. Emits `IOSurface` per frame |
| Input | `Touch` · `Press` · `Key` · `Scroll` | role | `@Mockable` protocols, one per input ability — `tap` / `swipe` / `touch1` / `touch2` / `twoFingerPath`; `button`; `key`; `scroll`. A device registers only those it has |
| Input | `Gesture` | protocol | one act of one ability, which it names: `Tap` / `Swipe` / `Touch1` / `Touch2` / `Pinch` / `Pan` (Touch), `ButtonPress` (Press), `Keystroke` / `TypeText` (Key), `WheelEvent` (Scroll) |
| Input | `GestureRegistry` | strategy | maps wire `"type"` strings to per-gesture parsers |
| Stream | `Stream` | port | `@Mockable` protocol — `start(on:)` / `stop` / `apply(_:)` / `requestKeyframe` / `requestSnapshot` |
| Stream | `StreamConfig` / `StreamFormat` | value | runtime knobs + `mjpeg` / `avcc` enum |
| Chrome | `DeviceChrome` | value | bezel layout from `chrome.json` — insets, corner radius, button anchors |
| Chrome | `DeviceProfile` | value | `profile.plist` parse result (chromeIdentifier) |
| Chrome | `Chromes` | aggregate | `@Mockable` protocol — `assets(forDeviceName:)` returns `DeviceChromeAssets` |
| Interface | `Interface` | port | `@Mockable` protocol — read/set × appearance, Increase Contrast, content size. Backed by `simctl ui` |
| Interface | `InterfaceAppearance` / `InterfaceContrast` | value | `light`/`dark`, `enabled`/`disabled`, plus the `unknown` / `unsupported` a device answers when it can't say. Those two have no `argument` — readable states, never instructions |
| Interface | `ContentSize` / `ContentSizeChange` | value | the 12 Dynamic Type categories; a separate change type because setting also accepts `increment` / `decrement`, which reading never answers |
| Plugin | `PluginManifest` | value | parsed `baguette-plugin.json` — name, apiVersion, declared `capabilities`, contributions. Rejects an unknown icon or capability at parse time |
| Plugin | `Plugin` | value | a manifest plus the directory it was read from (the command's cwd) |
| Plugin | `Plugins` | aggregate | `@Mockable` protocol — `all()`, `resolve(qualifiedCommand:)`, default-impl `listJSON` |
| Plugin | `PluginCapability` | value | the closed set a manifest may declare |
| Plugin | `PluginGrants` | collaborator | mints one unguessable token per command invocation carrying that plugin's set; revokes it on exit |
| Plugin | `PluginRoute` | value | which capability a path demands — closed table, so an unmapped route is unreachable by any plugin |
| Plugin | `PluginAccess` | value | the decision: `anonymous` (no grant — origin checks decide) / `granted` / `refused(message)` |
| Bakery | `BakeryRef` | value | `owner/repo`, `owner/repo/plugin`, a git URL or `file://`, normalized to host/owner/repo |
| Bakery | `BakeryMenu` | value | a repo's `baguette.json` — the plugins it offers, each path constrained to stay inside the repo |
| Bakery | `TrustDecision` | value | whether a source is already trusted, so consent is asked once |
| Bakery | `InstallPlan` | value | what to copy where, resolved against `BaguetteHome` |
| Common | `Point` / `Size` / `Insets` / `Rect` | value | coordinate primitives |

Adding a new gesture is one `Gesture`-conforming struct in
its ability's folder (`Device/Abilities/Touch/`, …) + one line in `GestureRegistry.standard`. Adding a
new stream format is one `Stream` impl in `Device/Abilities/Capture/Internal/` +
one case in `StreamFormat.makeStream` (beside the encoders, not among
the values). Caller code stays unchanged
(OCP).

### Implementations (`Internal/`)

`@Mockable` ports + concrete impls. The concrete impls do the
ObjC-runtime / SimulatorKit / CoreGraphics work; tests substitute
mocks at the port boundary.

| Context | Port | Concrete impl | What it wraps |
|---|---|---|---|
| Simulator | `Simulators` | `CoreSimulators` | CoreSimulator + SimulatorKit private classes via the ObjC runtime |
| Screen | `Screen` | `SimulatorKitScreen` | `SimDevice.io` framebuffer callback registration |
| Input | `Touch` · `Press` · `Key` · `Scroll` (a simulator's `HID`) | `IndigoHIDInput` | 9-arg `IndigoHIDMessageForMouseNSEvent` + `SimDeviceLegacyHIDClient` |
| Stream | `Stream` | `MJPEGStream` / `AVCCStream` | `JPEGEncoder` + `VideoEncoder` (VideoToolbox), envelope formatting |
| Stream | `FrameSink` | `StdoutSink` / `WebSocketFrameSink` | per-process or per-WS sink for encoded bytes |
| Chrome | `Chromes` | `LiveChromes` | composes `ChromeStore` + `PDFRasterizer`; caches per chrome identifier |
| Chrome | `ChromeStore` | `FileSystemChromeStore` | reads `/Library/Developer/CoreSimulator/.../profile.plist` + `/Library/Developer/DeviceKit/Chrome/...` |
| Chrome | `PDFRasterizer` | `CoreGraphicsPDFRasterizer` | turns composite PDFs into RGBA PNG |
| Interface | `Interface` | `SimctlInterface` | `xcrun simctl ui` — argv + exit handshake pure, spawn via `Subprocess` |
| Plugin | `Plugins` | `FileSystemPlugins` | scans plugin roots for `baguette-plugin.json`; later roots shadow earlier ones |
| Plugin | — | `PluginRoot` | resolves plugin roots: bundled → installed (`~/.baguette/plugins`) → `--plugin-dir` |
| Bakery | `Bakeries` | `FileSystemBakeries` | `bakeries.json` / `installed.json` under `BaguetteHome` |
| Bakery | `Checkout` | `GitCheckout` | shallow, non-interactive `git` — no submodules, pinned to a commit |
| Server | — | `Server` | Hummingbird HTTP + WebSocket server for `baguette serve` |
| Server | — | `PluginGrantMiddleware` | asks `PluginAccess` in front of every route, so a plugin's grant is checked once rather than per-handler |
| Server | — | `WebRoot` | resolves `Resources/Web/` via env override → source tree → `Bundle.module` |

`StdoutSink` and `WebSocketFrameSink` both conform to `FrameSink`
(`func write(Data)`) so the encoders don't know or care which they're
feeding. The WS sink also parses the encoder's HTTP-shaped envelopes
(MJPEG multipart, AVCC length-prefix) into per-frame WS messages
before forwarding.

### Commands and Server

Thin orchestration; ArgumentParser lives in `Commands/`, Hummingbird in
`Server/`.

- `RootCommand` (`Sources/Baguette/`) — top-level `AsyncParsableCommand`, registers all
  subcommands.
- `Commands/` — one file per subcommand. `InputCommand` reads stdin
  and runs `GestureDispatcher`. `ServeCommand` boots a `Server` with
  real `CoreSimulators` + `LiveChromes`. `StreamCommand` writes
  encoder bytes to stdout via `StdoutSink`.
- `GestureDispatcher` — pure JSON-line-in → ack-JSON-out using
  `GestureRegistry` + the screen's input `Abilities`. Used by both `InputCommand` (over stdin)
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
3. **`page/devices-stream.js` orchestrator** — translates the dialect to
   Baguette's wire (`type:"tap"`, x/y multiplied to device-point
   space), serialises to JSON, sends as a text WS message.
4. **`Server.streamWS`** — receives the text frame, runs
   `applyStreamControl` first (returns `false` since this isn't a
   `set_*` / `force_idr` / `snapshot`), then queues
   `GestureDispatcher.dispatch` on the device's lane (`GestureQueues`):
   one gesture at a time, in the order sent, off the event loop.
5. **`GestureDispatcher`** — parses the JSON via
   `GestureRegistry.standard.parse`, gets back a `Tap` value type,
   asks the screen's input for `Tap.ability` (`.touch`) and calls
   `tap.execute(on: touch)`; a screen without it is refused by name.
6. **`Tap.execute`** — calls `touch.tap(at:size:duration:edge:)`.
7. **`IndigoHIDInput.tap`** — lazily opens `SimDeviceLegacyHIDClient`
   and primes the input services. `IOHIDDigitizerDispatch` builds and patches
   digitizer down/up messages around the requested hold duration. Each send
   waits for its transport completion; see the
   [dispatch contract](features/touches/design.md#5-dispatch).
8. **SimulatorKit** — routes the messages to digitizer target `0x32`
   inside the sim. `backboardd` delivers a touch event through the
   normal iOS HID stack.
9. **UIKit** — gesture recognizers fire as if a finger touched the
   screen.

Total latency on warm services: a few milliseconds per gesture.

The main-thread hop in step 7 matters: `IndigoHIDMessageForMouseNSEvent`
reads AppKit / NSEvent thread-local state, so building it on any other
thread makes a malformed message the simulator silently drops.
`IndigoHIDInput` hops for each build alone (`onMainThread`), so a drag's
waits hold its device's lane, never the main thread. Buttons (`IndigoHIDMessageForButton` — pure C, no
AppKit dep) work from any thread, which was the diagnostic that
isolated the issue.

## Coordinate conventions

All wire-level coordinates — `x`, `y`, `startX`, `endX`, `x1`, `x2`,
`cx`, `cy` — are **device points**, same units as the `width` and
`height` carried in every gesture envelope. `IndigoHIDInput.sendMouse`
divides by `size.width` / `size.height` to produce the normalized
[0, 1] CGPoint the C function expects.

The browser's gesture sources (`baguette/gestures/`) speak normalized [0, 1] internally
and multiplies by `width` / `height` in `page/devices-stream.js`'s translator
before serialising. Documenting this once: **the wire is in points,
not normalized**.

Pinch/pan one-shots (`pinch`, `pan` subcommands) take radii / deltas
in points too — same unit system end to end.

## Streaming pipeline

```
Screen (IOSurface per frame)          Stream impl                        FrameSink
  SimulatorKitScreen — a simulator's framebuffer
  CoreDeviceScreen   — a phone's own stream, received over its tunnel by its
                       ScreenReceiver (RTPReceiver or AVConferenceReceiver),
                       decoded and cropped to its screen
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

Format-specific envelopes live in `Device/Abilities/Capture/Envelope.swift`:

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

- `GET /devices/:udid/chrome.json` — `DeviceChrome.layoutJSON`
  (composite size, screen rect, inner corner radius, buttons).
- `GET /devices/:udid/bezel.png` — the rasterized composite.

`DeviceFrame` (`device-frame.js`) overlays the screen `<canvas>` on
top of the bezel `<img>` (z-index 2 vs 1), positioned by `screen.{x,y,width,height}`
percentages and clipped to `innerCornerRadius` via the elliptical
`H% / V%` border-radius form so a tall phone screen gets a circular
corner instead of an oval.

## Server route surface

The shape of the route tree; the complete, current table is
[`serve.md`](serve.md).

```
GET  /                                      302 → /devices
GET  /devices                               sim.html (every device)
GET  /simulators                            sim.html (old spelling)
GET  /simulators.json                       Simulators.listJSON
GET  /simulators/:udid                      sim.html (same shell)
POST /devices/:udid/boot                    device.require(.power).turnOn()
POST /devices/:udid/shutdown                device.require(.power).turnOff()
GET  /devices/:udid/chrome.json             device.chrome(in:).layoutJSON()
GET  /devices/:udid/bezel.png               composite.data
GET  /devices/:udid/interface.json          appearance + contrast + content size
POST /devices/:udid/interface               set any subset, answer the result
GET  /devices/:udid/companion-screens.json   CarPlay display + paired watch
POST /devices/:udid/carplay-display         attach/reattach CarPlay via Simulator.app
GET  /devices/:udid/describe-ui.json        Accessibility.describeAll / describeAt
POST /devices/:udid/input                   GestureDispatcher (one envelope)
WS   /devices/:udid/stream?format=…         Stream + GestureDispatcher on the device's GestureQueues lane;
                                            the companion app's video when it streams one
GET  /devices.json                          Devices.listJSON (every device: kind, OS, state, abilities)
GET  /devices/:udid                         sim.html (same shell, device tree)
GET  /devices/:udid/screenshot.{jpg,png}    devices.require(.screen, of:) — any family
GET  /plugins.json                          Plugins.listJSON
POST /plugins/:id/commands/:cmd?udid=       PluginDispatch → the plugin's rows
GET  /bakeries.json                         trusted sources + pinned commits + install state
POST /bakeries/preview                      BakeryInstall.preview (trusts nothing)
POST /bakeries/install                      InstallDecision → BakeryInstall.install
                                            (already-trusted bakeries only, by id)
                                            (no install route — that's CLI-only, by design)
GET  /<file>.{html,js,css,…}                Resources/Web/<file>
```

`describe-ui.json` and `input` are the two routes a plugin subprocess
lives on: the accessibility tree and the gesture pipeline were both
WebSocket-only, which put them out of reach of a one-shot command. Both
answer `curl` and both are capability-gated.

Every request passes `PluginGrantMiddleware` first. A request carrying
no grant is *anonymous* — the origin checks decide, exactly as before
plugins existed. A request carrying one may only touch the routes its
manifest declared, and a route no capability names (`boot`, `shutdown`,
`orientation`, the `/plugins` and `/bakeries` surfaces) is unreachable
by any plugin, so a plugin can't run other plugins or install new ones.

No `/api/` prefix; UDID always in the path; format distinguished by
file extension. Static UI siblings live at the root so
`<script src="page/devices-list.js">` resolves naturally from a page served at
`/simulators` — no conflict with `/simulators/:udid` (UDIDs don't end
in `.js`).

`Server` is intentionally **dumb**: each route handler is a thin
binding from HTTP request to domain call + projection. Zero HTML
manipulation, no template extraction, no script inlining. Anything
UI-shaped lives in `Resources/Web/`.

## Web UI internals

`Resources/Web/` is ES modules, no bundler: `sim.html` loads one,
`page/page.js`, which imports the device page or the devices list, and they
import what they use; the farm (`farm/farm.html` → `farm/farm-app.js`) and
the SDK (`baguette/baguette.js`) are entries the same way. The folders, their
public faces and `internal/` rule are in
[web-page](features/web-page/design.md); `Tests/Web/boundaries.test.js`
holds them.

| Folder | Job |
|---|---|
| `page/` | the page roots: the device page, the devices list and its inline stream view |
| `device/` | what every device page shares: the device's roles, panels, toolbar |
| `families/` | each family's roles (simulator, phone, Android, Mac) |
| `panels/` | one folder per panel, its view in `internal/` |
| `stream/` | MJPEG / AVCC sessions over the WebSocket, WHEP for WebRTC |
| `capture/` | capture sizes, screenshots, recordings |
| `baguette/` | the JS SDK: transport, gestures, bezel, screen, buttons, keyboard |

Nothing a plugin ships reaches this page — no plugin script, CSS or
markup. A manifest names an icon from a host-owned set and every string
from `/plugins.json` goes through `escapeHTML` or `textContent`. That
constraint is what keeps the server's Origin / `Sec-Fetch-Site` /
DNS-rebind checks meaningful: a same-origin plugin script would make
all of them moot.

## Testing

Chicago-school state-based tests throughout. 110+ tests; every
external boundary is `@Mockable`, so tests substitute auto-generated
fakes and assert on returned values rather than recorded calls.
`Tests/BaguetteTests/` mirrors `Sources/` folder for folder
(`Devices/Simulator/`, `Device/Abilities/Touch/`, `Server/`, `Commands/`, …).

- **Pure parsers** (`DeviceChrome`, `DeviceProfile`, `ReconfigParser`,
  `GestureRegistry`) — feed JSON / plist data, assert on the parsed
  value.
- **Per-gesture parse + execute** — verify the wire dialect parses
  to the expected act and that `execute(on:)` calls the right method
  on its role's mock (`MockTouch`, `MockPress`, `MockKey`, `MockScroll`).
- **Aggregate semantics** — drive `MockSimulators` / `MockChromes`
  through their default-impl computed properties (`running`,
  `available`, `listJSON`). State, not interactions.
- **Live impl orchestration** (`LiveChromes`) — mock `ChromeStore` +
  `PDFRasterizer`, exercise cache hits / misses / failure paths.
- **Stream startup handshake** — verify the three-step
  screen-attach + sink-write contract.
- **Routes, in process** — `Tests/BaguetteTests/Server/Router/` runs the
  real router through `HummingbirdTesting` (`InProcessServer`): browser
  trust, plugin grants, both trees, refusal codes, deprecation headers.
- **System tests** — the few that drive the real thing an
  `Internal/System/` file wraps (VideoToolbox, …) are tagged `.system` and
  run only off CI (`SystemTests.available`).

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

- [`../README.md`](../README.md) — quickstart; [`commands.md`](commands.md)
  — every flag; [`wire.md`](wire.md) — the gesture wire;
  [`serve.md`](serve.md) — every `serve` route.
- [`features/plugins/README.md`](features/plugins/README.md) — the plugin contract:
  manifest schema, the command's JSON answer, the capability table and
  what it does and doesn't guarantee, bakery distribution.
- [`features/real-devices/design.md`](features/real-devices/design.md) — how a
  phone on a cable is reached: touches through CoreDevice's Universal HID, its
  H.264 screen stream, and its accessibility tree over the tunnel.
- `../Sources/Devices/Simulator/Internal/Input/IndigoHIDInput.swift` —
  the 9-arg `IndigoHIDMessageForMouseNSEvent` recipe, heavily
  commented.
