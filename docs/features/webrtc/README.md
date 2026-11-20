---
description: Watch a device's live screen in baguette serve over WebRTC (WHEP) instead of the stream WebSocket — H.264 over UDP, for a phone on Wi-Fi, Tailscale or any remote link. Use when the WebSocket view lags or stalls away from the Mac.
---

# WebRTC live view

`baguette serve` can show the phone's screen over WebRTC: H.264 sent over UDP
and played by the browser's own WebRTC stack, rather than frames over the stream
WebSocket. Touches and the toolbar work as usual. On the same Mac it is no
faster than the WebSocket; it is for viewing from somewhere else, where a lost
packet would otherwise hold the WebSocket's picture back. The research and
measurements behind it are in [design.md](design.md).

## Quick start

1. `baguette serve`, and open the device page.
2. Pick **WebRTC** in the toolbar's format picker, beside H.264 and MJPEG.

The choice is remembered, like the other two. To view from a phone, serve on an
address the phone can reach (`--host`, and `--allowed-hosts` for its name) or use
the bench kit below.

What changes and what doesn't:

- Only the phone's screen goes over WebRTC. CarPlay, the watch and the 3D panel
  keep their WebSocket, at H.264 (or MJPEG where the browser can't decode H.264).
- The picture still lands on the page's canvas, so recording, screenshots of
  the view and the accessibility inspector work as before.
- It plays on a plain-`http` page in every browser. H.264 over the WebSocket
  decodes with WebCodecs, which desktop Chrome only offers on a secure page
  (HTTPS or localhost); there, on `http://`, the choice is MJPEG or WebRTC.
  iOS browsers offer WebCodecs on plain `http` too, so all three work on a phone.

## HTTP and WebSocket

WHEP ([draft-ietf-wish-whep](https://datatracker.ietf.org/doc/draft-ietf-wish-whep/); WHIP, its publishing twin, is RFC 9725), on both trees:

```
POST   /devices/<UDID>/whep               body: SDP offer (Content-Type: application/sdp)
       → 201 Created, Location: /devices/<UDID>/whep/<viewer>, body: SDP answer
         404 unknown udid   409 the device isn't running   422 the offer can't be answered
DELETE /devices/<UDID>/whep/<viewer>      hang up → 204 (404 unknown viewer)
WS     /devices/<UDID>/whep/<viewer>/control
```

`display=` and `panel=` pick the plane, as on the stream socket. The control
socket carries what the stream socket carries from its page — gestures
([wire.md](../../wire.md)), `describe_ui`, paste and copy, and stream control
(`set_bitrate`, `set_fps`, `set_scale`, `force_idr`) — and no video:

```json
{"type":"tap","x":201,"y":437,"width":402,"height":874}
```

Each viewer has its own H.264 encoder, starting at the stream socket's defaults
(60 fps, 8 Mbps, full scale). Its bitrate then follows the link, retuned between
300 kbps and 8 Mbps at most once a second, by one of three methods:

| `congestion=` | Who estimates the bandwidth |
|---|---|
| `transport-cc` (the default when offered) | baguette, from the browser's per-packet arrival reports, the way Google's WebRTC does |
| `remb` | the browser, which sends its estimate (the older way) |
| `off` | nobody: the bitrate stays where it started or where `set_bitrate` put it |

Ask for one on the `POST` (`/devices/<UDID>/whep?congestion=remb`), or open the
device page with it (`/devices/<UDID>?congestion=remb`) to compare them by hand.
A method the browser didn't offer falls back to `off`. With REMB, a still screen
in desktop Chrome drops to 300 kbps until the screen moves (the browser's estimate
follows what arrives); `transport-cc` doesn't. The server log shows each change:

```
[baguette] [webrtc] retune 8000 → 1700 kbps
```

Reading a stall in the log: each cut of the bitrate says why, the queue it
measured or the share lost; a picture the browser lost asks for a keyframe;
packets it reported lost add up once a second:

```
[baguette] [webrtc] transport-cc cut to 4071 kbps: queue +62 ms
[baguette] [webrtc] browser lost 14 packets in 1003 ms, 14 resent
[baguette] [webrtc] browser lost a picture: keyframe asked for
```

Each viewer's packets are paced: a keyframe leaves over a few milliseconds at
2.5 × the target bitrate instead of in one burst, which a phone link's queue
takes without stalling. `?pacing=off` on the `POST` sends every packet at once —
only to measure what pacing buys (the bench's "no pacer" column).

A `set_bitrate` on the control socket still applies at once; the estimate then
retunes again within about a second if it disagrees.

## Gotchas

- **H.264 High profile only.** An offer without High-profile H.264 in
  packetization mode 1 is refused (422) and the page falls back to H.264 or
  MJPEG over the WebSocket. Chrome and Safari offer it; Firefox offers only
  Constrained Baseline, so it falls back.
- **Host addresses only.** baguette answers with this Mac's own IPv4 addresses
  (LAN, Tailscale, loopback); there is no STUN or TURN, so a viewer behind a
  NAT that can't reach one of them gets no picture.
- **Media on any free UDP port, unless told.** Each viewer takes its own port;
  to open a firewall for them, give `baguette serve --webrtc-ports 8190-8194`
  and each viewer takes the first free one in the range (a full range refuses
  the next viewer).
- **A viewer goes when its browser does.** Switching format or leaving the page
  hangs it up; if that goodbye never arrives, it hangs up after 30 s without a
  connectivity check, and its encoder stops either way.
- **The first picture waits for a keyframe**, requested as soon as the
  connection is secured, so allow a moment longer than the WebSocket's JPEG seed.

## Compare it yourself

`scripts/bench-live-view/` runs both transports side by side, on this Mac, a LAN
or Tailscale (`start.sh --tailscale`), with tap-to-photon and bandwidth runs. How
to use it and what it measured: [design.md#run-it](design.md#run-it).

## See also

[design.md](design.md) · [stream](../stream/README.md) ·
[serve.md](../../serve.md) · [handheld](../handheld/README.md)
