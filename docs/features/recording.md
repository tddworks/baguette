# Recording

Browser-side capture of the live view (bezel + screen + pinch overlay)
to a WebM/MP4 file. One button in the stream sidebar (and the device-
farm focus pane) toggles it on; clicking again stops, the file shows
up as a download link in the sidebar list.

The recording reuses what the live view already has on the page —
the bezel `<img>` DeviceFrame loaded, the chrome layout already
fetched, the live decoded canvas StreamSession is painting, and
PinchOverlay's existing dot positions. Nothing extra is fetched or
allocated until Record is pressed.

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

The constraint was strict: don't disturb the live stream. The streaming
pipeline already runs N hardware H.264 sessions in parallel under the
device farm (one per booted simulator). Adding a server-side recorder
spawned another VT compression session and pushed every device's
frame-delivery off cadence — fixed by moving the whole recording
client-side.

## Surface

```
GET /recorder.js                    — BrowserRecorder module
```

No new server endpoints. The bezel image and chrome layout the
recorder uses are the same `/simulators/:udid/bezel.png` and
`/simulators/:udid/chrome.json` the live view already fetches; the
recorder doesn't refetch them — it reuses the references DeviceFrame
already holds.

## Pipeline

```
Live view (DOM, untouched while idle)
  ├── DeviceFrame: <img bezel> + <div screenArea> + <canvas>
  └── PinchOverlay: <div container> + <div> dots

   ── Record pressed ──────────────────────────────────────
   ↓
BrowserRecorder.start()
   1. allocate compose canvas at layout.composite size
   2. start rAF compose loop:
        clearRect
        drawImage(frameImg)                     ← bezel under
        clip(roundRect screen)
          drawImage(sourceCanvas, screenRect)   ← live frames
          paintOverlayDots(overlayHost)         ← pinch dots
   3. compose.captureStream(60) → MediaRecorder

   ── Stop pressed ───────────────────────────────────────
   ↓
BrowserRecorder.stop()
   1. recorder.stop(), await final chunk
   2. cancel rAF loop, drop compose canvas
   3. blob = new Blob(chunks)
   4. return { url, blob, filename, mimeType, durationSeconds, bytes }
```

When idle (no recording in flight) **nothing extra runs**. No paint
loop, no compose canvas, no extra references held. The live view is
exactly as it always was.

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

## Why not server-side?

Earlier server-side iterations didn't pan out:

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

## BrowserRecorder

```js
const rec = new BrowserRecorder({
  canvas,        // surface.canvas — already painting
  frameImg,      // surface.frameImg — already loaded
  layout,        // chrome.json layout — already fetched
  overlayHost,   // pinchOverlay.container — already in DOM
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

```js
ctx.clearRect(0, 0, cw, ch);
if (useBezel) {
  ctx.drawImage(frameImg, 0, 0, cw, ch);          // bezel under
  ctx.save();
  roundRectPath(ctx, s.x, s.y, s.width, s.height, r);
  ctx.clip();
  ctx.drawImage(sourceCanvas, s.x, s.y, s.width, s.height);
  paintOverlayDots(ctx, s);                        // dots inside clip
  ctx.restore();
} else {
  ctx.drawImage(sourceCanvas, 0, 0, cw, ch);
  paintOverlayDots(ctx, { x: 0, y: 0, width: cw, height: ch });
}
```

DeviceKit composite PDFs have an opaque dark "off-glass" tint in the
screen rect (designed to sit UNDER live content). Bezel goes first;
screen on top — same z-order the live DOM uses (`screenArea` z-index
2, frameImg z-index 1).

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

### `farm-focus.js`

The focus pane gets a recorder context closure from FarmApp:

```js
this.focus.show(device, tile, {
  ...,
  getRecorderContext: () => ({
    canvas:      tile?.canvas || null,
    frameImg:    focusScreen?.querySelector('img'),
    layout:      this.chromeLayouts.get(udid) || null,
    overlayHost: tile?.pinchOverlay?.container || null,
  }),
});
```

Re-evaluated on each Record press so a re-focus mid-session can't
strand the recorder on a stale tile. The focus pane owns its own
`recording` state slot.

## Frontend module layout

```
Resources/Web/
├── recorder.js           BrowserRecorder (this feature)
├── stream-session.js     decode + paint loop (unchanged)
├── frame-decoder.js      MJPEG / AVCC decoders (unchanged)
├── device-frame.js       bezel chrome for the live view (unchanged)
├── capture-gallery.js    one-shot screenshot composite (unchanged)
├── sim-input.js          PinchOverlay + MouseGestureSource (unchanged)
├── sim-stream.js         single-device orchestrator
└── farm/
    ├── farm-focus.js     focus pane
    ├── farm-tile.js      per-device StreamSession
    └── …
```

`recorder.js` is loaded by both `sim.html` and `farm/farm.html` via
`<script src="/recorder.js">` — same pattern as the other shared
modules.

## Browser support

| browser | container | notes |
| --- | --- | --- |
| Chrome 113+ | MP4 (H.264) or WebM (VP9) | preferred path |
| Safari 14.1+ | MP4 (H.264) | works; isTypeSupported reports MP4 |
| Firefox | WebM (VP9 / VP8) | no MP4 muxer |
| Older / strict CSP | n/a | Record button hides itself when `MediaRecorder` is undefined |

## Testing approach

The recorder is a small JS module wired into two orchestrators
(`sim-stream.js`, `farm-focus.js`). It's exercised manually via the
live UI today; a future iteration could add a thin offscreen-canvas
test (`puppeteer + headless captureStream` works) — not yet in the
repo.

There are no Swift Testing suites for recording: the server isn't
involved.

## Known limits

- **No audio.** SimulatorKit exposes audio through a separate path
  not surfaced here, and recording the simulator's audio output
  would need a `MediaStreamAudioSourceNode` we don't currently have.
- **Tap rings aren't drawn.** Only pinch / 2-finger gestures populate
  PinchOverlay today, so single taps don't show in the recording.
  Extending PinchOverlay to render a brief auto-fading dot for taps
  is a small follow-up; the recorder picks them up automatically.
- **Long recordings live in RAM.** The Blob accumulates `chunks` until
  Stop. Multi-minute recordings at 1080p are fine; multi-hour ones
  are not.

## Extension points

- **More overlays.** The compose loop is one function per layer;
  adding a frame counter, a watermark, or a region highlight is one
  `ctx.draw…` call away.
- **Bezel toggle on the recorder.** Today the recorder uses bezel
  whenever `frameImg` and a chrome layout are passed. A "record
  without bezel" toggle is a one-line condition in
  `BrowserRecorder._paint`.
- **CLI-issued record trigger.** The browser is the recorder, but a
  WS verb the page listens for (`{type:"record"}` → click the button)
  would let `baguette serve` start recordings remotely without user
  interaction.
