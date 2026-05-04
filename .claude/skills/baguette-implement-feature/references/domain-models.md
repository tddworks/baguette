# Rich domain model patterns (baguette)

baguette's domain layer is a small set of value types + `@Mockable`
ports, organised by bounded context (`Domain/Input/`, `Domain/Screen/`,
`Domain/Stream/`, `Domain/Chrome/`, `Domain/Simulator/`). The two
recurring patterns: **rich values that own their behaviour** (so the
adapter stays a dumb wire emitter) and **wire DTOs with a one-line
`execute(on:)`** (so dispatch logic stays tested at the value level).

## Rich-value pattern

The value owns BOTH its identity AND the behaviour against the port.
`DeviceButton` and `KeyboardKey` are the canonical examples:

```swift
enum DeviceButton: String, Sendable, Equatable, Hashable {
    case home, lock
    case power, action
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
}

extension DeviceButton {
    /// Standard HID code for arbitrary-HID side buttons.
    /// Domain knowledge baked into the type — not in the adapter.
    var standardHIDUsage: HIDUsage? {
        switch self {
        case .home, .lock: return nil
        case .power:      return HIDUsage(page: 12, usage: 48)
        case .volumeUp:   return HIDUsage(page: 12, usage: 233)
        case .volumeDown: return HIDUsage(page: 12, usage: 234)
        case .action:     return HIDUsage(page: 11, usage: 45)
        }
    }

    /// Tell-don't-ask: the caller doesn't decide whether to route
    /// through legacy `*ForButton` or `*ForHIDArbitrary`; the adapter
    /// does, but the API surface stays "press this button."
    @discardableResult
    func press(duration: Double = 0, on input: any Input) -> Bool {
        input.button(self, duration: duration)
    }
}
```

Why this shape:

- The adapter (`IndigoHIDInput`) remains SRP-clean: it only knows
  "given a `DeviceButton`, route to the right SimulatorKit symbol."
  No chrome lookups, no per-call HID resolution at the wire.
- Tests live on the value, not on the service. `swift test` covers
  every button's `standardHIDUsage` without a booted sim.
- Adding a new device-specific code is one switch case, not a new
  adapter abstraction.

`KeyboardKey` follows the same shape with a value-typed struct
because the supported set is much larger:

```swift
struct KeyboardKey: Equatable, Hashable, Sendable {
    let hidUsage: HIDUsage

    static func from(wireCode: String) -> KeyboardKey? { … }
    static func decompose(character: Character) -> (key: KeyboardKey, modifiers: Set<KeyModifier>)? { … }

    @discardableResult
    func press(modifiers: Set<KeyModifier> = [], duration: Double = 0, on input: any Input) -> Bool {
        input.key(self, modifiers: modifiers, duration: duration)
    }
}
```

## Gesture (wire DTO) pattern

Gestures parse from JSON and delegate execution one line deep to the
rich-value method. They are NOT where domain logic lives — they're
just the wire envelope.

```swift
struct Press: Gesture, Equatable {
    static let wireType = "button"
    static let allowed = "home | lock | power | volume-up | volume-down | action"

    let button: DeviceButton
    let duration: Double

    static func parse(_ dict: [String: Any]) throws -> Press {
        let raw = try Field.requiredString(dict, "button")
        guard let button = DeviceButton(rawValue: raw) else {
            throw GestureError.invalidValue("button", expected: allowed)
        }
        return Press(
            button: button,
            duration: Field.optionalDouble(dict, "duration", default: 0)
        )
    }

    func execute(on input: any Input) -> Bool {
        button.press(duration: duration, on: input)   // ← one line
    }
}
```

Watch the seams:

- `wireType` is the JSON `"type"` value the registry routes on.
- `parse` uses `Field.required*` / `optional*` extractors — never
  open-code `dict["…"] as? Double`.
- Errors are `GestureError.missingField` / `.invalidValue(_, expected:)`
  with a human-readable hint. Don't silently drop bad input.
