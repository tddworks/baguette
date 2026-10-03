# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

### Added
- `list --json` and `/simulators.json` expose the installed device type, product family and runtime identity next to the editable name, so clients can filter and match devices after a rename. → [docs](docs/features/device-farm/README.md#catalog-identity)

### Fixed
- Injected dylibs no longer disarm each other: `DYLD_INSERT_LIBRARIES` is read with stdout and stderr kept apart, an unreadable environment fails the update instead of being overwritten; `network status` reports a failed query. → [docs](docs/features/camera/design.md#sharing-dyld_insert_libraries)

---

## [0.2.2] - 2026-10-03

### Added
- `baguette render-3d --screen` accepts `--hinge-degrees` and `--screen-orientation` to place saved screenshots on the active foldable panel, upright, with the requested fold. [Offline folded screenshots](docs/features/3d-rendering/models.md#offline-folded-screenshots).

### Fixed
- `baguette orientation` now rotates iPhone Duo instead of reporting success without rotating. [Rotation](docs/features/hinge/README.md#rotation).
- iPhone Duo `hinge`, rotation and hardware keys return once the guest has played the command and report a helper that failed to start; a helper that stops answering is stopped, so it cannot act after the command reports a timeout. [Hinge](docs/features/hinge/README.md)
- In a custom `--device-set`, where the angle cannot be read back, `baguette hinge` moves straight to the requested angle instead of sweeping from closed through the cover panel. [Hinge](docs/features/hinge/README.md#gotchas)
- An iPhone Duo `orientation` or `hinge` whose guest helper timed out exits 3 (HTTP `504`) instead of reporting an ordinary failure, since the change may have landed. [Rotation](docs/features/hinge/README.md#rotation)
- Input commands wait for HID transmission before reporting success or exiting; transmission errors and timeouts report failure. See [dispatch semantics](docs/features/touches/design.md#5-dispatch) ([#90](https://github.com/tddworks/baguette/pull/90)).
- `--device-set` now reaches display enumeration; stalled probes cancel output reads on timeout and failed display resolution retains `simctl` diagnostics. → [docs](docs/features/companion-screens/README.md#gotchas) ([#92](https://github.com/tddworks/baguette/pull/92))

---

## [0.2.1] - 2026-09-27

### Fixed
- The AX inspector and `baguette describe-ui` tree hit tests can select descendants outside empty or smaller container frames. → [docs](docs/features/accessibility/README.md#gotchas) ([#89](https://github.com/tddworks/baguette/pull/89))
- `baguette stream` no longer crashes on startup and now releases capture resources when stopped by Ctrl-C or SIGTERM.
- `baguette stream --help` no longer offers an `h264` format it rejects, and `baguette logs --help` lists the levels (`default`, `info`, `debug`) and styles (including `ndjson`) it actually accepts.

### Changed
- `CHANGELOG.md` now holds only the current minor; the 0.1.x history moved unchanged to `docs/changelog/0.1.md`.
- Docs reorganised: a short README, one guide per feature under `docs/features/<name>/`, a generated command reference in `docs/commands.md`, and `docs/wire.md` for the gesture JSON. Several examples that never ran are fixed.

### Added
- `baguette screenshot --metadata-output` writes a JSON sidecar with the captured frame's actual pixel sizes and crop or letterbox placement. → [docs](docs/features/screenshot/geometry.md) ([#91](https://github.com/tddworks/baguette/pull/91))

---

## [0.2.0] - 2026-09-22

### Changed
* ci: drop the Xcode 27 job's weekly schedule by @crockalet in https://github.com/tddworks/baguette/pull/83
* fix(pasteboard): write through devicectl before simctl pbcopy by @EYHN in https://github.com/tddworks/baguette/pull/84

## New Contributors
* @EYHN made their first contribution in https://github.com/tddworks/baguette/pull/84

## Older releases

[0.1](docs/changelog/0.1.md)

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/tddworks/baguette/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/tddworks/baguette/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/tddworks/baguette/compare/v0.1.99...v0.2.0
