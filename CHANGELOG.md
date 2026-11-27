# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

---

## [0.5.2] - 2026-11-27

### Changed
- The live view stays current: a WebSocket viewer a few frames behind skips to the next keyframe instead of queueing up to 32 MiB of lag, and the page asks for a keyframe as soon as its decoder loses the picture. → [docs](docs/features/stream/design.md)
- A live view (WebSocket or WebRTC) whose video encoder stops answering recovers on its own: after 1.5 s the stream opens a fresh encoder session and resumes from a keyframe instead of freezing. → [docs](docs/features/stream/design.md#an-encoder-that-stops-answering--both-viewers)
- MJPEG keeps up on a LAN or phone: each viewer gets the newest image, never a queue, `serve` starts it at half size and 30 fps (an eighth of the bytes), and the page paints images in order. → [docs](docs/features/stream/design.md#mjpeg--the-newest-image-and-only-it)

---

## [0.5.1] - 2026-11-26

### Changed
- `HingeControl` is now four programs, one per Apple subsystem: `CoreMotionAngle`, `DeviceHubControls`, `HIDButtons`, `AXPFrontmost`. Verbs and output are unchanged; each builds and fails on its own. → [design](docs/features/injected-programs/design.md)
- `CoreSimulators(injectedPrograms:)` takes a library host's copy of each program (`InjectedPrograms`). `CoreSimulators(hingeControl:)` still works for this release, deprecated: the one binary answers every program's verbs.
- `BAGUETTE_HINGECONTROL_TOOL` is replaced by one override per program: `BAGUETTE_COREMOTIONANGLE_TOOL`, `BAGUETTE_DEVICEHUBCONTROLS_TOOL`, `BAGUETTE_HIDBUTTONS_TOOL`, `BAGUETTE_AXPFRONTMOST_TOOL`.
- `HingeControlReply` is `InjectedProgramReply`, and `HingeAngle.parse(hingeControlLine:)` is `parse(coreMotionAngleLine:)`; the old names stay, deprecated.
- A key that fails on a foldable says `HIDButtons` failed, no longer a hinge error.

### Fixed
- On a foldable whose lit panel Core Device couldn't name, the fresh hinge read now uses a library host's own `CoreMotionAngle` rather than looking only for the CLI's.
- `describe-ui` on an Apple Watch (or another guest that isn't iOS) no longer fails with a dyld error. The `HingeControl` guest helper is built for the iOS simulator, so it isn't spawned in other guests, and a read keeps what the host bridge read when the helper can't run.

---

## [0.5.0] - 2026-11-26

### Added
- `describe-ui` gives an element its `nodeId` (one element across reads), a switch the `activationPoint` its knob is at, and a wide slider its `sliderTrack`; each only where it applies. → [docs](docs/features/accessibility/design.md#where-to-act-on-an-element)
- `Accessibility.adjust(_:by:)`: step a slider, stepper or picker through accessibility, read back after each step. `describe-ui` marks such elements `"adjustable"` with their `adjustmentActions`. → [docs](docs/features/accessibility/design.md#stepping-a-control)
- `Device.render3D` / `snapshot3D`: a device on its 3D model as it stands, in the library — the models and renderer are the caller's. `render-3d --udid` and `POST /devices/:udid/render-3d.png` go through it, so an iPhone Duo is posed at its hinge with its picture on the panel it lights.
- `CoreSimulators(hingeControl:)`: a library host hands its own copy of `HingeControl`, the guest helper, to the simulators it lists.

### Removed
- `BaguetteResources` (new in 0.4.0): a process-wide folder every lookup read. A host now hands each file to what uses it: `CoreSimulators(hingeControl:)`, and `LiveDeviceModels(rootURLs:)` for 3D models.

### Fixed
- iPhone Duo renders in 3D with Xcode 27.0 selected: its model ships only in Xcode 27.1 and later, and is now found in any installed Xcode, the selected one first. Before, the render failed with `localAssetNotFound`.
- iPhone Duo: the lit panel is the one Core Device reports, not the one the hinge angle suggests. After a fold in small steps the cover stayed lit at 100°, where the 90° rule bound the dark panel: a black screen, touches lost. → [docs](docs/features/iphone-duo/design.md#the-hinge)

## Older releases

[0.4](docs/changelog/0.4.md) · [0.3](docs/changelog/0.3.md) · [0.2](docs/changelog/0.2.md) · [0.1](docs/changelog/0.1.md)

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/tddworks/baguette/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/tddworks/baguette/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/tddworks/baguette/compare/v0.4.0...v0.5.0
