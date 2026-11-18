---
description: One output-size vocabulary (native, App Store presets, ratios, WIDTHxHEIGHT) with fit and background, shared by screenshots, recordings and 3D renders on the CLI, HTTP and the page. Use when a capture must come out at an exact size.
---

# Capture size

One vocabulary for "how big should this come out", shared by every surface
that produces an image or a video: the toolbar picker, the HTTP routes, and
the CLI — 2D and 3D alike. Saying `appstore-6.9` in the browser and
`--size appstore-6.9` on the command line means the same pixels. Flags:
[screenshot](../../commands.md#baguette-screenshot) ·
[record](../../commands.md#baguette-record) ·
[render-3d](../../commands.md#baguette-render-3d).

## Quick start

```bash
baguette screenshot --udid <UDID> --size appstore-6.9 -o hero.png
baguette record     --udid <UDID> --size square --duration 10 -o clip.mp4
baguette render-3d  --udid <UDID> --size square -o device.png
curl -o shot.png 'localhost:8421/devices/<UDID>/screenshot.png?size=square'
```

In the page, the toolbar's size picker offers the same presets plus fit,
background and "with or without the device bezel", persisted per surface.

## The presets

| spec | label | resolves to |
|---|---|---|
| `native` *(default)* | Native | the source's own dimensions |
| `appstore-6.9` | App Store 6.9″ | 1290 × 2796 |
| `appstore-6.5` | App Store 6.5″ | 1242 × 2688 |
| `appstore-ipad-13` | App Store iPad 13″ | 2064 × 2752 |
| `square` | Square | 1 : 1 |
| `16:9` | Landscape 16:9 | 16 : 9 |
| `9:16` | Portrait 9:16 | 9 : 16 |
| `4:3` | Classic 4:3 | 4 : 3 |
| `4:5` | Social 4:5 | 4 : 5 |

Two ad-hoc forms parse as well: `1920x1080` (exact pixels) and `3:2` (any
ratio not in the table). Anything else is rejected — baguette never
substitutes a nearby size.

### A ratio grows instead of cropping

A ratio preset resolves **against the source**, and it never downscales — it
grows the binding axis so the whole source still fits at 1 : 1:

```
r = ratioWidth / ratioHeight
sw/sh > r   →   (sw,  round(sw / r))     the source is wider: width binds
otherwise   →   (round(sh * r),  sh)     the source is taller: height binds
```

So a 1290 × 2796 phone frame asked for `square` gets a **2796 × 2796** canvas
with the phone centred, not a 1290 × 1290 crop through the middle of the
screen. The App Store presets are fixed: 1290 × 2796 is 1290 × 2796 whatever
you point it at.

## Fit and background

| fit | what it does |
|---|---|
| `contain` *(default)* | scale to fit, centre, letterbox the remainder |
| `cover` | scale to fill, let the overflow crop |
| `stretch` | distort to fill exactly |

`background` is `transparent` (`none` is accepted too) or `#RRGGBB` with the
`#` optional. It only ever shows through under `contain`, so at `native` size
the effective background is always `transparent`.

`#ffffff` is the default on every capture surface — the browser picker, the
HTTP routes, `baguette screenshot`, `baguette record`: a capture with a
letterbox is usually a finished artefact, and a marketing shot on a
checkerboard is not what anyone meant. `baguette render-3d` is the one
exception, defaulting to `transparent`: its whole point is a device you can
drop onto your own background.

## Who speaks it

| surface | how the size is said |
|---|---|
| `baguette screenshot` | `--size` / `--fit` / `--background` |
| `baguette record` | `--size` / `--fit` / `--background` (hex only) |
| `baguette render-3d` | `--size` / `--background` (`--fit` is a *different* axis — see below) |
| `GET …/screenshot.{jpg,png}` | `?size=&fit=&background=` |
| `GET …/screenshot-bezel.png` | `?size=&fit=&background=` |
| `POST …/render-3d.png` | `"size"` / `"background"` in the body (`"fit"` is the mesh axis) |
| `WS …/stream.3d.<fmt>` | `size=` (or explicit `width=&height=`) |
| toolbar picker | the size menu, persisted per surface |

A `native` capture sends no query parameters at all, so an old server and a
new page still agree on the default case.

**One name, two axes: `fit` on `render-3d`.** Everywhere else, fit says how a
frame sits inside the output canvas. On the 3D render it says how the
*screenshot* sits on the device's screen surface — a UV placement on the
mesh. Hence its default is `cover` there and `contain` here: an app
screenshot letterboxed inside a phone display would read as a bug. The three
mode names mean the same thing in both places (fill and crop / fit and pad /
distort); what they act on differs, so a UI must not forward its canvas fit
into a 3D render request. See [3d-rendering](../3d-rendering/README.md).

The 3D view's picker hides fit, background and the bezel toggle — controls
that surface can't honour.

## Filenames

A saved capture is named for what it is, so a folder of marketing shots sorts
and greps sensibly:

```
iPhone_17_Pro-2026-08-18T10-31-02-appstore-6.9-1290x2796.png
iPhone_17_Pro-2026-08-18T10-31-02-1206x2622.mp4       ← native
```

The resolved dimensions stand alone at `native` and are prefixed with the
size spec otherwise. Anything outside `[A-Za-z0-9._-]` becomes a hyphen, so
`16:9` lands as `16-9-4971x2796` — a colon is legal in an HFS+ filename, but
the Finder renders it as a slash, so `16:9-…png` would read like a path.

## Gotchas

- **JPEG has no alpha.** A `.jpg` cannot carry a transparent letterbox, so it
  mats *white* rather than honouring the request — an unmatted transparent
  canvas would flatten to black. Ask for PNG when you want the mat genuinely
  absent. Nothing warns you; format and background are independent flags.
- **MP4 has no alpha either.** `baguette record --background transparent` is
  rejected at argument-parse time, so you learn before the ten-second take
  rather than after.
- **Ratios never downscale**, so asking a tall phone for `16:9` produces a
  very wide canvas (4971 × 2796 from a 1290 × 2796 source). Use an explicit
  `WIDTHxHEIGHT` when you want a bounded output.
- **The size is a canvas, not a resample budget.** A `contain` plan of a fixed
  preset larger than the source upscales the source to fit; nothing sharpens
  it. `appstore-6.9` off a 1206 × 2622 simulator is a genuine 1290 × 2796 file
  made of interpolated pixels. Capture at native resolution if you need real
  detail.
- **A video canvas is rounded up to even dimensions.** H.264 4:2:0 chroma
  subsampling requires it, so `baguette record` grows the planned canvas by up
  to one pixel per axis and re-centres the frame. A recording and a
  screenshot at the same preset can differ by a pixel; the recording is never
  stretched to hide it.
- **A browser recording's size is locked when it starts.** If the live stream
  reconfigures its scale part-way through, later frames are re-planned into
  the box frozen at Record. Changing the picker takes effect on the next
  recording, not the current one.
- **The bezel toggle is only meaningful where a bezel exists.** On the 3D
  stage the source is already a rendered device, so the toggle is suppressed
  rather than silently ignored.
- **Presets are a snapshot of Apple's requirements.** When Apple changes the
  submission sizes, the preset changes with them — pin an explicit
  `WIDTHxHEIGHT` if you need a size that never moves.

## See also

- [design.md](design.md) — why one vocabulary, the paired Swift/JS geometry, bezel-composite growth
- [screenshot](../screenshot/README.md) · [recording](../recording/README.md) · [3d-rendering](../3d-rendering/README.md)
