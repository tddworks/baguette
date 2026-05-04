# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

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

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.1.62...HEAD
[0.1.62]: https://github.com/tddworks/baguette/compare/v0.1.61...v0.1.62
[0.1.61]: https://github.com/tddworks/baguette/compare/v0.1.6...v0.1.61
[0.1.6]: https://github.com/tddworks/baguette/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/tddworks/baguette/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/tddworks/baguette/compare/v0.1.1...v0.1.4
