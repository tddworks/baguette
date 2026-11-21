---
description: WebRTCKit, the Swift sender behind baguette's WebRTC live view — what its resend guard, RTX, STUN, ICE and TURN each do, and when a viewer needs them. Use when choosing serve's --stun / --turn or debugging a WebRTC viewer.
---

# WebRTCKit

WebRTCKit is the Swift sender behind baguette's WebRTC live view. It takes
encoded H.264 frames, connects to a browser, and sends the video. It helps the
browser recover from packet loss and estimates how much video the connection
can carry. Baguette handles screen capture, encoding, and input.

## What each feature does

| Feature | What it does | When it helps |
|---|---|---|
| **Resend guard** | Skips requests to resend video packets that are too old or were just retried. It also limits the bandwidth used for retries. | A burst of loss can trigger many repeat requests. The limit leaves room for new video. |
| **RTX** | Gives a resent packet its own identity while telling the browser which original packet it replaces. | If the retry arrives in time, the browser can still use it. With transport-cc, the sender can see the original loss and the retry separately. |
| **STUN** | Asks an external server which IP address and UDP port it sees for this connection. Think of it as finding out the return address your router put on a packet. | When the Mac or browser is behind a router, its local address may be unreachable from the other side. The discovered address is another option for ICE to try. |
| **ICE** | Tests addresses from both sides. The browser chooses a working path, and the Mac sends its own checks to help open that path. | The Mac and browser may have several ways to reach each other, such as a LAN address, a public address discovered by STUN, or a relay. |
| **TURN** | Offers an address on a relay server that can pass traffic between the Mac and browser. | When a direct path fails and both sides can reach the relay, it can carry the video. This takes relay bandwidth and adds a hop. |

For example, a phone on the same Wi-Fi can usually watch the Mac through a
local address that ICE checks. A phone on mobile data might need a public
address found with STUN or a relay provided by TURN. Once the video is playing,
the resend guard and RTX handle individual lost packets over whichever path ICE
selected.

## Turning them on

The resend guard, RTX and ICE checks are always on; nothing to configure.
STUN and TURN are `baguette serve` options, given to every viewer:

```bash
baguette serve --stun stun:stun.l.google.com:19302
baguette serve --turn turn:turn.example.com:3478 --turn-user me --turn-pass secret
```

The page learns the same servers before it makes its offer. Every flag:
[commands](../../commands.md#baguette-serve).

## Gotchas

- **Don't expose `serve` to the internet.** It drives the device and has no
  authentication yet. From outside your network, use Tailscale.
- **IPv4 and UDP only.** TURN over TCP or TLS (`turns:`) is refused, and so is
  an IPv6 socket.
- **mDNS candidates are skipped.** A browser that hides its addresses behind
  `.local` names gets no checks from the Mac. It still plays when it can reach
  one of the Mac's own addresses.
- **A TURN server that refuses the credentials, or doesn't answer within a
  second, gives no relay, silently.** The other candidates are still offered.
  To check, look for a `typ relay` line in the WHEP answer.

## See also

- [WebRTCKit design](design.md): the session, its paths, its laws.
- [Live view over WebRTC](../webrtc/README.md): the page, the CLI, remote viewing.
- [What was verified](../webrtc/design.md#6b--packet-recovery-and-connectivity-verification).
