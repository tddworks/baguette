# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

### Added
- **Accessibility tree extraction (`describe-ui`).** New `baguette describe-ui --udid <UDID> [--x <px> --y <px>]` CLI subcommand and `{"type":"describe_ui"}` WebSocket message dump the booted simulator's on-screen UI tree as JSON: per-node `role`, `label`, `value`, `identifier`, `frame` (in **device points**, ready to feed back into a `tap` envelope), plus `enabled` / `focused` / `hidden` traits and recursive `children`. Hit-test path returns the topmost AX element under a coordinate. Powered by the private `AccessibilityPlatformTranslation` framework's `AXPTranslator` — out of Simulator.app the tricky bit is wiring a `bridgeTokenDelegate` ourselves so the translator can route XPC requests to the right `SimDevice.sendAccessibilityRequestAsync:`; without that delegate every `frontmostApplication…` call returns `nil`. Cribbed the dispatcher pattern from `cameroncooke/AXe` and `Silbercue/SilbercueSwift`'s `AXPBridge.swift`. See [`docs/features/accessibility.md`](docs/features/accessibility.md).
- **Hardware side buttons (action / volume-up / volume-down / power) on the wire and CLI.** Extended `DeviceButton` with the four arbitrary-HID side buttons and added `press(duration:on:)` so the rich domain owns its own dispatch. New CLI: `baguette press --button <name> [--duration <s>]` accepts the full set; the wire JSON gains an optional `duration` for long-press semantics ("Hold for Ring" on the action button, Siri / SOS on power, etc.). Routes through `IndigoHIDMessageForHIDArbitrary(target, page, usage, operation)` — the iOS-26-correct 4-arg shape, NOT the (page, usage, op, timestamp) signature some open-source loaders use. The browser bezel overlay measures real `mousedown` → `mouseup` and forwards the elapsed time, so click-and-hold on a side button just works. `siri` is still rejected (crashes `backboardd` through every known Indigo path). See [`docs/features/buttons.md`](docs/features/buttons.md).
- **Mac keyboard input on the wire, CLI, and web UI.** New `Key` / `TypeText` gestures and a focus-gated browser capture: when the device screen has focus, every supported keystroke is forwarded automatically; click out and the host browser shortcuts (Cmd+R, Cmd+T, …) work normally again. CLI mirrors the wire — `baguette key --code KeyA --modifiers shift,command [--duration <s>]` and `baguette type --text "hello"`. Phase 1 covers letters, digits, named specials (Enter / Escape / Backspace / Tab / Space / Arrow\*), US punctuation, and the four modifiers (shift / control / option / command); IME / non-Latin / emoji is deferred to phase 2's `IndigoHIDMessageForKeyboardNSEvent` path. Wire codes are W3C `KeyboardEvent.code` strings so the browser forwards events verbatim — no translation table on the JS side. Mounted on both focus mode (`/simulators/<udid>`) and the focused tile in the device farm. See [`docs/features/keyboard.md`](docs/features/keyboard.md).
- **`baguette list --json`** emits the same `{"running":[…],"available":[…]}` envelope that `/simulators.json` serves. Plain `baguette list` keeps its per-line projection so existing scripts that grep field-by-field don't break; `--json` opts into the structured shape for tools that want one parse + a `running` / `available` split. Reuses `Simulators.listJSON` so the CLI and HTTP outputs stay byte-identical.

### Changed
- **`/simulators` defaults to "All Runtimes"** so every booted simulator (e.g. iOS 26.2 alongside the latest 26.x) is visible on first load. The runtime dropdown now lists "All Runtimes" first, then "Latest Runtime", then individual runtimes; users who want only the latest can re-select it. Fixes a discoverability gap where a simulator booted on a non-latest runtime was hidden until the user scrolled the dropdown.

---

## [0.1.65] - 2026-05-04

### Changed
- Bug fixes and improvements.

---

## [0.1.64] - 2026-05-04

### Added
- **One-shot JPEG screenshot endpoint + CLI.** New `GET /simulators/:udid/screenshot.jpg[?quality=&scale=]` route on `baguette serve` returns the current framebuffer as `image/jpeg`, so embedding pages can refresh on demand with a plain `<img src="…?t=…">` — no WebSocket plumbing required. New `baguette screenshot --udid <UDID> [--output <path>] [--quality 0.85] [--scale 1]` CLI mirrors it; defaults write to stdout so it composes with shell redirection. Both share `ScreenSnapshot.capture(...)`: open Screen, await one IOSurface (2 s timeout with a single-shot guard for the timer / callback / start-throw race), encode via the existing `JPEGEncoder` + optional `Scaler`, stop. See [`docs/features/screenshot.md`](docs/features/screenshot.md).

---

## [0.1.63] - 2026-05-04

### Added
- **Focus mode at `/simulators/<udid>`** — visiting the deep-link URL directly now skips the device list and drops straight into a clean "play the simulator" view: the bezel takes the full viewport (height-driven) with a single floating glass toolbar above it, mirroring a SwiftUI `VStack { Toolbar; Device }`. The toolbar carries a clickable `‹ <name> · iOS <ver>` breadcrumb (back to list), an inline H.264 / MJPEG segmented control, action buttons (Home / Screenshot / App-switcher), and a live fps badge. Action buttons drive `SimInput.button(...)`; Screenshot grabs the live canvas and downloads a PNG. Reuses the existing `DeviceFrame`, `StreamSession`, `SimInput`, `MouseGestureSource`, and `PinchOverlay` modules — no new transport, no new server route. Lives in `Resources/Web/sim-native.html` + `sim-native.js`; loaded by `sim.html` and synchronously sets `window.__baguetteNativeMode` so `sim-list.js` bails out before painting the list shell.
- **Light + dark theme with manual toggle.** Focus mode tokenises every colour at `#simNativeView` (`--nv-page-bg`, `--nv-bar-bg`, `--nv-text`, …) and tracks `prefers-color-scheme` by default. A floating glass pill in the bottom-right corner (`__nativeToggleTheme`) lets the user pin a theme, persisted to `localStorage.baguette.simTheme`; the pinned attribute beats the media query so manual choice always wins over the OS preference. Sun icon shows in light theme, moon in dark.

