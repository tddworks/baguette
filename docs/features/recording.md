# Recording

Server-side capture of the simulator's framebuffer to an MP4 file. One
button in the stream sidebar (and the device-farm focus pane) toggles
it on; the file appears as a download link the moment AVAssetWriter
finishes flushing the moov atom.

Lives at the existing `WS /simulators/:udid/stream` channel — the
verbs `start_record` and `stop_record` ride the same socket the live
stream uses. Finished files are served back over HTTP at
`/simulators/:udid/recording/:filename`.

If you want the end-to-end tap-to-`UITouch` story, read
[`../ARCHITECTURE.md`](../ARCHITECTURE.md). This doc is scoped to the
recording feature itself — what the pipeline looks like, why it sits
alongside the live stream rather than taking over a tap point inside
it, and the few non-obvious decisions worth pinning down.

## Why

Two requests pushed for it:

- **Reproducible bug evidence** — bug reports against simulator builds
  read better with a 10-second MP4 attached than a screenshot strip.
- **Demos / asset capture** — the same device-farm sessions used for
  reviews wanted a one-click "save the last minute" affordance.

The constraint was strict: don't disturb the live stream. The
streaming pipeline is already tuned for low-latency interactive use
(per-format encoders, a keep-alive pump, dynamic reconfig). Tying a
recorder to the live encoder couples recording quality to whatever
the user picked for streaming — which is the wrong default. A 60 fps
1290×2796 MP4 is the minimum bar regardless of whether the live
stream is at 8 fps thumbnail mode in the farm or 60 fps full quality
on the single-device page.

## Surface

```
WS  /simulators/:udid/stream                — same channel as live stream
                                               (verbs: start_record / stop_record)
GET /simulators/:udid/recording/:filename   — finished MP4 download
```

No new server endpoints; no client polls anything. The browser sends
`{type:"start_record"}` over the existing WS, the server replies
asynchronously with one of three text frames:

```
{"type":"record_started"}
{"type":"record_finished","url":"/simulators/<udid>/recording/<file>","filename":"…","format":"mp4","duration":12.34,"bytes":4567890}
{"type":"record_error","error":"…"}
```

`StreamSession.onText` (added alongside this feature) splits binary
frames from JSON text frames at the WebSocket level, so the same
socket carries encoded video bytes downstream and recording lifecycle
notifications without confusion.

## Pipeline

```
SimulatorKit framebuffer → IOSurface stream
    ├─→ Stream (mjpeg | avcc) → FrameSink → browser
    └─→ Recorder (parallel)   → AVAssetWriter → MP4 file
```

Two parallel `Screen` subscribers receive the same `IOSurface`
callbacks each time SimulatorKit composites a frame. The live stream
encodes for transport; the recorder encodes for storage. Neither
queue blocks the other.

`Screen.start(onFrame:)` registers a fresh callback UUID with
`com.apple.framebuffer.display`, so each call returns an independent
pipeline. Two parallel screens cost two callback registrations and
two `IOSurface` ref bumps per frame — negligible compared to the
encode work either side does.

## Why not tap the live encoder?

The first design tee'd the recorder into `AVCCStream`'s H.264 NALU
output and let `ffmpeg -c copy` mux them into MP4. Conceptually
clean — zero re-encode, near-zero CPU. In practice three things
broke it:

- **The live encoder uses a 5-second keyframe interval** so mid-stream
  IDRs don't stall the consumer. A recording started mid-stream had
  to wait up to 5 s for SPS/PPS, or force an extra IDR (cosmetic
  glitch on the live view).
- **`H264Encoder` emits the avcC parameter-set blob exactly once per
  session.** A recorder attaching mid-stream never saw it; ffmpeg
  refused to mux. Caching + replaying the description was a
  workaround, not a fix.
- **The keep-alive pump duplicates the last surface every `1/fps` s**
  to keep the consumer's `VideoDecoder` queue from going stale. Those
  duplicates carry the same content but different PTS — `ffmpeg -c
  copy` propagates them straight into the MP4, producing a video
  that judders even though the source wasn't.
- **MJPEG mode had no H.264 to copy.** Recording was simply unreachable
  for the farm tiles that ran MJPEG when WebCodecs was missing.

The current design takes the bytes upstream of any of those choices.
It costs one parallel encode, but on Apple Silicon VideoToolbox does
that almost free.

## Recorder

```swift
protocol Recorder: AnyObject, Sendable {
    func start(on screen: any Screen) throws
    func stop() async throws -> RecordingArtifact
    func cancel()
}
```

One implementation today: `AVAssetWriterRecorder`. `start` opens the
`Screen`, `stop` finalises the writer and returns the artifact,
`cancel` aborts without producing one (used by the WS-close `defer`).

