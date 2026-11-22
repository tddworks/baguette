---
description: WebRTCKit's domain design — one browser's send-only WebRTC session, the paths it reaches the browser by, how it recovers lost packets, and every law it owns. Read before changing anything under Sources/WebRTCKit.
---

# WebRTCKit — design

**Status:** BUILT, 2026-11-21. `Sources/WebRTCKit` is a target in this
package with its own tests (`Tests/WebRTCKitTests`); it depends on Mockable and
NIOSSL, never on baguette. **Designed, not built:** a standalone session test
(ICE, DTLS and SRTP on loopback with no baguette types), its own SwiftPM
package, IPv6 sockets, TURN over TCP or TLS, and receiving. **H.265** is
built in the kit (K1–K3, 2026-11-22) but sent only when its owner asks — and
baguette doesn't ask yet ([Codec](#codec--h264-today-h265-designed)).

This doc owns **one browser's sending session: the path it reaches the browser
by, what it sends, and what it does with the browser's feedback.** It hands
away:

| For | Read |
|---|---|
| What each feature does, for a user | [README](README.md) |
| The WHEP routes, the viewer, its stream and `EncoderRetune` | [webrtc design](../webrtc/design.md) |
| The bench, its measurements and the build history | [webrtc design §5–§6b](../webrtc/design.md#5--the-bench) |
| The kit as a context of the whole model | [CANONICAL_MODEL](../../CANONICAL_MODEL.md) |

## The one sentence

**Given a browser's offer and encoded H.264 frames, a sender puts those frames
in front of the browser over whichever path reaches it, repairs what that path
loses, and tells its owner how much the path can carry.**

```text
owner (baguette's WebRTCViewer) ── EncodedFrame ──▶ WebRTCSender ── SRTP over UDP ──▶ Browser
                                ◀── SenderEvents ──      │          (direct, or through a TURN relay)
                                                         ◀── checks, DTLS, RTCP feedback
```

The owner decides what the encoder makes; the sender only asks (a keyframe) and
reports (a bitrate). That split is what keeps the kit free of devices.

## 1 · Ubiquitous language

| Term | Meaning | Not to be confused with |
|---|---|---|
| **Sender** | One browser's session, sending only: `WebRTCSender` | The *viewer*, baguette's sender-plus-stream |
| **Owner** | Whoever feeds a sender frames and hears its `SenderEvents` | The browser, the sender's *peer* |
| **Candidate** | An address the browser might be reached at: *host* (its own), *srflx* (what a STUN server saw), *relay* (on a TURN server) | A *path*: a candidate on each side |
| **Check** | A signed STUN Binding request proving a path works, in either direction | *Consent*, which is the browser's checks continuing |
| **Nomination** | The browser marking one checked path as the one to use (`USE-CANDIDATE`); the browser controls, the sender is controlled | A check that merely succeeds |
| **Consent** | The browser still checking; 30 s without a check means it has gone (RFC 7675) | Keep-alive of a TURN allocation |
| **Allocation** | A relayed address held on a TURN server for one sender, for a lifetime, until released | A *permission*: which peers may use it |
| **Resend** | A lost packet sent again because the browser asked (NACK) | *RTX*, which is how a resend is framed when negotiated |
| **RTX** | A resend on its own stream: its own SSRC, sequence and payload type, the original sequence first (RFC 4588) | FEC: redundancy sent before anything is lost (not built) |
| **Target** | The bitrate the link can carry now, as the congestion control reads it | The encoder's bitrate, which the owner sets |
| **Pacing** | Spacing packets so a keyframe doesn't leave as one burst | Throttling the encoder |
| **Codec** | How the pictures are compressed on the wire: H.264 today, H.265 designed — `VideoCodec` | The *format* (MJPEG / AVCC / WebRTC), baguette's word for the transport |
| **Sendable codecs** | The codecs the owner's encoder can make, handed to the kit — the kit never knows what encodes them | The codecs the browser *offers* |
| **Parameter sets** | What a decoder needs before a keyframe: SPS + PPS (H.264), VPS + SPS + PPS (H.265) | A keyframe itself |
| **Packetizer** | Turns one picture into RTP payloads: RFC 6184 for H.264, RFC 7798 for H.265 — the `RTPPacketizer` role | The *pacer*, which decides when they leave |

"Sender" over "peer connection": it sends only, and the kit has no receiving
side to share a name with.

## 2 · The aggregate, from the root down

```
WebRTCSender  ◆                     ONE BROWSER'S SESSION: connecting → securing → live → hungUp
├─ answer : String                  written once by SessionDescription ◇ from the offer:
│                                   H.264 + RTX formats, ICE credentials, candidates, fingerprint
├─ ice : ICECredentials ◇            ours; the browser's, and its candidates, come from the offer
├─ nominated : DatagramAddress?     the path the browser chose last; media goes there
├─ datagrams : any Datagrams  ◆     one UDP socket, told apart by first byte (RFC 7983)
│   ├─ UDPDatagrams                 the socket itself (Internal/System/)
│   └─ RelayedDatagrams  ◆          the socket with a TURN relay beside it; reached through it,
│       └─ TURNAllocation ◇          a peer looks as if reached directly
│           └─ TURNServer ◇ · TURNAuth ◇   where, and who to be (MD5(user:realm:pass))
├─ handshake : any Handshake  ◆     DTLS, passive (BoringSSLHandshake in System/) → SRTP keys
├─ SRTPContext ◇                     protects RTP, unprotects RTCP; a rollover per SSRC
├─ H264Packetizer ◇ → RTPPacket ◇    single NAL or FU-A, parameter sets as STAP-A, ≤1200 B
├─ Pacer ◇                           what may leave now
├─ history : PacketHistory ◇         what left, for a second: the resend guard
├─ congestion : any CongestionControl   picked per sender by CongestionChoice ◇
│   ├─ TransportWideControl          transport-cc → SendHistory ◇ · FeedbackClock ◇ ·
│   │                                 BandwidthEstimate ◇ → QueueDelay ◇
│   ├─ ReceiverEstimateControl       REMB: the browser's own estimate
│   └─ FixedBitrate                  nothing estimated
└─ events : any SenderEvents  ◆     weak; keyframeNeeded · estimated(bitrate:at:) · hungUp · diagnostic

Gathered by the owner before the sender exists, through the sender's own socket:
STUNServer ◇ → publicAddress (srflx)  ·  TURNAllocation.allocate → RelayedDatagrams (relay)
```

### `WebRTCSender` — one browser's session

> **Pointable as:** the outgoing half of a video call, one per person watching.

| | |
|---|---|
| **Owns** | Its state; which path it is on; what it sent in the last second; the target |
| **Tell it** | `send(_ frame:)` · `tick(now:)` · `hangUp()` · `note(_:)` (an owner's line on its timeline) |
| **It answers** | `answer` · `state` · `pacing` |
| **Never** | Encodes, chooses the encoder's bitrate, sends before it is secured, sends in the clear, moves to a path the browser didn't nominate once one is, ignores signed feedback for where it came from, or knows what it is showing |

### `RelayedDatagrams` — the socket with a relay beside it

> **Pointable as:** a forwarding address at a post office.

| | |
|---|---|
| **Owns** | Its allocation and permissions, kept alive at half their lifetimes; which peers it last heard through the relay |
| **Tell it** | `permit(_ peers:)` · `keepAlive()` · `send(_:to:)` · `close()` |
| **Never** | Lets the sender see which path a datagram took; outlives its sender's socket without releasing the allocation |

## 3 · The tells

From `WebRTCViewers.admit` and `WebRTCViewer`, the kit's one owner today:

```
let offer = try SessionDescription(offer: sdp)               // refuses no H.264 mode 1 (422)
let reflexive = stun?.publicAddress(through: datagrams)      // srflx, or nil from a silent server
if let turn, let allocation = TURNAllocation.allocate(on: turn, through: datagrams) {
    let relay = RelayedDatagrams(over: datagrams, allocation: allocation)
    relay.permit(offer.candidates); relay.keepAlive()        // the sender now talks through relay
}
let sender = WebRTCSender(offer: offer, datagrams: …, handshake: …, congestion: CongestionChoice…,
                          encoderBitrate: …, events: …, reflexive: …, relay: …)
→ sender.answer                                              // the WHEP 201 body
sender.send(EncodedFrame(avcc:, isKeyframe:, parameterSets:)) // each encoded picture
sender.tick(now:)                                            // consent; DTLS retransmits
events.keyframeNeeded()  → the owner asks its encoder for an IDR
events.estimated(bitrate:at:) → the owner decides whether to retune (EncoderRetune)
sender.hangUp()                                              // closes the socket; releases the relay
```

## 4 · Invariants — each law, one owner

| Law | Owner |
|---|---|
| A viewer gets H.265 only when its owner asked for it, its offer carries Main-profile H.265 and the owner can send it; otherwise High-profile H.264 in packetization mode 1; neither → refused ([Codec](#codec--h264-today-h265-designed)) | `CodecChoice` |
| An offer carries a congestion-control method only when it numbers the extension 1–14, will receive it, and asks for its feedback on our H.264 or on every format | `SessionDescription` |
| A check is answered only when it names our username fragment and is signed with our ICE password | `STUNMessage` |
| With candidates in the offer, the sender checks each itself as the controlled agent, at once and then backing off (0.1–1.6 s), until secured; with none it is ICE-lite | `WebRTCSender` |
| The session follows the path the browser nominated last; a check that doesn't nominate never moves it | `WebRTCSender` |
| Feedback is the browser's when its SRTCP signature checks out, whichever of its addresses it arrives from | `WebRTCSender` |
| Nothing is sent before the handshake completes, and everything after it through SRTP | `WebRTCSender` |
| A secured session asks its owner for a keyframe, and again whenever the browser reports a lost picture | `WebRTCSender` |
| 30 s without a check hangs up; a hang-up is told to the owner once and nothing is sent after it | `WebRTCSender` |
| No RTP packet carries more than 1200 bytes of payload | `H264Packetizer` |
| Each stream's SRTP rollover is its own | `SRTPContext` |
| A lost packet is resent unless first sent over 1 s ago, resent in the last 100 ms, or resends would take more than half the target | `PacketHistory` |
| A resend leaves on its own stream, stamped anew for congestion control, when the offer pairs a resend format with our H.264; else as it was sent | `WebRTCSender` |
| With pacing on, packets leave at 2.5 × the target, faster when the queue couldn't otherwise empty within 500 ms; a small frame leaves at once | `Pacer` |
| The target is the lower of the delay- and loss-based estimates, between 300 kbps and the starting bitrate | `BandwidthEstimate` |
| Transport-cc reports are read on one unbroken timeline across their 24-bit wrap | `FeedbackClock` |
| A method is the one asked for when the offer can carry it; else transport-cc, else REMB, else none | `CongestionChoice` |
| A server-reflexive address is offered below the host ones, without naming the private base; a silent STUN server leaves the host ones | `STUNServer` |
| A relayed address is offered lowest; the browser's addresses are let through, kept alive until hang-up, then released; what comes through the relay reaches the sender as if from the peer | `RelayedDatagrams` |
| A signed request answered with a second 401 means the credentials are wrong: no relay, no retry | `TURNAllocation` |

These are the laws [CANONICAL_MODEL](../../CANONICAL_MODEL.md) lists for the
kit; the viewer's own (one encoder per viewer, retuning, reached only through
its device) are in [the webrtc design](../webrtc/design.md#4--invariants-each-law-one-owner).

## Session and network paths

1. **Connecting.** The owner parses the offer, opens a UDP socket, and can
   use the kit's STUN and TURN components to gather more candidates. The
   answer lists host addresses first, then the srflx address (priority
   1694498815), then the relay (16777215), both with `raddr 0.0.0.0 rport 0`.
2. **Checking.** With parseable candidates in the offer, the sender checks
   them as the controlled agent (USERNAME `theirs:ours`, PRIORITY,
   ICE-CONTROLLED, signed with the browser's password). The SDP parser takes
   UDP candidates with numeric IPs and skips mDNS (`.local`) and TCP. With
   none, the answer says `a=ice-lite` and the sender only answers checks.
   Media goes to the path the browser nominated last. **Why "last", not
   "first":** Chrome with several paths to the Mac (loopback, LAN, Tailscale)
   nominates one, then a better one, and sends its RTCP from there. Locked to
   the first, the sender dropped all 258 of a run's RTCP packets (2026-11-21):
   no resends, no keyframe requests, no congestion feedback, while the picture
   still played.
3. **Securing.** DTLS from the selected path only. When the handshake exports
   the SRTP keys the sender goes live and asks for a keyframe.
4. **Live.** Each frame is packetized, paced, stamped, protected and sent;
   RTCP feedback is read from the same path.
5. **Hung up.** By request, a failed handshake, or consent running out.
   Closing the socket releases any TURN allocation.

The STUN query goes through the sender's own socket so the mapping belongs to
it, with a 0.5 s deadline and one retry halfway. A TURN allocation is an
unsigned Allocate, the 401's realm and nonce, then the same request signed; a
438 (stale nonce) is answered with the new nonce. Permissions last 300 s and
are renewed every `min(lifetime / 2, 240 s)`.

## Recovering lost packets

1. The browser sends a NACK naming missing RTP sequence numbers.
2. `PacketHistory` applies the resend guard. Its budget refills at half the
   target and holds one second of it, so a loss burst can't add congestion of
   its own (libwebrtc caps resends too).
3. With RTX, the resend carries the original sequence number in front, on the
   RTX SSRC (`ssrc-group:FID`), with a new transport-wide sequence number and
   its real send time. **Why it matters:** before RTX, a resend reused the
   original's transport-wide number, so a loss repaired within `SendHistory`'s
   500 ms grace read as a packet that arrived late. The loss estimate never saw
   it, and the delay estimate took a fake queue sample of one resend round
   trip.

Recovery only helps if the resend arrives before the browser needs the
picture; when it doesn't, the browser asks for a keyframe, and that request
goes to the owner.

## Codec — H.264 today, H.265 designed

**Built in the kit (K1–K3); not asked for yet** — baguette's encoder and wiring
are slices 4–5. Why, when it pays and how it is measured belong to the live
view: [webrtc/hevc.md](../webrtc/hevc.md). What the kit owns is below.

**The one sentence:** *a sender sends the codec `CodecChoice` picks from what
its owner asked for, what the browser offered and what the owner can send —
High-profile H.264 unless all three say H.265.*

```text
 owner ── asked (h265 · h264 · auto · none) + sendable codecs ──┐
 offer ── SessionDescription reads H.264 AND H.265 ─────────────┤
                                                                ▼
                                                  CodecChoice ◇ → VideoCodec ◇ | refusal
                                                                │
                      ┌─────────────────────────────────────────┼─────────────────────────────┐
                      ▼                                         ▼                             ▼
     SessionDescription.answer:                   the owner: encode in it          WebRTCSender takes
     its rtpmap / fmtp lines                      (EncodedFrame.codec)              codec.packetizer
```

| Type | What it is |
|---|---|
| `VideoCodec` ◇ | `.h264(profileLevelID)` · `.h265(profileID, levelID, tier)`: its `rtpmap` / `fmtp` lines and its packetizer |
| `CodecChoice` ◇ | the law below — beside `CongestionChoice`, which chooses the same way |
| `RTPPacketizer` ◆ | `payloads(picture:, parameterSets:) → [Data]`; `H264Packetizer` (today, unchanged) and `H265Packetizer` play it — the sender holds `any RTPPacketizer`, so a codec is a new type, never an edit to the sender |
| `EncodedFrame` ◇ | unchanged: its NAL units are 4-byte length-prefixed for both codecs, and `parameterSets` holds 2 (H.264) or 3 (H.265). It carries no codec — the session chose one, and the sender cuts with that codec's packetizer |

**Choosing.**

| asked | offer carries Main-profile H.265 | owner can send H.265 | → |
|---|---|---|---|
| `h265` | yes | yes | **H.265** |
| `h265` | no, or the owner can't | — | High-profile H.264 — asking never refuses |
| `auto` | yes | yes | **H.265** |
| `auto` | otherwise | | H.264 |
| `h264` / none | — | — | H.264 — the default |
| any | neither usable | | refused (422), as today |

**Packetizing.**

| | H.264 — RFC 6184 (built) | H.265 — RFC 7798 (designed) |
|---|---|---|
| NAL header | 1 byte (type: 5 bits) | 2 bytes (type: 6 bits, layer id, temporal id) |
| parameter sets | SPS + PPS ahead of a keyframe, in one STAP-A (type 24) | VPS + SPS + PPS ahead of a keyframe, in one Aggregation Packet (type 48) |
| a large NAL | FU-A (type 28): FU indicator + header | FU (type 49): 2-byte payload header + FU header |
| a small NAL | single NAL unit packet | single NAL unit packet |
| marker · timestamp | last packet of the picture · 90 kHz | the same |

**Laws** — the first replaced §4's "an offer with no High-profile H.264 … is
refused, never answered with another codec", in the same change:

| Law | Owner |
|---|---|
| a browser gets H.265 only when its owner asked for it (or `auto`), its offer carries Main-profile H.265 and the owner can send it; otherwise High-profile H.264; neither → refused | `CodecChoice` |
| asking for H.265 never refuses a browser that can take H.264 | `CodecChoice` |
| the answer names exactly the codec the sender packetizes | `SessionDescription.answer` (from one `VideoCodec`) |
| a keyframe leaves after its parameter sets | each `RTPPacketizer` |
| no RTP packet carries more than 1200 bytes of payload | each `RTPPacketizer` |

**Build** (in `Tests/WebRTCKitTests`, no baguette types):

| Slice | What | Pins |
|---|---|---|
| K1 | `RTPPacketizer`; `H264Packetizer` plays it unchanged; `H265Packetizer` | byte for byte: a single NAL, an AP of VPS / SPS / PPS, FU start / middle / end with the right S / E bits and payload header |
| K2 | `VideoCodec`, `CodecChoice` | every row of *Choosing* |
| K3 | `SessionDescription` reads every H.264 and H.265 offered and answers the chosen one; the sender takes that codec's packetizer | the offer Chrome 157 posts, captured (`Chrome157Offer.swift`): H.265 Main at 49, Main 10 at 51, High H.264 at 118. An iPhone's offer is still to capture |

## 5 · Open questions

1. **Does RTX reduce freezes on a lossy link?** Measured only on loopback,
   where nothing is lost. The next phone run on mobile data answers it
   ([future work](../webrtc/design.md#6c--future-work--whats-left-what-each-is-for-and-when-its-needed)).
2. **Which pair carries the media under TURN?** Chrome played with only relay
   candidates, but the nominated pair isn't logged. A diagnostic line on
   nomination answers it.
3. **Authentication.** The kit doesn't need it; `serve` does, before `--stun`
   or `--turn` are used with a `serve` reachable from the internet. Skipped
   for now (2026-11-20); Tailscale is the way in from outside.
4. **When does it become its own package?** After the standalone loopback
   session test, so the package ships with proof it works without baguette.
5. ~~**Full ICE or ICE-lite?**~~ Both: full ICE when the offer carries
   candidates, ICE-lite when it doesn't, so an offer that doesn't wait for
   gathering still plays (2026-11-21, #149).
6. ~~**Does a relayed path need its own sender logic?**~~ No: `RelayedDatagrams`
   presents relayed peers as direct ones, and the system test against Pion's
   TURN server passed unchanged (2026-11-21, #150).
