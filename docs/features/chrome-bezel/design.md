---
description: How baguette places DeviceKit chrome buttons — chrome.json's per-anchor offset rule verified against SimulatorKit, the 2N − R rest position, and devicePadding canvas margins.
---

# Chrome bezel — design

## Path

- `baguette chrome`, the `bezel.png` / `chrome-button` / `definition.json`
  routes → `Chromes` (the device's `profile.plist` `chromeIdentifier` picks
  the bundle) → `DeviceChrome.parsing(json:)` → `LiveChromes` rasterizes the
  PDFs (`CGPDFDocument → CGImage`) and assembles the merged and bare
  composites.
- Button placement is computed twice from the same rule: Swift
  `buttonTopLeft` for the merged composite, the SDK's `Button.box` for the
  actionable overlay.

## Source data

Each chrome bundle lives at
`/Library/Developer/DeviceKit/Chrome/<id>.devicechrome/Contents/Resources/`
and ships:

- `chrome.json` — the layout schema (`images.sizing`, `images.devicePadding`,
  `paths.simpleOutsideBorder`, `inputs[].offsets`, etc.).
- A composite PDF (`PhoneComposite.pdf`, `WatchComposite.pdf`, …) and
  a 9-slice (`topLeft.pdf` / `top.pdf` / …) for chromes that ship
  only the corner pieces.
- One PDF per hardware input — `DigitalCrown.pdf`, `SideButton.pdf`,
  `Mute BTN.pdf`, `X_Power BTN.pdf`, plus their `... Dn.pdf` pressed
  variants.

## Two layers: `onTop`

Two layers feed the merged composite: every `onTop: false` button is
drawn BEHIND the composite (the cap pokes through a transparent slot
in the bezel rail — iPhone power/volume/action), every `onTop: true`
button is drawn ON TOP (Apple Watch's orange action button doesn't
appear in the watch composite at all). The actionable overlay
respects the same flag for z-index (z=0 behind the bezel `<img>`, z=2
in front).

## chrome.json button offsets — the asymmetric rule

Every `inputs[]` entry carries two offsets:

```json
{ "name": "side-button",
  "anchor": "right",
  "image": "SideButton",
  "imageDown": "SideButton Dn",
  "onTop": false,
  "offsets": {
    "normal":   { "x": -30, "y": 160 },
    "rollover": { "x": -25, "y": 160 }
  } }
```

The interpretation differs per anchor — verified by reading
SimulatorKit (`SimDisplayChromeView.ChromeInput.normalRect` /
`.rolloverRect`, plus the `centerXAnchor` / `centerYAnchor` /
`constraintEqualToAnchor:constant:` selrefs in
`/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/Versions/A/SimulatorKit`)
and by side-by-side comparison against the real `Simulator.app`
window:

| anchor          | `offset.x` means                                  | `offset.y` means          |
|-----------------|----------------------------------------------------|----------------------------|
| left            | image **CENTRE** on the anchored axis              | image **TOP** edge         |
| right           | image **LEFT (inner) edge**, measured outward from `composite.width` | image **TOP** edge |
| top             | image **TRAILING / LEADING (outer) edge**, depending on `align` | image **BOTTOM (inner) edge**, measured outward from the body top |
| bottom          | image **TRAILING / LEADING (outer) edge**, depending on `align` | image **TOP (inner) edge**, measured outward from the body bottom |

Why y is **TOP** for left/right but **INNER EDGE** for top/bottom:
the protrusion axis is perpendicular to the anchored axis. For left/
right-anchored caps (vertical pills on a side rail), y just slides the
cap UP/DOWN along the rail — using the cap's TOP edge means tall caps
(watch4 crown 67 px) and short caps (Mute BTN 32 px) with the same
`offset.y` start at the same y, which is the only sensible reading
when the cap is fully contained vertically (Image #8 regression in
the development history showed the action button drifting down when
y was treated as centre). For top/bottom-anchored caps (horizontal
pills on a top/bottom rail), y is the *protrusion axis* — the cap
needs to overshoot the body's top/bottom edge by some chrome-pixels,
exactly like x does for right-anchored caps. Hence both x and y for
top/bottom anchors are the cap's *inner* edge facing the body, with
the same `2N − R` at-rest mirror as right-anchor.

