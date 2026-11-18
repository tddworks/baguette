# TDD test patterns (baguette)

baguette uses **Chicago school** state-based TDD with
**Swift Testing** — never XCTest. Tests live in `Tests/BaguetteTests/`,
mirroring the Domain/Infrastructure split. The full suite runs in
~50 ms with no booted simulator required (the private SimulatorKit
boundary lives behind `@Mockable`).

## Why Chicago school here

| Chicago school (baguette uses)        | London school (avoid)                    |
|---------------------------------------|------------------------------------------|
| Test state changes and return values  | Test interactions between objects        |
| Mocks stub data, not verify calls     | Mocks verify method calls were made      |
| Focus on "what" (outcomes)            | Focus on "how" (call sequences)          |
| Design emerges from tests             | Design upfront, tests verify design      |

AGENTS.md is explicit: *"Chicago-school state-based throughout. Every
external boundary is an `@Mockable` protocol; tests substitute
auto-generated `MockXxx` fakes and assert on returned values rather
than recorded calls."* When you do call `verify(...)`, it's the
exception (e.g. confirming a dispatch reached the right port method),
not the rule.

## Swift Testing essentials

```swift
import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("HardwareButton")
struct HardwareButtonTests {
    @Test func `should give the arbitrary-HID buttons their iPhone-family codes`() {
        #expect(HardwareButton.power.standardHIDUsage      == HIDUsage(page: 12, usage: 48))
        #expect(HardwareButton.volumeUp.standardHIDUsage   == HIDUsage(page: 12, usage: 233))
        #expect(HardwareButton.volumeDown.standardHIDUsage == HIDUsage(page: 12, usage: 234))
        #expect(HardwareButton.action.standardHIDUsage     == HIDUsage(page: 11, usage: 45))
    }

    @Test func `should give lock no standard HID usage, as it is a button message of its own`() {
        #expect(HardwareButton.lock.standardHIDUsage == nil)
    }
}
```

Conventions:

- `@Suite("<Type>")` — name matches the type or feature under test.
- Test names are **business specs**: the gate's step-1 sentence,
  verbatim — see [Naming tests](#naming-tests).
- `#expect(...)` for assertions. `try #require(...)` to unwrap
  optionals before further assertions.
- Tests are tiny and direct. No setup helpers unless 3+ tests share
  the exact same fixture.

## Naming tests

A test name is the behaviour sentence from the AGENTS.md gate
(step 1), copied verbatim into a backtick identifier:

```
should <outcome the agent / simulator / app / viewer / plugin observes> [when <domain situation>]
```

- **Say what the business gets, not which code runs.** The actors
  are the people and things baguette serves — the agent driving the
  sim, the simulator, the app on screen, the browser viewer, a
  plugin. The name never contains a method or type name
  (`makeStream`, `applyShake`, `onLine`), a wire-field spelling
  (`camera_list`), or a mechanism verb (`returns`, `fires`,
  `executes`, `calls`, `parses`).
- **The `when` is a fact about the world**, not a code path:
  "when the simulator isn't booted", not "when `find` returns nil".
- **Pair every happy path with its counterpart.** "should stream
  frames to the viewer" travels with "should stream nothing when the
  simulator isn't booted".
- **The body follows the sentence**: arrange the situation (stubs on
  `MockXxx`), do one thing through the public surface, assert the
  outcome. Reach for `verify(...)` only when the side effect *is* the
  outcome ("should press the home button" → the `button` call), and
  `.called(0)` for "should … nothing".

| Mechanism-shaped (avoid)                                  | Business-shaped                                                          |
|-----------------------------------------------------------|--------------------------------------------------------------------------|
| `executes against the input surface`                      | `should press the home button on the simulator`                          |
| `rejects unknown button`                                  | `should refuse a button the simulator doesn't have`                      |
| `makeStream returns AVCCStream for avcc`                  | `should stream H.264 access units when the viewer asks for avcc`         |
| `applyShake reports unknownDevice when the simulator can't be found` | `should tell the agent the device is unknown when shaking a simulator that isn't there` |
| `single line in one chunk fires onLine once`              | `should deliver a log line as soon as its newline arrives`               |

Older tests predate this rule. Rename one to this shape when you
touch it; don't sweep files you aren't otherwise changing.

## Per-gesture parse + execute pattern

Every gesture's tests cover BOTH wire parsing AND port dispatch:

```swift
@Suite("Press")
struct PressTests {
    @Test func `should accept a home button press`() throws {
        let g = try Press.parse(["button": "home"])
        #expect(g == Press(button: .home))
    }

    @Test func `should hold the button for the duration asked`() throws {
        let g = try Press.parse(["button": "action", "duration": 1.2])
        #expect(g.duration == 1.2)
    }

    @Test func `should refuse a button the simulator doesn't have`() {
        #expect(throws: GestureError.invalidValue(
            "button",
            expected: "home | lock | power | volume-up | volume-down | action"
        )) {
            try ButtonPress.parse(["button": "siri"])
        }
    }

    @Test func `should press the home button on the simulator`() {
        let buttons = MockPress()
        given(buttons).button(.any, duration: .any).willReturn(true)

        _ = ButtonPress(button: .home).execute(on: buttons)
        verify(buttons).button(.value(.home), duration: .value(0)).called(1)
    }
}
```

Notes:

- Parse tests build a `[String: Any]` dict and call `ButtonPress.parse(...)`
  directly — no JSON round-trip, the registry already covers that.
- Reject tests pin the exact `GestureError` (matters for the wire
  ack the user sees: `{"ok":false,"error":"<message>"}`).
- Execute tests are the ONE place we use `verify(...)`. The point is
  "did the gesture call the right port method?" — pure dispatch
  confirmation. State-based assertions on the returned `Bool` are
  also welcome.

## Mockable cheatsheet

```swift
let touch = MockTouch()

