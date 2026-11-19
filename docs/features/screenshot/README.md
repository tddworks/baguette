---
description: Capture one frame of a simulator's screen as JPEG or PNG, at any capture size, optionally inside the device bezel — from the CLI, an HTTP GET or the page. Use for golden images, bug reports and App Store shots.
---

# Screenshot

One-shot image of the simulator's framebuffer, in JPEG or PNG, at whatever
size you asked for — and, over HTTP, composited inside the device's DeviceKit
bezel. Every flag:
[commands.md#baguette-screenshot](../../commands.md#baguette-screenshot).
For live video, see [recording](../recording/README.md).

## Quick start

```bash
baguette screenshot --udid <UDID> > shot.jpg                  # stdout, JPEG
baguette screenshot --udid <UDID> --output shot.png           # PNG, inferred from the name
curl -o shot.png   'localhost:8421/devices/<UDID>/screenshot.png'
curl -o framed.png 'localhost:8421/devices/<UDID>/screenshot-bezel.png'
```

In the page, every capture surface — the stream sidebar, the focus-mode
toolbar and the device-farm focus pane — has a Screenshot button with a size
chip beside it; each remembers its own selection. The chip's "Include bezel"
checkbox frames the capture in the device.

## Workflows

### App Store and marketing shots

```bash
# a submission-sized asset, letterboxed on white (the default)
baguette screenshot --udid <UDID> --size appstore-6.9 --output hero.png

# the same, with no mat at all — PNG, because JPEG has no alpha
baguette screenshot --udid <UDID> --size appstore-6.9 \
                    --background transparent --output hero-alpha.png

# a square social crop — cover fills the canvas and lets the edges go
baguette screenshot --udid <UDID> --size square --fit cover -o square.jpg

# the bezelled device centred on a white square, in one GET, no browser
curl -o square.png \
  'localhost:8421/devices/<UDID>/screenshot-bezel.png?size=square&background=ffffff'
```

The size vocabulary (`appstore-6.9`, `square`, `WIDTHxHEIGHT`, `W:H`, fit,
background) is shared with recording and 3D renders:
[capture-size](../capture-size/README.md).

### A thumbnail or a refresh-on-demand image

```bash
baguette screenshot --udid <UDID> --quality 0.6 --scale 2 > thumb.jpg
```

```html
<img src="http://127.0.0.1:8421/devices/<UDID>/screenshot.jpg?t=1727180000">
```

Rotate the `?t=` timestamp to refresh — no WebSocket plumbing in the
embedding page. `--scale` and `--size` compose in that order: scale reduces
what came off the framebuffer, then the size resolves against the *scaled*
frame, so `--scale 2 --size square` squares up the half-size frame.

### Picking the format

`--format` takes `png` or `jpg` (`jpeg` is an alias). It is **inferred from
`--output` when you don't say**: a path ending in `.png` writes PNG,
everything else — including stdout — writes JPEG. An explicit `--format`
always wins. So `-o hero.png` can't quietly produce JPEG bytes under a `.png`
name.

## HTTP

```
GET /devices/:udid/screenshot.jpg            ─┐   (any device; a simulator
GET /devices/:udid/screenshot.png             ├─   also under /simulators/…)
                                              │  ?quality= &scale= &size=
GET /devices/:udid/screenshot-bezel.png   ─┘   &fit= &background=
                        (…and ?buttons=)

   200 image/jpeg | image/png
   400 application/json   {"ok":false,"error":"Unknown size '…'. …"}
   404 application/json   {"ok":false,"error":"Device <udid> not found"}
   409 application/json   the device isn't running
   404 application/json   {"ok":false,"error":"no bezel for udid <udid>"}
   500 application/json   {"ok":false,"error":"<details>"}
```

- All three routes take the same five parameters; `?buttons=false` is the
  bezel route's own, giving the bare device body without the button
  overshoot (the same meaning as `bezel.png`).
- The extension *is* the format. `screenshot.jpeg` is a 404, not a third
  spelling.
- **`GET screenshot.jpg` with no parameters returns exactly what it always
  did** — nothing is redrawn or re-encoded, so an `<img>` already pointing at
  it is unaffected.
- `?background=ffffff` is the spelling that works unescaped: a literal `#`
  starts the URL fragment and never reaches the server. `%23ffffff` works
  too. On the CLI the `#` is optional as well, and values are trimmed and
  lowercased (`--fit CONTAIN` is accepted).
- `?quality=` defaults to `0.85` on `screenshot.jpg` and `1.0` on the PNG
  routes; `?scale=` is an integer divisor floored at `1`.
- `?size=` / `?fit=` / `?background=` on the bezel route apply to the
  composited image.

An unknown size, fit or background is rejected before the framebuffer is
touched — a typo costs a 400, not a two-second timeout — and the message
names the whole accepted set. The CLI prints the same sentences and exits
non-zero:

```
Unknown size 'nonsense'. Expected WIDTHxHEIGHT, W:H, or one of:
  native | appstore-6.9 | appstore-6.5 | appstore-ipad-13 | square |
  16:9 | 9:16 | 4:3 | 4:5
Unknown fit 'squish'. Expected one of: contain | cover | stretch
Unknown background 'chartreuse'. Expected 'transparent' or #RRGGBB
```

## Gotchas

- **PNG is not bit-exact.** The capture path encodes JPEG first, and the PNG
  routes decode that and re-encode losslessly. At the default `?quality=1.0`
  the loss is negligible, but two captures of the same unchanged frame aren't
  guaranteed byte-identical. Lowering `?quality=` on a `.png` request
  degrades the image *inside* a lossless container. `--quality` has no effect
  on a CLI PNG.
- **`transparent` is a PNG-only answer.** JPEG has no alpha, so a `.jpg`
  quietly mats white instead. Nothing warns you — format and background are
  independent flags.
- **`fit` and `background` do nothing at `--size native`** (the default):
  there is no spare canvas for them to act on.
- **A size is a canvas, not a resampler.** `--size appstore-6.9` off a
  1206 × 2622 device is a genuine 1290 × 2796 file of upscaled pixels. And
  ratios grow rather than crop — `--size 16:9` on a portrait device is very
  wide; use `WIDTHxHEIGHT`, or `--fit cover` when you do want the crop.
- **No bezel on the JPEG routes, and no bezel on the CLI.**
  `screenshot-bezel` is PNG only — the device body has rounded, transparent
  corners JPEG can't carry. There's no `--bezel` flag; a script wanting one
  reaches for `curl`.
- **Bezel composite needs DeviceKit chrome for the device** — it 404s rather
  than inventing a grey rectangle. See [chrome-bezel](../chrome-bezel/README.md).
- **The bezel cutout cover-fits.** A capture whose aspect doesn't quite match
  the chrome's screen rect loses a sliver at two edges rather than
  distorting. Worth knowing if you diff bezelled captures pixel-for-pixel.
- **The bezel composite is sized off the framebuffer**, not the chrome: an
  iPhone 17 Pro Max comes back at 1483 × 2984, not the chrome's ~494 × 995. A
  heavy `?scale=` shrinks the screen content but not the bezel.
- **An idle simulator can time out.** SimulatorKit only delivers a frame on a
  change; a quiescent screen can take seconds. After 2 s you get a clean 500
  instead of a hanging request.
- **It doesn't touch the live stream.** `?scale=`, `?quality=` and `?size=`
  only shape the returned image, never a running WebSocket stream (the
  stream's own `snapshot` verb, by contrast, shares its pacing).

## Pixel geometry

Use `--metadata-output frame.json` to write the captured frame's pixel sizes
and crop or letterbox placement alongside the image. See
[geometry sidecars](geometry.md) for the JSON fields and coordinate mapping.

## See also

- [design.md](design.md) — the capture pipeline, why not "stream + one frame", bezel z-order, timeouts
- [capture-size](../capture-size/README.md) — the size vocabulary
- [recording](../recording/README.md) · [chrome-bezel](../chrome-bezel/README.md)
