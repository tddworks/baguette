# Rich domain model patterns (baguette)

baguette's domain layer is value types plus `@Mockable` roles, one folder
per bounded context (`Domain/<Context>/`; the contexts, the tree and every
law's owner are in [CANONICAL_MODEL.md](../../../../docs/CANONICAL_MODEL.md)).
Its patterns, each below:

1. **The aggregate hands out roles**: `Simulator` is the root; callers ask it.
2. **A law lives on the node that holds its data**: callers ask, never decide.
3. **Rich values own their behaviour**, so the adapter stays a wire emitter.
4. **Every state is a case; invalid input never constructs.**
5. **A gesture parses itself and acts in one line**: `parse` then `execute(on:)`.
6. **A Domain decorator may wrap a role** when it owns a rule.

Every `@Mockable protocol` is named for its domain role (`Touch`, `Screen`,
`Hinge`, `Subprocess`), never `XxxPort` / `XxxService` / `XxxManager`.
**Aggregate CRUD is the one carve-out**: the plural collection noun
(`Simulators`, `Chromes`), never the suffix `XxxRepository`.

## 1. The aggregate hands out roles

`Simulator` is the aggregate root: a `@Mockable protocol` whose requirements
are the device's facts (`udid`, `state`, `deviceTypeName`), its commands
(`boot`, `shutdown`), and **factories for its roles** (`input()`, `hinge()`,
`displays()`, `accessibility()`, `defaults()`, …). The one adapter,
`CoreSimulator`, builds the Infrastructure behind each role.

```swift
// ✅ The caller asks the aggregate for the role it needs.
let pose = try sim.hinge().fold(to: 130, over: 0.8)
let input = sim.litPanelInput()

// ❌ The caller builds an adapter, or composes domain objects itself.
let surface = SimctlInputSurface()                    // App reaching into Infrastructure
let input = LitPanelInput(cover: …, unfolded: …, …)   // Server deciding the domain
```

Rules that need several roles live as **extension methods on the protocol**,
so they're tested against `MockSimulator` with no device:

```swift
extension Simulator {
    var canAcceptInput: Bool { state == .booted }

    func litPanel(in chromes: any Chromes) -> IntegratedPanel {
        guard chromes.panels(forDeviceName: deviceTypeName).contains(.secondary) else {
            return .primary       // one panel: never ask the hinge (a guest round trip)
        }
        return hinge().litPanel
    }
}
```

A new role is a new factory on `Simulator` and a new `@Mockable` protocol in
its context. The App layer parses and calls; `Server` transports. Neither
builds adapters or decides which composition of roles a use needs.

## 2. A law lives on the node that holds its data

If a rule reads one node's data, it is a computed property or method **on that
node**. Callers ask; they never read the state and decide.

```swift
extension Hinge {
    /// No reading means as booted, folded, so the cover. The one place that rule lives.
    var litPanel: IntegratedPanel { angle()?.litPanel ?? .primary }
}

// ❌ the same rule at a call site is a second owner, and they drift
let lit = sim.hinge().angle()?.litPanel ?? .primary
```

The smell is a `?? default`, an `if x.count > …`, or a `switch` over another
type's state at a call site. Grep for the rule before writing it: if it's
already somewhere, that is the owner. Each law and its owner is a row in
CANONICAL_MODEL §3.

## 3. Rich values own their behaviour

The value owns its identity and its behaviour against the role it dispatches
into. `DeviceButton` and `KeyboardKey` are the canonical examples:

```swift
/// What `press` presses: a navigation the system performs, or a button on
/// the device's body. Each device lists which it has (`Press.available`).
enum DeviceButton: Hashable, Sendable {
    case navigation(Navigation)        // home, app-switcher, the edge pulls, …
    case hardware(HardwareButton)      // lock, power, volume, action, the watch's
}

extension HardwareButton {
    /// Domain knowledge on the type, not in the adapter.
    var standardHIDUsage: HIDUsage? {
        switch self {
        case .lock:       return nil   // a button message of its own
        case .power:      return HIDUsage(page: 12, usage: 48)
        case .volumeUp:   return HIDUsage(page: 12, usage: 233)
        case .volumeDown: return HIDUsage(page: 12, usage: 234)
        case .action:     return HIDUsage(page: 11, usage: 45)
        // … the watch buttons carry their chrome.json codes.
        // `siri` is absent on purpose: every known path crashes backboardd.
        }
    }

    /// Tell, don't ask: the caller says "press this button"; the adapter
    /// picks the SimulatorKit symbol.
    @discardableResult
    func press(duration: Double = 0, on buttons: any Press) -> Bool {
        buttons.button(self, duration: duration)
    }
}
```

- The adapter (`IndigoHIDInput`) stays SRP-clean: "given a `DeviceButton`,
  route to the right symbol". No chrome lookups, no per-call resolution.
- Tests live on the value: every button's usage is covered without a sim.
- **What differs between devices is data**: a usage table, a profile's
  panels, a chrome. Never `if deviceTypeName == "iPhone Duo"`, never a
  subclass per device. A foldable's keys are a table in
  `FoldableInput.key(for:)`.

`KeyboardKey` has the same shape as a struct, because its set is large:
`from(wireCode:)`, `decompose(character:)`, `press(modifiers:duration:on:)`.

## 4. Every state is a case; invalid input never constructs

Each state a user can meet is a case carrying its data, and one value never
means two things. Asking a value for a `Bool` and then guessing what `false`
meant is the smell.

| Value | Its cases | Why it isn't a `Bool` or an optional |
|---|---|---|
| `PoseDelivery` | `delivered` · `rejected` · `unconfirmed` | a timed-out fold may have landed, so exit 3, not 1 |
| `InterfaceReading` / `ContentSize` | a value · `unknown` · `unsupported` | not booted and not supported are answers, not errors |
| `Relaunch` | `never` · `always` · `whenNeeded` | a running app may not see a write; the user picks |

A value that can be invalid refuses at construction, so nothing downstream
re-checks it: a failable `init?` when there's one way to be wrong, a throwing
`parse` with a named reason when there are several.

```swift
Coordinate(latitude: 91, longitude: 0)          // nil: out of range
LocationRoute(waypoints: [one], …)              // nil: a route needs two points
try HingeCommand.parse(pose: "ajar", angle: nil, duration: nil)   // throws HingeCommandError
```

## 5. A gesture parses itself and acts in one line

baguette has no DTOs: a `Tap` or a `ButtonPress` *is* the domain concept, and it
reads itself from the wire (`parse`) and acts on the role (`execute(on:)`).
Its rules live on the rich value it carries, so `execute` stays one line.

```swift
struct ButtonPress: Gesture, Equatable {
    static let wireType = "button"
    let button: DeviceButton
    let duration: Double

    static func parse(_ dict: [String: Any]) throws -> ButtonPress {
        let raw = try Field.requiredString(dict, "button")
        guard let button = DeviceButton(rawValue: raw) else {
            throw GestureError.invalidValue("button", expected: allowed)
        }
        return ButtonPress(button: button, duration: Field.optionalDouble(dict, "duration", default: 0))
    }

    static var ability: Ability<any Press> { .press }

    func execute(on buttons: any Press) -> Bool {
        button.press(duration: duration, on: buttons)   // ← one line
    }
}
```

- `parse` uses the `Field.required*` / `optional*` extractors; never
  open-code `dict["…"] as? Double`.
- An unknown value is a `GestureError` with the allowed set, never a silent
  fallback.
- An `if` inside `execute` means a rule is missing on the rich value.

## 6. A Domain decorator may wrap a role

`IndigoHIDInput` is the simulator's only input adapter, playing all four
roles (its `HID`); tests mock the role they test (`MockTouch`, `MockKey`, …).
Don't add a parallel hierarchy for testability. But a **Domain** type that
wraps a simulator's `HID` to own a rule is the right shape, composed by the
aggregate:

| Decorator | The rule it owns |
|---|---|
| `FoldableInput` | a foldable's keys, hardware and keyboard, go through the guest (`DeviceKeys`), not Indigo |
| `LitPanelInput` | on a socket that outlives a fold, each gesture goes to the lit panel; a touch stays on its digitizer until it lifts |

A decorator forwards everything else unchanged, holds roles not adapters
(`any HID`, `any Hinge`), and is built by a `Simulator` factory, not by
`Server`.

## struct vs class

A type is a `final class` when it owns **at least one** of these; otherwise
it's a `struct` or an `enum`:

1. **A resource released exactly once**: a `dlopen` handle, lock, file
   descriptor, socket, ObjC instance, VideoToolbox session.
2. **Mutable state several owners must see**: a cache, a connection table,
   a subscriber list.
3. **Identity that matters** (`===`): "the shared motor for this device".
4. **State that changes across calls behind a role whose methods aren't
   `mutating`**: `LitPanelInput` remembers the panel a touch went down on;
   `InputScreenGuard` its last observation. Keep that state small, behind a
   lock, and the type's surface the role's verbs.

| Type | Why it's a class |
|---|---|
| `Server` | NIO event loop and router state (1, 2) |
| `IndigoHIDInput` | `dlopen`'d functions, HID client, lock, warm-up cache (1, 2) |
| `CoreSimulators` · `CoreSimulator` | resolved device handles, lazy framework load (1, 2) |
| `SharedHinge` · `GuestHingeMotor` | one per device, shared by every caller (2, 3) |
| `LitPanelInput` | a touch's panel across calls (4) |

Domain **values** fail all four (`DeviceButton`, `KeyboardKey`, `HIDUsage`,
the gestures, `HingeAngle`, `DeviceChrome`) and stay structs and enums:
declare `Equatable` and the compiler writes `==`; `Sendable` is checked from
the stored properties instead of `@unchecked`; mutation is visible
(`mutating`, `var`); and there's no subclassing temptation. Before reaching for `final class` on a
domain type, name the resource, the second owner, the `===` test, or the
state that changes across calls. If you can't, it's a struct.

`Simulator` is a protocol, so the question is its adapter's: the live device
handle makes `CoreSimulator` a class, while the values it answers (`state`,
`metadata`, `SimulatorDefinition`) are structs.

## Anti-patterns

- **A rule at the call site**: `?? .primary`, a count check, a `switch` on
  another type's state. Move it to the node that holds the data.
- **The App or `Server` building adapters or composing roles**: ask the
  `Simulator` for a role; add a factory if there isn't one.
- **Domain reaching outward**: a Domain type importing an Infrastructure
  type (`MJPEGStream`, `FrameSink`) or calling the App's `log(…)`. Domain
  depends only on Foundation and IOSurface; a failure is its return value.
- **A `Bool` flag the caller decides, or an optional meaning two things**:
  name the cases.
- **Service objects with no state**: `OrderService.cancel(order)` belongs
  on the value (`order.cancel()`).
- **Pure data bags**: a domain `struct` with no methods is missing its
  behaviour.
- **A device-name branch**: make the difference data.
- **Async/await in the input path**: the HID API is synchronous and the wire
  is request/ack. A device's gestures run on its `GestureQueues` lane; the
  only main-thread hop is `IndigoHIDInput`'s, for each message build.

## Adding a domain type — checklist

1. Name its context (CANONICAL §5) and create it in `Domain/<Context>/`.
2. Name the laws it owns (CANONICAL §3). Grep for each: if it already lives
   elsewhere, that's the owner, or the duplicate to remove.
3. A value: `struct` or `enum`, `Equatable, Sendable`, invalid input refused
   in `init` / `parse`, every user-visible state a case.
4. Behaviour on the value: computed properties, and a verb
   (`press` · `apply` · `deliver`) that takes the role it acts on and
   forwards in one line.
5. A role for the outside world: a `@Mockable` protocol named for the role,
   handed out by a `Simulator` factory, implemented in `Infrastructure/<Context>/`.
6. A wire envelope: a sibling `Gesture` (or `parse(json:)`) with `parse`
   plus a one-line `execute`, registered on `GestureRegistry.standard`.
7. Tests in `Tests/BaguetteTests/<Context>/`, named `should <outcome> [when
   <situation>]`, Swift Testing only, every branch covered without a sim.
