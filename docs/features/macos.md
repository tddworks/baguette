# Native macOS apps

Drive native macOS applications the same way baguette drives iOS
simulators — same gesture / describe-ui wire envelopes, same
streaming pipeline, same agent-friendly surface. The iOS path is
unchanged; macOS lives at a sibling URL tree (`/mac/...`) and a
sibling CLI subcommand group (`baguette mac …`) so the two coexist
cleanly.

This doc explains the four-stage roll-out, the public APIs and
private symbol equivalents, the coordinate convention, and the TCC
permissions the user has to grant before any of it works.

## Surface area

| Capability         | iOS sim path                            | macOS app path                              |
|--------------------|-----------------------------------------|---------------------------------------------|
| List               | `baguette list` / `GET /simulators.json` | `baguette mac list` / `GET /mac.json` |
| One-shot screenshot| `baguette screenshot --udid X`          | `baguette mac screenshot --bundle-id Y`     |
| Describe UI        | `baguette describe-ui --udid X`         | `baguette mac describe-ui --bundle-id Y` / `GET /mac/Y/describe-ui` |
| Live stream + input| `WS /simulators/X/stream`               | `WS /mac/Y/stream`                          |
| Stdin input        | `baguette input --udid X`               | `baguette mac input --bundle-id Y`          |

Wire envelopes (`tap`, `swipe`, `scroll`, `key`, `type`, `describe_ui`)
are **identical** across both paths — the only difference is which
adapter receives them.

## Aggregate shape

`MacApps` is the macOS analogue of `Simulators`. Both are
plural-collection-noun aggregates over their own identity space
(UDID for iOS, bundle ID for macOS). The role-named protocols
(`Screen`, `Accessibility`, `Input`) are shared verbatim, so adding
macOS only required new Infrastructure adapters under each protocol —
not new Domain types.

```
                      ┌────────────────┐
                      │   App layer    │
                      │  (CLI, serve)  │
                      └───────┬────────┘
                              │
            ┌─────────────────┼─────────────────┐
            ▼                 ▼                 ▼
     ┌────────────┐    ┌────────────┐    ┌──────────────┐
     │ Simulators │    │  MacApps   │    │   Chromes    │
     │ (iOS UDID) │    │ (bundleID) │    │              │
     └─────┬──────┘    └─────┬──────┘    └──────────────┘
           │                 │
   produces│         produces│
           ▼                 ▼
     ┌──────────┐      ┌──────────┐
     │ Screen   │ ───► │ Stream   │   ← shared pipeline,
     │ Input    │      │ pipeline │     unchanged
     │ Accessib.│      │ (MJPEG / │
     └──────────┘      │  AVCC)   │
                       └──────────┘
```

## Infrastructure adapters

| Domain protocol  | iOS impl                          | macOS impl                       | I/O shape                |
|------------------|-----------------------------------|----------------------------------|--------------------------|
| `Simulators`     | `CoreSimulators` (CoreSimulator)  | n/a                              | one-shot fetch           |
| `MacApps`        | n/a                               | `RunningMacApps` (NSWorkspace)   | one-shot fetch           |
| `Screen`         | `SimulatorKitScreen` (private)    | `ScreenCaptureKitScreen`         | conversational SCStream  |
| `Accessibility`  | `AXPTranslatorAccessibility`      | `AXUIElementAccessibility`       | one-shot AX walk         |
| `Input`          | `IndigoHIDInput` (9-arg recipe)   | `CGEventInput`                   | one-shot per gesture     |

The macOS adapters use **public** APIs throughout — no `dlopen`,
no runtime selector lookups, no signature drift to fight. The
trade-off is that we go through TCC.

## Coordinates

Wire `(x, y, width, height)` is in **window-relative points**, with
the top-left of the target app's frontmost window content rect at
`(0, 0)`. This matches what the user sees in `mac screenshot`'s
JPEG output — the screenshot is cropped to the same window — so
frames returned by `mac describe-ui` are immediately usable as
`tap` envelopes without coordinate juggling.

