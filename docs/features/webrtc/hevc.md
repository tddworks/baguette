---
description: Design for sending H.265 (HEVC) to a WebRTC viewer — why and when it pays, the HEVC encoder, ?codec= from the page to the kit, and the measurement that decides whether it becomes the default. Read before touching the viewer's encoder or the WHEP request's codec.
---

# HEVC over WebRTC — "the same picture in fewer bits, when the viewer can take it"

**Status:** BUILT behind `?codec=h265` (K1–K3 in the kit; 4a–4d and 5 in
baguette): the encoder is codec-blind (`Codec`, `H264Codec`, `HEVCCodec`,
`VideoEncoder`), a viewer's stream and sender take the codec its session was
answered with (`Codecs.of(kind)`), and `?codec=` reaches it from the WHEP
request or the device page. Checked end to end (2026-11-22): headless Chrome 157
with `?codec=h265` decoded a 2560×1440 Mac display as `video/H265` (299 frames
in 6 s). Nothing asked stays High-profile H.264. H.265 stays **opt-in** until
slice 6 measures it winning; if it doesn't, the default never changes.

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
| **codec** (baguette's `Codec`) | one type per codec answering the four questions of §2: encoder type and profile, its record, its parameter sets | the kit's `VideoCodec`, an *offered* codec as a value — `Codecs.of(kind)` joins the two |
| **decoder configuration record** | what a decoder needs before the first picture, as the encoder made it: `avcC` (H.264), `hvcC` (H.265) | the parameter sets inside it |
| **what this Mac encodes** | the codecs VideoToolbox makes in hardware here — what baguette hands the kit as *sendable* | what a browser can decode |
| **measured to win** | slice 6's result: a lower bitrate or a sharper picture at the target congestion control settles on, with no worse latency or recovery | a codec being newer |

Codec, parameter sets, packetizer: [the kit's language](../webrtc-kit/design.md#1--ubiquitous-language).

## 2 · What changes in baguette — the codec, from first principles

Only four things differ between codecs, and each codec answers all four in
one place:

```
 1. which encoder to open         codec type (kCMVideoCodecType_H264 / _HEVC) + its profile (High / Main, auto level)
 2. its decoder configuration     the record VideoToolbox hands back, as is: "avcC" / "hvcC"
 3. its parameter sets            read out of that record — what RTP sends ahead of a keyframe
 4. how it travels over RTP       VideoCodec + RTPPacketizer — the kit's (K1–K3)
```

Everything else — sessions, reopening, the reference chain, forced keyframes,
rate and frame-rate tuning, the stream's envelopes, the sender — is the same
for every codec, so it never knows which one it carries (SRP); a new codec is
one new type, nothing else edited (OCP).

Measured (2026-11-22, one real frame each): VideoToolbox's keyframe format
description already carries the codec's decoder configuration record —
`avcC` (29 bytes, 2 parameter sets) for H.264, `hvcC` (98 bytes, 3) for HEVC —
under `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms`. So no
record is built and no SPS is parsed.

```
                 baguette (Device/Abilities/Capture)                                      WebRTCKit
 ┌────────────────────────────────────────────────────────────────────────────┐    ┌────────────────────┐
 │  Codec ◆ (role) — one type per codec, each answers 1–3:                    │    │ VideoCodec ◇       │
 │    codecType · profile: CompressionProperty · recordAtom: "avcC"|"hvcC"    │    │ RTPPacketizer ◆    │
 │    parameterSets(record:) → [Data]                                         │    │  H264 / H265       │
 │      ├── H264Codec  (High, avcC; reads it with AVCCParameterSets)          │    │ CodecChoice ◇      │
 │      └── HEVCCodec  (Main, hvcC; reads it with HVCCParameterSets ◇)        │    │   (K1–K3)          │
 │      … AV1 later = one new type                                            │    └─────────▲──────────┘
 │                                                                            │              │ kind ↔ Codec
 │  VideoEncoder ◆ (was H264Encoder) — codec-blind:                       │              │ (Codecs.of(kind))
 │    opens the session with codec.codecType, sets codec.profile + tuning;    │              │
 │    on a keyframe takes the format description's codec.recordAtom as is     │              │
 │    → Encoded { description: record, kind, avcc }                           │              │
 │        │                                                                   │              │
 │  the stream's description envelope — unchanged: "the decoder              │              │
 │    configuration record" (avcC on sockets, which stay H.264)               │              │
 │        │                                                                   │              │
 │  WebRTCViewer — codec-blind: sets = codec.parameterSets(record:) ─────────────────────────┘
 │    → EncodedFrame(avcc:, isKeyframe:, parameterSets:) → WebRTCSender       │
 └────────────────────────────────────────────────────────────────────────────┘
```

| Type | Its one job | Knows nothing of |
|---|---|---|
| `Codec` — `H264Codec`, `HEVCCodec` | what this codec looks like: encoder type and profile, its record, its parameter sets | sessions, keyframes, sockets, RTP |
| `VideoEncoder` | driving a compression session: open, tune, reopen, keyframes, the reference chain | which codec it runs |
| `AVCCParameterSets` · `HVCCParameterSets` | reading one record format | anything else |
| `WebRTCViewer` | feeding its sender frames and parameter sets | how a codec stores them |
| the kit — `VideoCodec`, the packetizers | how a codec travels over RTP | how it was encoded |

**What dies:** `AVCDecoderConfigurationRecord.bytes(sps:pps:)` — baguette
hand-building `avcC`, replaced by VideoToolbox's own record; `CompressedFrame`'s
`sps` / `pps`, replaced by `configuration` (the record, on a keyframe); the name
`H264Encoder` (now `VideoEncoder`), and `.highProfileAutoLevel` as a fixed tuning step — the profile
is the codec's. **Stays:** `AVCCParameterSets` (now `H264Codec`'s reader, and
still `VTH264Decoder`'s, which decodes a phone's stream); the socket path, H.264.

## 3 · The tells

```swift
// baguette says what it can send and what was asked; the kit chooses.
let viewer = try viewers.admit(offer, asked: query.codec, sendable: Codecs.encodable, …)

// The encoder is told its codec once, and never asks which it is.
let encoder = VideoEncoder(codec: Codecs.of(viewer.codec.kind), fps: fps, …)
session.open(width: w, height: h, codec: codec.codecType, …)
session.set(codec.profile)

// A keyframe carries the record the encoder made; the codec reads it.
let sets = codec.parameterSets(record: description)
sender.send(EncodedFrame(avcc: payload, isKeyframe: true, parameterSets: sets))
```

## 4 · Invariants — each law, one owner

| Law | Owner |
|---|---|
| what this Mac can encode is asked of VideoToolbox, never assumed | `Codecs.encodable` |
| a codec's decoder configuration is the record its encoder made, never one baguette builds | each `Codec` (`recordAtom`) |
| everything that isn't one of a codec's four answers is codec-blind | `VideoEncoder` · `WebRTCViewer` |
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
| 4a | `Codec` and `H264Codec`; the encoder goes codec-blind (`VideoEncoder`), taking `avcC` from the format description | the encoder's tests unchanged in behaviour; a `.system` test that VideoToolbox's own `avcC` gives the same parameter sets as the hand-built one did — before that dies |
| 4b | `HEVCCodec` and `HVCCParameterSets` | BUILT: a hand-made `hvcC` read byte for byte (SEI skipped, any array order), and a `.system` test that VideoToolbox's own `hvcC` gives VPS, SPS, PPS (NAL types 32, 33, 34) |
| 4c | the viewer takes its session's codec: `Codecs.of(kind)` for its encoder and its parameter sets | BUILT: the viewer's tests — an H.265 keyframe leaves after VPS, SPS, PPS, in one aggregation packet at the answered payload type. Its stream's encoder takes the codec in 5 |
| 4d | `VideoToolboxSession` opens the codec it's told | BUILT with 4a/4b: the session has opened `codec.codecType` since 4a; 4b's `.system` test runs the real HEVC encoder and reads its `hvcC` |
| 5 | wiring: `?codec=` from the WHEP request through `WebRTCViewers` to the viewer's stream and sender | BUILT: the route's tests (`?codec=h265` answers `H265/90000`, nothing asked `H264/90000`, an unknown codec refused), `WebRTCViewers`' (H.264 when this Mac can't encode H.265), the viewer's (its stream made in its codec), the page's (`codec=` asked, H.265 preferred); and headless Chrome decoding it |
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
