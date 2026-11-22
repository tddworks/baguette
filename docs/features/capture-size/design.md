---
description: Why capture size is one vocabulary, how the Swift and JS geometry stay identical, and why a bezel composite grows to the framebuffer instead of the DeviceKit viewport.
---

# Capture size — design

## Path

- Every capture surface (CLI flags, `?size=&fit=&background=` query, the 3D
  body, the page's picker) parses into one `CaptureSize` + `CaptureFit` +
  background, and one `plan` decides the canvas and the draw rect.
- The painters decide nothing: `CaptureCanvas` (CoreGraphics) and the page's
  `CaptureComposer` (canvas) allocate the target, fill the background and
  draw the source where the plan says. The decisions live in `plan`, which is
  why the decisions are the part that's unit-tested.

## Why

Before this existed, every capture surface invented its own answer to
"how big?". `baguette screenshot` had `--scale`, an integer divisor.
`render-3d` had `--size WIDTHxHEIGHT`, literal pixels only. The
browser's screenshot gallery saved whatever the canvas happened to be,
and the recorder saved whatever the bezel viewport happened to be.
None of them could say "App Store 6.9-inch", which is the size people
actually need, and none of them agreed with each other.

Three things fall out of having one vocabulary:

- **A preset is a preset everywhere.** Pick `appstore-6.9` in the
  toolbar, then reproduce the exact same pixels in CI with
  `--size appstore-6.9`. No conversion table in the user's head.
- **One geometry implementation, twice.** Swift and JS both derive the
  canvas and the draw rect from the same rules, and the paired test
  suites assert the same numbers, so a browser capture and a CLI
  capture of the same frame land on the same bytes-worth of layout.
- **Sizes compose with the other capture choices.** Fit, background,
  and "with or without the device bezel" are the same three follow-up
  questions whatever produced the frame, so they travel together as
  one value rather than as four loose arguments per call site.

## Placement

Both implementations return the same placement value: the canvas
size, plus where the source lands inside it.

```
Swift   plan(source:fit:) → CapturePlacement
                            { width, height, drawX, drawY,
                              drawWidth, drawHeight }

JS      plan(sourceW, sourceH, fit)
                          → { width, height, drawX, drawY,
                              drawW, drawH,
                              sourceWidth, sourceHeight }
```

Same numbers, two spellings — the abbreviated `drawW` / `drawH` are
what canvas code reads, and the JS plan additionally carries the
source box it was computed from so a painter can recover the scale
without being handed the source size a second time (that is exactly
what `CaptureComposer.compose` does). Don't "unify" the field names
without changing both test suites; they assert the spellings.

Under `cover` the draw origin goes **negative** — that overflow is
the crop. `isIdentity(for:)` (Swift) reports the "nothing to do" case
so callers can keep the original bytes instead of resampling: a
native-size JPEG is passed through untouched rather than decoded,
redrawn, and re-encoded at a slightly different quality.

## Background at `native`

`background` only ever shows through under `contain`, so at `native` size the
effective background is always `transparent` — a PNG of a transparent 3D
render doesn't silently gain a white mat. A `.jpg` with a transparent
letterbox mats *white* on purpose: an unmatted transparent canvas flattens to
black on encode, and a black border is not what anyone meant by
"transparent".

## Filenames: why `slug()` sanitises

`CaptureSettings.slug(width, height)` is the fragment: the resolved
dimensions on their own at `native`, prefixed with the size spec
otherwise. It sanitises anything outside `[A-Za-z0-9._-]` to a hyphen,
so `16:9` lands as `16-9-4971x2796`.

That colon is worth a sentence, because it looks harmless. A colon is
perfectly legal in an HFS+ filename — the OS stores it — but the
Finder *renders* it as a slash, so `16:9-4971x2796.png` appears in
Downloads as `16/9-4971x2796.png` and reads like a path. Sanitising in
`slug()`, the single place both screenshots and recordings name their
files, is what keeps the two surfaces identical without each growing
its own private swap.

## The page's capture settings

`CaptureSettings` bundles the four things a user picks — size, fit,
background, and whether to composite the device bezel — into one immutable
value with `plan()`, `toQuery()` (the `?size=&fit=&background=` the routes
accept, and **nothing at all** for `native`), `slug()` for download
filenames, and `restore` / `persist` against `localStorage`.

`CaptureComposer` does the canvas jobs: `paintComposite` layers
bezel → clipped screen → overlay at natural size, and `compose` maps a
source-coordinate paint into the target canvas with the background
filled. Both `CaptureGallery` and `BrowserRecorder` had their own copy
of that rounded-rect clip before this existed.

`composite(frameImg, screen, sourceCanvas)` answers "how big is the
composite, really" — and the answer is **not** the bezel's own size.
DeviceKit authors its bezels in points: an iPhone 17 Pro Max frame is a
474 × 990 viewport around a 438 × 954 cutout, while the live canvas
carries the device's full 1320 × 2868 framebuffer. Compositing at the
viewport resamples the screen down by ~3× and throws the detail away
*before* the picked size gets a look at it, which defeats the point of
asking for an App Store size. So the composite grows until the cutout
is 1:1 with the frames and the bezel is scaled up to meet it — soft
chrome around a sharp screen beats a sharp frame around a thumbnail:

```js
const c = CaptureComposer.composite(frameImg, screen, canvas);
const plan = size.plan(c.width, c.height, fit);
CaptureComposer.compose(ctx, plan, background, (x) => {
  if (c.scale !== 1) x.scale(c.scale, c.scale);
  CaptureComposer.paintComposite(x, { frameImg, screen, sourceCanvas });
});
```

Growth is capped at 4× — a canvas the browser refuses to allocate
paints nothing at all — and the bezel-less path stays at 1:1, since
that canvas is already at capture scale.

## Hiding controls a surface can't honour

`CaptureSizeMenu` takes three flags, all defaulting to shown:

| flag | hidden when |
|---|---|
| `showFrameToggle` | the source already contains the device (the 3D stage) |
| `showFitToggle` | canvas fit isn't the caller's to set — `fit` on `render-3d` is a different axis ([README](README.md#who-speaks-it)) |
| `showBackgroundToggle` | the render fills its own canvas, so a mat never shows |

The 3D view hides all three. All three are read at **render** time
rather than captured in the constructor, so a caller flips them on the
instance when the view switches 2D ↔ 3D and reopens the popover — no
rebuilding the menu, no losing the current selection.

Offering a control a surface will ignore is worse than not offering
it: a user who sets `fit: contain` for a 3D render and watches nothing
change has learned something false about the feature.

## Loading the browser half

The `capture/*.js` files are ES modules: whatever records or captures imports
`CaptureSettings`, `CaptureSizeMenu`, `BrowserRecorder` or `CaptureGallery`,
and they import the size vocabulary they need. Nothing has to be loaded first.

## Known limits (contributor)

- **The two catalogues are kept in sync by hand.** There is no generated
  source of truth; the paired Swift and JS test suites assert the **same**
  numbers on both sides, and they are what catch a drift — the ratio
  arithmetic is the part that quietly drifts. Adding a preset means editing
  both catalogues and both tests.
- **A recording's size is locked when it starts** because `captureStream`
  binds to the compose canvas' backing store, so the canvas can't be resized
  mid-recording.