Why x is **INNER EDGE** for right-anchor and **OUTER (trailing/
leading) EDGE** for top/bottom: again, perpendicular vs anchored axis.
Right-anchor x is the protrusion axis (cap pokes past the right rail)
→ measure the inner edge that anchors the cap to the body. Top/
bottom-anchor x is the *sliding* axis (cap slides along the top/
bottom rail) → measure the cap's edge that's flush with the body's
trailing/leading corner. Treating top/bottom x as the centre drifts
the cap by `imgW / 2` toward the body interior — visible on the iPad
Pro 13-inch (M4) power button as a cap landing 32 px right of where
Apple positions it (Image #13 regression).

Why right-anchor specifically also fixes watch4 crown/side-button:
DigitalCrown (25 wide) and SideButton (36 wide) ship offsets that,
under a CENTRE interpretation, land the entire image inside the body
silhouette. The overlay sits behind the bezel image's baked
crown/side silhouette and is invisible at rest — no cap-past-rail
protrusion (Image #14 regression). Inner-edge keeps both crown and
side-button visible past the rail with the cap-pop the chrome.json
offsets specify.

### At-rest position: `2N − R` on the protrusion axis

> Matched against Simulator.app. Xcode 27's Device Hub rests watch4's side
> button nearer −33.5 than −35; unconfirmed, see
> [device-hub-look.md](device-hub-look.md#open-questions).

chrome.json's `normalOffset` is the **hover** position — the cap
already popped past the rail — not the relaxed at-rest position.
At-rest mirrors the rollover delta INWARD on the protrusion axis:

```
right-anchor : restX = 2 · normalOffset.x − rolloverOffset.x
top-anchor   : restY = 2 · normalOffset.y − rolloverOffset.y
bottom-anchor: restY = 2 · normalOffset.y − rolloverOffset.y
```

For watch4's side-button (`normal=-30`, `rollover=-25`) that gives
`restX = -35` → image right edge at `composite.width + 1`, a 1 px
protrusion. Hover translates outward by `rollover − normal = +5`
chrome-px, landing the cap at `normalOffset.x = -30` → image right
at `composite.width + 6` (6 px protrusion), matching Apple's hovered
side-button. For caps without a hover animation (DigitalCrown ships
`normal == rollover = -23`) the formula collapses to `normalOffset.x`
and the cap stays fixed at 2 px protrusion.

For the iPad Pro 13-inch (M4) power button (`anchor=top`,
`align=trailing`, `normal=(-74, 8)`, `rollover=(-74, 3)`) the same
mirror on y gives `restY = 13` → image bottom edge 13 chrome-px
below the body top, so 3 chrome-px of the 16-tall cap protrude above
at rest; hover translates upward by `rollover − normal = -5` chrome-
px, popping the cap to 8 px protrusion.

### `buttonTopLeft` (Swift) and `Button.box` (JS SDK) summary

| anchor | Swift `buttonTopLeft` → top-left point | JS `box` → CSS `left`/`top` |
|---|---|---|
| left   | `(compX + offset.x − imgW/2, compY + offset.y)` | `cxPct − halfWPct%`, `tyPct%` |
| right  | `(compX + compW + (2N.x − R.x), compY + (2N.y − R.y))` | `(bareW + 2N.x − R.x) / bareW %`, `(2N.y − R.y) / bareH %` |
| top, trailing | `(compX + compW + restX − imgW, compY + restY − imgH)` | `(bareW + restX − imgW) / bareW %`, `(restY − imgH) / bareH %` |
| top, leading  | `(compX + restX, compY + restY − imgH)`                | `restX / bareW %`,               `(restY − imgH) / bareH %` |
| bottom, trailing | `(compX + compW + restX − imgW, compY + compH + restY)` | `(bareW + restX − imgW) / bareW %`, `(bareH + restY) / bareH %` |
| bottom, leading  | `(compX + restX, compY + compH + restY)`                | `restX / bareW %`,                  `(bareH + restY) / bareH %` |

`compX = buttonMargins.left`, `compY = buttonMargins.top` (the canvas
margins added around the rasterized composite — see below).
`restX = 2N.x − R.x`, `restY = 2N.y − R.y`.

## Canvas margins — `images.devicePadding`

Apple ships an `images.devicePadding` block on every chrome,
describing the canvas space reserved around the composite for button
overshoot and rollover-animation slack:

| chrome     | devicePadding                  |
|------------|--------------------------------|
| phone11    | `top:0, left:9, bottom:0, right:9`   |
| phone13    | `top:0, left:9, bottom:0, right:9`   |
| watch4     | `top:0, left:0, bottom:0, right:11`  |
| tablet5    | `top:9, left:0, bottom:0, right:10`  |

`LiveChromes.assemble` reads these verbatim into
`DeviceChromeAssets.buttonMargins` — the merged canvas is
`composite.size` plus `devicePadding` on each side. We do not infer
margins from button geometry (the prior `imgW ± offX` formula
coincidentally matched watch4's `right: 11` because the side-button
math worked out to 11, but produced wrong values for chromes whose
button geometry didn't line up — tablet5 has `top: 9` despite
shipping no buttons at all). The screen rect inside `layoutJSON` is
shifted by `(devicePadding.left, devicePadding.top)` so it lands on
the real screen cutout in the merged image.

## Hover animation (SDK overlay buttons)

The Baguette SDK's button part drives a three-state animation off
chrome.json's two offsets — same mirror everywhere now, all four anchors:

- **At rest** — position via `2N − R` on the protrusion axis (x for
  left/right, y for top/bottom). For `onTop:false` caps the overlay
  sits behind the bezel `<img>` (z=0) and only the cap-past-bezel
  portion is visible. For `onTop:true` caps (watch4 action) the
  overlay sits in front (z=2).
- **Hover** (`mouseenter`) — CSS transform translates outward by the
  chrome.json `rollover − normal` delta on the protrusion axis. The
  cap pops out from the rest position to `normalOffset` — the
  "popped out" hover state.
- **Press** (`mousedown`) — translates by `−delta` (inward of at-rest)
  and swaps the sprite to `imageDown.pdf`'s rasterized variant. On
  `mouseup`/`mouseleave` the cap snaps back to rest with the
  `imageDown` swap reverting to the at-rest sprite.

The press fires `onPress(name, durationSeconds)`. `name` is the wire
button (`'home'`, `'power'`, `'action'`, `'digital-crown'`,
`'side-button'`, `'left-side-button'`, …); `durationSeconds` is the
real mousedown→mouseup hold time — the Swift dispatch routes it
through `IndigoHIDMessageForHIDArbitrary` for buttons that need the
long-press semantics (e.g. Apple Watch action button's "Hold for
Ring", iPhone power's Siri / SOS).

## Adding a new chrome / button family

1. Confirm the simulator name maps to a chrome ID via its
   `profile.plist` (`chromeIdentifier`). Apple ships everything we
   need at `/Library/Developer/DeviceKit/Chrome/<id>.devicechrome/`.
2. If the new button has a wire-distinct HID code, add it to
   `DeviceButton` with the (page, usage) pair from chrome.json's `usagePage` /
   `usage` fields and a wire name matching chrome.json's `name`.
3. Extend `Press.allowed` so the gesture registry accepts the new wire name. Also widen
   `SimulatorDefinition.Button.wireButton(for:)` so the chrome.json
   name flows into the SDK's `definition.json` payload — the JS
   `_Button` part routes clicks through whatever envelope the
   definition advertises, no per-button JS edit needed.
4. The geometry path is data-driven — no code change needed for
   new chrome bundles unless their `inputs[]` carries a previously
   unseen `anchor` or `align` value.

## Verifying changes

```bash
# Restart baguette serve so the new binary + JS land.
make && pkill -f baguette/serve; ./Baguette serve &

# Pull the merged composite (with buttons baked) for the device:
curl -s "http://127.0.0.1:8421/devices/<UDID>/bezel.png" \
  -o /tmp/merged.png && sips -g pixelWidth -g pixelHeight /tmp/merged.png

# Pull the bare composite (no buttons baked — what the actionable
# overlay sits on top of):
curl -s "http://127.0.0.1:8421/devices/<UDID>/bezel.png?buttons=false" \
  -o /tmp/bare.png && sips -g pixelWidth -g pixelHeight /tmp/bare.png

# Inspect the SDK bootstrap the front-end consumes (button boxes
# in CSS-percent space, bezel image URLs, screen rect / clip radius):
curl -s "http://127.0.0.1:8421/devices/<UDID>/definition.json" | jq

# The legacy chrome.json route is still served for external tooling,
# but the SDK and every consumer page now read definition.json:
curl -s "http://127.0.0.1:8421/devices/<UDID>/chrome.json" | jq
```

Open `http://127.0.0.1:8421/simulators/<UDID>` (focus mode), flip the
top-toolbar bezel toggle (third icon from the right) to switch
between flat and actionable views, and hover the right-rail buttons —
the cap should slide outward by the chrome.json `rollover − normal`
delta on hover and snap inward on mousedown.