### AVAssetWriter pipeline

```
IOSurface
  → CVPixelBuffer (BGRA, IOSurface-backed)
  → CVPixelBufferPool copy (recycled buffer; zero alloc steady-state)
  → AVAssetWriterInputPixelBufferAdaptor.append(buf, withPresentationTime:)
  → AVAssetWriter (H.264 / mp4 via VideoToolbox under the hood)
  → moov atom flush on finish
```

Settings:

| key | value | why |
|-----|-------|-----|
| codec | H.264 (High profile, auto level) | matches what the live AVCC stream uses, hardware-encoded |
| bitrate | 8 Mbps (configurable) | full-quality default; not coupled to the live stream's bitrate |
| keyframe interval | 60 (≈ 1 s) | smooth seek points without bloating file size |
| frame reordering | disabled | constrains encoder latency, mirrors the live AVCC config |
| `expectsMediaDataInRealTime` | true | tells AVAssetWriter to prioritise timeliness over peak quality |
| `+faststart` | implicit | moov goes at the front so the file plays before fully downloaded |

### PTS strategy

```swift
let elapsed = Date().timeIntervalSince(firstFrameWallClock)
let pts = CMTime(seconds: elapsed, preferredTimescale: 600)
```

Wall-clock relative to the first real frame. Two reasons:

- **Idle moments stay idle.** A synthetic frame counter at 60 fps
  would compress idle pauses (no surface emitted ⇒ no frame ⇒
  invisible gap on playback). Wall-clock PTS preserves the simulator's
  real cadence; if the simulator stalls, the recording shows the
  stall.
- **The keep-alive pump does not exist on the recorder side.** The
  recorder records only what SimulatorKit actually emits. No
  duplicates, no drift.

The `600` timescale is the standard QuickTime granularity — fine
enough for 60 fps (each frame ≈ 10 ticks) without overflowing
`CMTime` for any realistic recording length.

### Back-pressure

```swift
guard input.isReadyForMoreMediaData else { return }
```

If AVAssetWriter's input buffer is full, drop the frame instead of
blocking the screen queue. With `expectsMediaDataInRealTime = true`
this rarely fires on Apple Silicon — VT keeps up. Dropping is the
right failure mode anyway: the alternative would be back-pressure
into SimulatorKit's framebuffer thread, which is shared with the
live stream.

### Pixel buffer pool

The first frame primes
`AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool`. Subsequent
frames `CVPixelBufferPoolCreatePixelBuffer` a recycled buffer and
`memcpy` rows from the IOSurface-wrapped source into it. Net effect:
zero allocation in the steady state, single contiguous BGRA buffer
per append.

The first few frames before the pool exists fall back to a direct
`CVPixelBufferCreateWithIOSurface` so we don't drop the start of the
recording.

## File layout

```
$TMPDIR/baguette-recordings/<pid>/<udid>/<udid>-<ms-timestamp>.mp4
```

Per-process directory under `FileManager.default.temporaryDirectory`
— on macOS that resolves to `/var/folders/.../T/baguette-recordings/`,
not `/tmp/`. Each `baguette serve` run owns its own subtree, so a
fresh server start can't accidentally serve files left by a previous
session, and the OS reaps abandoned files on the usual schedule.

`RecordingsDirectory.resolve(udid:filename:)` rejects empty inputs and
any filename containing `/` or `..`, so the download route can't be
talked into reading outside its sandbox.

## Server dispatch

```swift
for try await frame in inbound {
    guard frame.opcode == .text else { continue }
    let line = String(buffer: frame.data)
    if let cmd = RecordingControl.parse(line) {
        await handleRecording(cmd, …)
        continue
    }
    handleInbound(line: line, stream: stream, dispatcher: dispatcher)
}
```

`RecordingControl.parse` is a tiny pure parser — same shape as
`ReconfigParser`. It matches `start_record` / `stop_record` and
returns nil otherwise so the rest of the dispatch chain (reconfig,
gestures) keeps working unchanged.

`handleRecording`:

- **start** — create a fresh `simulator.screen()`, hand it to a new
  `AVAssetWriterRecorder`, and stash the recorder in the WS task's
  `var recorder: AVAssetWriterRecorder?` slot. Send `record_started`
  back over the WS.
- **stop** — `await recorder.stop()`, send `record_finished` (or
  `record_error` on failure). The await suspends only this task;
  Hummingbird keeps queuing inbound frames at the socket level and
  we re-enter the loop when stop returns.

