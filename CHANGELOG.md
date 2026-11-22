# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

### Changed
- `/devices` is the devices list, and `/` goes there: every device, whatever its kind. `/simulators` still serves the same page, and every `/simulators/:udid/…` route still answers. → [docs](docs/serve.md) ([#157](https://github.com/tddworks/baguette/pull/157))
- `POST /devices/:udid/input` taps land ~35 ms sooner (no wait on the Android tools listing devices); live streams encode a changed screen at once and refresh a still one on a steady beat (~14 ms; 53 frames shown/s, was 41).

- `baguette serve` prints the devices list's address (`…/devices`) when it starts. → [docs](docs/serve.md) ([#157](https://github.com/tddworks/baguette/pull/157))
- With WebRTC on, the device page's toolbar has an **HEVC · H.264** switch, remembered by the browser: HEVC (the default) falls back to H.264 when the browser can't play it, and says so; H.264 asks for H.264 only. `?codec=` still overrides it. → [docs](docs/features/webrtc/README.md) ([#157](https://github.com/tddworks/baguette/pull/157))
- The web page, the device farm and the JS SDK load as ES modules, one entry each; a page that embeds the SDK imports `/baguette/baguette.js` with `type="module"`, and `window.Baguette` still works once it has loaded. → [docs](docs/features/baguette-sdk/README.md) ([#157](https://github.com/tddworks/baguette/pull/157))

### Added
- The devices page (`/devices`) lists **This Mac** as a device to share when `serve --share-mac` is on: **Share…** makes a display for the screen you're on and opens it; `/mac/share` still works. → [docs](docs/features/web-page/design.md) ([#157](https://github.com/tddworks/baguette/pull/157))
- `baguette serve --share-mac` and `baguette list --mac` show this Mac's displays as devices: streamed, recorded, screenshotted and driven (click, drag, scroll, keys, typing) like a simulator. → [docs](docs/features/mac-screen/README.md) ([#156](https://github.com/tddworks/baguette/pull/156))
- A Mac display page's **Frame** button shows it in a MacBook Pro 14" or iMac 27" frame that fits its shape, or none (the default); `screenshot-bezel.png?chrome=` frames a still in the pick. → [docs](docs/features/mac-screen/README.md#frames) ([#156](https://github.com/tddworks/baguette/pull/156))
- The device page's **WebRTC** view streams H.265 when the browser offers it (Chrome, iPhone Safari), H.264 otherwise: no cost measured, a little smoother on slow links. `?codec=h264` forces H.264. → [docs](docs/features/webrtc/hevc.md) ([#156](https://github.com/tddworks/baguette/pull/156))
- `/mac/share`, opened on a phone or tablet, shares this Mac to it: a display the shape of its screen, main or extended, sharp, turning with it, its pointer drawn locally in the Mac's real shape. → [docs](docs/features/mac-screen/README.md#share-to-your-device) ([#156](https://github.com/tddworks/baguette/pull/156))

---

## [0.3.1] - 2026-11-21

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

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/tddworks/baguette/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/tddworks/baguette/compare/v0.2.15...v0.3.0
