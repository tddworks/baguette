# Recording

Video capture of a simulator, from two places that answer two
different questions:

- **In the browser** — capture of the live view exactly as you see it
  (bezel + screen + pinch overlay) to a WebM/MP4 file. One button in
  the stream sidebar, the native view's toolbar, and the device-farm
  focus pane toggles it on; clicking again stops, and the file shows
  up as a download link in the sidebar list.
- **`baguette record`** — a headless CLI verb that writes H.264 video
  (`.mp4` or `.mov`) of the raw framebuffer, for CI and scripted
  capture where no browser is involved.

Both take an output size from the shared vocabulary in
[`capture-size.md`](capture-size.md), so `--size appstore-6.9` on the
command line and "App Store 6.9″" in the toolbar picker mean the same
pixels.

The browser recorder reuses what the live view already has on the page —
the bezel `<img>` the Baguette SDK loaded, the screen geometry from
the SDK's `SimulatorDefinition.screen` (viewport / rect / clipRadius),
the live decoded canvas StreamSession is painting, and PinchOverlay's
existing dot positions. Nothing extra is fetched or allocated until
Record is pressed.

If you want the end-to-end tap-to-`UITouch` story, read
[`../ARCHITECTURE.md`](../ARCHITECTURE.md). This doc is scoped to
recording — the architecture, why we settled on a compose canvas
that only exists while recording, and the few non-obvious decisions
worth pinning down.

## Why

Two requests pushed for it:

- **Reproducible bug evidence** — bug reports against simulator builds
  read better with a 10-second clip + visible pinch fingers than a
  static screenshot strip.
- **Demos / asset capture** — the same device-farm sessions used for
  reviews wanted a one-click "save the last minute" affordance.
- **A specific output size** — an App Store preview clip and a
  bug-report GIF are not the same file. Once screenshots grew a size
  picker it made no sense for the recorder beside it to keep saving
  "whatever the bezel viewport happened to be".

For the browser recorder the constraint was strict: don't disturb the
live stream. The streaming pipeline already runs N hardware H.264
sessions in parallel under the device farm (one per booted simulator).
Adding a server-side recorder spawned another VT compression session
and pushed every device's frame-delivery off cadence — fixed by moving
that recording client-side.

`baguette record` came later and answers a different need: a build
script that wants a video artefact has no page to click Record on, and
no live stream to protect. The rest of this doc keeps the two apart
carefully, because the reasoning that rules server-side encode *out*
for one rules it *in* for the other.

## Surface

```
GET /recorder.js                    — BrowserRecorder module
GET /capture/capture-size.js        — the size vocabulary it plans with
GET /capture/capture-settings.js    — the user's selection, as one value
GET /capture/capture-composer.js    — the bezel/screen/overlay painter

baguette record --udid <UDID> --output clip.mp4|clip.mov
                [--size …] [--fit …] [--background '#ffffff']
                [--fps 30] [--duration 10] [--bitrate 8000000]
```

The browser recorder adds **no** server endpoints. The bezel image and
screen geometry it uses are the same `/simulators/:udid/bezel.png`
(the bare variant via `?buttons=false`) and
`/simulators/:udid/definition.json` the SDK already fetches; the
recorder doesn't refetch them — it reuses the references the SDK's
`Bezel` part already holds. The `capture/*.js` trio is what makes the
size options work; a page that doesn't load it still records, at the
natural composite size, after one `console.warn`. Recording is old
enough to predate the vocabulary — `sim.html` and the device farm both
used it before any of this existed — so a hard failure there would have
broken working pages for the sake of an option they never passed.

## Pipeline