The macOS adapter resolves the window's screen-global origin via
`AX kAXPositionAttribute` once per gesture (cheap; ~0.5 ms) and
adds it to the wire point before posting the `CGEvent`. This stays
correct when the user drags the window between gestures.

Multi-window addressing — picking a non-frontmost window — is a
future extension via `--window-id` that mirrors `--bundle-id`. For
now every command targets the frontmost window of the bundle.

## TCC permissions

Three system grants are needed across the four stages. Grant via
**System Settings → Privacy & Security**:

| Stage | Capability         | TCC pane needed     | Without it…                        |
|-------|--------------------|---------------------|------------------------------------|
| 1     | `mac screenshot`   | Screen Recording    | `SCShareableContent.current` returns no windows |
| 1     | `mac describe-ui`  | Accessibility       | `AXIsProcessTrusted()` is false; `MacAppError.tccDenied(.accessibility)` |
| 2     | `mac input`        | Accessibility       | `CGEventPost` events are silently dropped before reaching the target app |
| 3     | `WS /mac/.../stream` (frames) | Screen Recording  | as Stage 1 |
| 3     | `WS /mac/.../stream` (input)  | Accessibility     | as Stage 2 |

Re-builds during development can revoke the grant on first launch.
The repo's `macos-codesign` skill (self-signed certificate) makes
the grant persist across rebuilds — recommended setup for any
maintainer work on this surface.

## Wire JSON

Identical to the iOS path. Examples reproduced for completeness:

```json
{ "type": "tap",   "x": 120, "y": 200, "width": 800, "height": 600 }
{ "type": "swipe", "startX": 0, "startY": 0, "endX": 200, "endY": 100,
  "width": 800, "height": 600, "duration": 0.25 }
{ "type": "scroll", "deltaX": 0, "deltaY": -120 }
{ "type": "key",   "code": "KeyA", "modifiers": ["command"] }
{ "type": "type",  "text": "hello" }
{ "type": "describe_ui", "x": 120, "y": 200 }
```

`{ "type": "button" }`, `touch1`, `touch2`, and `twoFingerPath` are
**rejected** on the macOS path — hardware buttons don't apply to
macOS apps, and reliable multi-touch via `CGEvent` isn't a thing.
The adapter logs `[mac-input] rejecting: …` and returns `false`.

## Keyboard mapping

`KeyboardKey` carries a HID page-7 usage code on the wire (shared
with the iOS path). On macOS, `KeyboardKey.macKeyCode` translates
that to a Carbon `kVK_*` virtual-key value for
`CGEventCreateKeyboardEvent`. The mapping is in
`Sources/Baguette/Domain/Input/KeyboardKey+MacKeyCode.swift` and
is unit-tested against published Carbon constants.

Modifier flags (`shift`, `control`, `option`, `command`) map to
`CGEventFlags` bits via `KeyModifier.cgEventFlag`. The adapter
sets `CGEventSetFlags` once per keystroke and lets macOS handle
the modifier-down / modifier-up framing — more reliable than
posting raw modifier events around the key.

## Adding a new mac CLI subcommand

Five steps, mirroring `docs/features/buttons.md`:

1. **Wire shape** — what JSON envelope or CLI flag does it carry?
2. **Domain test** — fail first; assert the parsed shape.
3. **CLI subcommand** — new file in `App/Commands/Mac*Command.swift`,
   `@OptionGroup var target: MacAppOption` for the `--bundle-id`
   flag, register in `MacRootCommand.subcommands`.
4. **Server route** — paired `/mac/:bundleID/<verb>` handler in
   `Server.swift` if the feature is web-reachable.
5. **Doc + CHANGELOG** — table row in this file plus a CHANGELOG
   entry under `## [Unreleased]`.

## Smoke test

`scripts/smoke-mac.sh` exercises the entire surface end-to-end against
TextEdit and asserts on observable outcomes (textarea value, JPEG
bytes, AX role, HTTP status). Run after every change to the macOS
adapters:

```sh
make smoke-mac          # full suite (16 tests, ~30s)
./scripts/smoke-mac.sh --no-input    # skip input if Accessibility isn't granted
./scripts/smoke-mac.sh --no-serve    # skip serve routes
```

Tiers:

- **Tier 1** (no TCC) — `mac list` only.
- **Tier 2** (Screen Recording + Accessibility) — screenshot,
  describe-ui, every input gesture (type, key, tap, swipe-to-select,
  scroll), plus the rejected-gesture paths.
- **Tier 3** (Tier-2 grants + free port) — `serve` mode HTTP/WS
  routes (`/mac.json`, `/mac/<id>/describe-ui`, `/mac/<id>/screen.jpg`,
  `/mac`, `/mac-list.js`).

The script returns a non-zero exit code equal to the number of failed
tests, so CI can gate on it. It's deliberately not part of `swift
test` because the unit suite stays hermetic — see "Why these bugs
escaped the unit tests" below.

## Why these bugs escaped the unit tests

The first version of this surface had four bugs that only the smoke
test caught:

1. **`CGS_REQUIRE_INIT` crash** on first `SCStream` use.
2. **Mouse clicks silently ignored** because we never warped the
   cursor to the click location.
3. **Drag-select dropping mid-drag** because we warped the cursor on
   every `mouseDragged` step.
4. **`postToPid` for keyboard bypassed selection-replacement** —
   typing after a drag-select APPENDED instead of REPLACED.

None of these are detectable by `swift test`, by design:

- **Unit tests substitute `MockInput` / `MockScreen` / `MockAccessibility`.**
  They verify that `KeyboardKey.from(wireCode: "KeyA")?.macKeyCode == 0`,
  but they can't observe whether `CGEventCreateKeyboardEvent(0)` →
  `CGEventPost(.cghidEventTap, …)` ends up landing as an "A" character
  in TextEdit. The OS round-trip is the irreducible boundary.
- **The Infrastructure adapters are integration-only.** Per
  CLAUDE.md's adapter-split rules, `CGEventInput`,
  `ScreenCaptureKitScreen`, and `RunningMacApps` are excluded from
  unit coverage — they're the thin OS-call wrappers, with no
  conversational state machine to mock.
- **TCC, focus routing, and cursor-position hit-testing are
  emergent.** They're system-wide behaviours that only manifest
  with a real running app, real WindowServer, real TCC grants. No
  amount of in-process mocking would have surfaced them.

The unit suite caught everything it was capable of catching (parser
shape, JSON projection, AX-walker recursion, HID→Carbon mapping,
command-line wiring, server route construction). The smoke test
covers the layer below — what happens when those values cross the
OS boundary.

**Both layers are necessary.** Unit tests are fast and hermetic for
the inner-loop work; the smoke test is the gate for "does this
actually drive a Mac app." Skipping either leaves a real category
of bug uncovered.

## Known limits

- **TCC denials surface as silent no-ops on Input/Screen Recording**
  unless we explicitly probe `AXIsProcessTrusted`. The
  Accessibility adapter does; the Input adapter doesn't (yet) —
  silent gesture failure is the symptom there.
- **Multi-window addressing is frontmost-only.** `--window-id`
  is reserved for a future stage.
- **Sandboxed apps may report partial AX trees.** Safari content
  processes and App Store apps with hardened runtime can refuse
  `AXUIElement` reads even with full grants. We surface the
  partial tree rather than throwing.
- **No keyboard layout abstraction.** The HID → Carbon translation
  table assumes a US layout. Non-US layouts may swap letter / digit
  positions. Phase 2 of `keyboard.md` addresses this for iOS; the
  macOS path will follow.
- **Live streaming UI in browser is minimal.** `/mac/<bundleID>`
  shows a polling JPEG screenshot + curl/wscat hints rather than
  the full canvas streaming UI the iOS path has. The WS endpoint
  is fully functional; the browser canvas is Stage-4 polish.
