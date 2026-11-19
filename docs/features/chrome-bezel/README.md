---
description: Render a simulator inside a real-looking device bezel built from Apple's own DeviceKit chrome bundles — layout JSON, composite PNG, per-button images. Use when you need a framed device image or bezel geometry for a page.
---

# Chrome bezel rendering

`baguette serve` renders each simulator with a real-looking device bezel — the
rounded body silhouette, the rail, the side buttons — using Apple's own
DeviceKit chrome bundles (`/Library/Developer/DeviceKit/Chrome/`) as source.
No hand-curated bezel table to keep in sync: every simulator family gets its
bezel from the bundle Xcode ships. Every flag:
[commands.md#baguette-chrome](../../commands.md#baguette-chrome).

## Quick start

```bash
baguette chrome layout --device-name "iPhone 17 Pro" | jq .
baguette chrome composite --device-name "iPhone 17 Pro" > iphone17pro.png
```

`layout` emits the bezel layout JSON; `composite` rasterizes the composite PDF
to PNG. Either takes `--udid` instead of `--device-name`, and `--panel` for a
foldable.

In the page, focus mode's top-toolbar **bezel toggle** (third icon from the
right) switches between two views:

- **Flat** — the merged composite: the device body with hardware buttons baked
  into one PNG.
- **Actionable** — the bare body, with each hardware button as its own
  animatable image over it. Hover a cap and it slides outward; press and it
  snaps inward with the pressed sprite, and the hold time is sent as the
  button's press duration (so long-press semantics — Apple Watch's "Hold for
  Ring", iPhone power's Siri / SOS — work from the page).

Both views share one positioning rule, so the actionable overlay tracks the
merged composite pixel-for-pixel.

## HTTP

Any device answers by its model; a simulator also under its old `/simulators/<UDID>/…`.

| Route | Returns |
|---|---|
| `GET /devices/<UDID>/bezel.png` | Merged composite (buttons baked in) |
| `GET /devices/<UDID>/bezel.png?buttons=false` | Bare body, no buttons |
| `GET /devices/<UDID>/chrome-button/<name>.png` | One button's rasterized image (e.g. `powerButton.png`, `powerButton-down.png`) |
| `GET /devices/<UDID>/screen-mask.png` | The lit panel's framebuffer mask; `404` when the chrome names none |
| `GET /devices/<UDID>/definition.json` | The SDK bootstrap — bezel URLs, screen rect, button boxes ([baguette-sdk](../baguette-sdk/README.md)) |
| `GET /devices/<UDID>/chrome.json` | The legacy layout JSON, still served for external tooling |

Each takes `?panel=` on a foldable. For a screenshot already composited into
the bezel, use `screenshot-bezel.png` ([screenshot](../screenshot/README.md)).

```bash
curl -s "http://127.0.0.1:8421/devices/<UDID>/bezel.png?buttons=false" -o bare.png
curl -s "http://127.0.0.1:8421/devices/<UDID>/definition.json" | jq
```

## Gotchas

- **Needs Xcode's DeviceKit chrome bundles.** The device's `profile.plist`
  names its bundle (`chromeIdentifier`); a device whose chrome isn't
  installed has no bezel.
- **The page reads `definition.json`**, not `chrome.json`. Build new tooling
  on `definition.json`.

## See also

- [design.md](design.md) — chrome.json's asymmetric offset rule, the `2N − R` rest position, `devicePadding`
- [device-hub-look.md](device-hub-look.md) — how Xcode 27's Device Hub draws the same chrome, and what baguette must change to match it
- [baguette-sdk](../baguette-sdk/README.md) — the JS parts that draw the bezel
- [screenshot](../screenshot/README.md) — `screenshot-bezel.png`
- [buttons](../buttons/README.md)
