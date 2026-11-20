# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

### Added
- The device page's format picker offers **WebRTC** beside H.264 and MJPEG: the phone's screen as H.264 over UDP (WHEP), for viewing from a phone or another machine; it plays on plain HTTP too. → [docs](docs/features/webrtc/README.md)

- A WebRTC viewer adapts to its link: the browser's transport-cc reports set the encoder's bitrate (REMB, or none, with `?congestion=remb|off`), and its packets are paced so a keyframe doesn't overflow a phone link's queue. → [docs](docs/features/webrtc/README.md)
- `baguette serve --webrtc-ports 8190-8194` keeps WebRTC media to a UDP port range, for a firewall. → [docs](docs/features/webrtc/README.md)

### Fixed
- A tap posted to `POST /devices/:udid/input` reaches a simulator in ~50 ms instead of ~300 ms: the device's input is kept between requests, and finding a device no longer runs `devicectl` each time — every per-device route is faster.
- `baguette stream` no longer spins a full CPU core once its stdin closes (`< /dev/null`, `nohup`, a parent that closes the pipe); it stops reading commands and keeps streaming. → [docs](docs/features/stream/README.md)

---

## [0.3.0] - 2026-11-19

### Changed
- The serve page lists every device in one table, real or virtual, iOS or Android, with each one's kind and OS; it filters by platform, real or virtual, and OS. `/devices.json` now lists them all. → [docs](docs/serve.md)
- A phone's live screen that can't start now says why (on the page, or from `stream`) instead of quietly showing screenshots; a Mac without CoreDevice still shows screenshots. → [docs](docs/features/real-devices/screen-routes.md)

### Added
- Android emulators are devices: `list`, `boot` / `shutdown` by AVD name, `screenshot`, `stream` and the serve page, taps, swipes, two-finger gestures, scrolls, buttons (`back` included), keys and `type`; Android phones list too. → [docs](docs/features/android/design.md)
- `BAGUETTE_PHONE_SCREEN=avconference` has AVConference receive and decode a phone's live screen (HEVC) in baguette's own process, at the same CPU as baguette's own receiver, still the default. → [docs](docs/features/real-devices/screen-routes.md)

### Fixed
- An H.264 stream on the serve page picks up again at the next keyframe after the browser's decoder fails, instead of freezing on its last picture at 0 fps until a refresh. → [docs](docs/serve.md)
- A phone's live screen shows on the first open instead of screenshots until a refresh, and keeps streaming past its first 15 seconds; `describe-ui` and touches reach it cold too: baguette now keeps the phone's CoreDevice tunnel up. → [docs](docs/features/real-devices/design.md)

### Changed
- `baguette serve`'s page and every per-device route live under `/devices/<UDID>/…`, for a simulator or a phone alike; page controls show only what the device can do. `/simulators/<UDID>/…` still answers, deprecated (`Deprecation` header), and goes in a later release. → [docs](docs/serve.md)
- A `key`, `type`, `button` or `scroll` sent to a phone on a cable says `<phone> can't do key` (or `press`, `scroll`) instead of a bare `{"ok":false}`; the phone takes touches only. → [docs](docs/features/real-devices/README.md)
- A companion-screen stream that finds no framebuffer now answers `noMatchingFramebuffer(…)` instead of `noMatchingPort(…)`; match the new text if a script reads it. → [docs](docs/features/companion-screens/README.md)

## Older releases

[0.2](docs/changelog/0.2.md) · [0.1](docs/changelog/0.1.md)

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/tddworks/baguette/compare/v0.2.15...v0.3.0
