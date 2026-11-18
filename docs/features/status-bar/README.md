---
description: Override the simulator's status bar (time, carrier, network, signal bars, battery) or clear it back to live values, from the CLI, HTTP or the focus-mode panel. Use when preparing clean demo screenshots or App Store captures.
---

# Status bar

Override the booted simulator's status bar (fixed time, carrier name,
data-network type, Wi-Fi / cellular mode and signal bars, battery state and
level) or clear everything back to live values. It's the same mechanism as
Xcode's Simulator menu, `simctl status_bar`, behind a CLI, HTTP routes and a
browser panel. Every flag: [commands.md#baguette-status-bar](../../commands.md#baguette-status-bar).

## Quick start

```bash
# Picture-perfect demo state: 9:41, full bars, charged.
baguette status-bar override --udid <UDID> \
  --time 9:41 --operator-name Baguette \
  --data-network 5g --cellular-bars 4 --wifi-bars 3 \
  --battery-state charged --battery-level 100

baguette status-bar clear --udid <UDID>
```

In the browser: open `/simulators/<UDID>` and click the signal-bars toolbar
button. The **Status Bar** card reads the device's current overrides when it
opens and applies each change live (250 ms debounce), sending only the field you
changed. "Clear overrides" drops them all. There's no preview; the live stream
shows the result.

## HTTP

| Method | Path | Does |
|---|---|---|
| GET | `/devices/<UDID>/status-bar` | Current overrides as JSON (`{}` if none) |
| POST | `/devices/<UDID>/status-bar` | Apply the fields in the body |
| DELETE | `/devices/<UDID>/status-bar` | Clear all overrides |

A simulator answers under its old `/simulators/<UDID>/status-bar` too. A device without a status bar to override answers
`422`; one that isn't running, `409`.

```bash
curl -X POST http://127.0.0.1:8421/devices/<UDID>/status-bar \
  -d '{"batteryLevel":68,"dataNetwork":"5g"}'
```

Body keys are camelCase: `time`, `operatorName`, `dataNetwork`, `wifiMode`,
`wifiBars`, `cellularMode`, `cellularBars`, `batteryState`, `batteryLevel`.
Every field is optional, but at least one is required. A single-field POST
(`{"wifiBars":1}`) updates only that indicator; simctl merges it into the
existing overrides.

```
200 {"ok":true}                                                (POST / DELETE)
200 {"dataNetwork":"wifi","wifiBars":2,…}                      (GET)
400 {"ok":false,"error":"set at least one status-bar field"}
404 {"ok":false,"error":"unknown udid: <udid>"}
500 {"ok":false,"error":"status-bar override failed (simctl error)"}
```

## Gotchas

- **Unknown enum values fail loud.** A present `dataNetwork` / `wifiMode` /
  `cellularMode` / `batteryState` with an unrecognised value is `400`, not
  silently dropped.
- **Out-of-range numbers are clamped**, not rejected: `wifiBars` to 0–3,
  `cellularBars` to 0–4, `batteryLevel` to 0–100.
- **`hide` exists only for the data network.** simctl can't hide the battery or
  Wi-Fi glyph individually; use `clear` to drop all overrides at once.
- **Scoped to the device, until reboot.** Overrides persist across app launches
  but are cleared by a simulator erase or reboot.
- **The CLI can't read overrides back**; use `GET` over HTTP.
- One UDID per invocation; there's no batched multi-device form.

## See also

[design.md](design.md): the simctl path and where the value sets come from ·
[screenshot](../screenshot/README.md)
