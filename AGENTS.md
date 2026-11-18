# AGENTS.md

Guidance for every coding agent working in this repository (Claude Code reads this file too). It holds the rules that apply to every task; everything else is one link away, loaded only when relevant.

## TDD is non-negotiable (read this first)

**You MUST write a failing test before writing any production code.** This rule overrides every other instinct, including "the change is small", "it's just a one-liner", "I'll add the test after". If you catch yourself opening a file under `Sources/` before a test under `Tests/BaguetteTests/` exists and fails, stop and reverse course.

**Pre-implementation gate** — before editing anything in `Sources/` (a value, role, adapter, command or route), you must have done all of the following in order:

1. Stated the user-facing behaviour in one sentence using **domain language**, shaped `should <outcome> [when <situation>]`. Good: "should land a tap on the simulator as a finger down, hold and up", "should describe no UI when no app is frontmost". Bad: "IndigoHIDInput calls sendMouse twice" — an interaction, not a behaviour.
2. Written a `@Test` in `Tests/BaguetteTests/<same folder as the source>/<Suite>.swift` that asserts the expected outcome. **The step-1 sentence is the test name, verbatim** — no method/type names or mechanism verbs (`returns`, `fires`, `calls`); pair each happy path with its `when …` twin; rename old ones on touch. Prefer state assertions (`#expect(filter.argv == [...])`, `#expect(node.frame == ...)`) over interaction assertions. For `@Mockable` abstractions, use the auto-generated `MockXxx` (`given(input).tap(...).willReturn(true)`); plain test doubles backed by Mockable are the canonical mocking style — never mock the value type itself.
3. Run the test and **observed it fail** — `swift test --filter "<SuiteName>"` for the fastest loop. A compile error counts as red only when the failing symbol is the one the test names (`KeyboardKey.from(wireCode:)` doesn't exist yet); a generic build error somewhere else doesn't.
4. Reported the red result back to the user (one line is fine: "test `should map a letter key onto HID page 7` fails: `KeyboardKey.from is not a member`").

Only after step 4 may you write code under `Sources/`. Pure docs / CHANGELOG edits and Resources/Web/ JS tweaks are exempt; the moment a value, role, adapter, command or route changes, the gate applies.

### Naming the abstractions

Every `@Mockable protocol` in this codebase is named **for the role it plays in the domain**, never for its architectural pattern. Look at the existing list — `Simulators`, `Simulator`, `Touch`, `Screen`, `Stream`, `Accessibility`, `LogStream`, `DeviceHost`, `Chromes`. **The words "Port" / "Service" / "Manager" never appear**, and you're not adding them. If you find yourself reaching for `XxxPort` / `XxxService` / `XxxManager`, the abstraction isn't named yet — keep going until the noun describes what the thing *is* in the domain. "A subprocess" is fine; "a log process port" is not.

**Repository is the one carve-out — but only for aggregate CRUD, and only spelled as the collection noun.** When the protocol genuinely *is* a DDD collection-like interface for an aggregate root (load / save / delete by identity), it takes the **plural of the aggregate** — `Simulators`, `Chromes`, `Books`, `Orders` — exactly as the existing aggregates already do. The suffix `XxxRepository` is still banned; the *role* (aggregate persistence) is the legitimate case the plural-noun convention already covers. If your protocol isn't aggregate persistence (it's an adapter, an event source, a process boundary, …), the carve-out doesn't apply — pick a role-noun like `Subprocess` / `LogStream` instead.

### Splitting an adapter that wraps 3rd-party I/O

When an adapter in `Internal/` wraps a private framework or external I/O (private SimulatorKit / CoreSimulator / AccessibilityPlatformTranslation symbols, `Foundation.Process`, `Pipe`, `dlopen`, …), the file gets two responsibilities:

- **What it does** — the value-domain orchestration (state transitions, recursion, byte-to-line splitting, frame projection, error mapping). This MUST be unit-tested.
- **How it talks to the outside** — the irreducible private-API call (`dlopen`, `class_getMethodImplementation`, `Process.run`, `kill(pid)`). This is integration-only.

Always separate the two. Two patterns, picked by the **shape of the irreducible call**:

1. **One-shot fetch** — the adapter makes a single private-API call, then operates on the value it gets back (e.g. `AXPTranslator.frontmostApplicationWithDisplayId:` returns one `AXPMacPlatformElement`, then we walk it). Lift the post-fetch logic into a **pure static factory or value type beside its ability** (`AXNode.walk(from:transform:)`, `AXFrameTransform.map(_:)`, `LineBuffer`). Drive it directly with `Fake…` `NSObject` subclasses that override KVC. The Infrastructure adapter shrinks to "make the call, hand the result to the static factory." No new abstraction needed.

2. **Conversational I/O** — the adapter talks back-and-forth with the outside (start / stream-bytes / signal-exit / terminate). Pure helpers don't capture the state machine cleanly. Introduce **one small `@Mockable` collaborator named like a domain noun** (`Subprocess`, never `LogProcessPort`) — start / terminate / `onBytes` / `onExit`. The orchestrator depends on `any Subprocess`; tests inject `MockSubprocess` and drive the state machine deterministically. The concrete impl (`HostSubprocess`) is a thin wrapper over `Foundation.Process` (~30 LOC) — integration-only.

The naming bar is the same for both: **collaborators are domain nouns, never pattern labels**. If the noun isn't obvious, the abstraction probably shouldn't exist yet.

### Coverage target

**~100% of the device model.** Every value type, every static factory, every `@Mockable` collaborator's behaviour-spec is covered.

**Adapters split as above.** The orchestrator is unit-tested via the collaborator's `MockXxx`; only the irreducible call lines stay uncovered — in `AXPTranslatorAccessibility` the four-line `dlopen` → `frontmostApplicationWithDisplayId:` dance, in `SimDeviceLogStream` just `Process.run` + `kill(pid)`. New code includes its unit-testable portion before it lands.

**Skipping the gate violates the project's primary rule.** The Chicago-school workflow is under [Testing approach](#testing-approach).

## Build & test

```bash
swift build                                        # debug build (carries MOCKING flag + mocks)
swift test --filter "<SuiteName>"                  # the fastest red/green loop
swift test                                         # the whole Swift Testing suite, no booted sim required
make test-web                                      # Resources/Web/ unit tests (node --test)
```