- `execute` does not contain dispatch logic. If you find yourself
  writing `if/else` inside it, the rule is missing on the rich value.

## Port pattern (`@Mockable`)

The adapter boundary is a `@Mockable` protocol. Methods return `Bool`
synchronously — there are no async actors in the input path. The
existing port:

```swift
@Mockable
protocol Input: Sendable {
    func tap(at point: Point, size: Size, duration: Double) -> Bool
    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool
    func touch1(phase: GesturePhase, at point: Point, size: Size) -> Bool
    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool
    func button(_ button: DeviceButton, duration: Double) -> Bool
    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool
    func scroll(deltaX: Double, deltaY: Double) -> Bool
    func twoFingerPath(start1: Point, end1: Point, start2: Point, end2: Point,
                       size: Size, duration: Double) -> Bool
}
```

Notice:

- Each method is **one verb** the rich domain calls. No "perform"
  / "dispatch" / "do" generic methods — the verb names ARE the API.
- One concrete implementation: `IndigoHIDInput`. Don't introduce
  parallel hierarchies for testability — `MockInput` (auto-generated
  by `@Mockable`) is the test seam.
- All methods sync + `Bool`-returning. The async / actor patterns
  in other Swift codebases don't apply here; SimulatorKit's HID API
  is synchronous and the wire is request/ack.

## struct vs class — three-condition rule

A type should be a `final class` when it owns **at least one** of
these. Otherwise it's a `struct` (or `enum`).

1. **Non-trivial deinit responsibility** — a resource that must be
   released exactly once: `dlopen` handle, lock, file descriptor,
   socket, NIO event loop, ObjC instance, VideoToolbox session.
2. **Mutable state observed from multiple owners simultaneously** —
   when A holds a reference and mutates, B (also holding it) must
   see the change. Caches, connection tables, request queues.
3. **Identity tested with `===`** — "is this *the same instance*"
   is a domain question, not just "are these values equal."

baguette's class boundaries each satisfy at least one condition:

| Type             | Why it's a class                                  |
|------------------|---------------------------------------------------|
| `Server`         | NIO event loop + router state (1, 2)              |
| `IndigoHIDInput` | dlopen'd fns + SimDeviceLegacyHIDClient + lock + warmup cache (1, 2) |
| `CoreSimulators` | resolved-device cache, lazy framework load (2)    |
| `LiveChromes`    | chrome cache + lock (1, 2)                        |
| `H264Encoder`    | VTCompressionSession + frame queue + lock (1, 2)  |

baguette's domain values fail all three:

| Type           | Resource? | Multi-owner mutation? | Identity? | Verdict |
|----------------|-----------|-----------------------|-----------|---------|
| `DeviceButton` | no        | no                    | no        | enum    |
| `KeyboardKey`  | no        | no                    | no        | struct  |
| `HIDUsage`     | no        | no                    | no        | struct  |
| `Press` / `Tap` / `Swipe` / … | no | no            | no        | struct  |
| `DeviceChrome` / `ChromeButton` | no | no            | no        | struct  |
| `Simulator`    | no        | no (snapshot value)   | UDID is a field, not `===` | struct |

### The "but DDD says entities are classes" objection

The classical DDD argument: *"`Simulator` has a UDID, two with the
same UDID are the same → identity → class."*

Look at what `Simulator` actually IS in baguette. It's a **snapshot**:
when `simulators.find(udid:)` returns a `Simulator`, you have a value
reflecting the device's state at that moment. Boot the device, then
re-read your local value — `state` still says `.shutdown`. Fresh
state requires re-querying the host (`CoreSimulators`, which IS a
class because it owns the live cache).

That's the right factoring: **the live entity is the host (class);
the value type is the snapshot (struct).** Same separation SwiftUI
uses (`@Observable class` for live state, plain structs for view
data) for the same reason. Making `Simulator` a class would force
you to answer "who keeps it fresh?" — either build a live-proxy
class with subscriptions / invalidation / threading, or accept a
stale class with all the class downsides and none of the upsides.

