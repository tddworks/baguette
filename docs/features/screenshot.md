# Screenshot

One-shot JPEG of the simulator's framebuffer. Two entry points share
the same capture path:

- `GET /simulators/:udid/screenshot.jpg` — served by `baguette serve`,
  returns `image/jpeg` bytes.
- `baguette screenshot --udid <UDID>` — CLI; writes to `--output` or
  stdout.

If you want the live recording-and-overlays story instead, read
[`recording.md`](recording.md). This doc is scoped to single-frame
capture — pipeline shape, the tunables, and the few non-obvious
trade-offs.

## Why

`baguette serve` already streams via WebSocket and accepts `snapshot`
as an inline verb on that channel, but two real workflows wanted a
plain HTTP fetch:

- **Browser cache-busting** — `<img src="…/screenshot.jpg?t=…">` with
  a rotating timestamp is the simplest possible "refresh on demand"
  affordance for review tools and dashboards. No WS plumbing needed
  in the embedding page.
- **CLI / CI** — `curl -o shot.jpg …` and `baguette screenshot --output
  shot.jpg` drop into shell pipelines, golden-image diffs, and bug
  reports without spinning up a stream session.

The endpoint name and content-type match what every browser already
expects from an `<img>` tag — no new client code path on the page.

## Surface

```
GET /simulators/:udid/screenshot.jpg[?quality=0.85][?scale=1]
                                                    │
                                                    ▼
   200 image/jpeg                                ScreenSnapshot.capture
   404 application/json   {"ok":false,"error":"unknown udid: <udid>"}
   500 application/json   {"ok":false,"error":"<details>"}
```

```
baguette screenshot --udid <UDID> [--output <path>] [--quality 0.85] [--scale 1]
```

`--output` defaults to stdout, so it composes with redirection:

```bash
baguette screenshot --udid 5A1B… > shot.jpg
baguette screenshot --udid 5A1B… --output /tmp/shot.jpg
baguette screenshot --udid 5A1B… --quality 0.6 --scale 2 > thumb.jpg
```

## Pipeline

```
ScreenSnapshot.capture(screen, quality, scale, timeout)
   1. open SimulatorKit Screen (registers framebuffer callbacks)
   2. await first IOSurface delivered to the @Sendable callback
        ─ first-claim wins:           timer fires    → throw .timeout
                                      callback fires → encode + return
                                      start() throws → propagate error
   3. if scale ≥ 2: Scaler.downscale → CVPixelBuffer
      else:         use IOSurface zero-copy
   4. JPEGEncoder.encode → Data
   5. defer { screen.stop() }
```

The `SnapshotSession` actor-of-sorts (`@unchecked Sendable` holder)
owns the encoder, scaler, and a single-shot `claim()` flag. Three
producers race for the flag — the timeout timer, the frame callback,
and the `screen.start()` throw path — and only the first wins, so the
continuation can never resume twice.

The same helper drives both the HTTP route and the CLI; quality / scale
defaults match between them (`0.85`, `1`) so tooling that calls one
sees the same bytes as tooling that calls the other.

## Why a separate path, not "stream + read one frame"?

Three reasons:

1. **No WS handshake.** The HTTP route is a single GET; embedding pages
   and curl scripts don't need to know how to speak the binary frame
   format or the JSON control verbs.
2. **No reconfig churn.** A streaming session would have to be opened,
   asked to emit a snapshot, then closed — which on a busy simulator
   means waiting for the next encoder seam. The one-shot path bypasses
   the encoder entirely; it just grabs the next IOSurface that
   SimulatorKit hands over.
3. **No live-stream interference.** A snapshot grabbed via the WS
   `snapshot` verb shares the live encoder pacing (`StreamConfig.fps`,
   `scale`). The HTTP screenshot ignores both — `?scale=` and
   `?quality=` only affect the returned JPEG, never the live stream.

`?quality` and `?scale` mirror the WS knobs deliberately so callers
can pick the same trade-off they're used to from the streaming path.

## Tunables

| Knob        | CLI flag       | URL param   | Default | What it changes |
|-------------|----------------|-------------|---------|-----------------|
| Quality     | `--quality`    | `?quality=` | `0.85`  | JPEG lossy compression (0.0 – 1.0) |
| Scale       | `--scale`      | `?scale=`   | `1`     | Integer downscale divisor (1 = native, 2 = half, …) |
| Output path | `--output, -o` | —           | stdout  | CLI only |

Both `quality` and `scale` are clamped to sane minima — `scale` is
floored at `1`, `quality` is whatever `kCGImageDestinationLossyCompressionQuality`
clamps it to (effectively `[0, 1]`).

## Timeouts and errors

`ScreenSnapshot.capture` takes a `timeout: TimeInterval = 2.0`. Two
real failure modes it guards against:

- **Idle simulator** — SimulatorKit only fires the framebuffer callback
  on a frame change. A simulator booted but quiescent (lock screen
  with no clock tick visible, headless test runner waiting on input)
  may not emit a frame for several seconds. The timeout converts that
  into a clean 500 / `Failure.timeout` instead of a hanging request.
- **Wedged GPU pipe** — pre-iOS-26 simulators occasionally lose their
  framebuffer descriptor mid-session. Without the timeout the await
  is unbounded.

The HTTP layer translates everything to `application/json` error
envelopes; the CLI exits non-zero with the underlying message logged.

## Files

```
Sources/Baguette/
├── Infrastructure/
│   └── Screen/
│       └── ScreenSnapshot.swift         capture helper (this doc)
├── Infrastructure/
│   └── Server/
│       └── Server.swift                  /screenshot.jpg route
└── App/
    ├── Commands/
    │   └── ScreenshotCommand.swift       baguette screenshot
    └── RootCommand.swift                 registers ScreenshotCommand
```

## Known limits

- **No PNG.** Only JPEG. Browsers care about the extension; switching
  to `screenshot.png` would mean wiring `CGImageDestination` to
  `public.png` and a new route — easy, just not built.
- **No bezel composite.** The endpoint returns the raw simulator
  framebuffer. Compositing the DeviceKit bezel around it is a browser-
  side concern (`bezel.png` + the JPEG layered in CSS / canvas) — same
  trade-off the live stream makes.
- **Synchronous on the request thread.** A request that has to wait
  the full 2 s for the timeout pins one Hummingbird request task. Not
  a problem at human-scale request rates; would matter under heavy
  scripted polling.

## Extension points

- **Region capture.** A `?rect=x,y,w,h` query param + a one-line
  `CGImage.cropping(to:)` would let dashboards grab just the status
  bar or a known UI region without a server-side composite step.
- **Bezel-composite variant.** A `screenshot-bezel.jpg` route layering
  `JPEGEncoder` over the rasterized DeviceKit composite would mirror
  what the device-farm wall already shows — useful for marketing
  capture without spinning up a browser.
- **WebP / AVIF.** The `CGImageDestination` switch is a one-line
  format string; smaller payloads at the same visual quality matter
  for thumbnail-heavy pages like `/farm`.
