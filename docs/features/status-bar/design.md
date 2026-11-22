---
description: Why status-bar overrides go through simctl instead of SimulatorHID, and where the value sets and ranges were verified. Read before changing the status-bar spellings or adapter.
---

# Status bar: design

## Path

- CLI `baguette status-bar override|clear`, `GET|POST|DELETE /devices/<UDID>/status-bar` (or `/simulators/…`),
  and the focus-mode panel (`panels/status-bar/internal/status-bar-view.js`)
- → `StatusBarOverride` (value) → `StatusBar` (`Simulator.statusBar()` vends a fresh handle)
- → `SimctlStatusBar` → `Subprocess.run("/usr/bin/xcrun", ["simctl","status_bar",udid,"override", …])`;
  `GET` parses `simctl status_bar … list`.

Unlike taps and swipes, this is **not** a SimulatorHID path: it shells out to
`xcrun simctl status_bar <udid> override | clear`, the same mechanism Xcode's
Simulator menu uses. No booted-device HID plumbing is involved; it's a one-shot
subprocess. The irreducible `xcrun` spawn lives in `HostSubprocess` (shared with
`LogStream`), so the adapter is unit-covered via `MockSubprocess`.

## Where the spellings come from

The `--dataNetwork` / `--wifiMode` / `--cellularMode` / `--batteryState` value
sets and the `0-3` / `0-4` / `0-100` ranges are verified against
`xcrun simctl status_bar … override` help output (Xcode 26). The Domain enums
carry these as their raw `wireName`s, so the CLI `ExpressibleByArgument`
conformances, the HTTP body parser and the argv projection share one spelling
table: change a spelling in `StatusBarOverride.swift` and every entry point
follows.

`overrideArguments` projects the set fields to simctl's argv in a stable order,
clamping `wifiBars` to 0…3, `cellularBars` to 0…4 and `batteryLevel` to 0…100,
so a bad slider value can't make the spawn fail.

## The panel is a dumb sender

`panels/status-bar/internal/status-bar-view.js` `GET`s the current overrides on open, so the card reflects
the device. On change it debounces (250 ms) and `POST`s **only the field that
changed**: changing Wi-Fi bars sends `{"wifiBars":N}` alone, so the data-network
indicator can't flip to "5G" and the battery isn't re-applied. All domain logic
(the `list` parse, argv, clamping, validation) stays in Swift.