### Why structs are *also* the better default

Even where the rule is genuinely a coin-flip, structs win on
secondary criteria:

- **Sendable is free.** Pure-let structs of `Sendable` fields are
  automatically `Sendable`. Classes need explicit `final class … :
  Sendable` with all-immutable storage, or `@unchecked Sendable`
  annotations that the compiler can't verify.
- **Equality is unambiguous.** Structs use structural `==`; classes
  force a choice (identity? structural? mixed?) at every comparison
  site, adding cognitive load.
- **Mutation is visible.** A struct method that mutates must be
  `mutating`, and the caller must use `var`. Classes hide mutation
  behind ordinary calls — you can't tell `obj.foo()` mutates from
  the call site alone.
- **No subclassing temptation.** Open class hierarchies invite "I'll
  subclass to add a feature," which is almost always wrong in a
  domain layer (favour composition + protocols).

### Concrete contrast

```swift
// ✅ Right — struct, none of the three conditions met.
struct KeyboardKey: Equatable, Hashable, Sendable {
    let hidUsage: HIDUsage
    @discardableResult
    func press(modifiers: Set<KeyModifier> = [], duration: Double = 0,
               on input: any Input) -> Bool {
        input.key(self, modifiers: modifiers, duration: duration)
    }
}

// ❌ Wrong — final class with no reference-semantics need. Adds:
//   - explicit Sendable maintenance
//   - identity-vs-structural-equality choice at every == site
//   - heap allocation per parse + ARC retain/release per pass
//   - subclass temptation (even with `final`, defaulting to class
//     normalises class as the go-to)
//   …and gives back NOTHING the rich-domain pattern needs.
final class KeyboardKey: Sendable {
    let hidUsage: HIDUsage
    init(hidUsage: HIDUsage) { self.hidUsage = hidUsage }
    func press(modifiers: Set<KeyModifier> = [], duration: Double = 0,
               on input: any Input) -> Bool { … }
}
```

### The decision question

Before reaching for `final class` on a domain value, answer one of:

- "Which resource does it own that has a non-trivial deinit?"
- "Where in the system do two owners need to see the same mutations?"
- "Where in the codebase do we test `===` on it?"

If you can't answer any of them concretely, the type is a struct.

## Anti-patterns

- **Service objects with no state.** `OrderService.cancel(order)` is a
  smell — the operation belongs on the value (`order.cancel()`).
- **Domain types that are pure data bags.** If your `struct` has no
  methods, you're missing the rich-domain pattern; revisit which
  behaviour belongs to it.
- **`Press.execute` doing more than calling a rich method.** Means
  the dispatch decision should have moved up to the value. (The
  buttons feature evolved exactly this way: chrome-driven HID
  resolution lived briefly on the gesture, then moved to
  `DeviceButton.standardHIDUsage` where it belonged.)
- **Async/await in the input path.** None of the existing input
  surface is async. Don't introduce it; the wire is request/ack.

## Adding a value type — checklist

1. Create the type in `Domain/<Context>/<Name>.swift`. Make it
   `Equatable, Sendable`. Add `Hashable` only if a Set/Dict needs it.
2. Decide where domain knowledge lives — almost always on the value
   itself as computed properties or extension methods.
3. Add a `press` / `dispatch` / `apply` method (whichever verb fits)
   that takes `on input: any Input` and returns `Bool`. One line:
   forward to the matching `Input` port method.
4. If it parses from the wire, add a sibling `<Name>: Gesture` that
   wraps it with `parse` + `execute`. Register on
   `GestureRegistry.standard`.
5. Tests in `Tests/BaguetteTests/<Context>/`. Use Swift Testing
   `@Suite`/`@Test`/`#expect` (never XCTest). Test every branch of
   computed-property behaviour without booting a sim.
