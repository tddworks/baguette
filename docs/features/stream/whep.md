---
description: A proposal to carry the serve live view over WebRTC (WHEP) next to the stream WebSocket, and how we measure whether it is actually faster before we build it. Read before changing how the browser receives video.
---

# Live view over WebRTC (WHEP): design and bench

**Status:** DESIGN, approved 2026-11-20; being built on `feat/whep-live-view` in the order of [§6](#6--build-sequence-test-first-each-slice-green). Slice 0 (spike) has been run on localhost; [results](#slice-0-results--localhost-2026-11-20). The stream WebSocket is the only live view
today. Nothing under `Sources/` refers to WebRTC, WHEP, RTP or SDP. The first
slice is a **bench**, not a feature. We ship the transport only if the bench
meets the [decision rule](#the-decision-rule).

This doc owns **how encoded frames travel from `baguette serve` to the page,
and how we compare two ways of doing it**. It doesn't change what gets encoded
or how input gets in:

| For | Read |
|---|---|
| The encoder, AVCC tags and retune commands | [stream](README.md) |
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
| **H.264 on a phone without HTTPS** | WebCodecs needs a secure context, so a plain-`http` phone page gets MJPEG (issue #71): more bytes, skipped frames | Nothing extra. `<video>` decodes WebRTC H.264 on any page |
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
| **WHEP** | WebRTC-HTTP Egress Protocol (RFC 9725): POST an SDP offer, get an SDP answer and a `Location` to `DELETE` later | WHIP, the publishing side |
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
reference chain. Everything below lives in the Stream context:
`Sources/Device/Abilities/Capture/RTP/` (`RTPPacket`, `H264Packetizer`, shared
with a phone's screen) and `Capture/WebRTC/` (the rest). The laws are also in
[CANONICAL_MODEL](../../CANONICAL_MODEL.md).

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
    └─ RTCPFeedback ◇                  PLI · FIR → keyframe; NACK → resend from history; REMB → bitrate
```

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
stream → sink.write(env)  → viewer.send(env): packets, SRTP, datagrams
viewer.receive(SRTCP)     → PLI/FIR: stream.requestKeyframe() · NACK: resend · REMB: stream.apply(bitrate)
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
POST offer → answer; drop goog-remb lines; add b=AS:15000 if the answer has no bandwidth line
ontrack: receiver.jitterBufferTarget = 0, playoutDelayHint = 0 → <video autoplay playsinline muted>
getStats() every 500 ms: reconnect when no first frame in 10 s or no new frame for 3 s
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
| 10 | Every bench run compares the transports on the same device, build, encoder settings and impairment, one transport at a time | the bench harness (`scripts/bench-live-view`) |

Law 1 is what makes the comparison fair. If WebRTC needs different tuning
(for example a shorter GOP for loss recovery), the bench runs both transports
on that tuning too.

## 5 · The bench

**One probe, both transports.** Tap-to-photon is what a user feels, and both
transports can measure it the same way from inside the page:

1. The simulator's Safari shows a probe page that turns the screen from black
   to white on `touchstart` and back on `touchend`.
2. The bench page taps the centre through `POST /devices/:udid/input` (the same
   route for both transports) and records `t0 = performance.now()`.
3. Every presented frame (`requestVideoFrameCallback` on the `<video>`, the
   `requestAnimationFrame` paint on the canvas) samples the centre pixel. The
   first white sample gives `t1`.
4. **Tap-to-photon = t1 − t0.** One tap every 0.5–0.7 s (randomised so taps
   don't line up with vsync), 100 per run. Results show on the page.

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

**The matrix:** {websocket, webrtc} × {localhost, LAN Wi-Fi, 50 ms RTT, 50 ms +
1 % loss, 50 ms + 5 % loss, 5 Mbps cap} × {1, 4, 8 devices} for CPU. We apply
impairments with `dnctl` + `pfctl` dummynet on the loopback or LAN interface,
scripted so every run can be reproduced. Network Link Conditioner is fine for
spot checks.

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

It prints three URLs:

- **`/bench/?udid=…`**, the measured runs: latency 100 taps, bandwidth 30 s and
  a 10-tap quick check, once per transport. Plus buttons that put the probe page
  or the animated list on the simulator.
- **`/devices/<udid>`**, `baguette serve`'s own page, unchanged: today's
  WebSocket view.
- **`/devices/<udid>?transport=webrtc`**, the same page with the WHEP video
  laid over the stream canvas (`whep-overlay.js`, injected by the proxy). The
  video ignores pointer events, so touch, scroll and the toolbar still go through
  the page's own input and socket. That socket is held at 2 fps so it doesn't
  compete for bandwidth. A badge shows the WebRTC state and fps. Use this pair to
  feel the difference by hand.

One process, `proxy.mjs`, serves it all on one origin:

```
viewer ──http :8777──▶ proxy.mjs ─┬─ /bench/*          ▶ the bench pages; /bench/bridge/on|off ▶ the WHEP source
                                  ├─ /whep             ▶ MediaMTX :8889 (media itself: UDP :8189, direct)
                                  ├─ /api/*            ▶ baguette serve, prefix stripped
                                  └─ everything else   ▶ baguette serve 127.0.0.1:8421, as is (HTTP + WebSocket)
```

- **A phone gets MJPEG on the WebSocket, H.264 on WebRTC.** Browsers only
  expose WebCodecs (`VideoDecoder`) to secure contexts (HTTPS or localhost).
  So a phone on plain `http://` can't decode the WebSocket's H.264, and the
  serve page falls back to MJPEG (issue #71); the bench does the same. WebRTC's
  `<video>` needs no secure context, so it plays H.264 on that same page.
  **H.264 on a phone without HTTPS is itself a WebRTC benefit.** Note: MJPEG
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
1. **`RTPPacket`** moves from the iPhone family to the Stream context and learns
   to serialize. *Pinned: "should write the header a phone's parser reads back".*
2. **`H264Packetizer`.** *Pinned: "should fragment a picture too big for one
   packet into FU-A packets with start and end bits", "should bundle SPS and
   PPS into one STAP-A ahead of a keyframe", "should mark the last packet of a
   picture".*
3. **`STUNMessage`.** *Pinned: "should answer a check whose integrity matches the
   ICE password", "should refuse a check whose integrity doesn't match".*
4. **`SessionDescription`.** *Pinned: "should answer an offer with its H.264
   payload type in packetization mode 1", "should refuse an offer with no H.264
   it can send".*
5. **`SRTPContext`.** *Pinned: RFC 3711 key-derivation and protect vectors.*
6. **`RTCPFeedback`.** *Pinned: PLI, FIR, NACK and REMB parsed from a compound
   packet.*
7. **`Datagrams` + `Handshake`**, the two `System/` files. *Pinned: `.system`
   tests (a loopback UDP round trip, a DTLS handshake between two contexts that
   exports the same SRTP keys).*
8. **`WebRTCViewer`** against `MockDatagrams` / `MockHandshake`. *Pinned: the
   laws 2, 5, 6, 7.*
9. **`WebRTCViewers` and the routes**: `POST`/`DELETE /devices/:udid/whep` and
   the control WebSocket, through `InProcessServer`.
10. **The page**: a WebRTC option beside H.264 and MJPEG, painting the `<video>`
    onto the stream canvas. *Pinned: `make test-web`.*
11. **REMB → bitrate.**
12. **Docs**: a user README, `serve.md` rows, CHANGELOG; the bench kit pointed
    at the native route, and the full matrix run on it.

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
