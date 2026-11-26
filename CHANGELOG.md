# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

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

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/tddworks/baguette/compare/v0.4.0...v0.5.0
