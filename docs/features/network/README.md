---
description: Condition one simulator's app network (added latency, capped downlink, failed requests, or offline) with NLC presets or custom numbers, via CLI, HTTP or the focus-mode card. Use when testing how an app degrades on a bad network.
---

# Network conditioning

Make a simulator's apps see a worse network than your Mac has: added latency, a
capped downlink, a share of requests failing outright, or no connection at all.
Only the one simulator is affected; the rest of your Mac stays fast. Every flag:
[commands.md#baguette-network](../../commands.md#baguette-network).

There is no `simctl` verb behind this: baguette injects `VirtualNetwork.dylib`
into apps and conditions their requests from inside. Two consequences come first:

> **Only apps launched _after_ `network set` are conditioned.** Relaunch the
> target app, or `xcrun simctl launch --terminate-running-process <udid> <bundle-id>`.
> **Changing the condition afterwards needs no relaunch**: a running app picks it
> up within about 100 ms.
>
> **Only URLSession-shaped traffic is seen.** REST, GraphQL, image loading and
> `URLSessionWebSocketTask` are conditioned. `WKWebView` page loads and raw
> sockets are not. Read [Gotchas](#gotchas) before trusting a result.

## Quick start

```bash
baguette network set    --udid <UDID> --profile 3g
baguette network set    --udid <UDID> --latency 300 --bandwidth 400 --loss 5
baguette network set    --udid <UDID> --offline
baguette network status --udid <UDID>
baguette network clear  --udid <UDID>      # also un-conditions apps already running
```

In the browser, the focus-mode **Network** card does the same.

`set` takes **exactly one** source: a preset, some numbers, or `--offline`.
Mixing them is an error rather than a merge, and a `set` naming nothing is an
error too. `--latency` is the **whole round trip** in ms; `--bandwidth` is
downlink kbps (omit it to leave the link unmetered); `--loss` is the percentage
of requests failed.

### Presets

Borrowed from Network Link Conditioner, vocabulary and figures both, so `3g`
means what every iOS developer already means by 3G.

| Preset | Downlink | Round-trip latency | Loss |
| --- | --- | --- | --- |
| `wifi` | 40 000 kbps | 2 ms | 0% |
| `dsl` | 2 000 kbps | 10 ms | 0% |
| `lte` | 50 000 kbps | 130 ms | 0% |
| `3g` | 780 kbps | 200 ms | 0% |
| `edge` | 240 kbps | 800 ms | 0% |
| `very-bad-network` | 1 000 kbps | 1 000 ms | 10% |
| `100-loss` | — | — | 100% |

Two deliberate translations from NLC: NLC states a one-way delay, so each preset
carries twice NLC's figure as its round trip; and NLC conditions uplink and
downlink separately, while baguette paces the response only, so presets carry
NLC's *downlink* figure and uploads run at full speed.

## Workflows

### Confirm it's working

Arm something impossible to miss, relaunch the app under test, and watch the
dylib's own log:

```bash
baguette network set --udid <UDID> --latency 3000
xcrun simctl launch --terminate-running-process <UDID> <bundle-id>
xcrun simctl spawn <UDID> log stream --predicate 'subsystem == "com.baguette.network"'
```

```text
[VirtualNetwork] installed (registerClass=1 configSwizzle=1) — a condition is armed
[VirtualNetwork] conditioning: 3000 ms latency, 0 bytes/0 ms, 0% loss
[VirtualNetwork] conditioning GET https://api.example.com/v2/orders
```

A request that normally returns in ~500 ms taking ~3.5 s is the whole
confirmation. If the banner says `configSwizzle=0`, nothing an app does on its
own sessions is being conditioned. For WebSockets, the banner only says the
hooks are installed; `conditioning websocket …` lines say they're being used.

### Don't forget it's on

A forgotten throttle is invisible: it reads as "the app is slow" or "the backend
is flaky", possibly days later. So:

- `baguette network status` (or plain `baguette network`) reports what **this
  simulator** is subject to, including whether the dylib is actually armed.
- The browser's toolbar keeps an **amber dot** lit whenever a condition is armed,
  whether or not the card was ever opened, even if you armed it from the CLI.
- `network clear` un-conditions apps that are already running.
- The dylib logs every conditioned request (at most one line a second).

## HTTP

| Method | Path | Does |
|---|---|---|
| POST | `/simulators/<UDID>/network` | Set a condition |
| GET | `/simulators/<UDID>/network` | Read the current state |
| DELETE | `/simulators/<UDID>/network` | Clear, including for running apps |

`POST` takes exactly one of three spellings (`"offline": false` doesn't count as
a source):

```json
{ "profile": "3g" }
{ "latencyMs": 300, "bandwidthKbps": 400, "lossPercent": 5 }
{ "offline": true }
```

All return the current state, which is also what `GET` answers:

```json
{ "ok": true, "active": true, "latencyMs": 200, "bandwidthKbps": 780,
  "lossPercent": 0, "offline": false, "summary": "200 ms latency, 780 kbps",
  "profiles": ["wifi", "dsl", "lte", "3g", "edge", "very-bad-network", "100-loss"] }
```

`400` for a body naming no condition or more than one; `404` for an unknown
udid; `500` for a build with no bundled dylib or an injection status query
that fails. `network status` also reports a failed query as an error,
never as inactive conditioning.

## Gotchas

- **Apps must be launched after arming** (dyld inserts libraries at exec time).
- **URLSession traffic only.** `NWConnection` / Network.framework, raw sockets
  and most gRPC stacks are **not conditioned**. Nor are realtime SDKs that open
  their own socket: Ably's `ably-cocoa` (SocketRocket, measured) and Starscream.
  Check what your realtime layer uses before trusting `--offline` to reach it.
- **`WKWebView` and Safari page loads are not conditioned**: WebKit fetches in
  its own process. A hybrid app can be half-throttled: native `fetch` slowed,
  web content not.
- **WebSockets get latency, loss and offline, but not bandwidth.** Inbound loss
  drops the message (the connection stays up); offline fails with
  `NSURLError -1009`. The TCP connection itself isn't torn down.
- **Request-level, not packet-level.** "20% loss" means 20% of requests fail,
  immediately (`NSURLErrorNetworkConnectionLost`), not by hanging to a timeout;
  for timeouts use a large `--latency`. Right for "does my app degrade
  gracefully", wrong for transport tuning.
- **Downlink only.** Upload bodies aren't paced.
- **Background sessions aren't conditioned**: they run in `nsurlsessiond`.
- **The re-issued request uses a default configuration.** Per-session cookie
  stores and custom TLS handling on the app's own session aren't reproduced;
  `httpAdditionalHeaders` survive.
- **Requests are never retried**, so a conditioned `POST` fails rather than
  resending an empty body.
- **Debug React Native builds**: the JS bundle download is conditioned too. On
  `edge` a 23 MB bundle takes minutes. Arm something mild, let the app load,
  then change the condition live.
- **Injected, not simulated.** Only the app's own process is conditioned; a
  device not running an injected app has a normal network. To condition
  everything (TLS included), use a system proxy / NLC deliberately; it's
  system-wide.
- A simulator reboot clears the injection; `status` reports it as not armed.

## See also

[design.md](design.md): why a dylib, how interception was measured, pacing and
WebSocket hooks · [motion](../motion/README.md) (the same injection approach) ·
[location](../location/README.md)
