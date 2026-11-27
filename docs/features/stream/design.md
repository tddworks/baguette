---
description: Why a live stream skips ahead instead of queueing — the WebSocket viewer's frame allowance and keyframe recovery, and the encoder watchdog both the WebSocket and WebRTC viewers share. Read before touching FrameBacklog, WebSocketFrameSink, LatestFrame, VideoEncoder or frame-decoder.js.
---

# A live picture skips; it never queues

**Status:** BUILT (2026-11-27). Ideas taken from [Sill](https://github.com/Saffsanity/sill),
a Mac-to-iPad window streamer that stays smooth on the same kind of
pipeline (VideoToolbox HEVC, one frame inside the encoder, a TCP link).

This document owns **what the AVCC WebSocket stream does when a viewer
falls behind, how the page recovers a lost picture, and what every
encoded stream — WebSocket and WebRTC alike — does when the encoder stops
answering**. The encoder's
tuning and the frame pacing are in [README.md](README.md); WebRTC's own
recovery (NACK, PLI, congestion control) is in [webrtc/design.md](../webrtc/design.md).

## The problem

Every hiccup between the encoder and the viewer — a busy tab, a Wi-Fi
blip, a garbage-collection pause — left frames waiting on the socket.
The AVCC backlog kept *every* reference frame, because each H.264 / HEVC
delta needs the one before it, and gave up only at **32 MiB**: half a
minute of lag at 8 Mbit/s before anything gave. A queue on a live picture
buys latency, not smoothness, and the lag never caught up.

On the page, a `VideoDecoder` that reported an error was rebuilt at the
next keyframe — but nothing asked for one, so the picture froze until the
encoder's periodic IDR, up to `keyFrameIntervalSeconds` (5 s) later.

## The one sentence

**When a viewer is more than a few frames behind, the next delta is not
sent; the viewer waits for a keyframe, which the stream is asked for at
once, and which replaces everything still queued in front of it.**

```
 encoder ──▶ FrameBacklog (one per viewer) ──▶ drain task ──▶ WebSocket ──▶ page
              │                                                              │
              │ delta, ≥ frameAllowance waiting → dropped, ask a keyframe    │ decoder error, or its
              │ every delta after it            → dropped (already asked)    │ queue past 2 deltas →
              │ keyframe                        → queued; drops every frame  │ skip deltas until the
              │                                   queued before it but the   │ next key, send
              │                                   newest description         │ {"type":"force_idr"}
              ▼                                                              ▼
         stream.requestKeyframe()  ◀──────────────── force_idr ──────────────┘
```

## Laws

| # | Law | Owner |
|---|-----|-------|
| 1 | A viewer never has more than `frameAllowance` encoded frames (or `defaultByteBudget` bytes) waiting; past it, a delta is dropped rather than queued | `FrameBacklog` |
| 2 | Once a delta is dropped, every later delta is dropped until a keyframe: a delta without its reference decodes to garbage | `FrameBacklog` |
| 3 | A keyframe is never dropped, and it supersedes every frame queued before it except the newest decoder description | `FrameBacklog` |
| 4 | The stream is asked for a keyframe once per drop, not once per dropped frame | `FrameBacklog` (says when), `WebSocketFrameSink` (asks) |
| 5 | The page asks for a keyframe the moment its decoder loses the picture, and decodes no delta until one comes | `frame-decoder.js` |
| 6 | Streams whose frames the backlog can't read (`frameMetadata=1` packets) keep every frame and end at `referenceByteBudget`, as before | `FrameBacklog` |

`frameAllowance` is 6 frames, 100 ms at 60 fps: enough to absorb a
keyframe crossing the link with the deltas that follow it, short enough
that a stalled viewer is back on the live picture within one keyframe.

## Why these numbers, from Sill

- **Sill drops at 2 frames in flight** on a home link (`StreamServer`,
  "the delta-drop rule") and sends a parameter set plus keyframe when the
  device is ready again. Baguette counts frames *waiting behind the one
  being written*, a bit later than Sill's unacknowledged count, so it
  allows more.
- **Sill's remote rule found a loop**: dropping deltas *behind* a large
  keyframe that is still crossing wastes that keyframe, and the next one,
  and so on (0–3 fps on a hotspot). Law 3 is the local answer: a keyframe
  empties the queue in front of it, so it goes next, and the allowance
  leaves room for the deltas behind it.
- **Sill's device asks for a keyframe** when its display layer fails, with
  backoff (2 s, doubling to 32 s), because a still window sends none by
  itself. Baguette's still screen keeps re-encoding at `--fps`
  (`RefreshCadence`), so a keyframe asked for comes within a frame; the page
  needs no backoff beyond asking once per loss.

## MJPEG — the newest image, and only it

MJPEG is what a browser falls back to on a plain-`http://` LAN origin,
which has no WebCodecs — so it is what a phone or another computer on the
network gets. Measured 2026-11-27 on an iPhone 18 Pro at full size: **~890 KB
a JPEG at ~48 fps, ~340 Mbit/s**. No Wi-Fi link carries that; the backlog
then held 4 MiB of images and trimmed the *oldest*, so the viewer watched a
stale, stuttering queue.

**One sentence:** an MJPEG viewer has at most one image waiting — a newer
one replaces it — the stream starts at half size and 30 fps, and the page
decodes one image at a time and never paints an older one after a newer.

| # | Law | Owner |
|---|-----|-------|
| 10 | An MJPEG viewer has one image waiting at most; a newer image replaces it, so its frame rate is what its link carries | `FrameBacklog` |
| 11 | `serve` starts MJPEG at half size (`scale` 2) and 30 fps — about an eighth of the bytes; `set_scale` / `set_fps` still raise it | `StreamConfig.default(for:)` |
| 12 | The page decodes one JPEG at a time, keeping only the newest that arrived meanwhile, so images are painted in the order they were taken | `frame-decoder.js` |

## An encoder that stops answering — both viewers

The WebSocket and the WebRTC viewer are fed by the same `AVCCStream`:
`LatestFrame` hands VideoToolbox one frame and takes the next only when
that frame's answer comes. Sill saw the Mac's hardware encoder **wedge**
(a session takes a frame and never returns it, for hours) — with one frame
inside, the picture freezes for good and nothing says why. WebRTC can't
save it: a PLI only asks the same silent encoder for a keyframe.

**One sentence:** a frame the encoder has held past `stallLimit` is given
up on; the session is let go without waiting on it, and the next frame
opens a fresh one, which starts with a keyframe and its description.

| # | Law | Owner |
|---|-----|-------|
| 7 | A frame held past the stall limit frees the consumer for the next frame, and its late answer changes nothing | `LatestFrame` |
| 8 | Only a stream that sets a stall limit is watched; a frame answered in time is never given up on | `LatestFrame` |
| 9 | A session given up on is let go without waiting on the frame inside it; its late answers become nothing, and the next frame opens a new session that starts with a keyframe | `VideoEncoder` |

`stallLimit` is 1.5 s, Sill's: a healthy keyframe takes ~50 ms, so only a
wedged session gets there. `VTCompressionSessionInvalidate` on a wedged
session may itself block, so it is called off the encode queue.

## Not done yet

- **The slow state.** Sill found the hardware encoder settles into ~30 ms
  a frame (≈33 fps) after a stretch of few frames, at 3024×1964 but never
  at 1512×982, and opens a new session when it does (`EncoderSlowState`).
  A simulator's frame is in between; measure before copying it.
- **Per-second counters** (captured, encoded, sent, dropped, painted), the
  way Sill found its 33 fps plateau, so smoothness is measured, not
  guessed.
- **The still-screen refresh.** Re-encoding the last frame at full rate
  costs encoder time and bandwidth; Sill sends nothing while still. Sill
  also saw the hardware encoder slow down after stretches of few frames,
  so the refresh may be keeping it warm. Measure before changing it.
