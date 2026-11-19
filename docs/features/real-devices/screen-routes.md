# A phone's screen: two receivers

> One `CoreDeviceScreen` runs every phone's live screen (a Mac without CoreDevice shows stills instead, through `DevicectlScreen`); only its `ScreenReceiver` — who turns the stream into pictures — differs: baguette's own (`rtp`, the default) or Apple's AVConference, run in baguette's own process (`avconference`). Pick one with `BAGUETTE_PHONE_SCREEN`; the research behind the second is in [design.md](design.md#the-screen-through-avconference-in-process-spike-2026-11-19).

## The session — `CoreDeviceScreen`, every rule once (`Screen/CoreDevice/`)

```
CoreDeviceScreen.start()   — synchronous: it throws when the session can't start
 1. tunnel.open(to:)               RemoteDevice.connect() → TunnelEnds (phone …::1, Mac …::2)
 2. openSocket()                   UDPSocket, IPv6, any port
    receiver.offer()               the receiver's own offer
    starter.start(on:)             CoreDevice startMediaStream(StartRequest{negotiatorOffer, receiverIP, port})
                                   ← StartResponse: streamConfig (SourceIP/Port, SSRCs), negotiatorAnswer
    receiver.accept(answer)        each receiver reads its own part
 3. receiver.start(croppedTo:)     the phone's screen size, from devicectl displays
    relay:  socket.receive() → receiver.receive()       the phone's datagrams
            receiver.nextReport() → socket.send()       its reports, back to where the phone streams from
 4. onPicture → onFrame            each picture as the receiver decodes it — a push, no timer
 5. stop, or no picture in 8 s → RTCP goodbye, receiver stopped, socket closed — never a silent switch to stills
```

Tested through `MockScreenReceiver`, `MockTunnel`, `MockMediaStreamStarter`, `MockDatagramSocket`. `PhoneScreenRoute` picks the receiver.

**Why no fallback to stills.** A start that fails is a failure to see, not one to paper over: the screenshot fallback once hid a dead tunnel as "first open shows stale screenshots until a refresh". Whether a phone can stream live at all is known before anything starts — it has CoreDevice or it doesn't — so the phone registers `CoreDeviceScreen` or `DevicectlScreen`, never both.

## `rtp` — `RTPReceiver`, baguette's own (`Screen/CoreDevice/RTP/`)

```
offer()      MediaStreamOffer: AVConference's fields minus HEVC → H.264 only
accept()     the two sources (SSRCs) from streamConfig
receive()    RTPPacket → VideoDepacketizer   H.264 frames (single NALs, FU-A; 0x92 carries the avcC's SPS/PPS)
             DecodeGate                      nothing until a keyframe after a loss
             VTStreamDecoder                 H.264 → BGRA IOSurface, cropped to the screen (clean aperture)
nextReport() ReceiverFeedback                receiver reports, picture-loss requests
```

All pure values but the decoder, unit-tested byte for byte (`RTPReceiverTests`, `MediaStreamPackets`, `ReceiverFeedback`).

## `avconference` — `AVConferenceReceiver`, Apple's, in-process (`Screen/CoreDevice/AVConference/`)

```
offer()      AVCMediaStreamNegotiator, mode 5 → negotiates HEVC
accept()     negotiatorAnswer → the negotiator
start()      an AVCVideoStream run in-process (avcMediaStreamOptionRunInProcess), on a LoopbackRelay
receive()    → the relay → AVConference: jitter buffer, depacketizing, loss recovery, rate control, HEVC decode
nextReport() ← the relay ← AVConference's RTCP
pictures     _VCVideoStream_DidReceiveRemoteFrame, AVConference's per-picture C callback, wrapped by
             DecodedPictureTap → our queue (NewestWaiting: the newest picture wins, AVConference's
             thread never held) → PictureConversion: BGRA IOSurface, cropped to the screen
```

Its private calls are in `AVConference/Internal/System/` (≤ 100 lines a file, left out of coverage like every `Internal/System/`); `NewestWaiting` is tested.

## Side by side

| | `rtp` | `avconference` |
|---|---|---|
| Offer | baguette's, H.264 only | Apple's negotiator, HEVC |
| RTP → frames | `VideoDepacketizer` | AVConference |
| RTCP, loss recovery | `ReceiverFeedback`, `DecodeGate` | AVConference (its 5-second report fails, harmlessly) |
| Decode | `VTStreamDecoder` (H.264) | AVConference (HEVC) |
| Pictures out | pushed to `onFrame` as decoded | pushed to `onFrame` as decoded, after YUV → BGRA |
| Private surface | CoreDevice | CoreDevice, plus AVConference's internals (`_opaqueStream`, one replaced method) |
| A failed start | an error, reported | an error, reported |

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
BAGUETTE_PHONE_SCREEN=avconference baguette serve     # or stream, record, screenshot
```

Anything else, or nothing, is `rtp`. A route that can't start reports why (the page shows the error, `stream` exits with it). **Known issue:** while the screen scrolls, `avconference` shows some frames scaled rather than cropped (the stream's padding as a strip at the right and bottom); `rtp` doesn't — the reason the default stayed `rtp`. The route is read when baguette starts, for every phone it streams.
