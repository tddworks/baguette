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

CLAUDE.md is explicit: *"Chicago-school state-based throughout. Every
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

@Suite("DeviceButton")
struct DeviceButtonTests {
    @Test func `arbitrary-HID buttons carry standard iPhone-family codes`() {
        #expect(DeviceButton.power.standardHIDUsage      == HIDUsage(page: 12, usage: 48))
        #expect(DeviceButton.volumeUp.standardHIDUsage   == HIDUsage(page: 12, usage: 233))
        #expect(DeviceButton.volumeDown.standardHIDUsage == HIDUsage(page: 12, usage: 234))
        #expect(DeviceButton.action.standardHIDUsage     == HIDUsage(page: 11, usage: 45))
    }

    @Test func `home and lock have no standard HID usage`() {
        #expect(DeviceButton.home.standardHIDUsage == nil)
        #expect(DeviceButton.lock.standardHIDUsage == nil)
    }
}
```

Conventions:

- `@Suite("<Type>")` — name matches the type or feature under test.
- Test names use **backtick-quoted sentences** in present tense
  describing the observable outcome — `parses lowercase letter
  codes`, `home and lock have no standard HID usage`. Read like
  spec lines.
- `#expect(...)` for assertions. `try #require(...)` to unwrap
  optionals before further assertions.
- Tests are tiny and direct. No setup helpers unless 3+ tests share
  the exact same fixture.

## Per-gesture parse + execute pattern

Every gesture's tests cover BOTH wire parsing AND port dispatch:

```swift
@Suite("Press")
struct PressTests {
    @Test func `parses home button`() throws {
        let g = try Press.parse(["button": "home"])
        #expect(g == Press(button: .home))
    }

    @Test func `parses optional duration`() throws {
        let g = try Press.parse(["button": "action", "duration": 1.2])
        #expect(g.duration == 1.2)
    }

    @Test func `rejects unknown button`() {
        #expect(throws: GestureError.invalidValue(
            "button",
            expected: "home | lock | power | volume-up | volume-down | action"
        )) {
            try Press.parse(["button": "siri"])
        }
    }

    @Test func `executes against the input surface`() {
        let input = MockInput()
        given(input).button(.any, duration: .any).willReturn(true)

        _ = Press(button: .home).execute(on: input)
        verify(input).button(.value(.home), duration: .value(0)).called(1)
    }
}
```

Notes:

- Parse tests build a `[String: Any]` dict and call `Press.parse(...)`
  directly — no JSON round-trip, the registry already covers that.
- Reject tests pin the exact `GestureError` (matters for the wire
  ack the user sees: `{"ok":false,"error":"<message>"}`).
- Execute tests are the ONE place we use `verify(...)`. The point is
  "did the gesture call the right port method?" — pure dispatch
  confirmation. State-based assertions on the returned `Bool` are
  also welcome.

## Mockable cheatsheet

```swift
let input = MockInput()

// Stub a return value (Chicago school: data, not call counts).
given(input).tap(at: .any, size: .any, duration: .any).willReturn(true)
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
  debug, so `MockInput` is always available. Don't write tests that
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
swift test --filter "GestureRegistry/parses tap" # one test
```

Run after every red→green cycle. The suite is fast enough that
"run once at the end" wastes feedback — keep `swift test --filter`
in your loop.