// Stub a return value (Chicago school: data, not call counts).
given(touch).tap(at: .any, size: .any, duration: .any).willReturn(true)
given(input).button(.any, duration: .any).willReturn(true)
given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

// Stub a specific value to trigger a specific return.
given(input).button(.value(.lock), duration: .any).willReturn(false)

// Verify (exception, not rule — only for dispatch confirmation).
verify(input).button(.value(.power), duration: .value(2.0)).called(1)
verify(input).key(.any, modifiers: .value([.shift]), duration: .any).called(1)
```

Matchers:

- `.any` — anything goes.
- `.value(x)` — must equal `x` (the type must be `Equatable`).
- For sets / collections, pass the literal you expect; mockable
  uses Equatable semantics.

## What NOT to test

- **`IndigoHIDInput` end-to-end.** It crosses into private
  SimulatorKit; covering it requires a booted sim and isn't part
  of `swift test`. Trust the Mockable boundary.
- **The `MOCKING` flag itself.** It's `.debug`-only; tests run in
  debug, so `MockTouch`, `MockPress`, `MockKey` and `MockScroll` are always available. Don't write tests that
  assert build conditionals.
- **Hand-rolled mocks.** `@Mockable` generates them; if a port
  changes, regenerate by rebuilding rather than editing fakes.

## Patterns by context (where to mirror)

| You're testing                | Existing template to follow                                |
|-------------------------------|------------------------------------------------------------|
| Pure parsers                  | `DeviceChromeTests`, `DeviceProfileTests`, `ReconfigParser*` |
| Per-gesture parse + execute   | `PressTests`, `KeyGestureTests`, `TypeTextGestureTests`     |
| Aggregate semantics           | `SimulatorsTests` (drives `running` / `available` via Mock) |
| Wire envelope round-trip      | `MJPEGEnvelopeTests`                                        |
| Server route handlers         | `BezelRoutesTests`, `Server bezel + chrome-button routes`   |
| Stream pipeline               | `StreamFormatTests`, `MJPEGStream` / `AVCCStream` suites    |

When adding a new context, scan the closest existing suite and
match its rhythm. The codebase's confidence rests on uniform test
shape — a new suite that invents its own conventions makes the next
maintainer slower.

## Running tests

```bash
swift test                                       # full suite (~50 ms, ~245 tests)
swift test --filter DeviceButton                 # one suite by name
swift test --filter "GestureRegistry/should accept a tap" # one test
```

Run after every red→green cycle. The suite is fast enough that
"run once at the end" wastes feedback — keep `swift test --filter`
in your loop.
