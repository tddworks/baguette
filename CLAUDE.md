# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & test

```bash
make                                          # release build via ./build.sh → ./Baguette
swift build                                   # debug build (carries MOCKING flag + mocks)
swift test                                    # full Swift Testing suite (110+ tests, no booted sim required)
swift test --filter Simulators                # one suite
swift test --filter "GestureRegistry/parses tap"   # one test
```

Hybrid build: pure SPM with `-F` / `-rpath` flags into Xcode private frameworks (`CoreSimulator`, `SimulatorKit`, `IOSurface`, `VideoToolbox`, `CoreGraphics`, `ImageIO`). `build.sh` does `swift build -c release` then copies the binary to `./Baguette`. Targets `arm64e-apple-macos26.0`; requires Xcode 26 + Apple Silicon.

Tests use **Swift Testing** (`@Suite`, `@Test`, `#expect`) — never XCTest. `MOCKING` is `.debug`-only so release builds carry no mock code (don't reach for `MockXxx` outside the test target).

## Architecture

Three-layer split with strict inward-flowing imports: `App` → `Domain` + `Infrastructure`; `Infrastructure` → `Domain`; `Domain` depends only on Foundation + IOSurface.

```
Sources/Baguette/
├── App/                CLI dispatch (ArgumentParser) + use-case orchestration
├── Domain/             pure Swift; value types + @Mockable aggregate ports
├── Infrastructure/     concrete @Mockable port impls (private-API code lives here only)
└── Resources/Web/      vanilla IIFE modules served by `baguette serve`
```

`Domain/` and `Infrastructure/` are split into bounded contexts (`Simulator/`, `Input/`, `Screen/`, `Stream/`, `Chrome/`) that mirror across both layers — a feature lives in one place across both. `Tests/BaguetteTests/` mirrors the same split.

### Two consumers, one pipeline

Both `baguette input` (stdin JSON, used by host plugins as a long-lived subprocess) and `baguette serve` (browser WS) funnel into the same `GestureDispatcher` → `Input` port → `IndigoHIDInput`. The only difference is the App-layer entry point.

### The crucial detail: 9-arg `IndigoHIDMessageForMouseNSEvent`

iOS 26 changed `SimulatorHID`'s wire format. The 5-arg signature used by `idb` / `AXe` routes to a pointer service that drops messages or crashes `backboardd`. Baguette uses the **9-arg signature from Xcode 26's preview-kit**, which routes to digitizer target `0x32`. The recipe lives in `Sources/Baguette/Infrastructure/Input/IndigoHIDInput.swift` (heavily commented).

`IndigoHIDMessageForMouseNSEvent` reads AppKit / NSEvent thread-local state, so it **must run on `MainActor`**. Calling it from a NIO event-loop thread builds malformed messages that the simulator silently drops. `Server.streamWS` hops to `MainActor` before invoking `GestureDispatcher`. Buttons (`IndigoHIDMessageForButton`) are pure C and thread-safe — useful as a sanity check when input fails.

### Coordinate conventions

Wire-level coordinates (`x`, `y`, `startX`, `endX`, `x1`, `x2`, `cx`, `cy`) are in **device points**, same units as the `width` / `height` carried in every gesture envelope. Browser-side `SimInput` works in normalized [0, 1] internally; `sim-stream.js` multiplies by `width` / `height` before serialising. `IndigoHIDInput.sendMouse` divides by size internally before handing to the C function. Wire is points, not normalized.

### Extensibility hot spots

- New gesture: one `Gesture`-conforming struct in `Domain/Input/` + one line in `GestureRegistry.standard`.
- New stream format: one `Stream` impl in `Infrastructure/Stream/` + one case in `StreamFormat.makeStream`. Envelope formats live in `Domain/Stream/Envelope.swift`.
- New web UI piece: a single-purpose IIFE in `Resources/Web/` that hangs one class on `window`, loaded by `<script>` tag in `sim.html`. No bundler / module graph.

### `baguette serve` route surface

Single resource tree, no `/api/` prefix; UDID always in path; format distinguished by extension. One bidirectional WebSocket per stream carries encoded binary frames (server→browser) and JSON text messages (browser→server) for both stream control (`set_bitrate` / `set_fps` / `set_scale` / `force_idr` / `snapshot`) and gestures. `Server` is intentionally dumb — UI lives in `Resources/Web/`. `BAGUETTE_WEB_DIR` overrides the served root for live-iteration without rebuilding.

## Testing approach

Chicago-school state-based throughout. Every external boundary is an `@Mockable` protocol; tests substitute auto-generated `MockXxx` fakes and assert on returned values rather than recorded calls. Patterns:

- Pure parsers (`DeviceChrome`, `DeviceProfile`, `ReconfigParser`, `GestureRegistry`) — feed JSON / plist, assert parsed value.
- Per-gesture parse + execute — verify wire dialect parses to the right value type and `execute(on: input)` calls the right `Input` method.
- Aggregate semantics — drive `MockSimulators` / `MockChromes` through default-impl computed properties (`running`, `available`, `listJSON`).

## Known iOS 26 limits

- `key` / `type` keyboard input — not yet on the host-HID path; routed through external tooling.
- `siri` button — crashes `backboardd` via every known Indigo path; explicitly rejected.
- Single-finger streaming (`touch1-*`) routes correctly but `UIPinchGestureRecognizer` treats it as an interactive pan; prefer `touch2-*` for pinch / multi-finger.

## Further reading

- `README.md` — quickstart, full CLI reference, wire protocol JSON examples.
- `docs/ARCHITECTURE.md` — end-to-end tap-to-`UITouch` flow, layer diagrams, route table.
- `Sources/Baguette/Infrastructure/Input/IndigoHIDInput.swift` — the 9-arg recipe.
