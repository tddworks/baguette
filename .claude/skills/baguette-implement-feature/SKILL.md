---
name: app-implement-feature
description: |
  Guide for implementing features in baguette — a Swift CLI + WebSocket server
  that drives iOS simulators via private SimulatorKit. Use this skill when:
  (1) Adding a new gesture, button, keyboard surface, stream format, or
      device-chrome behaviour (anything that lands across Domain / Infrastructure /
      App + Resources/Web).
  (2) Extending an existing wire-protocol envelope, CLI subcommand, or HTTP route.
  (3) User asks "add feature X to baguette", "implement <gesture>", "wire <new
      verb> through serve / input / CLI", or similar.
  (4) Touching the iOS-26 SimulatorKit / IndigoHID surface — those edits MUST
      go through this skill's Architecture phase before code lands.
  Avoid using this skill for refactors that don't add a new feature (keep those
  TDD-driven without the architecture-approval gate).
---

# Implement a feature in baguette

baguette is a **CLI + WebSocket server**, not a SwiftUI app. There is no
ViewModel layer, no Repository pattern, no async actors in the input
path — gestures are synchronous `Bool`-returning calls into a
`@Mockable` `Input` port whose only concrete adapter is `IndigoHIDInput`.
The frontend is hand-written vanilla JS IIFEs (no bundler) that talk
to the server via one WebSocket per stream.

Read [`CLAUDE.md`](../../../CLAUDE.md) before proceeding — the architecture
section there is authoritative; this skill describes the **process** of
adding features that fit it.

## Workflow

```
┌──────────────────────────────────────────────────────────────┐
│  0. ARCHITECTURE DESIGN (user approval required)             │
│     wire shape · domain types · which layers change · risks  │
├──────────────────────────────────────────────────────────────┤
│  1. DOMAIN TDD                                                │
│     value types + Gesture parser + execute(on:input)         │
├──────────────────────────────────────────────────────────────┤
│  2. INFRASTRUCTURE TDD                                        │
│     extend `Input` port + adapter impl (only `IndigoHIDInput` │
│     today; mock-tested via Mockable)                          │
├──────────────────────────────────────────────────────────────┤
│  3. WIRING                                                    │
│     register on GestureRegistry · CLI subcommand · WS route  │
│     · browser IIFE (when user-facing)                        │
├──────────────────────────────────────────────────────────────┤
│  4. DOCS + CHANGELOG (mandatory before reporting "done")      │
│     create or update `docs/features/<feature>.md` ·           │
│     update `CHANGELOG.md` Unreleased section ·                │
│     update `skills/baguette/` references when CLI / wire     │
│     surface changed                                           │
└──────────────────────────────────────────────────────────────┘
```

## Phase 0: Architecture Design (mandatory)

For any feature that crosses a layer boundary or touches the
SimulatorKit / IndigoHID surface, **stop and design before coding**.
Briefly produce:

1. **Wire shape** — the JSON envelope on `baguette serve` WS / `baguette input` stdin. Field names, optional vs required, default values.
2. **CLI surface** — subcommand + flag names. Match existing patterns (`--udid`, `--width`, `--height`).
3. **Domain types** — value types (struct/enum) and which port method is added/changed. Rich domain: behaviour lives on the value, not in a service (`DeviceButton.press`, `KeyboardKey.press` are the templates).
4. **Adapter changes** — how `IndigoHIDInput` (or other adapters) handle it. Which SimulatorKit symbol, which arg shape. Flag iOS-26-specific gotchas explicitly (signature drift between idb/AXe and Xcode 26 has burned us before — see [`buttons.md`](../../../docs/features/buttons.md) for the canonical example).
5. **Frontend** — does the browser need to send / receive this? If yes, which IIFE(s) change.

Present a short ASCII diagram + a "files to touch" list, then **ask
the user to approve** before writing code. The cost of a wrong
SimulatorKit signature is a backboardd crash, not just a failing test.

### Architecture diagram template

```
Wire JSON                Domain                       Infrastructure
{type:"<verb>",          ┌─────────────┐             ┌────────────────┐
 …}                ─────▶│ <Verb>      │             │ IndigoHIDInput │
                         │ Gesture +   │  Input port │ adapter        │
                         │ value types │ ───────────▶│ (SimulatorKit) │
                         └─────────────┘             └────────────────┘
                              ▲                              │
                              │                              ▼
                         GestureRegistry                  iOS sim
                              ▲
       CLI ─── ArgumentParser ┤
       WS  ─── Server.streamWS┤
       JS  ─── sim-input{,-bridge}.js
```

