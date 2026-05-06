# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## TDD is non-negotiable (read this first)

**You MUST write a failing test before writing any production code.** This rule overrides every other instinct, including "the change is small", "it's just a one-liner", "I'll add the test after". If you catch yourself opening a file under `Sources/Baguette/` before a test under `Tests/BaguetteTests/` exists and fails, stop and reverse course.

**Pre-implementation gate** — before editing anything in `Sources/` (Domain value type, Domain port, Infrastructure adapter, App-layer command), you must have done all of the following in order:

1. Stated the user-facing behaviour in one sentence using **domain language**, not implementation language. Good: "a tap is dispatched as down → hold → up against the input surface", "describe-ui returns nil when no app is frontmost", "logs reject `notice` because the iOS-runtime `log` binary doesn't accept it". Bad: "IndigoHIDInput calls sendMouse twice" — that's an interaction, not a behaviour.
2. Written a `@Test` in `Tests/BaguetteTests/<Context>/<Suite>.swift` that asserts the expected outcome. Prefer state assertions (`#expect(filter.argv == [...])`, `#expect(node.frame == ...)`) over interaction assertions. For ports, use the auto-generated `MockXxx` (`given(input).tap(...).willReturn(true)`); plain test doubles backed by Mockable are the canonical mocking style — never mock the value type itself.
3. Run the test and **observed it fail** — `swift test --filter "<SuiteName>"` for the fastest loop. A compile error counts as red only when the failing symbol is the one the test names (`KeyboardKey.from(wireCode:)` doesn't exist yet); a generic build error somewhere else doesn't.
4. Reported the red result back to the user (one line is fine: "test `parses lowercase letter wire codes onto HID page 7` fails: `KeyboardKey.from is not a member`").

Only after step 4 may you write code under `Sources/`. Pure docs / CHANGELOG edits and Resources/Web/ JS tweaks are exempt; the moment a Domain type, Infrastructure adapter, or App command changes, the gate applies.

**Coverage target: ~100% of Domain + Infrastructure adapter code that doesn't touch private SimulatorKit / CoreSimulator / AccessibilityPlatformTranslation symbols directly.** Adapters that DO touch those frameworks are split: error-path branches (host nil, device not booted, `alreadyStarted`, idempotent `stop`, etc.) are unit-tested via `@Mockable` ports; the actual private-API call path is integration-only — manually smoke-tested against a booted simulator. New code must include the unit-testable portion.

**If you skip the gate, you are violating the project's primary rule.** The Chicago-school workflow, value-type domain, and `@Mockable` port pattern are described in [Testing approach](#testing-approach).

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

**TDD first.** Write the failing test before the implementation — every behaviour change to a Domain or Infrastructure type starts with a red `@Test`, then the smallest impl that turns it green, then refactor. Don't ship parser / aggregate / serialization changes ahead of their tests, even when "obvious"; the codebase's confidence rests on the test suite covering each new field at the moment it lands. JS modules under `Resources/Web/` have no test harness — keep their changes minimal and exercise them through the Swift layer that produces their JSON inputs.

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
