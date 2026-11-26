# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

---

## [0.4.0] - 2026-11-26

### Added
- `BaguetteKit`, a Swift package library: the device model and every device family, without the CLI or the HTTP server, for a host that drives devices itself. Pin it by version, as `examples/ListSimulators` shows. → [docs](docs/ARCHITECTURE.md#layout-outside-in)
- `BaguetteCoreDevice`, a second library: a phone on a cable live (screen, touch, tunnel) through Xcode's CoreDevice, as `CoreDeviceAccess.live`. Pin it by revision; without it a phone is devicectl stills.
- `BaguetteResources.use(folder:)`: a library host names where it keeps the 3D models, injected dylibs and hinge helper, looked in before the CLI's resource bundle.

### Fixed
- Builds against swift-nio-ssl 2.37.6 and later, which a package depending on baguette resolves to: WebRTC's DTLS calls BoringSSL by its plain names.

## Older releases

[0.3](docs/changelog/0.3.md) · [0.2](docs/changelog/0.2.md) · [0.1](docs/changelog/0.1.md)

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/tddworks/baguette/compare/v0.3.3...v0.4.0