### Changed
- **`SimInputBridge` is now shared by the single-device pages too.** `sim.html` loads `sim-input-bridge.js`, and both `sim-stream.js` (sidebar mode) and `sim-native.js` (focus mode) call `window.SimInputBridge.makeTransport(session, log)` instead of carrying private `toBaguetteWire` + `phasedTouchWire` copies. ~140 lines of duplicated dialect translation removed; `farm-tile.js`, `sim-stream.js`, and `sim-native.js` now share one source of truth for the SimInput → Baguette wire-format mapping.

---

## [0.1.62] - 2026-05-03

### Changed
- Bug fixes and improvements.

---

## [0.1.61] - 2026-05-03

### Fixed
- **`baguette serve` no longer fails to launch when Xcode lives outside `/Applications/Xcode.app`** ([#1](https://github.com/tddworks/baguette/issues/1)). Two layers:
  - **Link-time:** `Package.swift` was declaring `SimulatorKit` and `CoreSimulator` as `linkedFramework`s, which baked LC_LOAD_DYLIB entries that dyld had to resolve before `main()` ran — and the rpaths it baked alongside them only matched `/Applications/Xcode.app`. Users with Xcode at e.g. `/Applications/Xcode_26.app` got `Library not loaded: @rpath/SimulatorKit.framework` and an immediate abort. Nothing in `Sources/` actually `import`s either framework, so the entries (and their rpath / `-F` flags) are gone; the binary now starts cleanly anywhere.
  - **Runtime:** `CoreSimulators.developerDir()` blindly trusted `xcode-select -p`, which on many machines points at `/Library/Developer/CommandLineTools` (no SimulatorKit) — particularly after a user renames their Xcode bundle. The resolver now verifies that `SimulatorKit.framework` actually exists at the selected developer directory and, if not, scans `/Applications` for any `Xcode*.app` (preferring the canonical `Xcode.app`) whose `Contents/Developer` does have it.

---

## [0.1.6] - 2026-05-03

### Added
- **Browser-side recording.** Record button in the single-device sidebar (`/simulators/<udid>`) and the device-farm focus pane (`/farm`) captures the live view to a downloadable WebM/MP4. The recording reuses what's already on the page — bezel `<img>`, decoded canvas, PinchOverlay's existing dot positions — and composites them into a recording-only canvas while active; idle cost is zero. Chrome / Safari preference for MP4 (H.264), WebM (VP9 / VP8) fallback. Exposed as `BrowserRecorder` in `Resources/Web/recorder.js`. See [`docs/features/recording.md`](docs/features/recording.md).
- **Auto-bump live stream quality during recording.** When Record is pressed on `/simulators/<udid>`, the stream is reconfigured to scale=1, 60 fps, 8 Mbps so the source canvas is at native resolution before drawImage scales into the composite — restored to the user's previous preset on Stop.

### Changed
- **MediaRecorder defaults tuned for visible quality** — `videoBitsPerSecond: 12_000_000` and `imageSmoothingQuality: 'high'` on the compose canvas, both overridable per `BrowserRecorder` instance.
- 
---

## [0.1.5] - 2026-05-03

### Changed
- Bug fixes and improvements.

---

## [0.1.4] - 2026-05-03

### Added
- **Device farm — interactive multi-device control surface served by `baguette serve`.** A standalone web UI that streams every booted simulator side-by-side, with filtering, sorting, wall / list view modes, and live telemetry per tile. Pieces:
  - **Bezel display mode** with `DeviceFrame` integration; falls back to **9-slice bezel composition** when a device has no packaged frame asset. Chrome buttons can layer above the viewport via `onTop` z-order.
  - **Input round-trips through the existing pipeline** — `SimInputBridge` wires the farm UI's gestures, hardware buttons, and pinch overlay into `GestureDispatcher` → `IndigoHIDInput`, so anything the CLI can drive, the farm UI can drive.
  - **Focused tile mirroring** is a canvas copy — the focus pane re-parents the source canvas directly rather than spinning up a separate `<video>` element.

### Changed
- **Farm grid rendering optimized** — selection updates use delta diffs instead of full re-mounting; element mounting and bezel rendering reworked for fewer DOM writes per frame; wall view layout unified and flexbox-centered.

### Fixed
- **Wrapper sizing now matches bezel image dimensions** so device frames align in the farm grid.
- **Element rendering in raw (no-bezel) mode** correctly handles toggling display modes.
- **`ReconfigParser` number parsing** simplified to handle numeric casting consistently.

---

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.1.65...HEAD
[0.1.65]: https://github.com/tddworks/baguette/compare/v0.1.64...v0.1.65
[0.1.64]: https://github.com/tddworks/baguette/compare/v0.1.63...v0.1.64
[0.1.63]: https://github.com/tddworks/baguette/compare/v0.1.62...v0.1.63
[0.1.62]: https://github.com/tddworks/baguette/compare/v0.1.61...v0.1.62
[0.1.61]: https://github.com/tddworks/baguette/compare/v0.1.6...v0.1.61
[0.1.6]: https://github.com/tddworks/baguette/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/tddworks/baguette/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/tddworks/baguette/compare/v0.1.1...v0.1.4
