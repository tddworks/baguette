---
description: Design for sending H.265 (HEVC) to a WebRTC viewer — why and when it pays, the HEVC encoder, ?codec= from the page to the kit, and the measurement that decides whether it becomes the default. Read before touching the viewer's encoder or the WHEP request's codec.
---

# HEVC over WebRTC — "the same picture in fewer bits, when the viewer can take it"

**Status:** the kit's part is BUILT (K1–K3: packetizer, codec choice, offer
and answer); baguette's isn't (slices 4–7), so every viewer still gets
High-profile H.264. H.265 stays **opt-in** (`?codec=h265`) until slice 6
measures it winning; if it doesn't, the default never changes.

This document owns **why baguette would send H.265, how the live view asks for
it and encodes it, and how it is decided**. The codec choice, the SDP and the
packetizer are WebRTCKit's — the kit depends on nothing of baguette's, so it
knows the codecs its owner *can send*, never what encodes them:

| For | Read |
|---|---|
| choosing the codec, the answer's SDP, RFC 7798 packetization, the kit's laws and its slices K1–K3 | [webrtc-kit design — Codec](../webrtc-kit/design.md#codec--h264-today-h265-designed) |
| the WebRTC live view — transport, congestion, recovery, the bench | [design](design.md) |
| the encoder's tuning (`H264Tuning.lowLatency`) and frame pacing | [stream](../stream/README.md) |
| a phone streaming *to* baguette, which stays H.264 | [real-devices](../real-devices/design.md) |

---

## Why — and why not yet

H.265 gives **the same picture in ~30–40 % fewer bits** (or a sharper one in
the same bits). That shows only when **bandwidth is the limit**:

| Link | Measured | H.265 helps? |
|---|---|---|
| LAN, a moving 2560 × 1440 display | 1.3 Mbit/s of an 8 Mbit/s budget | no — the encoder has bits to spare |
| LAN / Tailscale, a shared phone display | 0.5 Mbit/s | no |
| cellular, Tailscale relayed (DERP), a weak Wi-Fi | congestion control drives the target down | **yes** — where text smears in motion |

What the stack has, checked 2026-11-22:

```
 Mac       VideoToolbox: hardware HEVC encoder (Apple silicon)                 ✓ there
 Chrome    157 (macOS): RTCRtpReceiver lists video/H265; mediaCapabilities     ✓ measured
           webrtc/H265 1206×2622@60 → supported, powerEfficient
 Safari    iPhone: H.265 over WebRTC in recent versions                        ? not verified (slice K3)
 page      whep-session.js: H.264 first in setCodecPreferences, every other    ✓ an offer already
           codec after it                                                        carries H.265
 baguette  VideoToolboxSession: kCMVideoCodecType_H264 only                    ✗ slice 4
 kit       reads and answers H.265, cuts it per RFC 7798 — when asked            ✓ K1–K3 built
```

## The one sentence

**A viewer asks for a codec on its WHEP request; baguette tells the kit what
this Mac can encode, encodes in the codec the kit chose, and the kit sends it —
H.264 unless the viewer, the browser and the Mac all say H.265.**

```
 Browser                                  baguette (per WebRTC viewer)            WebRTCKit
 ┌──────────────────────┐  POST …/whep    ┌──────────────────────────────┐        ┌───────────────────────────────┐
 │ offer: H264, H265, … │  ?codec=h265    │ WebRTCViewers.admit ★        │ asked, │ SessionDescription ★          │
 │ (whep-session.js:    │ ──────────────▶ │  asked = ?codec=             │ send-  │ CodecChoice ◇ ★ → VideoCodec  │
 │  H.264 first, every  │                 │  sendable = what this Mac's  │ able,  │ answer ★ (H265/90000 or       │
 │  other codec after)  │  answer         │  VideoToolbox encodes        │ offer  │          H264/90000)          │
 │                      │ ◀────────────── │                              │ ─────▶ │                               │
 │                      │                 │ Stream for this viewer       │ codec  │                               │
 │                      │                 │  VideoEncoder ★ ── Video-    │ ◀───── │                               │
 │                      │                 │  ToolboxSession ★ (H.264 |   │        │                               │
 │                      │                 │  HEVC Main, realtime)        │ Encoded│ WebRTCSender                  │
 │  hardware decode     │   SRTP / UDP    │        └─────────────────────┼──Frame▶│  any RTPPacketizer ★          │
 │  (H.265 or H.264)    │ ◀───────────────┼──────────────────────────────┼────────│  RTX · pacing · transport-cc  │
 └──────────────────────┘   PLI / FIR ───▶│ keyframe asked of the stream │        │  — unchanged                  │
                                          └──────────────────────────────┘        └───────────────────────────────┘
```

---

## 1 · Ubiquitous language

| Term | Meaning | Not to be confused with |
|---|---|---|
| **H.265 / HEVC** | one codec, two names; the SDP says `H265/90000` | HEIC, the still-image format built on it |
| **asked** | the codec a page requests on its WHEP request: `?codec=h265`, `h264`, `auto`, or nothing | what the browser *offers* (the kit's word) |
| **what this Mac encodes** | the codecs VideoToolbox makes in hardware here — what baguette hands the kit as *sendable* | what a browser can decode |
| **measured to win** | slice 6's result: a lower bitrate or a sharper picture at the target congestion control settles on, with no worse latency or recovery | a codec being newer |

Codec, parameter sets, packetizer: [the kit's language](../webrtc-kit/design.md#1--ubiquitous-language).

## 2 · What changes in baguette

```
WebRTCViewers ◆ ★          reads ?codec= off the WHEP request; hands the kit asked + sendable
└── WebRTCViewer ◆         one browser, one stream, one sender — unchanged
    └── Stream (per viewer)
        └── VideoEncoder ◆ ★        today's H264Encoder, told its codec at start
            └── CompressionSession ◆ (System: VideoToolboxSession ★ — HEVC Main, realtime,
                                     parameter sets from CMVideoFormatDescriptionGetHEVCParameterSetAtIndex)
StreamFormat.avcc (sockets)         stays H.264 — the WebSocket path is untouched
whep-session.js                     passes ?codec= when the page asks (slice 7: `auto`)
```

VideoToolbox frames both codecs' NAL units with a 4-byte length, so the
encoder's output reads the same way; only the codec type and the
parameter-set call differ.

## 3 · The tells

```swift
// baguette says what it can send and what was asked; the kit chooses.
let sendable = VideoCodec.encodable(by: VideoToolboxSession.self)   // H.264 always, H.265 where hardware has it
let viewer = try viewers.admit(offer, asked: query.codec, sendable: sendable, …)

// The stream is told its codec, once.
let stream = StreamFormat.avcc.makeStream(config: .default, sink: sink, codec: viewer.codec)
```

## 4 · Invariants — each law, one owner

| Law | Owner |
|---|---|
| what this Mac can encode is asked of VideoToolbox, never assumed | `VideoCodec.encodable` (baguette's side) |
| a viewer's encoder makes exactly the codec its sender was answered with | `WebRTCViewer` (one `VideoCodec`, given to both) |
| the WebSocket (AVCC) path stays H.264 | `StreamFormat.avcc` for sockets |
| H.265 is the default only once measured to win (slice 6) | this doc — a decision, not code |
| a phone streams H.264 to baguette, never HEVC | `MediaStreamOffer` — untouched |

The codec choice itself — and its replacing CANONICAL_MODEL's "an offer with no
H.264 … is refused" — is the kit's: [its laws](../webrtc-kit/design.md#codec--h264-today-h265-designed).

## 5 · Build sequence (test-first, each slice green)

Slices K1–K3 are the kit's ([its build](../webrtc-kit/design.md#codec--h264-today-h265-designed));
then:

| Slice | What | Pins |
|---|---|---|
| 4 | `VideoToolboxSession` makes an HEVC session; `VideoEncoder` told its codec; parameter sets from the format description | a `.system`-tagged test against the real encoder: a frame, three parameter sets |
| 5 | wiring: `?codec=` from the WHEP request through `WebRTCViewers` to the viewer's stream and sender | through `InProcessServer`: `?codec=h265` with an H.265 offer answers `H265/90000`; without it, `H264/90000` |
| 6 | **measure**: the same scene, H.264 vs H.265 — the LAN, then a phone on cellular over Tailscale | the bitrate congestion control settles on, text sharpness at it, glass-to-glass latency, recovery after induced loss |
| 7 | only if 6 wins: `auto` prefers H.265, the page asks `auto`; docs + CHANGELOG | — |

## 6 · Open questions

- **Does iPhone Safari offer and decode H.265 over WebRTC?** Chrome 157's offer
  carries it (captured); an iPhone's is still to capture — the first thing
  slice 5 does, on the device.
- **Does H.265 recover from loss as well as H.264?** Both wait for a keyframe
  after a lost reference. The repo's note that HEVC "mosaics under motion" is
  about Apple's own phone stream, not this encoder — slice 6 drops packets on
  purpose to find out.
- **Is it worth it on the LAN at all?** Probably not (1.3 Mbit/s of 8) — the
  case is slow links only, which is why it is opt-in until measured.
- **Cheaper alternatives first?** A higher bitrate ceiling on a fast LAN, or
  trading frame rate for sharpness on a slow one (a still page of text needs
  detail, not 60 fps) — [design §6c](design.md#6c--future-work--whats-left-what-each-is-for-and-when-its-needed).
