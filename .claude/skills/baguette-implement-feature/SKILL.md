---
name: app-implement-feature
description: |
  Guide for implementing features in baguette — a Swift CLI + WebSocket server
  that drives iOS simulators (private SimulatorKit) and physical iPhones on a
  cable (private CoreDevice and the phone's own services). Use this skill when:
  (1) Adding a new gesture, button, keyboard surface, stream format, or
      device-chrome behaviour (anything that lands across Device/, Devices/,
      Commands/, Server/ + Resources/Web).
  (2) Extending an existing wire-protocol envelope, CLI subcommand, or HTTP route.
  (3) User asks "add feature X to baguette", "implement <gesture>", "wire <new
      verb> through serve / input / CLI", or similar.
  (4) Touching the iOS-26 SimulatorKit / IndigoHID surface, or CoreDevice /
      a phone's tunnel services — those edits MUST go through this skill's
      Architecture phase before code lands.
  Avoid using this skill for refactors that don't add a new feature (keep those
  TDD-driven without the architecture-approval gate).
---

# Implement a feature in baguette

baguette is a **CLI + WebSocket server**, not a SwiftUI app. There is no
ViewModel layer, no async actors in the input path — gestures are
synchronous `Bool`-returning calls into one of four `@Mockable` input
roles — `Touch`, `Press`, `Key`, `Scroll` — each a device ability.
A simulator's `IndigoHIDInput` plays all four (its `HID`); a phone on a
cable plays `Touch` only and registers nothing else. The frontend
is hand-written vanilla JS IIFEs (no bundler) that talk to the server
via one WebSocket per stream.

**Naming abstractions**: every `@Mockable protocol` in this codebase is
a **domain noun for the role it plays** — `Touch`, `Key`, `Screen`,
`Accessibility`, `LogStream`, `DeviceHost`, `Subprocess`, `Chromes`,
`Simulators`. The pattern-label suffixes **"Port" / "Service" /
"Manager" never appear**. If you reach for `XxxPort`, the abstraction
isn't named yet — keep going until the noun describes what the thing
*is* in the domain.

**Repository is allowed — but only for aggregate CRUD, and only
named as the collection noun.** A protocol that is genuinely a DDD
collection-like interface for an aggregate root (load / save / delete
by identity) takes the **plural of the aggregate** — `Simulators`,
`Chromes`, `Books`, `Orders` — not `BookRepository` / `OrderRepo`. The
suffix `Repository` is still banned; the *role* (aggregate persistence)
is the legitimate case the plural-noun convention already covers.
If your protocol isn't aggregate persistence (it's an adapter, an
event source, a process boundary, …), the repository carve-out
doesn't apply — pick a role-noun like `Subprocess` / `LogStream`
instead.

Read [`AGENTS.md`](../../../AGENTS.md) — the "TDD is non-negotiable" gate,
the naming rule, and the orchestrator-vs-collaborator split for adapters
that wrap 3rd-party I/O are authoritative there. This skill describes
the **process** of adding features that fit those rules.

## The tree you are adding to

Outside in — a layer only imports layers below it, and families never
import each other:

```
Sources/
├── Commands/   Server/        the two ways in: the CLI and `baguette serve`
├── Devices/<Family>/          Simulator · iPhone · CompanionPhone — what only one family does
├── Plugins/{Plugin,Bakery}/
├── Device/                    module BaguetteDevice: id, kind, power, Chrome/, Abilities/<ability>/
└── Baguette/                  @main + Resources/Web
```

Every folder: its public face at the top, its implementations in
`Internal/`, and the bare call to the outside world (a private symbol,
VideoToolbox, a socket, a process, a signal) in `Internal/System/`,
≤100 lines a file — the only code unit coverage leaves out.
`Tests/BaguetteTests/` mirrors `Sources/` folder for folder.

## Workflow