```
Live view (DOM, untouched while idle)
  ├── SDK Bezel: <img bezel> + <div screenArea> + <canvas>
  └── PinchOverlay (SDK gesture): <div container> + <div> dots

   ── Record pressed ──────────────────────────────────────
   ↓
BrowserRecorder.start()
   1. { width, height, scale } =
        CaptureComposer.composite(frameImg, screen, canvas)
        bezel on  → screen.viewport GROWN until the screen cutout is 1:1
                    with the arriving frames (see below)
        bezel off → the source canvas, scale 1
   2. plan = settings.plan(width, height)
      allocate compose canvas at plan.width × plan.height   ← TARGET size
   3. start rAF compose loop:
        CaptureComposer.compose(ctx, plan, background, (c) => {
          if (scale !== 1) c.scale(scale, scale)
          CaptureComposer.paintComposite(c, {
            frameImg,        ← bezel under
            sourceCanvas,    ← live frames, clipped to the screen radius
            onOverlay,       ← pinch dots, inside that clip
          })
        })
   4. compose.captureStream(fps) → MediaRecorder

   ── Stop pressed ───────────────────────────────────────
   ↓
BrowserRecorder.stop()
   1. recorder.stop(), await final chunk
   2. cancel rAF loop, drop compose canvas
   3. blob = new Blob(chunks)
   4. return { url, blob, filename, mimeType, durationSeconds, bytes }
        filename carries the size slug:
          <device>-<stamp>-1206x2622.mp4               ← native
          <device>-<stamp>-appstore-6.9-1290x2796.mp4
```

When idle (no recording in flight) **nothing extra runs**. No paint
loop, no compose canvas, no extra references held. The live view is
exactly as it always was.

## Output size

The recorder plans against a `CaptureSettings` — the same value the
toolbar's size chip edits and the screenshot gallery reads. See
[`capture-size.md`](capture-size.md) for the preset table and the
placement maths; the recorder-specific parts are:

- **The compose canvas is allocated at the target size**, not at
  natural size with a resize afterwards. `CaptureComposer.compose`
  sets the transform so `paintComposite` keeps drawing in the source's
  own coordinates, letterboxed into the target box.
- **The size is locked at `start()`.** `captureStream` binds to the
  compose canvas' backing store, so the canvas can never be resized
  mid-recording — a MediaRecorder whose source canvas changes
  dimensions produces a broken file. If the live stream reconfigures
  its scale part-way through, later frames are re-planned against the
  box that was frozen at Record and letterboxed into it. Changing the
  picker takes effect on the *next* recording.
- **The bezel composite is supersampled before the target size is
  applied.** DeviceKit authors its bezels in points — an iPhone 17 Pro
  Max frame is a 474 x 990 viewport around a 438 x 954 cutout — while
  the live canvas carries the device's full 1320 x 2868 framebuffer.
  Compositing at the bezel's own size would resample the screen down
  by ~3x and throw the detail away before the picked size ever got a
  look at it, so `CaptureComposer.composite` grows the composite until
  the cutout is 1:1 with the arriving frames and scales the bezel up
  to meet it. Soft chrome around a sharp screen beats a sharp frame
  around a thumbnail. Growth is capped at 4x — a canvas the browser
  refuses to allocate paints nothing at all — and the bezel-less path
  stays 1:1, because that canvas is already at capture scale.
- **The filename carries the slug**, so a folder of clips says what
  each one is: `iPhone_17_Pro-<stamp>-appstore-6.9-1290x2796.mp4`.
  `CaptureSettings.slug()` sanitises the spec, so a ratio lands as
  `16-9-4971x2796` — a colon is legal in an HFS+ filename but the
  Finder draws it as a slash.

## Why a compose canvas, not a DOM-element capture?

The web platform's `ctx.drawImage` only accepts `<img>`, `<canvas>`,
`<video>`, `ImageBitmap`, and `SVGImageElement`. There's no
"rasterize this DOM subtree" API at video frame rate:

- **`Element.captureStream()`** — doesn't exist.
- **`<foreignObject>` SVG hack** — slow (~30–80 ms/frame), and the
  embedded `<canvas>` inside the foreignObject renders blank.
- **`getDisplayMedia` + Region Capture** — Chrome only, requires a
  permission prompt.
- **`html2canvas`** — same speed/correctness issues as the SVG hack.

But our DOM tree is only three things — a bezel `<img>`, a `<canvas>`,
and a few absolute-positioned dots. drawImage handles the first two
natively and GPU-accelerated. The dots are 4 lines of "read
`element.style.left`, `ctx.arc`". So "copy the DOM into a canvas"
reduces to drawing each layer manually — which is what the compose
loop does.

## Why the browser records the live view