A `defer { recorder?.cancel() }` in `streamWS` covers the
WS-disconnects-mid-recording case. `cancel()` stops the screen
subscription, asks AVAssetWriter to abort, and removes the partial
file.

## Frontend

### `sim-stream.js`

A `recordingState` closure variable holds the per-stream lifecycle:

```js
const recordingState = { active, startedAt, timer, entries };
```

`window._simToggleRecord` sends the verb. `handleServerText` reacts
to the three lifecycle events. Optimistic UI flips the button to
"Saving…" the moment the user clicks Stop, since
`AVAssetWriter.finishWriting` can take a beat while it flushes the
moov atom.

Finished entries render below the Record button as styled download
links — filename, duration, size — using the standard `download="…"`
attribute so a click hits the recording route and saves the MP4.

### `farm-focus.js`

Mirrors the same lifecycle on the farm's focus pane. The toggle is a
new `data-action="toggle-record"` button in the Stream Controls card;
the entries surface in the same pane.

`FarmTile` gained an `onText` callback in its `StreamSession`
construction so per-tile JSON text frames bubble up. `FarmApp` routes
them to `FarmFocus.handleServerText` only when the udid is the
selected one — tiles in the grid don't surface a Record button (yet),
so dropping their text frames keeps the dispatch trivial.

### `stream-session.js`

A small but load-bearing change: `socket.onmessage` now splits binary
(→ decoder) from text (→ `onText` callback + log forwarding). Before
this, server-pushed text events were getting parsed by the decoder's
error fallback and silently dropped.

```js
socket.onmessage = (e) => {
  if (e.data instanceof ArrayBuffer) { this.decoder.feed(e); return; }
  try {
    const obj = JSON.parse(e.data);
    if (onText) onText(obj);
    if ((obj.type === 'error' || obj.ok === false) && obj.error) log(obj.error, true);
  } catch { /* not JSON; ignore */ }
};
```

## Testing approach

The pure / value parts are Chicago-style state-tested:

| target | suite |
|---|---|
| `RecordingFormat`, `RecordingArtifact` | `RecordingArtifactTests` |
| `RecordingControl.parse` | `RecordingControlTests` |
| `RecordingsDirectory` (path traversal, resolution) | `RecordingsDirectoryTests` |

`AVAssetWriterRecorder` is tested via integration — running a real
simulator screen against it requires a booted device, which lands
in the manual test plan rather than CI. Its pure helpers
(`makePooledBuffer`, the configure-on-first-frame branch) are
covered indirectly via end-to-end runs.

## Known limits

- **One recording per stream session.** Concurrent recordings against
  the same WS aren't useful (you'd get two files of the same screen)
  and aren't gated explicitly — `start_record` while already recording
  is a no-op.
- **No audio.** SimulatorKit exposes audio through a separate path
  that isn't wired into the recorder yet.
- **Dimensions fix on the first frame.** A simulator that rotates
  mid-recording will produce a file with letterboxed orientation.
  Detecting orientation changes and reconfiguring the writer mid-
  stream is doable but not done.
- **No cleanup policy.** Files persist for the life of the
  `baguette serve` process, then `/var/folders` reaps them on the
  OS's normal schedule. A `--recording-dir` override + LRU eviction
  would be a small follow-up.

## Extension points

- **New container format**: add a case to `RecordingFormat`; the
  artifact metadata and download route already key off
  `format.fileExtension`. AVAssetWriter supports `.mov` natively —
  one settings tweak away.
- **Audio track**: add a second `AVAssetWriterInput` for audio,
  connected to a SimulatorKit audio capture. The MP4 muxer accepts
  multi-track input; the recording protocol would gain
  `start_record` options.
- **Server-side region crop / scale**: AVAssetWriter accepts a
  `transform` matrix on its input. Useful for "record without bezel"
  or "record at half-resolution" — both wireable as start_record
  options.
- **Per-tile recording in the farm grid**: today only the focused
  tile has a Record button. The wiring is the same — every
  `FarmTile` already routes server text frames; surface a button
  per tile and route the verb through `FarmTile.startRecord` /
  `stopRecord`.

## Surface deltas vs. live stream

| concern | live stream | recorder |
| --- | --- | --- |
| screen subscription | one (owned by the stream) | parallel, owned by recorder |
| encoder | per-format (MJPEG / VT H.264) | VT H.264 via AVAssetWriter |
| bitrate / fps / scale | reconfigurable mid-stream | fixed for a recording session |
| timestamps | n/a (live) | wall-clock PTS, 600 timescale |
| keep-alive pump | yes (1/fps) | no — only real surfaces |
| transport | binary WS frames | MP4 file on disk |
| cleanup | WS close stops the stream | WS close cancels in-flight recording |