## Phase 1: Domain TDD

Write the failing test FIRST, in `Tests/BaguetteTests/<Context>/`.

Patterns that already exist — match them:

- **Pure value types** — `struct Foo: Equatable, Sendable { … }`. Add
  `Hashable` only if a Set / Dictionary key actually needs it.
- **Rich domain methods** — verbs live on the value:
  ```swift
  extension DeviceButton {
      func press(duration: Double = 0, on input: any Input) -> Bool {
          input.button(self, duration: duration)
      }
  }
  ```
- **Gesture protocol** — wire DTO with `static let wireType` + `static
  func parse` + `func execute(on input: any Input)`. The body of
  `execute` should be one line that delegates to a rich-domain method.
- **Field extractors** — use `Field.requiredString` / `requiredDouble`
  / `optionalDouble`. Don't open-code `dict["…"] as? Double`.

Example test rhythm (from `KeyboardTests.swift`):

```swift
@Suite("KeyboardKey")
struct KeyboardKeyTests {
    @Test func `parses lowercase letter wire codes onto HID page 7`() {
        #expect(KeyboardKey.from(wireCode: "KeyA")?.hidUsage
            == HIDUsage(page: 7, usage: 0x04))
    }
}
```

Run `swift test --filter <Suite>` after each red→green cycle.

## Phase 2: Infrastructure TDD

The `Input` protocol is `@Mockable`. Tests substitute `MockInput`:

```swift
let input = MockInput()
given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)

KeyboardKey.from(wireCode: "KeyA")!.press(modifiers: [.shift], on: input)
verify(input).key(.value(_), modifiers: .value([.shift]), duration: .value(0))
    .called(1)
```

If the feature needs a new Input method, add it to the protocol with
a doc comment, then update `IndigoHIDInput`. **Do not** introduce a
new adapter abstraction layer — there is exactly one production
implementation and it lives in `Infrastructure/Input/`.

For `IndigoHIDInput` changes that call SimulatorKit symbols:

- Resolve the symbol in `resolveFunctions()` and log presence in the
  `[hid] symbols resolved …` line.
- Match the arg signature against a verified open-source bridge (see
  the `kittyfarm` typedef approach used for the buttons feature in
  [`docs/features/buttons.md`](../../../docs/features/buttons.md)) —
  guessing the signature from older `idb` / AXe code has burned us
  before.
- Add `log(...)` lines at each branch (symbol resolved, message
  built non-nil, sent) so users can see exactly where dispatch dies.
- Bracket multi-step sequences (modifiers, two-finger holds) with
  matching down/up pairs; never leave a key/modifier latched.

## Phase 3: Wiring

Each new gesture / verb flows through the same checklist:

1. **`GestureRegistry.standard`** — one `r.register(<Verb>.self)`
   line in `Domain/Input/GestureRegistry.swift`.
2. **CLI subcommand** — new `struct …Command: ParsableCommand` in
   `App/Commands/GestureCommands.swift` (or a sibling). Add to
   `RootCommand.subcommands`. Update `CommandParsingTests`.
3. **Server WS** — usually nothing: `Server.streamWS` already routes
   wire JSON through `GestureDispatcher.dispatch(line:)`. New behaviour
   only if you're adding a *control* verb that bypasses the gesture
   path.
4. **Browser** — when the feature is user-facing:
   - Add the wire field handling to `Resources/Web/sim-input-bridge.js`
     (translate plugin dialect → baguette wire).
   - Expose a method on `SimInput` in `sim-input.js`.
   - If a new DOM-driven module is needed, write a single-purpose
     IIFE that hangs one class on `window`, add a `<script>` tag in
     `sim.html` (and `farm/farm.html` if the farm path uses it),
     and mount it from `sim-native.js` and/or `farm/farm-tile.js`.
   - The frontend stays a **dumb sender**: no HID codes, no chrome
     lookups, no domain logic. The Swift side owns rich domain.

## Phase 4: Docs + Changelog (mandatory before "done")

When the code is green and the feature works end-to-end, **before**
reporting completion:

### 4a. Feature doc

Create or update `docs/features/<feature>.md`. Match the existing
shape ([`buttons.md`](../../../docs/features/buttons.md),
[`keyboard.md`](../../../docs/features/keyboard.md),
[`screenshot.md`](../../../docs/features/screenshot.md)):

- One-paragraph **what + why** intro listing all entry points (CLI,
  wire JSON, browser).
- **Wire JSON** examples (every shape, with required + optional fields explained).
- **Dispatch path** — which Input method, which SimulatorKit symbol,
  which arg shape (with the iOS-26 signature gotcha documented if
  relevant).