Earlier attempts to record **the live stream** server-side didn't pan
out. This argument is about the live-stream and device-farm case, and
it is still correct — see the next section for why `baguette record`
is not the same situation.

1. **`ffmpeg -c copy` tap into AVCC** — `H264Encoder` emits SPS/PPS
   only on the first IDR; a recorder attaching mid-stream never saw
   them. The keep-alive pump duplicated the last surface every `1/fps`
   to keep `VideoDecoder` fresh, and `-c copy` propagated those
   duplicates into the MP4 — recording judders even though the source
   is smooth. MJPEG mode had no H.264 to copy at all.
2. **Parallel `Screen` subscription + `AVAssetWriter`** — frame-perfect
   and format-agnostic, but each booted device already runs a VT
   session for its live AVCC stream. Recording adds N+1 simultaneous
   VT sessions; per-session throughput drops, every farm tile stutters.

Browser-side sidesteps both: zero new server-side encode, the
recording matches what the user sees post-bezel, post-overlay.

## Why `baguette record` is a different question

Both objections above are about **a recorder attaching to a stream
that is already running for someone else**. Neither one holds for a
standalone CLI invocation, and it's worth being precise about why,
because the two answers otherwise look like the doc contradicting
itself:

| | recording the live stream | `baguette record` |
|---|---|---|
| SPS/PPS | encoder is already past its first IDR; a late attacher never sees the parameter sets | owns the encode from frame one, so it *emits* the first IDR |
| VT sessions | adds an N+1th session to N already running for the farm | the only session; there is no live stream competing |
| Pacing | must not disturb a viewer's cadence | nobody is watching; it sets its own fps |
| Composition | should match what the user sees (bezel, overlays) | there is no view — the raw framebuffer is the truth |