Every other target (`make`, `make docs`, `make check-docs`, …) and the toolchain requirement are in [CONTRIBUTING.md](CONTRIBUTING.md#build--test). Tests use **Swift Testing** (`@Suite`, `@Test`, `#expect`) — never XCTest. `MOCKING` is `.debug`-only so release builds carry no mock code (don't reach for `MockXxx` outside the test target).

## Architecture

Imports flow inward, outside in: `Sources/Commands/` (the CLI) and `Sources/Server/` (`baguette serve`) → `Devices/{Simulator,iPhone,CompanionPhone}` + `Plugins/{Plugin,Bakery}` → `Device/` (`BaguetteDevice`: id, kind, power, `Chrome/`, `Abilities/<ability>/`), which imports nothing of ours. Each folder's public face is at its top, its implementations in `Internal/`. Device families never import each other → [devices](docs/features/devices/design.md). `Tests/BaguetteTests/` mirrors `Sources/`. `Sources/Baguette/` holds `@main` and `Resources/Web/`, the page's vanilla IIFE modules.

**Two consumers, one pipeline.** Both `baguette input` (stdin JSON, used by host plugins as a long-lived subprocess) and `baguette serve` (browser WS) funnel into the same `GestureDispatcher` → the gesture's role (`Touch`, `Key`, …) → `IndigoHIDInput`. The only difference is the App-layer entry point.

### The crucial detail: 9-arg `IndigoHIDMessageForMouseNSEvent`

iOS 26 changed `SimulatorHID`'s wire format. The 5-arg signature used by `idb` / `AXe` routes to a pointer service that drops messages or crashes `backboardd`. Baguette uses the **9-arg signature from Xcode 26's preview-kit**, which routes to digitizer target `0x32`. The recipe lives in `Sources/Devices/Simulator/Internal/Input/IndigoHIDInput.swift` (heavily commented).

`IndigoHIDMessageForMouseNSEvent` reads AppKit / NSEvent thread-local state, so it **must build on the main thread**; elsewhere its messages are malformed and silently dropped. `IndigoHIDInput` hops there for the build alone; gestures run on their device's `GestureQueues` lane. Buttons (`IndigoHIDMessageForButton`) are pure C and thread-safe — useful as a sanity check when input fails.

**Coordinates.** Wire coordinates (`x`, `y`, `startX`, `x1`, `cx`, …) are **device points**, the units of the `width` / `height` every gesture envelope carries — never normalized. The browser normalizes internally and `sim-stream.js` multiplies back before sending; `IndigoHIDInput.sendMouse` divides by size before the C call.

## Testing approach

Chicago-school state-based throughout. Every external boundary is an `@Mockable` protocol; tests substitute auto-generated `MockXxx` fakes and assert on returned values rather than recorded calls. Patterns:

- Pure parsers (`DeviceChrome`, `DeviceProfile`, `ReconfigParser`, `GestureRegistry`) — feed JSON / plist, assert parsed value.
- Per-gesture parse + execute — verify the wire parses to the right act and `execute(on:)` calls its role's mock.
- Aggregate semantics — drive `MockSimulators` / `MockChromes` through default-impl computed properties (`running`, `available`, `listJSON`).

## Known limits

One line each; the research behind every line is in the linked `design.md`. Read it before touching that path.

- **Xcode 27's Device Hub shadows the legacy input surface.** `baguette boot` / `heal` repair it with `notifyutil -s … 0` *then* a backboardd kickstart, in that order; don't try to prevent it during boot (#77) → [device-hub](docs/features/device-hub/design.md)
- **A HID target is only a constant some create-service message registered, never computed.** An unknown target kills backboardd; `IndigoHIDTargetForScreen` is a trap → [companion-screens](docs/features/companion-screens/design.md)
- **iPhone Duo: the hinge decides which of two panels is lit.** `0x32` is a slot, not the cover; never power a screen off; its keys go through `dtuhidd`, not Indigo → [iphone-duo](docs/features/iphone-duo/design.md), [hinge](docs/features/hinge/design.md)
- **`key` / `type` are US-ASCII only** (HID page 7); anything else goes through `paste` → [keyboard](docs/features/keyboard/design.md)
- **`siri` crashes backboardd** via every known Indigo path; it is rejected → [buttons](docs/features/buttons/design.md)
- **`touch1-*` pinches read as a pan** to `UIPinchGestureRecognizer`; use `touch2-*` → [touches](docs/features/touches/design.md)
- **`CLHeading` is unavailable**; only `CLLocation.course` is drivable, and it skews on diagonal bearings. Keep positions truthful; don't "fix" the course → [location](docs/features/location/design.md)
- **CoreMotion is reachable only by injection**, so only apps launched after arming see it → [motion](docs/features/motion/design.md)

## When you are…

- **moving a domain rule** → [CANONICAL_MODEL](docs/CANONICAL_MODEL.md)
- **adding a feature** (gesture, route, verb, stream, web UI) → the `baguette-implement-feature` skill
- **changing a route or the gesture wire** → [docs/serve.md](docs/serve.md), [docs/wire.md](docs/wire.md)
- **touching docs** → [docs/documentation-design/](docs/documentation-design/README.md)
- **following a tap end to end** → [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); the 9-arg recipe is in `Sources/Devices/Simulator/Internal/Input/IndigoHIDInput.swift`