- **Where the magic numbers come from** — link to the spec / chrome
  bundle / Apple HID page so the next maintainer can verify them.
- **Adding a new <thing>** — five-step recipe matching the
  Phase-1→3 checklist above.
- **Known limits** — be honest about phase-1 scope (no IME, no
  emoji, no F-keys, etc.).

### 4b. CHANGELOG

Append a bullet under `## [Unreleased]` → `### Added` (or `### Changed`
for behaviour changes). Match the prose tone of existing entries —
explain WHAT shipped, WHY it matters, and any non-obvious gotcha
(e.g. the iOS-26 4-arg signature for buttons). Link the feature doc.

```md
- **<Feature name>.** One-sentence summary of what shipped and the
  primary entry point. Mention any iOS-26 / SimulatorKit gotcha worth
  preserving for future maintainers. See [`docs/features/<feature>.md`](docs/features/<feature>.md).
```

### 4c. Skill references

If the feature changed the **CLI surface** or **wire-protocol
envelope**, also update:

- `skills/baguette/SKILL.md` — the "What's wired vs what isn't" list.
- `skills/baguette/references/cli.md` — new flags / subcommands.
- `skills/baguette/references/wire-protocol.md` — new envelope shapes.

These files are what the agent skill loads; if they're stale, the
next agent will mis-propose stale invocations.

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
  testing.** `IndigoHIDInput` is allowed to be the only `Input` impl;
  don't invent a parallel hierarchy.
- **`MOCKING` outside the test target.** It's `.debug`-only by design
  so release builds carry no mock code. Don't reach for `MockXxx`
  from production code.

## References

- [`CLAUDE.md`](../../../CLAUDE.md) — authoritative architecture + iOS-26
  gotchas (the 9-arg `IndigoHIDMessageForMouseNSEvent` recipe, the
  MainActor requirement, the wire-coordinate convention).
- [`docs/features/buttons.md`](../../../docs/features/buttons.md) — the
  reverse-engineering canonical: how we found the iOS-26 4-arg
  `HIDArbitrary(target, page, usage, op)` signature.
- [`docs/features/keyboard.md`](../../../docs/features/keyboard.md) —
  end-to-end feature with focus-gated browser capture, CLI, and wire.
- [Architecture diagram patterns](references/architecture-diagrams.md)
- [Rich domain model patterns](references/domain-models.md)
- [TDD test patterns](references/tdd-patterns.md)

## Checklist (use TaskCreate for non-trivial features)

### Phase 0 — Architecture
- [ ] Wire JSON shape sketched (required vs optional fields)
- [ ] CLI subcommand + flag names follow existing patterns
- [ ] Domain types listed (value types + which port method changes)
- [ ] Adapter SimulatorKit symbol + arg signature verified against a known-good source
- [ ] iOS-26 gotchas flagged (MainActor? new symbol? signature drift?)
- [ ] User has approved the design

### Phase 1 — Domain (red → green → refactor)
- [ ] Failing test in `Tests/BaguetteTests/<Context>/`
- [ ] Value types in `Domain/<Context>/`
- [ ] Rich-domain method on the value (e.g. `.press(...)`)
- [ ] `Gesture` parser + `execute(on:)` delegates one line to the rich method
- [ ] `swift test --filter <Suite>` green

### Phase 2 — Infrastructure
- [ ] `Input` port extended (with doc comment)
- [ ] `IndigoHIDInput` impl with `[hid]` log lines at branches
- [ ] Mockable test stubs return values; verify(...).called(N) on the right method
- [ ] `swift test` green

### Phase 3 — Wiring
- [ ] `GestureRegistry.standard` registers the new gesture
- [ ] CLI subcommand registered in `RootCommand`; `CommandParsingTests` updated
- [ ] Browser changes (if any) span `sim-input.js`, `sim-input-bridge.js`,
      relevant IIFE, and BOTH `sim.html` + `farm/farm.html` script tags
- [ ] Manual smoke test on a booted sim (note: tests don't cover the
      private SimulatorKit boundary)

### Phase 4 — Docs + Changelog
- [ ] `docs/features/<feature>.md` created or updated
- [ ] `CHANGELOG.md` Unreleased entry written in the existing prose tone
- [ ] `skills/baguette/SKILL.md` "What's wired" list updated (if CLI/wire changed)
- [ ] `skills/baguette/references/cli.md` updated (if CLI changed)
- [ ] `skills/baguette/references/wire-protocol.md` updated (if wire changed)