So the rejected design ("parallel `Screen` subscription +
`AVAssetWriter`") is exactly the design `baguette record` uses. It was
never wrong; it was wrong *as a passenger on a busy farm*. Run it on
its own and it is the frame-perfect, format-agnostic path the earlier
note called it.

The practical rule that falls out: **don't run `baguette record`
against a device whose stream a browser is also watching** if you care
about that browser's smoothness. You'll get a good recording and a
choppier live view, which is the N+1 problem back again — just now
opted into deliberately rather than imposed on every farm tile.

## `baguette record` — the CLI

```bash
baguette record --udid 5A1B… --output demo.mp4 --duration 10
baguette record --udid 5A1B… --output hero.mp4 --size appstore-6.9
baguette record --udid 5A1B… --output demo.mov --fps 60   # ^C to stop
```

It subscribes to the simulator's `Screen` — in parallel with nothing
else — and feeds surfaces to `AVAssetWriter` as H.264 (High profile,
a keyframe every 2 s).

| Flag | Default | Meaning |
|---|---|---|
| `--udid` | — | The booted simulator to record |
| `--output`, `-o` | — | **Required.** `.mp4` or `.mov` |
| `--size` | `native` | Output size, from [`capture-size.md`](capture-size.md) |
| `--fit` | `contain` | How the frame sits in that size |
| `--background` | `#ffffff` | Letterbox colour — hex only |
| `--fps` | `30` | 1–120 |
| `--duration` | — | Stop after N seconds; omit to run until SIGINT |
| `--bitrate` | `8000000` | Target bits per second |

There is no `--format`: the container is the `--output` extension, and
an unrecognised one is a validation error (`Unknown recording
container 'webm'. Expected one of: mp4 | mov`) rather than a file that
plays nowhere. There is no stdout path either — `AVAssetWriter` needs
a seekable destination, and a video is not a thing you pipe.

**Stopping.** `--duration` elapsing and SIGINT (`Ctrl-C`) do the same
thing, whichever comes first: flush the writer and close the file. An
interrupted recording is a playable file, not a truncated one. (`kill
-9` is not, and can't be.) On success one line goes to **stderr**, so
`--output` stays the only thing that touches your data:

```
Recorded 152 frames · 5.03s · 2796×2796 → /tmp/r.mp4
```

### Three things that differ from a screenshot

- **The size resolves against the first frame.** The simulator's own
  frame dimensions aren't known until SimulatorKit delivers one, so a
  ratio preset can't be planned before recording starts. It resolves
  once, on frame one, and holds for the take.
- **Even dimensions, always.** H.264 4:2:0 chroma subsampling wants
  even width and height, so the planned canvas is rounded **up** and
  the frame re-centred inside it. It is never stretched to fit — a
  half-pixel of letterbox is cheaper than a distorted recording.
- **`transparent` is rejected, not silently substituted.** MP4 has no
  alpha channel. `--background` takes `#RRGGBB` and nothing else, so
  you find out at argument-parse time rather than by discovering a mat
  you didn't choose in the finished file. (The screenshot routes make
  the opposite call and quietly mat white — a still is cheap to redo,
  a ten-second take is not.)

### Pacing: an idle simulator records nothing

SimulatorKit fires the framebuffer callback **on a frame change**, not
on a clock. `--fps` is therefore a ceiling enforced by *dropping*
frames that arrive too close together — never by duplicating the last
one to fill a gap. A simulator sitting on a static screen delivers no
frames at all, so a quiet stretch mid-recording costs nothing: the
last committed frame simply stays on screen for as long as the picture
didn't change.

The sharp edge is the degenerate case. A device nobody drives at all
delivers *zero* frames, and there is no such thing as a video of no
frames — so the command exits non-zero with

```
No frames captured — the simulator screen never changed.
Drive some input while recording.
```

rather than writing ten seconds of a still image. This is the same
quiescence that makes `screenshot` need a 2-second timeout; here it
surfaces as an error you can act on instead of a hang.

### Where it lives

```
Sources/Baguette/
├── Domain/Recording/          RecordingPlan / FrameCadence /
│                              RecordingFormat / RecordingError /
│                              RecordingSummary / ScreenRecorder
│                              + the @Mockable `Reel` collaborator
└── Infrastructure/Recording/  AVAssetWriterReel.swift
```

The usual split: `ScreenRecorder` owns the conversational lifecycle
(start / accept frame / pace / finish) against `any Reel` and is
driven by `MockReel` in `Tests/BaguetteTests/Recording/`; only the
`AVAssetWriter` calls are integration-only. `Reel` is named for what
it is — the thing frames are committed to — not for the pattern it
implements.

Nothing about this is wired into `baguette serve`: no route, no WS
verb. Server-side encode happens here and only here, for the reason
in the previous section.

## BrowserRecorder

```js
const rec = new BrowserRecorder({
  canvas,        // sim.canvas — already painting
  frameImg,      // sim._bezel.frameImg — already loaded
  screen,        // sim.screen.def — SDK SimulatorDefinition.screen
  overlayHost,   // sim.pinchOverlayContainer — already in DOM
  settings,      // CaptureSettings — size + fit + background + bezel
  bezel: true,   // false → the source canvas already IS the device
  fps: 60,
});
rec.start();
const artifact = await rec.stop();
//   { url, blob, filename, mimeType, durationSeconds, bytes }
rec.cancel();
```

Constructor takes references; nothing is fetched. `start()` allocates
the compose canvas, kicks off the paint loop, and spins up
`MediaRecorder` over `compose.captureStream(fps)`. `stop()` awaits the
final chunk, releases the compose canvas, and returns the artifact.

`settings` is the preferred way to say what you want. Loose
`captureSize` / `fit` / `background` options are read only when
`settings` is absent, so the older call sites kept working while the
picker was rolled out surface by surface. `bezel` defaults to
`settings.withFrame` — the picker's "Include bezel" checkbox and the
recorder agree without the caller wiring them together — and an
explicit `bezel` wins over both. Pass nothing but `canvas` and you get
the historical behaviour: native size, bezel on.

### MIME type probing

```js
const PREFERRED_MIME_TYPES = [
  'video/mp4;codecs=avc1.42E01E',  // Safari + Chrome (≥113)
  'video/webm;codecs=vp9',         // Chrome + Firefox
  'video/webm;codecs=vp8',         // older browsers
  'video/webm',                    // ultimate fallback
];
```

The first MIME `MediaRecorder.isTypeSupported` accepts wins; falling
through to `''` lets the browser pick its own default.

### Per-frame paint

The layering lives in `CaptureComposer`, not here:

```js
CaptureComposer.compose(ctx, plan, background, (c) => {
  CaptureComposer.paintComposite(c, {
    frameImg, screen, sourceCanvas,
    onOverlay: (c2, rect) => paintOverlayDots(c2, rect),
  });
});
```

`compose` clears, fills the background, and sets the transform;
`paintComposite` draws bezel → clipped screen → overlay. With no
bezel (or no chrome layout available) `paintComposite` degrades to
drawing the source canvas at the full rect, overlay included.

The degradation is per-layer, not all-or-nothing: a bezel that has
decoded still paints when the source canvas hasn't produced a frame
yet, and only the screen layer and its overlay are skipped. Pressing
Record in the first moments of a stream therefore opens on the device
chrome with a dark screen — which is what the live view shows too —
rather than on an empty canvas.

DeviceKit composite PDFs have an opaque dark "off-glass" tint in the
screen rect (designed to sit UNDER live content). Bezel goes first;
screen on top — same z-order the live DOM uses (`screenArea` z-index
2, frameImg z-index 1).

That painter is shared, and that was the point of extracting it:
`CaptureGallery` and `BrowserRecorder` each carried their own copy of
this z-order and their own hand-rolled rounded-rect path. Two copies
of a clip path is two chances for a screenshot and a recording of the
same device to disagree about where the screen ends.

### Pinch overlay copy

```js
const hostRect = overlayHost.getBoundingClientRect();
const sx = screenRect.width  / hostRect.width;
const sy = screenRect.height / hostRect.height;
for (const dot of overlayHost.children) {
  const left = parseFloat(dot.style.left);
  const top  = parseFloat(dot.style.top);
  ctx.arc(screenRect.x + left * sx,
          screenRect.y + top  * sy,
          18 * Math.max(sx, sy),
          0, Math.PI * 2);
  ctx.fill();
  ctx.stroke();
}
```

Reads PinchOverlay's existing DOM dots each tick — no caching, no
mutation. Position scaling maps host-local pixels (PinchOverlay's
host element) to composite-canvas coordinates.

### Performance

| phase | per-frame cost | total |
|---|---|---|
| `drawImage(frameImg)` (3.6 MP bitmap blit) | ~0.3 ms | hardware-accelerated |
| `drawImage(sourceCanvas)` clipped | ~0.5 ms | "" |
| 0–2 pinch dots (`arc + fill`) | ~0.05 ms | negligible |
| **per-frame paint total** | **~1 ms** | well under 60 fps budget |
| **idle (not recording)** | **0 ms** | nothing runs |

Recording adds ~6% of one core for the compose loop, plus whatever
the browser's VT/VPx encoder uses (typically hardware). The live
view stays untouched — DOM bezel, DOM PinchOverlay, current paint
cadence.

## Recording the 3D stage

The 3D viewport (see [`3d-rendering.md`](3d-rendering.md)) paints a
canvas like every other stream — `Sim3DPanel` shares `StreamSession`
with the 2D path — so recording it needs no new machinery. It needs
one thing turned **off**: the frames already contain a photorealistic
device, so wrapping them in a DeviceKit bezel would draw a phone
around a phone.

That's the `bezel: false` case — equivalently, handing the recorder no
`frameImg` and no `screen`, since a composite with no chrome to draw
degrades to the same thing. With it, the natural size is the source
canvas rather than the bezel viewport, `paintComposite` skips the
bezel and the screen clip entirely, and the size vocabulary applies
unchanged: `square` on a 1200 × 1200 3D canvas is still a square, it
is just a square with a rendered iPhone in it.

### …but `contain` is the wrong fit there

The 3D canvas is not a picture of a device the way the 2D canvas is —
it is a **viewport onto a scene**, a device standing in the middle of
empty margins. Letterboxing that whole viewport into a tall App Store
canvas therefore shrinks the *device* into the emptiness instead of
cropping the emptiness away, and a 6.9″ recording comes out as a small
phone adrift in bands.

A screenshot doesn't have this problem: it re-renders server-side at
the exact size and the RealityKit camera frames to whatever it renders
into. A recording has no such escape — `BrowserRecorder` composites
the stage canvas frame by frame as it arrives — so the fit has to
carry it:

```js
Sim3DPanel.recordingFit(settings, stageCanvas)  // → 'cover' | 'contain'
```

`cover` when the target is **narrower** than the stage: it eats the
side margins and keeps full height. `contain` when the target is
wider, because past that point there is no more device to show, only
bars — and cropping into the device is worse than a bar beside it.
From a 1600 × 1250 stage:

| size | fit | kept from the stage |
| --- | --- | --- |
| `appstore-6.9` | cover | 577 × 1250 — full height, sides cropped |
| `square` | cover | 1250 × 1250 |
| `9:16` | cover | 703 × 1250 |
| `16:9` | contain | letterboxed, the phone intact |

Only recordings, and only in 3D. In 2D the source canvas already *is*
the device, so the user's own fit choice stands.

**What this costs.** At `appstore-6.9` the recording upscales a
577 × 1250 region of the live stream to 1290 × 2796. The live 3D
stream is bounded at 1600 px per side for encoder cost (see
[`3d-rendering.md`](3d-rendering.md)), so that bound is the ceiling on
a 3D recording's real detail. Reshaping the stream to the target
aspect was tried and rejected: an App Store 6.9″ stream is 738 × 1600,
which `object-fit: contain` then upscales across a much larger stage,
so the live view went soft and its framing moved. Trading a visible
regression in the thing the user is looking at for a sharper file is
the wrong way round.

## Lifecycle on the page

### `sim-stream.js`

```js
const recordingState = {
  recorder, layout,
  active, startedAt, timer, entries,
};
```

`startStream` caches the chrome layout into `recordingState.layout`.
`_simToggleRecord` either constructs a `BrowserRecorder` from the
existing `surface.canvas` / `surface.frameImg` / `pinchOverlay.container`
references and calls `start()`, or stops the active one and pushes
the artifact onto `entries`. `stopStream` cancels any in-flight
recording and revokes Blob URLs to keep long sessions from leaking
memory.

The sidebar's Capture and Record controls share one size picker
between them — the selection is a property of "what I want out of this
device", not of which button produced it, so a screenshot and a clip
taken a second apart come out at the same dimensions.

### `sim-native.js`

The native (focus-mode) view had no Record button at all until the
size vocabulary landed; screenshots were its only capture. It now
carries both, side by side in the toolbar: a size chip mounted by
`CaptureSizeMenu` (persisted under its own storage key, so the native
view and the legacy sidebar remember separate selections) and a
Record button that shows an elapsed `mm:ss` readout while running.
Finished clips collect in a dock whose rows are download links; closing
it revokes the Blob URLs.

The button is hidden outright when `MediaRecorder` is unavailable
rather than rendered and failing on click. An in-flight recording is
cancelled on the transitions that invalidate its source canvas —
flipping 2D↔3D, a stream restart (a codec swap reallocates the
canvas), and page unload.

### `farm-focus.js`

The focus pane gets a recorder context closure from FarmApp:

```js
this.focus.show(device, tile, {
  ...,
  getRecorderContext: () => ({
    canvas:      tile?.canvas || null,
    frameImg:    focusScreen?.querySelector('img'),
    screen:      this.definitions.get(udid)?.screen || null,
    overlayHost: tile?.overlayContainer() || null,
  }),
});
```

Re-evaluated on each Record press so a re-focus mid-session can't
strand the recorder on a stale tile. The focus pane owns its own
`recording` state slot, and its own size picker — the farm's focus
pane is where marketing captures actually get taken, so it gets the
same chip as the single-device views rather than inheriting a global.

## Frontend module layout

```
Resources/Web/
├── recorder.js           BrowserRecorder (this feature)
├── stream-session.js     decode + paint loop (unchanged)
├── frame-decoder.js      MJPEG / AVCC decoders (unchanged)
├── capture-gallery.js    one-shot screenshot composite (SDK shape)
├── capture/              the shared size vocabulary
│   ├── capture-size.js       presets + placement maths
│   ├── capture-settings.js   the user's selection, persisted
│   ├── capture-composer.js   bezel/screen/overlay painter
│   └── capture-size-menu.js  the toolbar picker
├── baguette/             Baguette SDK
│   ├── parts/bezel.js    bezel chrome for the live view
│   ├── parts/screen.js   screen + PointerInterpreter + PinchOverlay
│   └── …
├── sim-stream.js         single-device orchestrator
└── farm/
    ├── farm-focus.js     focus pane
    ├── farm-tile.js      per-device StreamSession + SDK Simulator
    └── …
```

`recorder.js` is loaded by exactly two pages — `sim.html` and
`farm/farm.html` — via `<script src="/recorder.js">`, the same pattern
as the other shared modules. The native view has no script tag of its
own: `sim-native.html` is a *template* that `sim-native.js` extracts
into the live page, and `sim.html` is what loads both of them. Each of
the two pages loads the `capture/` trio first, so `CaptureSize`,
`CaptureSettings`, and `CaptureComposer` are on `window.Baguette`
before `start()` — and see [Surface](#surface) for what happens when
they aren't.

## Browser support

| browser | container | notes |
| --- | --- | --- |
| Chrome 113+ | MP4 (H.264) or WebM (VP9) | preferred path |
| Safari 14.1+ | MP4 (H.264) | works; isTypeSupported reports MP4 |
| Firefox | WebM (VP9 / VP8) | no MP4 muxer |
| Older / strict CSP | n/a | Record button hides itself when `MediaRecorder` is undefined |

## Testing approach

The recorder itself is a small JS module wired into three
orchestrators (`sim-stream.js`, `sim-native.js`, `farm-focus.js`) and
is exercised manually via the live UI; a future iteration could add a
thin offscreen-canvas test (`puppeteer + headless captureStream`
works) — not yet in the repo. What *is* unit-tested is everything it
delegates to: `Tests/Web/capture-size.test.js`,
`capture-settings.test.js`, and `capture-composer.test.js` cover the
placement maths, the persisted selection, and the paint geometry, so
"the recording came out the wrong size" is a covered failure even
though "the recording came out" isn't.

`baguette record` splits the same way the other Infrastructure
adapters do: the frame pacing and size planning are unit-covered,
and the irreducible `AVAssetWriter` calls stay integration-only.

## Known limits

- **No audio.** SimulatorKit exposes audio through a separate path
  not surfaced here, and recording the simulator's audio output
  would need a `MediaStreamAudioSourceNode` we don't currently have.
- **Tap rings aren't drawn.** Only pinch / 2-finger gestures populate
  PinchOverlay today, so single taps don't show in the recording.
  Extending PinchOverlay to render a brief auto-fading dot for taps
  is a small follow-up; the recorder picks them up automatically.
- **Long recordings live in RAM** *(browser only)*. The Blob
  accumulates `chunks` until Stop. Multi-minute recordings at 1080p
  are fine; multi-hour ones are not. `baguette record` writes through
  `AVAssetWriter` to the output path as it goes and has no such
  ceiling.
- **The size is fixed for the whole clip.** Both recorders decide the
  output box when they start and letterbox every later frame into it.
  Rotating the device mid-recording therefore letterboxes rather than
  resizing the file — which is the right answer for a video container,
  but it does mean a portrait→landscape clip is framed for whichever
  came first.
- **`baguette record` records the framebuffer, not the view.** No
  bezel, no pinch overlay, no cursor — those are browser-side layers.
  If you want the composite, record in the browser.
- **Running both at once costs the live view.** A CLI recording of a
  device a browser is streaming reintroduces the N+1 VideoToolbox
  problem for that device. It works; the live view gets choppier.

## Extension points

- **More overlays.** The compose loop is one function per layer;
  adding a frame counter, a watermark, or a region highlight is one
  `ctx.draw…` call away.
- **Audio.** The one genuinely missing track.
- **Bezel on the CLI path.** `baguette record` could composite the
  DeviceKit chrome server-side the way `screenshot-bezel.png` does —
  the artwork and the layout are already available to the process; it
  is a per-frame draw the recorder currently doesn't do.
- **Remote record trigger.** The browser recorder is still only
  startable by a human clicking Record. A WS verb the page listens
  for (`{type:"record"}` → click the button) would let a script drive
  a *composited* recording, which `baguette record` deliberately
  doesn't produce.
- **Frame-accurate trimming.** Both paths give you the whole take;
  neither trims. `--duration` is a stop condition, not an edit.