```
┌──────────────────────────────────────────────────────────────┐
│  0. ARCHITECTURE DESIGN (user approval required)             │
│     place it in CANONICAL_MODEL · think the domain first     │
│     wire shape · domain types · adapter split · risks        │
├──────────────────────────────────────────────────────────────┤
│  1. THE ABILITY (Device/Abilities/<ability>/) — TDD           │
│     value types · pure static factories · the @Mockable role │
│     · rich-domain methods · the `Ability` key                 │
├──────────────────────────────────────────────────────────────┤
│  2. THE FAMILY (Devices/<Family>/) — TDD                      │
│     register the ability where the family can perform it;   │
│     its adapter in Internal/ (decisions, tested via a role's │
│     MockXxx), the bare call in Internal/System/ (≤100 lines) │
├──────────────────────────────────────────────────────────────┤
│  3. THE WAYS IN (Commands/, Server/, the page) — TDD          │
│     GestureRegistry (gestures) · CLI subcommand run against │
│     DeviceOption.$reachable · route through InProcessServer │
│     · browser IIFE shown by the device's abilities           │
├──────────────────────────────────────────────────────────────┤
│  4. DOCS + CHANGELOG (mandatory before reporting "done")      │
│     `docs/features/<feature>/README.md` (+ `design.md` for    │
│     private-API research) · one CHANGELOG line · `make docs`  │
│     · `make check-docs` clean for the files you touched       │
└──────────────────────────────────────────────────────────────┘
```

## Phase 0: Architecture Design (mandatory)

For any feature that crosses a folder boundary or touches the
SimulatorKit / IndigoHID / AXPTranslator / CoreDevice / spawn surface,
**stop and design before coding**. A bug fix that moves a rule or adds a type goes
through Steps A and B too.

### Step A: Place it in the canonical model

Read [`docs/CANONICAL_MODEL.md`](../../../docs/CANONICAL_MODEL.md) — the
tree, the words, every law and its one owner, the contexts — then answer:

| Question | If yes |
|---|---|
| Which context owns the question it answers? (CANONICAL §5) | a role or value of what a device is or can do goes in `Sources/Device/Abilities/<ability>/` (module `BaguetteDevice`, `public`), its host implementation in that ability's `Internal/`; what only one family does goes in `Sources/Devices/<Family>/` (`Simulator/`, `iPhone/`, `CompanionPhone/`), its private-API adapter in `Devices/<Family>/Internal/<ability>/` — families never reference each other; plugins in `Sources/Plugins/`; the test in `Tests/BaguetteTests/` at the same path as the source; one that fits no context is a missing word — ask before inventing a folder |
| Which node is told? (CANONICAL §2) | a new verb lands on one node of the tree; `Commands`/`Server` only parse and call it |
| Does it add or change a law? (CANONICAL §3) | it gets **one** owner — the node that holds the data. Grep for the rule first: if it's already written somewhere, that's the owner, or the duplicate to remove |
| Does it need a new role for the outside world? | a `@Mockable` protocol named for the role, an `Ability` each device family registers in its `Abilities` only when it can perform it, and reached through `devices.require(.xxx, of: id)` — never built by `Commands` or `Server` ([devices design](../../../docs/features/devices/design.md)) |
| Does what differ between devices become a branch? | make it data: profile, chrome, model, a registration table |

When the doc doesn't cover it, write the change into CANONICAL_MODEL.md first
(tree lines, a law with its owner, a §6 row) — that diff is part of the
design you present. Code that disagrees with the doc is behind; don't bend
the design to it.

### Step B: Think the domain first

Ask the five questions of every type the change touches, check its context
with the six, and draw now beside proposed →
[`references/domain-shape.md`](references/domain-shape.md).

### Step C: The shape

Briefly produce:

1. **Wire shape** — the JSON envelope on `baguette serve` WS / `baguette input` stdin. Field names, optional vs required, default values.
2. **CLI surface** — subcommand + flag names. Match existing patterns (`--udid`, `--width`, `--height`).
3. **Device types** — value types (struct/enum) and which `@Mockable` abstraction is added/changed. Rich domain: behaviour lives on the value, not in a service (`DeviceButton.press`, `KeyboardKey.press` are the templates). **Name new abstractions for their domain role** — `Subprocess`, `DeviceHost`, `Accessibility`. **Never `XxxPort` / `XxxService` / `XxxManager`, and never the suffix `XxxRepository`.** If the abstraction *is* aggregate CRUD (load / save / delete by identity for an aggregate root), name it as the **plural collection noun** — `Simulators`, `Chromes`, `Books`. If the noun isn't obvious, the abstraction probably shouldn't exist yet.
4. **Adapter changes** — how the production class (`IndigoHIDInput`, `AXPTranslatorAccessibility`, `SimDeviceLogStream`, …) handles it. Which private-API symbol, which arg shape. Flag iOS-26-specific gotchas explicitly (signature drift between idb/AXe and Xcode 26 has burned us before — see [`buttons/design.md`](../../../docs/features/buttons/design.md) for the canonical example).
5. **I/O split (only when the adapter wraps 3rd-party I/O)** — read [AGENTS.md's "Splitting an adapter that wraps 3rd-party I/O"](../../../AGENTS.md#splitting-an-adapter-that-wraps-3rd-party-io) section and pick a pattern:
   - **One-shot fetch** (single private-API call → operate on the value): lift the post-fetch logic into a pure static factory beside its ability (`AXNode.walk(from:transform:)`, `AXFrameTransform`, `LineBuffer`). The adapter shrinks to "make the call, hand the result to the static factory." No new abstraction needed.
   - **Conversational I/O** (start / stream / signal-exit / terminate): introduce one small `@Mockable` collaborator named like a domain noun (`Subprocess`, never `LogProcessPort`). The orchestrator depends on `any Subprocess`; tests inject `MockSubprocess`. The concrete impl (`HostSubprocess` ~30–50 LOC) is integration-only and lives in `Internal/System/`, which coverage leaves out.
6. **Frontend** — does the browser need to send / receive this? If yes, which IIFE(s) change.

Present the CANONICAL_MODEL diff (if any), a short ASCII diagram and a
"files to touch" list, then **ask the user to approve** before writing code. The cost of a wrong
SimulatorKit signature is a `backboardd` crash, not just a failing test.

### Architecture diagram templates

**Gesture-style feature** (a new act of an input role):

```
Wire JSON           Device/Abilities/Touch|Key|…   Devices/Simulator/Internal/
{type:"<verb>",     ┌──────────────┐  role        ┌────────────────┐ IndigoChannel ┌─────────────────────┐
 …}           ─────▶│ <Verb>       │ ────────────▶│ IndigoHIDInput │ ─────────────▶│ System/             │
                    │ Gesture +    │ Touch/Press/ │ (which messages│               │ SimulatorKitIndigo- │
                    │ value types  │ Key/Scroll   │  in what order)│               │ Channel (9-arg call)│
                    └──────────────┘              └────────────────┘               └─────────────────────┘
                         ▲
                    GestureRegistry ◀── Commands/ (ArgumentParser) · Server.deviceStream (WS) · baguette/gestures/*.js
```

**Conversational-I/O feature** (start / stream / terminate — split
the orchestrator from the host-process collaborator):

```
Device/Abilities/<x>/       <x>/Internal/ (or Devices/<F>/Internal/)   …/Internal/System/
┌─────────────────┐         ┌──────────────────────┐  any <Role>     ┌──────────────────────┐
│ value types,    │ ──────▶ │ <Feature> adapter     │ ──────────────▶ │ the concrete <Role>  │
│ pure factories, │         │ (state machine, order,│                 │ (≤100 lines: only    │
│ the ability's   │         │  retries, error map)  │ ◀── Mock<Role>  │  the outside call)   │
│ role            │         └──────────────────────┘    in tests     └──────────────────────┘
└─────────────────┘                    ▲
       Commands/ (CLI) · Server/ (/devices/:udid/<feature>, both trees)
```

The worked example to copy: `H264Encoder` → `CompressionSession` (role) →
`System/VideoToolboxSession` in `Device/Abilities/Capture/`.

## Phase 1: The ability (Device/Abilities/<ability>/)

Write the failing test FIRST, in `Tests/BaguetteTests/<the source's folder>/`, named
`should <outcome> [when <situation>]` in domain language — see
[Naming tests](references/tdd-patterns.md#naming-tests).

Patterns that already exist — match them:

- **Pure value types** — `struct Foo: Equatable, Sendable { … }`. Add
  `Hashable` only if a Set / Dictionary key actually needs it.
- **Rich domain methods** — verbs live on the value:
  ```swift
  extension DeviceButton {
      func press(duration: Double = 0, on buttons: any Press) -> Bool {
          buttons.button(self, duration: duration)
      }
  }
  ```
- **Gesture protocol** — one act of one input ability (a tap, a
  keystroke, a button press) that parses itself from the wire:
  `static let wireType` + `static func parse` + `static var ability`
  (the role it needs: `.touch`, `.press`, `.key`, `.scroll`) +
  `func execute(on role:)`. The body of `execute` should be one line that
  delegates to a rich-domain method. Name the act for what it is
  (`Keystroke`, `ButtonPress`, `WheelEvent`), never the ability's name.
- **Field extractors** — use `Field.requiredString` / `requiredDouble`
  / `optionalDouble`. Don't open-code `dict["…"] as? Double`.

Example test rhythm (from `KeyboardTests.swift`):

```swift
@Suite("KeyboardKey")
struct KeyboardKeyTests {
    @Test func `should map a lowercase letter key onto the keyboard HID page`() {
        #expect(KeyboardKey.from(wireCode: "KeyA")?.hidUsage
            == HIDUsage(page: 7, usage: 0x04))
    }
}
```

Run `swift test --filter <Suite>` after each red→green cycle.

## Phase 2: The family (Devices/<Family>/)

The family registers the ability in its `Abilities` only where it can
perform it, and implements its role in `Internal/`. `@Mockable` roles get
auto-generated `MockXxx` companions; tests substitute the mock and assert
on returned state:

```swift
let keyboard = MockKey()
given(keyboard).key(.any, modifiers: .any, duration: .any).willReturn(true)

KeyboardKey.from(wireCode: "KeyA")!.press(modifiers: [.shift], on: keyboard)
verify(keyboard).key(.any, modifiers: .value([.shift]), duration: .value(0))
    .called(1)
```

If the feature needs a new method on an existing abstraction, add it
to the protocol with a doc comment, then update the production
adapter. **Do not** introduce a parallel hierarchy just to enable
testing — each family has one adapter per role it plays (`IndigoHIDInput`
for all four on a simulator, `DigitizerTouch` for a phone's `Touch`), and
that's all there needs to be. A role a device can't play is not registered,
never implemented as `false`.

### Adapter wraps 3rd-party I/O? Pick the split.

If your adapter touches a private framework, `Foundation.Process`,
`dlopen`, `Pipe`, `kill(pid)`, or any external XPC, **do not pile
all of that into one class**. Use one of the two splits.

**(a) One-shot fetch — pure factory beside its ability.** When the
private-API call is "make one call, get a value back, operate on the
value" (`AXPTranslator.frontmostApplicationWithDisplayId:` returns
one `AXPMacPlatformElement`), lift the post-fetch logic into a pure
static factory beside its ability and drive it with `Fake…` `NSObject`s that
override KVC / selectors. The adapter shrinks to "make the call,
hand the result to the factory." Examples:

- `AXNode.walk(from rootElement: NSObject, transform: AXFrameTransform, depthCap:, deadline:) -> AXNode`
- `AXFrameTransform.map(_ macFrame: CGRect) -> CGRect`
- `LineBuffer.append(_ bytes: Data) -> [String]`
- `AXElementReader.string/bool/frame/children(...)`

These all live in `Device/Abilities/<ability>/`, are exercised by direct unit
tests, and the adapter calls them after the irreducible private-API
call.

**(b) Conversational I/O — domain-named collaborator.** When the
adapter has a real conversation with the outside (`start` → many
`onBytes` → `onExit`, plus a `terminate` poke), pure helpers don't
capture the state machine cleanly. Introduce one small `@Mockable`
collaborator beside the adapter, named like a noun for what it *is*
(`Subprocess`, never `LogProcessPort`):

```swift
@Mockable
protocol Subprocess: AnyObject, Sendable {
    func run(executable: URL, arguments: [String],
             onBytes: @escaping @Sendable (Data) -> Void,
             onExit:  @escaping @Sendable (Int32) -> Void) throws
    func terminate()
}
```

The orchestrator depends on `any Subprocess`. Tests inject
`MockSubprocess` and drive every byte/exit/terminate path. The
concrete impl (wraps `Foundation.Process`, a private symbol, a
socket…) is the **only** integration-only file. It goes in that
folder's `Internal/System/` (≤100 lines), which `codecov.yml` leaves
out by one rule — never add a file path to the ignore list. CI builds
its regex from that list; `make check-coverage` fails a `System/` file
that grew decisions. Everything else it uses must be a tested value.

### Coverage expectation per file

After the split:
- Pure factories / value types: **100%** unit-tested.
- The adapter in `Internal/` (`H264Encoder`, `IndigoHIDInput`, `SimDeviceLogStream`): **≥ 90%** unit-tested via its role's `MockXxx`.
- The irreducible call, in `Internal/System/`: integration-only, left out of coverage by its folder. Prove it with a test against the real thing, tagged `.tags(.system), .enabled(if: SystemTests.available)` with a `.timeLimit` (see `VideoToolboxSessionTests`).
- A route: drive it through the real router with `InProcessServer` (`Tests/BaguetteTests/Server/Router/`), not just its static handler.

If you can't get the orchestrator into a `MockXxx`-driven test, it's
not split correctly — go back to Phase 0.

### When the adapter calls private SimulatorKit symbols

For `IndigoHIDInput` (and any future direct private-symbol caller):

- `IndigoHIDInput` decides which messages, in what order; it sends them
  through `IndigoChannel`. The `dlsym` table is `System/IndigoFunctions.swift`
  and the 9-arg build-and-send is `System/SimulatorKitIndigoChannel.swift`,
  built on the main thread. A new symbol goes there, logged in the
  `[hid] symbols resolved …` line; its decisions go in the input.
- Match the arg signature against a verified open-source bridge (see
  the `kittyfarm` typedef approach used for the buttons feature in
  [`docs/features/buttons/design.md`](../../../docs/features/buttons/design.md)) —
  guessing the signature from older `idb` / AXe code has burned us
  before.
- Add `log(...)` lines at each branch (symbol resolved, message
  built non-nil, sent) so users can see exactly where dispatch dies.
- Bracket multi-step sequences (modifiers, two-finger holds) with
  matching down/up pairs; never leave a key/modifier latched.

### When the adapter reaches a physical phone (CoreDevice, tunnel services)

For anything under `Devices/iPhone/Internal/` (research:
[`docs/features/real-devices/design.md`](../../../docs/features/real-devices/design.md)):

- **Bind CoreDevice in Swift** with `@_silgen_name` on stand-in types
  (`Internal/System/CoreDeviceSymbols.swift` and its neighbours); it's weak-linked, and a Mac — or CI —
  without it builds with no `COREDEVICE` define. Every member the
  `COREDEVICE` side adds needs its stub in the `#else` branch, or CI's
  build fails where yours passes. Check with `hasCoreDevice = false` in
  `Package.swift` before pushing.
- **Bound every wait** on CoreDevice or the phone (`wait(timeout:)`,
  deadline-aware sockets, a cooldown before retrying a failed open): a
  locked phone or a stalled tunnel never answers.
- **Check a resilient type's size** (`CoreDeviceFramework.valueSize`)
  before CoreDevice writes one into a fixed buffer.
- **Wire formats are values**, beside the mechanism that uses them
  (`Internal/Accessibility/`: `DTXMessage`, `XPCObject`, `HTTP2Frame`,
  `AXTreeDump`; `Internal/Screen/CoreDevice/RTP/`: `MediaStreamOffer`,
  `ReceiverFeedback`), unit-tested byte for byte; the socket and the private call
  are the only untested lines, and live in `Internal/System/`.
- **A phone serves one session** per service at a time and is shared
  with the user — share reads (`SharedRead`) rather than open a second.
- **Look before you touch.** Screenshot the user's phone before sending
  any input, and only send input that can be undone: it is someone's
  real device, with real apps open.

## Phase 3: The ways in (Commands/, Server/, the page)

Each new gesture / verb flows through the same checklist:

1. **`GestureRegistry.standard`** — one `r.register(<Verb>.self)`
   line in `Device/Abilities/Touch/GestureRegistry.swift`.
2. **CLI subcommand** — new `struct …Command: ParsableCommand` in
   `Sources/Commands/GestureCommands.swift` (or a sibling). Add to
   `RootCommand.subcommands`. Update `CommandParsingTests`, and test its
   `run()` against mocks: `run(_:on:terminal:)` in
   `Tests/BaguetteTests/Commands/CommandRun.swift` sets
   `DeviceOption.$reachable`, `CommandOutput.$current` and
   `Terminal.$current`. Its stdin / signal / port I/O goes in
   `Commands/Internal/System/`.
3. **Server** — a gesture needs nothing: `Server.deviceStream` already
   routes wire JSON through `GestureDispatcher.dispatch(line:)`. A new
   route registers under both trees with `Server.deviceRoutes("<leaf>")`,
   reaches its role with `Server.role(_:of:in:)` (refusals 422 / 409 /
   404), and is tested through the real router with `InProcessServer`
   (`Tests/BaguetteTests/Server/Router/`).
4. **Browser** — when the feature is user-facing:
   - Build the wire envelope in `Resources/Web/baguette/gestures/`
     (`gesture-envelope.js`; a new pointer source beside the mouse,
     touch and wheel ones).
   - Build resource URLs through `BaguetteTarget.path(udid, rest)`
     (`target.js`), never a hardcoded `/simulators/`, so the same page
     serves `/devices/<udid>`. A device page shows only what the
     device's abilities in `/devices.json` back.
   - If a new DOM-driven module is needed, write a single-purpose
     IIFE that hangs one class on `window`, add a `<script>` tag in
     `sim.html` (and `farm/farm.html` if the farm path uses it),
     and mount it from `sim-native.js` and/or `farm/farm-tile.js`.
   - The frontend stays a **dumb sender**: no HID codes, no chrome
     lookups, no domain logic. The Swift side owns rich domain.
   - Small, reusable browser logic gets a `node:test` unit test —
     see [references/js-testing.md](references/js-testing.md).

A new **stream format** is one `Stream` impl in `Device/Abilities/Capture/Internal/`
plus one case in `StreamFormat.makeStream` (same folder); its byte envelope lives in
`Device/Abilities/Capture/Envelope.swift`. No call site switches on the format.

## Phase 4: Docs + Changelog (mandatory before "done")

When the code is green and the feature works end-to-end, **before**
reporting completion:

### 4a. Feature doc

Follow [`docs/documentation-design/`](../../../docs/documentation-design/README.md):
each fact has one home, and every doc links instead of copying.

- **`docs/features/<feature>/README.md`** (≤200 lines), for someone
  *using* the feature: a `description:` frontmatter line (what + when,
  ≤250 chars), quick start, workflows, the feature's own HTTP /
  WebSocket routes and messages (one example each), gotchas, see also.
  No flag tables — link `../../commands.md#baguette-<cmd>`. No file maps.
  Match [`shake`](../../../docs/features/shake/README.md).
- **`docs/features/<feature>/design.md`**, only when there is research
  the code can't explain: the path to the irreducible private call,
  which symbol and arg shape, where each magic number was measured
  (spec / chrome bundle / Apple HID page), ordering that matters, dead
  ends tried, known limits in full. This is where the iOS-26 gotchas go.
- A new gesture's envelope goes in [`docs/wire.md`](../../../docs/wire.md);
  a new route gets one row in [`docs/serve.md`](../../../docs/serve.md)
  linking to the feature README.
- A limit every agent must know on every task gets **one line** in
  AGENTS.md's "Known limits", linking to the `design.md`.

### 4b. CHANGELOG

One bullet under `## [Unreleased]`, ≤300 chars (URLs excluded).
`Removed` / `Changed` before `Added`; anything incompatible starts with
`Breaking:`. Start with what the user types or clicks, say the effect —
not the type, symbol or file (those go in the PR and `design.md`) —
and end with the docs + PR links:

```md
- `baguette hinge` folds iPhone Duo to a pose or an angle, swept like Device Hub. → [docs](docs/features/hinge/README.md) ([#NN](https://github.com/tddworks/baguette/pull/NN))
```

### 4c. Generated docs

Run `make docs`: it regenerates `docs/commands.md`, the `docs/README.md`
index and the `baguette` skill's references from the binary and the
docs. Never hand-edit those. Then `make check-docs` must report nothing
new for the files you touched. If the CLI or wire surface changed, update
the `skills/baguette` page that covers the verb's job (the agent workflow,
not the flag table — `make docs` writes that).

## Anti-patterns to avoid

- **Reaching for `class` to hold rich domain.** Use `struct` (or
  `enum`) with extension methods. Swift structs already have methods,
  computed properties, protocol conformance, and auto-synthesised
  `Equatable` / `Hashable` / `Sendable` — everything rich domain
  needs. `final class` is reserved for boundaries that genuinely
  need reference semantics (`Server`, `IndigoHIDInput`,
  `CoreSimulators`, `LiveChromes`, `H264Encoder`). See
  [`references/domain-models.md`](references/domain-models.md) for
  the full rule.
- **Plumbing chrome (or any aggregate) into `IndigoHIDInput`.** SRP
  violation — the adapter's job is wire-format dispatch, not domain
  resolution. Resolve overrides at the call site or on the rich
  domain value.
- **Positional triples on the JS side.** `simInput.button(name, dur, hidUsage)`
  is wrong shape; either accept an options object or move the resolution
  back into Swift.
- **`type` / `key` reaching the wire as a no-op fallback.** If you
  can't implement a feature, fail loudly with a parse error — silent
  drops mid-string are worse than an explicit `{"ok":false,"error":"…"}`.
- **Adding a Mockable abstraction with one concrete impl just for
  testing.** One adapter per role a family plays (`IndigoHIDInput`,
  `DigitizerTouch`) is enough; don't invent a parallel hierarchy. The exception is the
  orchestrator + collaborator split for 3rd-party I/O — there the
  collaborator (`Subprocess`) earns its `MockSubprocess` because the
  state machine is real.
- **Naming an abstraction `XxxPort` / `XxxService` / `XxxManager`,
  or suffixing aggregate persistence with `XxxRepository`.** These
  are pattern labels, not domain nouns. The codebase uses role-named
  protocols (`Touch`, `Key`, `Screen`, `Accessibility`, `LogStream`,
  `DeviceHost`, `Subprocess`). For aggregate CRUD specifically, use
  the **plural collection noun** (`Simulators`, `Chromes`, `Books`)
  — not `BookRepository`. If the noun isn't obvious, the abstraction
  probably shouldn't exist yet — keep the logic inline or push it
  into a pure helper instead.
- **Cramming the irreducible private-API call AND the orchestration
  logic into one file.** That's the original sin that kept
  `IndigoHIDInput` at 14% and `H264Encoder` at 18% coverage, excluded
  wholesale. The decisions go in `Internal/`, the bare call in
  `Internal/System/`; `make check-coverage` fails a System file over 100
  lines.
- **A rule at the call site.** `hinge.angle()?.litPanel ?? .primary` in
  four places is four owners; the rule lives on the node that holds the
  data (`Hinge.litPanel`) and callers ask it. Grep before you write a rule.
- **A domain decision in `Server` or a command.** The way in parses and
  calls; which input follows a fold, or which surface heals, is the
  device's (`LitPanelInput`, the `.inputSurface` ability), built where it
  can be tested.
- **A file path on the coverage ignore list.** `codecov.yml` leaves out
  kinds of code (`**/Internal/System/**`), never a file; a file that needs
  leaving out is a file that wants splitting.
- **`MOCKING` outside the test target.** It's `.debug`-only by design
  so release builds carry no mock code. Don't reach for `MockXxx`
  from production code.

## References

- [`AGENTS.md`](../../../AGENTS.md) — authoritative architecture + iOS-26
  gotchas (the 9-arg `IndigoHIDMessageForMouseNSEvent` recipe, the
  MainActor requirement, the wire-coordinate convention).
- [`docs/features/buttons/design.md`](../../../docs/features/buttons/design.md) — the
  reverse-engineering canonical: how we found the iOS-26 4-arg
  `HIDArbitrary(target, page, usage, op)` signature.
- [`docs/features/keyboard/README.md`](../../../docs/features/keyboard/README.md) —
  end-to-end feature with focus-gated browser capture, CLI, and wire.
- [`docs/CANONICAL_MODEL.md`](../../../docs/CANONICAL_MODEL.md) — the
  tree, the words, the laws and their owners, the contexts. Read first.
- [Think the domain first](references/domain-shape.md) — five questions per
  type, six per context, keeping it in scope.
- [Architecture diagram patterns](references/architecture-diagrams.md)
- [Rich domain model patterns](references/domain-models.md)
- [TDD test patterns](references/tdd-patterns.md)

## Checklist (use TaskCreate for non-trivial features)

### Phase 0 — Architecture
- [ ] Read CANONICAL_MODEL; named the context, the node that is told, and each law's one owner
- [ ] Grepped for the rule before writing it; no second owner
- [ ] Five questions asked of touched types, context checked, now/proposed drawn ([domain-shape.md](references/domain-shape.md))
- [ ] CANONICAL_MODEL updated first when the tree, a law or an owner changes
- [ ] Wire JSON shape sketched (required vs optional fields)
- [ ] CLI subcommand + flag names follow existing patterns
- [ ] Device types listed (value types + which `@Mockable` abstraction is added/changed)
- [ ] New abstraction names are domain nouns (no `XxxPort / XxxService / XxxManager`; aggregate CRUD uses the plural collection noun like `Books`, not `BookRepository`)
- [ ] Adapter private-API symbol + arg signature verified against a known-good source
- [ ] If the adapter wraps 3rd-party I/O, the orchestrator-vs-collaborator split is decided (one-shot factory vs `@Mockable` collaborator)
- [ ] iOS-26 gotchas flagged (MainActor? new symbol? signature drift?)
- [ ] User has approved the design

### Phase 1 — The ability (red → green → refactor)
- [ ] Failing test in `Tests/BaguetteTests/<the source's folder>/`
- [ ] Value types in `Device/Abilities/<ability>/` (or `Devices/<Family>/`)
- [ ] Rich-domain method on the value (e.g. `.press(...)`)
- [ ] If the feature introduces a pure factory (`AXNode.walk`, `LineBuffer.append`, `AXFrameTransform.map`), it's covered at 100%
- [ ] If a new collaborator was introduced, it's `@Mockable` and named for its domain role
- [ ] `swift test --filter <Suite>` green

### Phase 2 — The family
- [ ] The ability registered in the family's `Abilities` only where it can perform it
- [ ] Existing role extended with a doc comment (or new role added)
- [ ] Adapter in `Internal/` with `[<context>]` log lines at branches
- [ ] If 3rd-party I/O: the adapter depends on `any <Role>`; the concrete role is in `Internal/System/`, ≤100 lines, deciding nothing; a `.system`-tagged test proves it against the real thing
- [ ] Mockable: one stub per member (`.willProduce` to branch), every `verify` correct — a failing one crashes the runner
- [ ] Coverage: adapter ≥ 90%; pure factories at 100%; `make check-coverage` clean
- [ ] `swift test` green

### Phase 3 — The ways in
- [ ] `GestureRegistry.standard` registers the new gesture (gestures only)
- [ ] CLI subcommand registered in `RootCommand`; `CommandParsingTests` updated; its `run()` tested against mocks (`run(_:on:terminal:)`)
- [ ] A new route under both trees (`Server.deviceRoutes`), tested through `InProcessServer`
- [ ] Browser changes (if any) span `baguette/gestures/` (wire envelopes),
      relevant IIFE, URLs through `BaguetteTarget.path`, and BOTH
      `sim.html` + `farm/farm.html` script tags
- [ ] Manual smoke test on a booted sim — and on a phone when a phone family
      registers it, screenshotting it before any input (the irreducible private-API call is
      integration-only — make sure it actually works end-to-end)

### Phase 4 — Docs + Changelog
- [ ] CANONICAL_MODEL matches the code (laws, owners; §6 row removed when fixed)
- [ ] `docs/features/<feature>/README.md` created or updated, with `description:`
- [ ] `design.md` for any private-API research; one AGENTS.md line if every agent needs it
- [ ] `docs/wire.md` / `docs/serve.md` updated if the gesture wire or routes changed
- [ ] One `CHANGELOG.md` [Unreleased] bullet, ≤300 chars, with docs + PR links
- [ ] `make docs` run; `make check-docs` clean for touched files
- [ ] `skills/baguette` page for the verb's job updated (if CLI/wire changed)
