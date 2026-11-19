# A phone's screen: two receivers

> Both routes start the phone's own stream through CoreDevice, over the same tunnel. They differ in who writes the offer, and who receives, reassembles and decodes the stream: Apple's AVConference, run in baguette's own process (`avconference`, the default), or baguette (`rtp`). Pick one with `BAGUETTE_PHONE_SCREEN`; the research behind the second is in [design.md](design.md#the-screen-through-avconference-in-process-spike-2026-11-19).

## `rtp` — `MediaStreamScreen`, baguette's own receiver

```
MediaStreamScreen.stream()
 1. tunnel.open(to:)               RemoteDevice.connect() → TunnelEnds (phone …::1, Mac …::2)
 2. openSocket()                   UDPSocket, IPv6, any port
 3. MediaStreamOffer(...).bytes    our offer: AVConference's fields minus HEVC → H.264 only
 4. starter.start(on:)             CoreDevice startMediaStream(StartRequest{negotiatorOffer, receiverIP, port})
                                   ← StartResponse: streamConfig (SourceIP/Port, SSRCs)
 5. receive() loop:
      socket.receive()             the phone's RTP datagrams
      RTPPacket → VideoDepacketizer   H.264 frames (single NALs, FU-A; 0x92 carries the avcC's SPS/PPS)
      ReceiverFeedback             our RTCP: receiver reports, picture-loss requests
      DecodeGate                   nothing until a keyframe after a loss
      VTStreamDecoder              VideoToolbox: H.264 → BGRA IOSurface → onFrame
```

Everything after the start is baguette's code and unit-tested byte for byte (`MediaStreamPackets`, `ReceiverFeedback`, `MediaStreamSession`).

## `avconference` — `AVConferenceScreen`, AVConference's receiver in-process

```
AVConferenceScreen.stream()
 1. tunnel.open(to:)               the same
 2. openSocket()                   the same UDPSocket on the tunnel
 3. mirroring.offer()              Apple's offer: AVCMediaStreamNegotiator, mode 5 → negotiates HEVC
 4. starter.start(on:)             the same CoreDevice call; the StartResponse also carries negotiatorAnswer
 5. mirroring.accept(answer:)      the negotiator takes the phone's answer
    mirroring.start()              an AVCVideoStream run in-process, on a LoopbackRelay (IPv4 loopback pair)
 6. relay — baguette only carries bytes:
      socket.receive() → mirroring.deliver()      the phone's RTP/RTCP into AVConference
      mirroring.nextReport() → socket.send()      AVConference's RTCP back to the phone
    inside AVConference:           jitter buffer, depacketizing, loss recovery, rate control, HEVC decode
 7. each decoded picture, pushed as it is decoded:
      _VCVideoStream_DidReceiveRemoteFrame     AVConference's per-picture C callback, after its jitter
                                               buffer; DecodedPictureTap wraps it (calls the original)
      → our queue (newest waiting wins)        AVConference's thread is never held
      → PictureConversion                      BGRA IOSurface, cropped to the screen
                                               (1328 × 2896 coded for 1320 × 2868; size from devicectl)
      → onFrame                                the moment it's ready, no timer
```

The decisions (order, relay, which picture goes on, the fallback, stopping) are `AVConferenceScreen`'s, tested through `MockMirroring`; the AVConference calls are `AVConferenceMirroring` and its neighbours in `Internal/System/`.

## Side by side

| | `rtp` | `avconference` |
|---|---|---|
| Offer | baguette's, H.264 only | Apple's negotiator, HEVC |
| RTP → frames | `VideoDepacketizer` | AVConference |
| RTCP, loss recovery | `ReceiverFeedback`, `DecodeGate` | AVConference (its 5-second report fails, harmlessly) |
| Decode | `VTStreamDecoder` (H.264) | AVConference (HEVC) |
| Pictures out | pushed to `onFrame` as decoded | pushed to `onFrame` as decoded, after YUV → BGRA |
| Private surface | CoreDevice | CoreDevice, plus AVConference's internals (`_opaqueStream`, one replaced method) |
| Fallback | screenshots | screenshots |

## Measured

2026-11-19, iPhone 18 Pro Max (iOS 27.0.1) on a cable, macOS 26, debug builds. Each route ran 30 s through `baguette stream --format avcc` with a swipe every 1.5 s; frames are each route's own 5-second log line, CPU is `ps` on the baguette process (which also re-encodes the output as H.264).

| | `rtp` | `avconference`, first cut (pull) | `avconference` (push) |
|---|---|---|---|
| Frames per 5 s | 157–168 (≈ 33 fps) | 146–158 (≈ 30 fps) | — |
| Dropped | 0 | not counted | not counted (recovered inside AVConference) |
| CPU | 104–105 % | 186–197 % | 106–107 % |

**Smoothness**, measured as the spacing between pictures while the screen moves: 22 s each through `baguette stream --format mjpeg` (its JPEG encoding adds the same noise to both), each JPEG timestamped as it arrived, gaps under 250 ms kept.

| In motion | `rtp` | `avconference` (push) |
|---|---|---|
| Pictures in 22 s | 751 | 788 |
| Median spacing | 18.8 ms (53 fps) | 18.0 ms (56 fps) |
| p90 | 44.3 ms | 34.6 ms |
| p99 | 68.6 ms | 103.7 ms |
| Std dev | 13.5 ms | 15.1 ms |

**Pull judders; push doesn't.** The first cut asked for the last decoded picture on its own 60 Hz timer: each answer came a tick late (asked asynchronously), the timer drifted against AVConference's display clock, and the H.264 pump downstream resampled again — two unsynchronised clocks over 30–50 fps content. Pictures now go on from AVConference's per-picture callback, as `rtp`'s do from the decoder.

**The first cut's extra CPU was the pull, not the decoding.** `sample` put it in `-[VCVideoStream sendLastRemoteVideoFrame:]`: it hands each picture to `+[VideoUtil convertPixelBuffer:toImageType:…]`, a full-size JPEG encode for a remote client, on every request (~60 a second). The push never calls it. What remains of the route's own is `PictureConversion` (YUV → BGRA, done by vImage on the CPU).

**Not measured yet:** picture quality under motion (where HEVC might win), the rarer long gaps (`avconference`'s p99), behaviour on a lossy link such as Wi-Fi (where AVConference's recovery might), a release build, and latency from a touch to the picture.

## Choosing

```bash
BAGUETTE_PHONE_SCREEN=rtp baguette serve     # or stream, record, screenshot
```

Anything else, or nothing, is `avconference`. When AVConference can't start the stream, the phone shows screenshots — set `rtp` to use baguette's own receiver instead. The route is read when baguette starts, for every phone it streams.
