---
description: A proposal to carry the serve live view over WebRTC (WHEP) next to the stream WebSocket, and how we measure whether it is actually faster before we build it. Read before changing how the browser receives video.
---

# Live view over WebRTC (WHEP): design and bench

**Status:** BUILT on `feat/whep-live-view`, slices 1–10 of [§6](#6--build-sequence-test-first-each-slice-green):
the WHEP routes and the page's **WebRTC** choice play through baguette's own
ICE-lite, DTLS-SRTP and RTP, checked end to end in Chrome on 2026-11-20 (the serve
page at 38–40 fps, touches through the control socket). Congestion control (slice 11,
transport-cc) is built and tested over a simulated link; not yet measured on a
real throttled one. How to use it: [README](README.md).

This doc owns **how encoded frames travel from `baguette serve` to the page,
and how we compare two ways of doing it**. It doesn't change what gets encoded
or how input gets in:

| For | Read |
|---|---|
| The encoder, AVCC tags and retune commands | [stream](../stream/README.md) |
| The stream WebSocket route and its messages | [serve.md](../../serve.md#one-websocket-per-stream), [wire.md](../../wire.md) |
| How a tap reaches the simulator | [ARCHITECTURE.md](../../ARCHITECTURE.md) |
| Many devices on one page | [device-farm](../device-farm/README.md) |

---

## The one sentence

**The live view should get the same H.264 frames over whichever transport
shows them to the user sooner and keeps them steadier, and we choose by
measuring, not by guessing.**

```
  Screen ─▶ H264 Stream (VideoToolbox, H264Tuning.lowLatency)
               │  AVCC envelopes
               ├─▶ WebSocketFrameSink ─TCP─▶ VideoDecoder ─▶ <canvas>   today
               └─▶ RTP sink ──SRTP/UDP──────▶ <video>                   proposed
  gestures ────────── stream WebSocket (unchanged on both paths) ─────▶ Touch
```

## What we expect, and why it has to be measured

What the current path does (shipped code):

| Stage | Today | What it costs |
|---|---|---|
| Encode | `H264Tuning.lowLatency`: no B-frames, `MaxFrameDelayCount 0`, low-latency rate control, IDR every 5 s | Already the FaceTime/screen-share setup. WebRTC uses the same encoder, so it wins nothing here |
| Transport | One binary WS message per AVCC chunk over TCP | **No loss on localhost.** On Wi-Fi or a WAN, one lost segment holds back every frame behind it (head-of-line blocking) |
| Backpressure | `FrameBacklog` keeps every AVCC reference; the socket closes once a viewer is 32 MiB behind | A slow link builds up delay rather than dropping frames, then fails outright |
| Bitrate | Fixed (8 Mbps default); the page retunes it by hand with `set_bitrate` | Nothing reacts to the link by itself |
| Decode/paint | WebCodecs `optimizeForLatency`, one-frame queue drawn on `requestAnimationFrame` | Up to one display refresh waiting for rAF; no jitter buffer |

**Hypotheses.** Each one is a row in the bench, and each can turn out false:

- **H1 — Localhost: WebRTC is no faster and may be slower.** A browser jitter
  buffer at target 0 still paces frames, and RTP packetising and SRTP add work.
  We expect the gap to be under one frame (≤ 17 ms at 60 fps).
- **H2 — A lossy or slow link: WebRTC holds latency where the WebSocket
  drifts.** NACK/PLI plus congestion control (TWCC/GCC) trade picture quality
  for delay. TCP trades delay for quality and then hits the 32 MiB close.
- **H3 — Freezes: WebRTC recovers faster after a loss burst.** A PLI asks for
  one IDR. TCP has to resend everything first.
- **H4 — Host CPU: about the same per stream.** The same VT session runs
  either way. SRTP and pacing are cheap next to the encode. This matters at
  device-farm scale.

## What WebRTC buys, and when

Measured so far: on one Mac, nothing. Latency, bitrate and CPU are the same or
slightly worse (see the [results](#slice-0-results--localhost-2026-11-20)). Every
benefit below needs the viewer on another machine, and none is measured yet:

| Benefit | Why the WebSocket can't do it | What it takes in baguette |
|---|---|---|
| **Latency stays bounded under loss** | TCP holds every later frame behind one lost segment (head-of-line blocking). The backlog grows until `FrameBacklog` closes the socket at 32 MiB | Nothing extra. UDP drops the damaged frame, and NACK/PLI repairs or restarts from an IDR (law 2) |
| **Bitrate follows the link** | Fixed 8 Mbps until someone sends `set_bitrate` | Wire the viewer's TWCC/REMB estimate to `H264 Stream.apply(config)`. MediaMTX can't, so the spike shows none of it |
| **Reaches viewers behind NAT** | `serve` binds loopback; remote means `--allowed-hosts` plus a reverse proxy and open ports | STUN, and TURN for strict networks: a relay to run or rent |
| **Any WHEP player can watch** | AVCC-over-WebSocket is baguette's own framing; only our page reads it | Nothing extra. OBS, GStreamer, Cloudflare, LiveKit and MediaMTX speak WHEP. An SFU can fan one upload out to many viewers |
| **H.264 in any browser without HTTPS** | Desktop Chrome offers WebCodecs only in a secure context, so a plain-`http` page there gets MJPEG (issue #71): more bytes, skipped frames. iOS browsers (WebKit) offer it on plain `http`, measured 2026-11-20, so this one doesn't apply on an iPhone | Nothing extra. `<video>` decodes WebRTC H.264 on any page |
| **The browser decodes and paints** | The page runs WebCodecs plus canvas painting in JS | Nothing extra, but the spike's `<video>` showed fewer fps (42 vs 52), so this isn't a win yet |

**Cost:** a WebRTC stack (open question 1), a second transport to maintain, a
keyframe request on every join, and the unexplained fps gap.

**So:** WHEP pays off for remote viewing (a phone on Wi-Fi via
[handheld](../handheld/README.md), a [device farm](../device-farm/README.md)
watched from other machines, a hosted device cloud). For a local developer
tool, the WebSocket is as good or better. The phone and lossy rows of the bench
decide it.

## 1 · Ubiquitous language

| Term | Meaning | Not to be confused with |
|---|---|---|
| **Live view** | The moving picture of the device on the serve page | A *recording* (a file) or a *screenshot* (one image) |
| **Transport** | How encoded frames cross the network to the live view: `websocket` or `webrtc` | The *format* (`mjpeg` / `avcc`). WebRTC carries H.264 only |
| **WHEP** | WebRTC-HTTP Egress Protocol ([draft-ietf-wish-whep](https://datatracker.ietf.org/doc/draft-ietf-wish-whep/); its publishing twin WHIP is RFC 9725). baguette serves the playback endpoint, the browser is the WHEP player: it POSTs an SDP offer, get an SDP answer and a `Location` to `DELETE` later | WHIP, the publishing side |
| **Viewer** | One browser peer watching one device's live view | The *page*: a farm page holds many viewers |
| **Keyframe request** | The viewer asking for an IDR (RTCP PLI/FIR, or `force_idr` on the WS) | A *snapshot* (a JPEG seed; WebRTC has none) |
| **Tap-to-photon** | Time from sending a tap to that tap's pixel change showing in the live view | *Encode latency*, which is one part of it |
| **Freeze** | A gap of more than 200 ms between presented frames while the screen is changing | An idle screen. An idle sim still re-encodes at `--fps`, so the gap shows |
| **Impairment** | A network condition the bench applies: added RTT, loss %, bandwidth cap | A real network, which the bench also runs on, labelled as such |

"Transport" is chosen over "protocol" because `wire.md` already uses
"protocol" for the gesture JSON.

## 2 · The aggregate, from the root down

Each viewer owns a stream of its own, the way each stream WebSocket does today,
so `Stream` gains no attach/detach and two viewers never share an encoder's
reference chain. The viewer, its registry and `EncoderRetune` live in the
Stream context (`Sources/Device/Abilities/Capture/WebRTC/`); everything that
sends — `SessionDescription`, ICE-lite, DTLS-SRTP, RTP and RTCP, the pacer,
congestion control — is **WebRTCKit** (`Sources/WebRTCKit/`: `Signaling/`,
`Transport/`, `Media/`, `Congestion/`), a library that knows nothing of devices
and is to become its own package. The viewer is a `WebRTCSender` (the kit's
session: `EncodedFrame` in, `SenderEvents` out) plus a stream of its own: it
turns AVCC envelopes into frames, asks the stream for the keyframes the
sender needs, and lets the encoder follow the sender's bitrate through
`EncoderRetune`. `RTPPacket` is the kit's, shared with a phone's screen. The laws are also in [CANONICAL_MODEL](../../CANONICAL_MODEL.md).

```
WebRTCViewers  ◆                      the live viewers by id — admit(offer, …) → answer · find(id) · hangUp(id)
└─ WebRTCViewer  ◆                    ONE BROWSER: new → connecting → securing → live → hung up
    ├─ stream : any Stream            its own AVCCStream; hanging up stops it
    ├─ offer → answer : SessionDescription ◇   H.264 packetization mode 1 or a refusal; ice-lite,
    │                                  our ufrag/pwd and DTLS fingerprint, setup:passive, sendonly
    ├─ datagrams : any Datagrams  ◆   its UDP socket (System/): send(_:to:) · onReceive
    ├─ handshake : any Handshake  ◆   its DTLS server (System/, BoringSSL): receive(datagram) → replies;
    │                                  when done, the SRTP keys
    ├─ STUNMessage ◇                   a connectivity check in, its success response out (integrity + fingerprint)
    ├─ RTPFrameSink                    the stream's FrameSink: AVCC envelope → access unit → packets
    │   └─ H264Packetizer ◇            RFC 6184: single NAL or FU-A, SPS/PPS as STAP-A; ≤ 1200 B payload
    ├─ RTPPacket ◇                     header + payload, both ways (shared with a phone's screen)
    ├─ SRTPContext ◇                   AES-CM-128 + HMAC-SHA1-80: protect RTP, unprotect RTCP
    ├─ RTCPFeedback ◇                  PLI · FIR → keyframe; NACK → resend from history;
    │                                  transport-cc → arrivals (TransportFeedback ◇)
    ├─ SendHistory ◇                   transport-wide sequence → send time and size, bounded;
    │                                  each packet's outcome once; LOST ONLY AFTER 500 ms MISSING
    └─ BandwidthEstimate ◇             GCC's shape (AIMD + a loss-based rate; THE TARGET IS THE LOWER
        │                              OF THE TWO, between a floor and the starting bitrate), with
        │                              recovery from its own bursts' measured capacity, and fast
        │                              (50 %/s) back to the rate before a cut the queue never repeated
        └─ QueueDelay ◇                the queue = the delay FLOOR of packets sent in the last 200 ms
                                       minus the floor of the last 10 s; jitter can't lift a floor;
                                       fewer than 10 packets is no evidence
```

**How much the link takes is one role, `CongestionControl`, with three
implementations the viewer can't tell apart** (decided 2026-11-20): it answers
which SDP lines it needs, what each packet carries, what it makes of the
browser's feedback, and the bitrate it wants (or none).

| Implementation | Who estimates | Each packet carries | Feedback read |
|---|---|---|---|
| `TransportWideControl` (default) | baguette (GCC, below) | transport-wide sequence | transport-cc |
| `ReceiverEstimateControl` | the browser | `abs-send-time` (24-bit, 6.18 s) | REMB |
| `FixedBitrate` | nobody | nothing | nothing |

`CongestionChoice` picks one per viewer: `?congestion=transport-cc|remb|off` on
the WHEP `POST`, else transport-cc if offered, else REMB if offered, else none.

**transport-cc is the default (decided 2026-11-20, after the jitter fix).** On
the phone it then looked as sharp as REMB had, while REMB, unchanged, started
soft: Chrome's estimate cut on connect (`8000 → 3276 kbps`) and ramped about 10 %
a step. REMB was briefly the default before that fix, for the reason below.

**Why REMB was the default for a while (2026-11-20), and what it costs.** On a phone
over Tailscale (Chrome on iOS), REMB gave the best picture: the log showed no
REMB retunes at all, so it most likely stayed at 8 Mbps, while transport-cc had
cut to ~300 kbps and was climbing back at 8 %/s. Whether that cut was real
congestion or a misread (late packets counted as lost; keyframe bursts without a
pacer) is still open. The cost: REMB's estimate is the browser's, about 1.5× what
arrives, so in desktop Chrome a still screen drops it to the 300 kbps floor, and
where a browser sends no REMB nothing adapts. `?congestion=transport-cc` keeps
the measuring method one parameter away.
The viewer keeps `EncoderRetune` (law 12), shared by all three.

**Congestion control is the sender's (transport-cc), as libwebrtc does it.**
Every packet carries a transport-wide sequence number (an RTP header extension);
the browser reports when each one arrived (RTCP transport-cc feedback, about every
50–100 ms); the viewer estimates the bandwidth from those reports and retunes its
own encoder. REMB, where the browser does the estimating and sends one number,
was the simpler option and was turned down for the industry's current way
(decided 2026-11-20). The same feedback comes from an SFU, so it carries over to
publishing (open question 5).

The demultiplexing of one UDP port (RFC 7983) is the viewer's: first byte 0–3
is STUN, 20–63 is DTLS, 128–191 is RTP/RTCP.

### `WebRTCViewer` — one browser watching one device

> **Pointable as:** a person on the other end of a video call.

| | |
|---|---|
| **Owns — the call's state** | `new → connecting → securing → live → hungUp`; a hung-up viewer never sends again and its stream is stopped |
| **Tell it** | `receive(_ datagram:, from:)` · `send(_ envelope:)` (from its sink) · `tick(now:)` (consent) · `hangUp()` |
| **It answers** | `state` · `id` · `answer` |
| **Never** | Encodes, sends before `live`, sends in the clear, or knows which device it shows |

`Datagrams` and `Handshake` are the two conversations with the outside
(pattern 2 in AGENTS.md); the viewer is tested against `MockDatagrams` and
`MockHandshake`. Their concrete forms are `Internal/System/` files of under 100
lines each.

## 3 · The tells

```
POST /devices/:udid/whep  body: SDP offer
  viewers.admit(offer, stream: …, datagrams: …, handshake: …) → (id, answer)  or a refusal (422)
  → 201 Created, Location: /devices/:udid/whep/:id, body: SDP answer
viewer.receive(STUN)      → a success response; the browser's address is learned
viewer.receive(DTLS)      → handshake replies; when done: SRTP keys, state live, stream.requestKeyframe()
stream → sink.write(env)  → viewer.show(env): packets into its Pacer; each stamped, SRTP'd and sent as it leaves
viewer.receive(SRTCP)     → PLI/FIR: stream.requestKeyframe() · NACK: resend · transport-cc / REMB: its
                            CongestionControl's target → EncoderRetune → stream.update(.bitrate(target))
WS  /devices/:udid/whep/:id/control   gestures and stream control for that viewer, through GestureDispatcher
DELETE /devices/:udid/whep/:id        viewers.hangUp(id)
```

Touches keep going over a WebSocket: the viewer's own control socket, which
carries no video. A DataChannel would need SCTP and stays out of scope.

### The page's side

The page's side of WHEP, tuned for latency rather than smoothness:

```
RTCPeerConnection({ bundlePolicy: "max-bundle" })
addTransceiver("video", { direction: "recvonly" }), H.264 first in setCodecPreferences
POST offer → setRemoteDescription(answer), as the server wrote it
  (the bench page alone drops goog-remb and adds b=AS:15000, to pin Chrome to transport-cc)
ontrack: receiver.jitterBufferTarget = 0, playoutDelayHint = 0 → <video autoplay playsinline muted>
(designed, not built: getStats() every 500 ms, reconnecting when no first frame in
 10 s or no new frame for 3 s — WhepSession today shows a failure and stops)
```

## 4 · Invariants (each law, one owner)

| # | Law | Owner |
|---|---|---|
| 1 | Both transports carry the same encoded frames: same tuning, same bitrate, same fps | `H264 Stream` |
| 2 | A viewer sees no picture before a keyframe: it asks for one when its handshake completes and whenever the browser reports a lost picture | `WebRTCViewer` |
| 3 | Only the stream makes an IDR; a viewer only asks for one | `H264 Stream.requestKeyframe` |
| 4 | No RTP packet carries more than 1200 bytes of payload | `H264Packetizer` |
| 5 | A viewer sends nothing before its handshake completes, and every packet after it through SRTP | `WebRTCViewer` |
| 6 | One viewer, one encoder; hanging up stops it | `WebRTCViewer` |
| 7 | A viewer the browser stops answering (no STUN check for 30 s) hangs up | `WebRTCViewer` |
| 8 | A STUN check is answered only when it names the viewer's username fragment and is signed with its ICE password | `STUNMessage` |
| 9 | An offer with no High-profile H.264 in packetization mode 1 is refused | `SessionDescription` |
| 11 | A viewer's encoder targets the lower of the delay-based and loss-based estimates, between a floor (300 kbps) and its starting bitrate | `BandwidthEstimate` |
| 12 | A viewer retunes its encoder on a move of more than 10%. Drops apply immediately. Increases wait at least one second after the last retune | `EncoderRetune` |
| 13 | An offer carries a congestion-control method only when it numbers its extension 1–14, will receive it (not `inactive`/`sendonly`), and asks for its feedback on our H.264 or on every format (`*`) | `SessionDescription` |
| 17 | With pacing on, a viewer's packets leave at 2.5 × its target as the normal rate, faster whenever the queue couldn't otherwise empty within 500 ms of its oldest packet; a small frame leaves at once. `?pacing=off` sends each as it comes | `Pacer` |
| 16 | A viewer is reached only through the device it watches: its control socket and hang-up refuse another device's address | `WebRTCViewers` |
| 14 | Transport-cc reports are read on one unbroken timeline, across the wrap of their 24-bit reference time | `FeedbackClock` |
| 15 | A retune turns one knob of the config as it stands, so a viewer's retune and its page's `set_fps` both land | each `Stream` (`update(_: StreamConfig.Change)`) |
| 10 | Every bench run compares the transports on the same device, build, encoder settings and impairment, one transport at a time | the bench harness (`scripts/bench-live-view`) |

Law 1 is what makes the comparison fair. If WebRTC needs different tuning
(for example a shorter GOP for loss recovery), the bench runs both transports
on that tuning too.

## 5 · The bench

**One probe, both transports.** Tap-to-photon is what a user feels, and both
transports can measure it the same way from inside the page:

1. The simulator's Safari shows the tap probe: black at rest, red while a touch
   on its left half is down, green for its right half, black again on
   `touchend`.
2. The bench page taps through `POST /devices/:udid/input` (the same route for
   every transport), alternating left and right, and records
   `t0 = performance.now()`.
3. Every presented frame samples the centre pixel, stamped when it reaches the
   screen (`expectedDisplayTime` on the `<video>`; the next vsync after the
   canvas paint). The first frame in this tap's colour gives `t1`; a late
   answer to the last tap is the other colour, never counted.
4. **Tap-to-photon = t1 − t0.** One tap every 0.25–0.45 s after the screen is
   black again (randomised so taps don't line up with vsync), 100 per run,
   each waiting up to 5 s; a tap with no answer is a miss, outside the
   percentiles, and counted. Results show on the page.

Both paths include input delivery, the render and the encode. The difference
between the two transports is the video path alone.

**What we record per run:**

| Metric | Source |
|---|---|
| Tap-to-photon p50 / p95 / p99 | the probe |
| Frame interval jitter (stddev), freezes per minute | presented-frame callbacks |
| Time to first frame | page load → first paint |
| Recovery after a 2 s blackout | last frame before → first fresh frame after |
| Host CPU and memory of `baguette serve` | `top -pid`, sampled 1 Hz |
| Browser decode path, frames dropped | `getStats()` / `VideoDecoder` counters |

**Senders to compare.** Beside baguette's own WebRTC, two more columns:
**WebRTC (no pacer)**, the same sender with `?pacing=off` — the A/B for the
pacer, one difference only; and **WebRTC (Pion)**, a reference: the same
`baguette stream` encoder at serve's settings, sent through
[Pion](https://github.com/pion/webrtc) with its Google Congestion Control and
leaky-bucket pacer (`scripts/bench-live-view/pion/`, built by `start.sh` when
Go is installed). Pion's target retunes the encoder through the stream's
stdin at most once a second, on a change over 10 %. A PLI or FIR asks for a
keyframe. Same screen, encoder and page, but
Pion's whole send path differs (pacer, estimator, packetization), so a gap
says *that* the senders differ, not which part — and close results don't
show the encoder is the limit unless a run also shows neither estimate held
it back. What runs found, and what they support, is in §6 (slice 11).

**The matrix:** {websocket, webrtc, webrtc without pacer, webrtc via Pion} × {localhost, LAN Wi-Fi, 50 ms RTT, 50 ms +
1 % loss, 50 ms + 5 % loss, 5 Mbps cap} × {1, 4, 8 devices} for CPU. We apply
impairments with `dnctl` + `pfctl` dummynet, scripted so every run can be
reproduced — **on loopback only** (`impair.sh` shapes `lo0`: a browser on this
Mac). A phone over Wi-Fi or Tailscale crosses another interface the script
doesn't touch: those runs are the real network, unimpaired, and are recorded
apart. Network Link Conditioner is fine for spot checks.

### Run it

The kit is `scripts/bench-live-view/`. It needs a release build, `mediamtx`,
`ffmpeg` (`brew install mediamtx ffmpeg`), `node` and `python3`.
Boot a simulator first.

```bash
scripts/bench-live-view/start.sh              # this Mac: http://127.0.0.1:8777/…
scripts/bench-live-view/start.sh --lan        # a phone on the same Wi-Fi: http://<mac-ip>:8777/…
scripts/bench-live-view/start.sh --tailscale  # a phone on your tailnet: http://<tailscale-ip>:8777/…
scripts/bench-live-view/stop.sh
```

It prints two URLs:

- **`/bench/?udid=…`**, the measured runs: latency 100 taps, bandwidth 30 s and
  a 10-tap quick check, once per transport. Plus buttons that put the probe page
  or the animated list on the simulator. WebRTC runs use baguette's own
  `/devices/:udid/whep`; add `whep=/whep` to a bench URL to measure the MediaMTX
  spike instead, which the proxy then starts.
- **`/devices/<udid>`**, `baguette serve`'s own page: switch between H.264,
  MJPEG and WebRTC in its format picker to feel the difference by hand.

One process, `proxy.mjs`, serves it all on one origin:

```
viewer ──http :8777──▶ proxy.mjs ─┬─ /bench/*          ▶ the bench pages; /bench/bridge/on|off ▶ the spike's WHEP source
                                  ├─ /whep             ▶ MediaMTX :8889, the spike (media: UDP :8189, direct)
                                  ├─ /api/*            ▶ baguette serve, prefix stripped
                                  └─ everything else   ▶ baguette serve 127.0.0.1:8421, as is (HTTP + WebSocket)
```

- **Which H.264 a viewer can decode depends on its browser.** Desktop Chrome
  exposes WebCodecs (`VideoDecoder`) only to secure contexts (HTTPS or
  localhost), so on plain `http://` the WebSocket's H.264 is unavailable and the
  serve page falls back to MJPEG (issue #71); the bench does the same. iOS
  browsers (WebKit; Chrome on iOS checked 2026-11-20) expose it on plain `http`
  too (`isSecureContext` false, `VideoDecoder` a function), so an iPhone gets
  H.264 either way. WebRTC's `<video>` needs no secure context anywhere. Note: MJPEG
  skips unchanged frames, so on the static probe its presented fps and
  "freezes" read low; that's by design, not a stall. Over Tailscale, MediaMTX
  announces the tailnet address as an ICE candidate and keeps RTP payloads
  ≤ 1200 B to fit the tunnel's 1280 MTU. macOS may ask to let `node` and
  `mediamtx` take incoming connections.
- **One encoder per run (law 6).** The bench page tells the proxy to stop the
  WHEP source before a WebSocket run and start it before a WebRTC run. Opening
  the plain serve page stops it too.
- **`baguette serve` stays on loopback.** Only the proxy is on the LAN.
  Anyone on that network can still drive the simulator through it, so use
  `--lan` on a trusted network.
- **Compare within one session.** Absolute numbers drift between sessions. The
  same Mac measured WebSocket p50 at 310 ms in the morning and 355 ms in the
  afternoon, through both the proxy and serve directly. Run both transports
  back to back and compare those.
- Desktop automation: start Chrome with `--remote-debugging-port=9333`, then
  `node scripts/bench-live-view/drive.mjs '<bench URL>'` prints the result
  JSON. `impair.sh` applies dummynet to the video direction only (needs `sudo`).

### Slice 0 results — localhost (2026-11-20)

Setup: Bench iPhone 17 Pro sim (iOS 26.4), baguette 0.2.15 release build,
Chrome 157, M-series Mac. Same encoder settings on both paths (60 fps, 8 Mbps,
scale 1). The WebSocket path is the real `serve` route. The WebRTC path is
`baguette stream --format avcc` → AVCC-to-Annex-B script → `ffmpeg -c copy` →
RTSP → MediaMTX 1.21 → WHEP. The page sets up its peer as described in
[the viewer](#the-viewer).
Taps go over `POST /devices/:udid/input` on both paths. Two alternating rounds
of 100 taps each.

| | WebSocket r1 / r2 | WebRTC (spike) r1 / r2 |
|---|---|---|
| Tap-to-photon p50 | 309.9 / 311.4 ms | 325.3 / 325.6 ms |
| p95 | 334.2 / 330.7 ms | 353.3 / 357.8 ms |
| p99 | 344.8 / 339.4 ms | 366.7 / 374.5 ms |
| Presented fps | 52.5 / 52.6 | 42.1 / 41.5 |
| Frame interval stddev | 5.8 ms | 12.9 / 13.2 ms |
| Freezes per minute | 0 | 0 |
| Time to first frame | ~395 ms | 780 / 5854 ms |
| Host CPU (all baguette, bridge and MediaMTX processes) | 12 % | 12–13 % |

What it says:

- **H1 holds.** On localhost, WebRTC is about 15 ms (one frame) slower at p50
  and about 22 ms slower at p95. That's right at the decision rule's limit,
  and the spike's extra hops (script, ffmpeg's parser, RTSP over TCP, MediaMTX
  re-packetising to 1440 B) account for part of it. A native `RTPFrameSink`
  might close the gap. It won't beat the WebSocket.
- **Time to first frame shows why law 2 matters.** MediaMTX waits for the next
  IDR, and the 5 s GOP made one join take 5.9 s. A native sink has to request
  a keyframe on attach.
- **The WebRTC `<video>` presented about 42 fps against the WebSocket's 52,
  with twice the jitter.** Not yet explained. Suspects: the wall-clock
  timestamps ffmpeg assigns, or Chrome pacing playout to RTP time. Investigate
  before slice 1.
- **H4 holds.** CPU is the same once the bug below is excluded.
- **Found while doing this:** `baguette stream` spins a full core (≈ 104 %
  CPU) once its stdin closes, because `ControlChannel`'s readability handler
  stays installed at EOF. The first round of this bench was thrown out because
  of it. Fixed separately (`ControlChannelTests`).

**Network usage** (30 s, measured in the page; the wire estimate adds TCP/IP or
UDP/IP + SRTP headers):

| Screen | WebSocket | WebRTC (spike) |
|---|---|---|
| Static (the fixture) | 0.11 Mbps, 1,579 messages | 0.12 Mbps, 1,635 packets |
| Animated (scrolling list, redrawn every frame) | 7.08 Mbps (53 MB/min), 1,570 messages | 7.17 Mbps (54 MB/min), 22,480 packets |

Same encoder, same bytes: on a link with no congestion, the transport changes
neither the bitrate nor the data use. WebRTC sends about 14× as many packets
(each ≤ 1440 B, against one WebSocket message per frame), which costs about 1 %
in headers. WebRTC's bandwidth advantage, congestion control, only shows up
once the sender retunes VideoToolbox from the viewer's feedback. MediaMTX
can't do that, so a native `RTPFrameSink` would have to wire TWCC/REMB to
`set_bitrate`. With a fixed 8 Mbps target, neither path can fit an
animated screen (~7 Mbps) into a 5 Mbps link without someone calling
`set_bitrate`. That's what the 5 Mbps row in the matrix tests.

**Native route, localhost (2026-11-20, 5 taps, same bench page):** p50 351 ms,
p95 379 ms, 41.9 presented fps; the WebSocket measured about 355 ms in the same
session. The ~42 fps ceiling showed with MediaMTX too, so it is Chrome's WebRTC
playout, not the spike's ffmpeg.

**Still to run:** H2 and H3, the lossy rows. These are where WebRTC is
expected to win. They need `sudo` for dummynet.

### The decision rule

Ship `transport=webrtc` as an option only if **all** of these hold:

- Under 1 % or 5 % loss, tap-to-photon p95 improves by ≥ 30 % and freezes per
  minute drop by half or more.
- On localhost, p50 is at most one frame (17 ms) worse.
- Host CPU per stream is at most 20 % higher at 8 devices.

If only the lossy rows win, ship it as opt-in for remote viewing and keep the
WebSocket as the default. If nothing wins, record the numbers here and close
this doc.

## 6 · Build sequence (test-first, each slice green)

0. ~~**Spike, no `Sources/` changes.**~~ **DONE** for localhost, and the
   kit runs from a phone (`scripts/bench-live-view`, see [Run it](#run-it)).
   Lossy and phone rows still to fill in. *Pinned: the results tables above.*
1. ~~**`RTPPacket`**~~ **DONE** moves from the iPhone family to the Stream context and learns
   to serialize. *Pinned: "should write the header a phone's parser reads back".*
2. ~~**`H264Packetizer`.**~~ **DONE** *Pinned: "should fragment a picture too big for one
   packet into FU-A packets with start and end bits", "should bundle SPS and
   PPS into one STAP-A ahead of a keyframe", "should mark the last packet of a
   picture".*
3. ~~**`STUNMessage`.**~~ **DONE** *Pinned: "should answer a check whose integrity matches the
   ICE password", "should refuse a check whose integrity doesn't match".*
4. ~~**`SessionDescription`.**~~ **DONE** *Pinned: "should answer an offer with its H.264
   payload type in packetization mode 1", "should refuse an offer with no H.264
   it can send".*
5. ~~**`SRTPContext`.**~~ **DONE** *Pinned: RFC 3711 key-derivation and protect vectors.*
6. ~~**`RTCPFeedback`.**~~ **DONE** *Pinned: PLI, FIR, NACK and REMB parsed from a compound
   packet.*
7. ~~**`Datagrams` + `Handshake`**~~ **DONE**, the two `System/` files. *Pinned: `.system`
   tests (a loopback UDP round trip, a DTLS handshake between two contexts that
   exports the same SRTP keys).*
8. ~~**`WebRTCViewer`**~~ **DONE** against `MockDatagrams` / `MockHandshake`. *Pinned: the
   laws 2, 5, 6, 7.*
9. ~~**`WebRTCViewers` and the routes**~~ **DONE**: `POST`/`DELETE /devices/:udid/whep` and
   the control WebSocket, through `InProcessServer`.
10. ~~**The page**~~ **DONE**: a WebRTC option beside H.264 and MJPEG, painting the `<video>`
    onto the stream canvas. *Pinned: `make test-web`.*
11. **Congestion control (transport-cc)**, replacing "REMB → bitrate":
    1. ~~*Negotiate it*~~ **DONE**: the answer adds `a=rtcp-fb:<pt> transport-cc` and the
       `transport-wide-cc` header extension at the offer's id. *Pinned: an offer
       without the extension is still answered, without adaptation.*
    2. ~~*Number every packet*~~ **DONE**: a one-byte header extension (RFC 8285) on
       `RTPPacket` with a 16-bit transport-wide sequence.
    3. ~~*`TransportFeedback`*~~ **DONE**: RTCP RTPFB FMT 15 — base sequence, reference time,
       run-length and status-vector chunks, small and large deltas.
    4. ~~*`SendHistory`*~~ **DONE**: feedback → sent/arrived pairs; wraparound; losses.
    5. ~~*`BandwidthEstimate`*~~ **DONE**: delay-based and loss-based rates; each constant's
       source (draft-ietf-rmcat-gcc, libwebrtc defaults) noted here.
    6. ~~*`WebRTCViewer` retunes its encoder*~~ **DONE** (laws 11–12).
    7. *Prove it* on a throttled link (Network Link Conditioner or `impair.sh`).
    8. ~~*A pacer*~~ **DONE**: `Pacer` lets a viewer's packets out at 2.5 × the
       target (libwebrtc's pacing factor) in 5 ms slices; a packet into an empty
       pacer brings 5 ms of credit, so a small frame still leaves at once; idle
       time isn't saved up; it aims to send every packet within 500 ms of its
       arrival, speeding up as the queue ages (a target, not a hard bound: a
       late timer can stretch it). Each packet is stamped
       (transport-wide sequence, send time) as it leaves, so the estimate reads
       real send times. Retransmissions skip it. Side effect: a slice leaves
       with one send time, so below ~4 Mbps a slice holds fewer than the 10
       packets a burst needs, and the jump to a burst-measured capacity no
       longer fires there — the 8 %/s climb does, as in libwebrtc. *Pinned:
       `PacerTests`, "should spread a keyframe's packets over time instead of
       sending them all at once".* To measure on the phone: freezes and frame
       jitter against p95 (see the table below).

    **Rebuilt from first principles after the phone test (2026-11-20).** On the
    phone, transport-cc blurred the picture where REMB didn't. A simulated link
    with per-packet jitter reproduced it — on a 20 Mbps link with room to spare,
    still / busy screen, the target after 30 s:

    | Jitter | GCC as first ported | Now |
    |---|---|---|
    | 15 ms | 8,000 / 7,521 kbps | 8,000 / 8,000 kbps |
    | 40 ms | 8,000 / 1,381 kbps | 8,000 / 8,000 kbps |
    | 80 ms | 1,102 / 382 kbps | 8,000 / 8,000 kbps |
    | 150 ms | 300 / 300 kbps | 8,000 / 8,000 kbps |

    The causes, each a GCC assumption a screen over a mobile link breaks: a
    packet reported "not received" was counted lost, though over a jittery link
    it is usually just late (now: lost only after 500 ms missing, each packet
    once); GCC's trendline over 5 ms groups read random jitter as a growing
    queue (now: `QueueDelay`'s delay floor, by send time, and no judgement from
    fewer than 10 packets — a still screen's handful); and after any cut it
    crawled back at 8 %/s (now: up to its bursts' measured capacity at once, or
    50 %/s back to the rate before a cut the queue never repeated). Real limits
    still bite: on a 2 Mbps link it settles at ~1.9 Mbps; 20 % loss still cuts;
    freed, it is past 7 Mbps within 6 s (`TransportWideControlLinkTests`).

    **Review fixes (2026-11-20)**, each pinned by a test that failed first: the
    offer's extension is taken only with its `rtcp-fb` on our payload type and
    an id of 1–14 (Pion intersects the same way); `FeedbackClock` unwraps the
    24-bit reference time, as libwebrtc's feedback adapter does; the measured
    arrival rate spans the earliest to the latest arrival and a report is read
    in sending order however listed, its window ending at the latest arrival
    (libwebrtc keys by arrival time too) — the more honest rate makes recovery
    ~0.5 s slower than before; a retune is a
    `StreamConfig.Change` the stream applies on its own queue, so it can't undo
    a `set_fps` that lands at the same moment.

    **Against a production sender (2026-11-20).** Our estimator beside Pion's
    GCC (`pion/interceptor` v0.1.51 `pkg/gcc`, a port of libwebrtc's goog_cc):

    | | Pion / libwebrtc | Ours | Why |
    |---|---|---|---|
    | Cut on overuse | 0.85 × received rate | same | — |
    | Climb | 8 %/s; additive near the last cut | same shape: 8 %/s; one packet per 200 ms within 20 % of capacity | Pion keys "near" to the cuts' mean ± 3σ |
    | Response time | 100 ms + the measured RTT, in the additive step | a fixed 200 ms | simplification |
    | Climb cap | 1.5 × received rate, never lowers the target | same | — |
    | Received rate | 500 ms window, by arrival | same | — |
    | Loss | < 2 % climb, > 10 % cut by half the loss | same thresholds; climb 8 %/s (Pion 5 % every 200 ms) | slower climb |
    | Congestion signal | Kalman / trendline over 5 ms arrival groups, adaptive threshold 6–600 ms | `QueueDelay`: the delay floor by send time (LEDBAT / SCReAM style) | deliberate: GCC as first ported read mobile jitter as congestion |
    | A missing packet | lost at once | lost after 500 ms | deliberate: on a mobile link it is usually late |
    | After a cut | climbs back at the normal rate | jumps to 85 % of what its bursts measured, or 1.5×/s back to the rate before a cut the queue never repeated | ours alone, still under the 1.5 × cap |
    | **Pacer** | **leaky bucket, a slice every 5 ms** | **none: a keyframe's 60+ packets leave at once** | **the gap** |

    The bench's reference column runs that sender for real: the same encoder
    through Pion (`scripts/bench-live-view/pion/`). Results, the colour probe:

    Before baguette had a pacer (2026-11-20) — the baseline:

    | Run | Sender | misses | p50 | p95 | p99 | fps | interval σ | freezes/min |
    |---|---|---|---|---|---|---|---|---|
    | Phone, Tailscale, 100 taps | baguette | 0 | 476 ms | 677 ms | 755 ms | 45.4 | 13.5 ms | 4.06 |
    | Phone, Tailscale, 100 taps | Pion | 0 | 468 ms | 963 ms | 1,168 ms | 51.0 | 4.8 ms | 0 |
    | Phone, Tailscale, 10 taps (old white probe) | baguette | — | — | — | — | 33.3 | 111.9 ms | 12.1 |
    | Phone, Tailscale, 10 taps (old white probe) | Pion | — | — | — | — | 35.4 | 148.4 ms | 5.4 |

    | 30 s, animated list, phone over Tailscale | Payload | Wire (est.) | Packets | fps |
    |---|---|---|---|---|
    | baguette | 6.19 Mbps | 6.39 Mbps | 19,684 | 43.2 |
    | Pion | 6.21 Mbps | 6.41 Mbps | 20,042 | 48.1 |

    (The 10-tap rows' latencies were the old probe's and meaningless; their
    smoothness columns stand.)

    Read: the median is the same, and so is the ~400 ms floor under both. That
    floor is not the network (see "Where the floor comes from" below). Both
    carried what the encoder made, so neither estimate held it back.

    What the data supports, and no more: **in this run Pion played smoother**
    (a third of the frame jitter, no freezes, more frames) **and had the worse
    tail** (p95 963 against 677 ms, from one episode, taps 50–70). It does
    *not* say why: Pion differs in its pacer, its estimator and its whole send
    path at once, and one run on an unimpaired, uncontrolled link can't
    separate them — nor rank transport-cc against REMB, or either under a cap
    or loss (that needs `impair.sh`, on loopback). The pacer is the likeliest
    cause of the smoothness, so it was built next; the test of that is our own
    sender with and without it (`?pacing=off`), same link, same run — measured
    on smoothness against p95.

    **The pacer's own A/B (2026-11-20)**: the same sender with and without its
    pacer (`?pacing=off`), one after the other, phone on mobile data over
    Tailscale:

    | Run | Pacer | misses | p50 | p95 | p99 | fps | interval σ | freezes/min |
    |---|---|---|---|---|---|---|---|---|
    | 100 taps | on | 0 | 386 ms | 709 ms | 898 ms | 51.9 | 3.3 ms | 0 |
    | 100 taps | off | 0 | 379 ms | 409 ms | 438 ms | 50.2 | 7.1 ms | 0 |

    | 30 s, animated list | Pacer | Payload | Packets | fps |
    |---|---|---|---|---|
    | | on | 7.37 Mbps | 23,456 | 52.1 |
    | | off | 7.02 Mbps | 22,381 | 47.2 |

    With the pacer: half the frame jitter and ~10 % more frames on a busy
    screen; the median the same; a worse tail (p95 +300 ms), from episodes
    (taps 20 and 50, ~600 ms) — the shape Pion showed too. The cause is not
    known. The server logged no *retune*, but that says only that the
    encoder's bitrate never moved over 10 %: the pacer reads the congestion
    control's target afresh on every slice, so it may have paced well below
    8 Mbps while the encoder kept sending 8 (a keyframe takes ~30 ms only at
    the full 20 Mbps). One run each can't separate the pacer from the radio
    either. The server now logs `[webrtc] pacer held a packet N ms, pacing for
    T kbps` whenever packets it sends had waited over 50 ms — their real wait,
    and the target then — so the next runs (alternated, several each), lined up
    with the slow taps, show which.

    **The same A/B on loopback** (this Mac's own headless Chrome, 3 runs each,
    alternated, 100 taps): paced p50 384–387 / p95 406–412 / p99 417–424 ms,
    interval σ 9.2–9.5 ms; unpaced p50 375–384 / p95 403–412 / p99 410–444 ms,
    σ 9.3–9.7 ms; **no `pacer held` line** in any run. On a clean link the
    pacer adds no delay and none of the tail; whatever it costs on the phone
    happens only where that link queues or the target drops — the next phone
    runs, with the log, say which. (Nor does it smooth anything here: loopback
    has no queue for a burst to overflow.)

    **Where the floor comes from.** The WebSocket transport on loopback reads
    the same: p50 367 ms. Split with the probe page reporting its `touchstart`
    (the simulator shares the Mac's clock): **~307 ms (292–329) pass between
    the tap's `POST /input` and Safari's `touchstart`**; capture, encode, send
    and paint take the other ~80 ms. The cost is the route, not the device:
    each `POST /input` builds the device's input afresh — a new HID connection,
    `[hid] symbols resolved` logged per request — and the request takes ~300 ms
    even for a 10 ms tap. The device page doesn't pay it: its socket keeps one
    input. **Fixed:** `DeviceInputs` keeps each running device's input
    across requests (dropped once the device is seen not running), and
    POST → `touchstart` fell to 206–245 ms (median ~222; the request itself
    ~470 ms first, then ~235 ms through the tap's lift). That made up ~85 ms
    of the 307, not all: the remaining ~220 ms is the touch's way through the
    simulator — our HID message, backboardd, Safari's web process — which the
    device page's socket pays too, so it is in what users feel. Where those
    220 ms go was measured next, and wasn't the simulator: the tap itself
    took 21 ms (its 20 ms hold; each HID message confirmed at once), and the
    route spent ~220 ms *finding the device* — every per-device request asks
    every source, and the phones source ran `devicectl list devices` (~195 ms)
    to say "not mine". **Fixed:** `CoreDevicePhones` reads the list once,
    answers from it for 2 s, then answers at once while a fresh one is read
    behind. POST → `touchstart` is now ~50 ms (40–61), the request ~70 ms,
    and on loopback tap-to-photon p50 ~110 / p95 ~134 ms unpaced, p50 ~118 /
    p95 ~146 paced (one 50-tap run each, which now vary ±40 ms run to run —
    the floor no longer hides the noise). The pacer's own wait, logged down
    to 5 ms for one run: at most 6 ms, pacing at the full 8 Mbps.

    **Phone on mobile data over Tailscale, after the input fix (2026-11-20)**,
    one run each, back to back:

    | Run | Pacer | misses | p50 | p95 | p99 | fps | interval σ | freezes/min |
    |---|---|---|---|---|---|---|---|---|
    | 100 taps | on | 0 | 219 ms | 353 ms | 384 ms | 44.0 | 21.3 ms | 8.37 |
    | 100 taps | off | 2 | 246 ms | 404 ms | 472 ms | 43.5 | 22.0 ms | 10.13 |
    | 30 s animated list | on | | 7.35 Mbps | | | 41.2 | | |
    | 30 s animated list | off | | 7.12 Mbps | | | 41.6 | | |

    The fixed input path took ~250 ms off the median (~470 → ~220 ms). This
    time the pacer led on every latency column, where the run before it
    trailed on the tail: on this link one run each doesn't separate them,
    and nothing says the pacer hurts. The log says what the link did: in the
    paced latency run the target was cut to 4.1 then 5.5 Mbps, and the pacer
    held packets 50–53 ms at those rates (9 times); in the paced bandwidth run
    the target saw-toothed between ~1.5 and ~3.6 Mbps. **Freezes, 8–10 a
    minute with or without the pacer, are the link's**: the estimate keeps
    cutting on this path, and that, not pacing, is the next thing to work on
    (which losses or delays trigger the cuts; whether a NACK or a keyframe
    request follows each freeze).

    **What the cuts are (2026-11-20)**, with each cut's cause logged, taps
    now over the viewer's control socket as the page sends them, mobile data
    over Tailscale: 100 taps p50 161 / p95 320 / p99 899 ms, 2 misses, fps
    43.7, interval σ 25.3 ms, 6.7 freezes/min; 30 s animated list 6.67 Mbps,
    41.7 fps. Over the ~111 s of both runs:

    - The sender logged 664 packet resend requests and 664 resends, with one
      keyframe request. Those counts describe the sender's attempts.
    - Nine of ten logged cuts named queue delay, +51 to +200 ms. One named
      a 50 % loss sample.
    - The rate returned to 8 Mbps within about a second of cuts to 4.6 and
      5.6 Mbps. This speed points to the burst-based jump. Batching can make
      a short burst's observed arrival rate exceed what the link carries over
      a longer window. A simulated 5 Mbps link with batched arrivals also
      reproduced this overshoot.

    A second separate queue within 10 s now caps both fast recovery paths
    at the observed arrival rate. Further increases use the normal climb.
    The cap expires after 10 s, or clears when what arrives over the
    half-second window exceeds it by more than 20 %. An isolated delay spike still
    recovers toward the rate held before its first cut. A fresh phone run is
    needed to measure the effect on visible freezes and the latency tail.

    **The phone run after it (2026-11-20)**, mobile data over Tailscale, taps
    over the control socket:

    | 100 taps | p50 | p95 | p99 | misses | interval σ | freezes/min |
    |---|---|---|---|---|---|---|
    | paced (new build) | 171 ms | 353 ms | 386 ms | 0 | 25.8 ms | 8.96 |
    | paced | 150 ms | 254 ms | 318 ms | 1 | 34.9 ms | 12.28 |
    | no pacer | 142 ms | 271 ms | 302 ms | 0 | 22.2 ms | 12.59 |

    30 s animated list: paced 7.33, 2.85, 5.55, 6.15 Mbps (44.6, 23.2, 34.5,
    43.9 fps); no pacer 6.81 Mbps (40.1 fps); Pion 4.42 Mbps (31.1 fps). The
    link varied more between runs than any sender did: these runs neither
    confirm nor refute the fix. The log says more:

    - **Radio dropouts:** reports with 96–99 % lost, each followed by keyframe
      requests and a cut — the worst run's cause, and no sender's to avoid.
    - **Ours — the encoder lags the pacer after a cut.** `cut to 1707 kbps`,
      then `pacer held a packet 162 ms`, `226 ms`, before `retune 8000 →
      1707`: the pacer slows at once, the encoder (retuned at most once a
      second) keeps making 8 Mbps, and the backlog is local. libwebrtc retunes
      on every target change.
    - **Ours — the cap lifts on a dropout's catch-up.** `retune 2098 → 8000`,
      `1504 → 6528`: what was held in the network during a stall arrives at
      once, the half-second window reads it as >20 % over the cap, the cap
      lifts and the target jumps back.

    The native sender now applies decreases without the cooldown (law 12).
    Successful retunes and pacer waits carry timestamps from the same
    viewer clock. To measure this change, compare builds with the pacer on and
    a single input path per run. The bench rejects a native tap run if its
    input socket closes. A separate experiment can test lifting the cap only
    after sustained arrivals.

    **After the encoder follows drops at once (2026-11-20)**, mobile data over
    Tailscale, one viewer at a time (the run before it shared the uplink with
    device-page viewers on `?congestion=remb`, which sit at 300 kbps on a
    still screen — not a measurement of anything): 100 taps p50 147 / p95 257
    / p99 339 ms, 1 miss, fps 43.4, interval σ 20.1 ms, 11.1 freezes/min;
    30 s animated list 7.25 Mbps, 46.6 fps. The log over both: **no cut, no
    retune, no pacer hold**; ~6 packets a second reported lost (639, under
    1 %), all resent; two keyframe requests. So these freezes are not the
    congestion control's nor the pacer's: the likeliest cause is loss
    repair — a frame with a lost packet waits a NACK round trip (100–200 ms
    over mobile and Tailscale), and the bench counts a gap over 200 ms as a
    freeze. Sender and bench timestamps can now test this explanation. A
    match with loss recovery would support comparing RED/ULPFEC or a lower
    mobile ceiling.

    **Its no-pacer counterpart, and the decision (2026-11-20)**, same link,
    one viewer each: 100 taps p50 156 / p95 298 / p99 377 ms, 0 misses,
    interval σ 27.0 ms, 8.9 freezes/min; 30 s animated list 3.4 Mbps,
    37.5 fps. Against the paced run (147 / 257 / 339 ms, σ 20.1, 11.1/min,
    7.25 Mbps, 46.6 fps) the pacer led on latency, smoothness and throughput,
    trailing only on the freeze count. The logs differ most: the paced
    bandwidth run made **no cut**; the unpaced one was cut 20 times, for
    queues of +238, +152, +434 and once +1212 ms — what unpaced bursts do to
    a mobile queue (that link was also rougher: twice the loss reports).
    **The pacer stays on by default**; `?pacing=off` remains for A/Bs. The
    same log still shows the cap lifting on a stall's catch-up
    (`2050 → 8000` a second later): lifting it only on sustained arrival is
    still to do, and so is a minimum pacing rate, so a keyframe drains in
    ~50 ms even at a low target.

    **Freezes against the sender's timeline (2026-11-20)**, mobile data over
    Tailscale, each freeze's start on the Mac's clock (phone-to-Mac
    uncertainty 18–31 ms), two rounds:

    | Run | p50 | p95 | p99 | fps | freezes/min | frozen | sender log |
    |---|---|---|---|---|---|---|---|
    | R1, 100 taps | 198 ms | 317 ms | 438 ms | 42.0 | 9.9 | 3.2 s | 3 cuts |
    | R1, 30 s busy | 4.67 Mbps | | | 38.7 | 16.0 | 3.3 s | 24 cuts, 31 retunes |
    | R2, 100 taps | 162 ms | 261 ms | 404 ms | 44.4 | 5.1 | 2.1 s | 1 cut |
    | R2, 30 s busy | 7.28 Mbps | | | 44.0 | 16.0 | 2.0 s | no cut |

    Lined up with the resend requests before each of the 35 freezes, against
    1,600 random moments in the same runs (packets asked for again in the
    300 ms before): ≥3 — 69 % of freezes, 46 % at random; ≥6 — 37 % / 17 %;
    ≥10 — 14 % / 4 %. "Any resend in the 500 ms before" (97 % / 92 %) tells
    nothing: they come ~5–6 a second. So **freezes follow bursts of loss
    2–3.5× more often than chance, not always**; a third had fewer than three
    resends before them. Most are 205–280 ms, against the bench's 200 ms
    threshold — a frame or few late, about one resend round trip. Next, not
    in this PR: RED/ULPFEC (a lost packet rebuilt without the round trip;
    bursts need more redundancy) or a lower ceiling on mobile.

    **Correlating a stall.** Join the benchmark's `viewerID` with the sender's
    [event log](README.md#http-and-websocket). The benchmark records
    gaps over 200 ms within the measurement window, from the last displayed
    frame (or the window start) through the first frame that follows. It sums
    their full durations. `recoveredAtMs: null` means the measurement ended
    while the picture was still stalled. When `freezeClock` is `server`, the
    bench proxy supplied the Mac's time and `clockUncertaintyMs` gives the
    estimate's uncertainty. If calibration is unavailable, durations remain
    comparable and the timestamps use the browser clock.

    Two bench fixes came first: a frame is stamped when it reaches the screen
    (`expectedDisplayTime`), not when its interval began (that gave negative
    samples); and each tap is answered in its own colour (left red, right green,
    sides alternating), as on a phone link a late answer to the last tap was
    counted for the next.

    Over a simulated 2 Mbps bottleneck (`BandwidthEstimateTests`), the target
    falls from 8 Mbps to 1.7 Mbps within 2 s and saw-tooths just under 2 Mbps
    (additive increase near capacity, back to 85 % of what arrives on overuse);
    when the link frees up at 20 s it climbs additively to 2.4 Mbps, then 8 % a
    second, back to 8 Mbps by 44 s. 20 % loss halves it repeatedly; 1 % doesn't
    move it.

    In Chrome on 2026-11-20 (native route, localhost): the answer negotiates
    transport-cc, Chrome's reports arrive and are read; a still screen left the
    bitrate alone, and a forced `set_bitrate` of 2 Mbps was retuned back to
    8 Mbps within a second. That run first found a bug the simulation missed:
    capping the rate at 1.5× what arrives also pulled it *down* while a still
    screen sent little, to the 300 kbps floor. libwebrtc's cap only stops an
    increase; so does ours now, pinned by "should keep its bitrate while a still
    screen sends far less than it allows".
12. ~~**Docs**~~ **DONE**: a user README, `serve.md` rows, CHANGELOG; the bench
    kit pointed at the native route. The full matrix on it is still to run.

## 6b · Next: resends, then connectivity (simplest first)

Each step stands alone: test-first, its own PR, measured on the phone where
it changes what the viewer sees. Steps 1–2 are WebRTCKit's `Media/` and
`Congestion/`; 3 is the serve routes; 4–7 are WebRTCKit's `Transport/`.

1. **Resend guard** (`Media/`, pure logic). A resend is skipped when its
   packet is too old to help (older than the browser can still use), and
   resends stay under a share of the target bitrate, so a loss burst can't
   add congestion of its own (libwebrtc does both). *Pinned: "should not
   resend a packet too old to arrive in time", "should keep resends under
   their share of the target".*
2. **RTX** (RFC 4588; `Signaling/`, `Media/`, `Congestion/`). Today a resend
   is the stored packet again — same transport-wide sequence number — so
   `SendHistory` counts a loss repaired within its 500 ms grace as a packet
   that *arrived late*: the loss estimate never sees it, and the delay
   estimate gets a fake queue sample of one resend round trip. With RTX, the
   answer takes the offer's `rtx` format (`apt=` our H.264) and an
   `ssrc-group:FID`; a resend leaves on its own stream with the original
   sequence number in front, a new transport-wide number and its real send
   time. *Pinned: "should count a loss its resend repaired as a loss, not a
   delay", "should answer the offer's rtx format for our H.264".* Measure:
   freezes and cuts on the phone, before and after.
3. **Authentication** (serve). A browser reachable from the internet can
   reach `serve`, which drives the device: WHEP and the control socket need
   a credential first (a token per session at least). The prerequisite for
   4–7. *Decide first: a token in the URL, or per-viewer sign-in.*
4. **Server-reflexive candidate** (`--stun stun:host:port`). The kit asks a
   STUN server for its public address and offers it beside the host ones
   (a STUN binding request; `STUNMessage` already reads the reply's shape).
   Alone it reaches only a NAT that lets anyone in — most don't; step 5
   makes it useful.
5. **Full ICE.** The kit stops being ICE-lite: it pairs its candidates with
   the browser's, sends its own checks (opening its NAT toward the browser),
   and nominates a pair. The browser's candidates come with the offer (the
   page waits for gathering) or by WHEP trickle (`PATCH`). Covers most home
   and office NATs.
6. **TURN client** (`--turn turn:host:3478 --turn-user … --turn-pass …`).
   Allocate, permissions, channels, refresh: a relay candidate that gets
   through symmetric NATs and strict firewalls, at the relay's latency.
   *Decide first: self-hosted coturn or a provider.*
7. **WHEP `Link: rel="ice-server"`.** The answer names the STUN and TURN
   servers, so the browser uses them too.

Until 3–6 land, Tailscale is the way to view from outside the network: it
gives all of this, privately.

## 7 · Open questions

1. ~~**Which WebRTC stack?**~~ **ANSWERED: our own, in Swift.** The BoringSSL
   inside `swift-nio-ssl`, already in the build, does DTLS and exports SRTP
   keys (`DTLS_method`, `SSL_CTX_set_tlsext_use_srtp`,
   `SSL_export_keying_material`), probed on 2026-11-20. That leaves ICE-lite,
   SDP, RTP and SRTP: small, well-specified, and testable as values. libwebrtc
   (tens of MB) and a Pion sidecar (a second binary to ship) lost on weight.
2. **Move input to a DataChannel?** It would mean a second WebRTC negotiation
   just for control. Out of scope until the video result is in. Changing both at once
   would make the bench meaningless.
3. **MJPEG over WebRTC?** No. WebRTC has no JPEG video codec. MJPEG stays
   WebSocket-only.
4. **Does a localhost-only user ever benefit?** H1 says no. If the bench
   confirms that, WebRTC is a remote-viewing feature, and the
   [handheld](../handheld/README.md) phone-over-Wi-Fi case is its first real
   user.
5. **Publishing to an SFU (later, its own PR).** An SFU (Selective Forwarding
   Unit: Cloudflare Calls, LiveKit, mediasoup, Janus, MediaMTX) relays one upload
   to many viewers without re-encoding. It would give baguette many simultaneous
   viewers for one encoder and upload (a team on one simulator, a device farm
   watched from many machines), and reach viewers that can't reach the Mac, since
   the Mac connects out. Revyl's page uses Cloudflare's STUN server, which suggests
   they sit behind Cloudflare's SFU (an inference; the page doesn't show it).
   What it takes — baguette publishes with **WHIP** (RFC 9725, WHEP's publishing twin),
   so the roles flip:

   | | Today (WHEP, direct) | SFU (WHIP publish) |
   |---|---|---|
   | Offer | the browser makes it | baguette makes it |
   | ICE | baguette answers checks (ICE-lite) | baguette sends checks (full ICE, controlling) |
   | DTLS | server | client (`BoringSSLHandshake` has the role; tests use it) |
   | Reach | browsers reach the Mac | the Mac connects out |
   | Bandwidth feedback | transport-cc from the browser | the same, from the SFU |

   RTP, packetizing, SRTP, RTCP feedback and congestion control carry over
   unchanged. New: writing an offer, full-ICE checks, and a setting naming the
   SFU's WHIP URL and token. An SFU forwards one bitrate to everyone: adapting per
   viewer would need simulcast (several encodings at once), a further step.
   Worth it once many viewers or a hosted device cloud matter; for one or a few
   viewers the direct connection is the right shape.
