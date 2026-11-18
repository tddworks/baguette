---
description: Why network conditioning injects a dylib, how the URLProtocol/configuration-swizzle interception was measured, the pacing schedule, the WebSocket hooks and the boundary it deliberately stops at. Read before changing VirtualNetwork or the network routes.
---

# Network conditioning: design

## Path

- `baguette network set|clear|status`, `POST|GET|DELETE /devices/<UDID>/network` (or `/simulators/…`),
  the focus-mode Network card
- → `NetworkProfile` / `NetworkCondition` / `NetworkSchedule` (host-side, tested) → `Network`
- → writes `/tmp/BaguetteNetwork-<udid>.json` and `launchctl setenv DYLD_INSERT_LIBRARIES`
- → `VirtualNetwork.dylib` in the app: `NSURLProtocol` + session-configuration swizzle.

## Why this needs a dylib at all

Network Link Conditioner exists, and so do the `dnctl` / `pfctl` dummynet
rules underneath it. Both are **system-wide**. A simulator app uses the
host's network stack as the host user, so there is no interface, process or
route to scope a rule to: conditioning one simulator that way degrades your
whole Mac and every other simulator with it. NLC also needs `sudo` and a
separate prefpane install.

Per-app injection is the only way to condition **one simulator** while the
rest of the machine stays fast. That's the gap this fills — and it's why the
trade-offs below are worth accepting rather than designed around.

## Design choices in the surface

- `set` takes **exactly one** source. Mixing is an error rather than a merge —
  "3G but lossier" reads like it ought to work, and once it does, whether the
  preset or the flag wins becomes something you have to remember. A `set` naming
  nothing is also an error: it costs an app relaunch and achieves nothing
  visible, which is far more likely a forgotten flag than an intention.
- Presets are NLC's, so nobody has to defend a number baguette invented.
  `NetworkProfileTests` pins each one.
- The browser posts the preset's **name**, not its numbers — that's what keeps
  NLC's figures in Swift instead of copied into JavaScript where the two would
  drift. `profiles` rides along in every response so the card can offer the
  presets without a second copy of the list. `"offline": false` is not counted
  as a source, because the card posts its whole form and that key rides along
  with real numbers on every ordinary request.

## Dispatch path

```text
   Host (Swift, tested)                        iOS Simulator app
┌────────────────────────────┐              ┌────────────────────────┐
│ NetworkProfile.condition   │              │  app's own URLSession  │
│ NetworkCondition (valid)   │              │  ── fetch / images ──  │
│ NetworkSchedule(bandwidth) │              └───────────▲────────────┘
│ NetworkCondition.encoded() │                          │ URLProtocol
└───────────┬────────────────┘                          │
            │  /tmp/BaguetteNetwork-<udid>.json         │
            ▼  (shared /tmp, as the camera uses)        │
      ┌───────────┐      launchctl setenv        ┌──────┴───────────┐
      │  Network  │ ──── DYLD_INSERT_LIBRARIES ─▶│ VirtualNetwork   │
      │ @Mockable │                              │ .dylib           │
      └───────────┘                              └──────────────────┘
```

Every judgement call is resolved host-side and arrives pre-computed —
including the **pacing schedule**: how many bytes the dylib may release per
tick and how long a tick is. The dylib compares and subtracts, nothing more.
Same division of labour [motion](../motion/design.md#why-an-intent-not-a-sample-stream)
has.

The obvious pacing shape — a fixed 50 ms tick with however many bytes that
works out to — is wrong at the slow end: a link whose tick is 6.25 bytes
rounds to 6 and quietly delivers 4% under. So the rounded byte count is taken
as given and the interval derived back from it, which makes the delivered
rate exact at every bandwidth.

## How the interception works, and what it took to find out

Two mechanisms, and which one matters was **measured before any of this was
written**, against a real React Native app making real traffic:

| Mechanism | Reaches |
| --- | --- |
| `+[NSURLProtocol registerClass:]` | `NSURLConnection` and `NSURLSession.shared` |
| Swizzling `+[NSURLSessionConfiguration defaultSessionConfiguration]` / `ephemeralSessionConfiguration` | everything else |

A 100-second run with registration alone, against a fully launched and online
app, intercepted **zero** app requests — the only thing it saw was React
Native's Metro dev-server ping. RN's `fetch` goes through
`RCTHTTPRequestHandler`, which builds its own session from
`defaultSessionConfiguration`; so do image loading, MapLibre's tile requests,
and REST clients generally. **The swizzle is why this feature works**; the
registration is kept for the minority that `registerClass` does reach. The
load banner says which took:

```bash
xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.baguette.network"'
# [VirtualNetwork] installed (registerClass=1 configSwizzle=1) — a condition is armed
# [VirtualNetwork] conditioning: 200 ms latency, 4875 bytes/50 ms, 0% loss
# [VirtualNetwork] conditioning GET https://api.example.com/v2/orders
```

That's also the fastest way to confirm injection is live: launch the app and
look for those lines. The dylib logs through `os_log`, never `NSLog` — it is
loaded into *every* process launched while conditioning is armed, including
the `launchctl` baguette spawns to read `DYLD_INSERT_LIBRARIES`, and a banner
on stderr can come back as part of the value being read.

Three more things the probe established, each of which shapes the code:

- **The re-issued request re-enters our own protocol.** The swizzle puts
  `VNProtocol` into the configuration the inner session is built from, so
  without a marker this is an infinite loop rather than a slow request. The
  guard is load-bearing, not defensive.
- **Bodies never arrive as `HTTPBody`, only as `HTTPBodyStream`** — and a
  stream reads exactly once. So **this never retries a request**: a second
  attempt would send an empty body and read as a server bug rather than a
  failed request. Conditioned `POST`s come back intact, verified against an
  HMAC-signed token request that would fail on a corrupted body.
- **Pacing streams rather than buffers.** Collecting the response and then
  replaying it in slices makes wall-clock the sum of both and holds a 23 MB
  bundle in memory. Bytes are released from a backlog on a timer instead,
  with the upstream task suspended above a high-water mark.

The inner session is **shared** and built from a *default* configuration.
One-per-request would add an unmeasured TLS handshake to every request in a
tool whose job is adding a measured delay, and an ephemeral configuration
would silently drop the cookies an app authenticates with.

### WebSockets

WebSockets are part of the URL Loading System but do **not** go through
`NSURLProtocol` — once the socket is open, messages bypass the protocol
machinery entirely. So `URLSessionWebSocketTask` gets its own pair of hooks,
on the two methods every client funnels through:

| | Outbound (`sendMessage:`) | Inbound (`receiveMessageWithCompletionHandler:`) |
| --- | --- | --- |
| latency | delayed before sending | delayed before delivery |
| loss | the send fails | the message is **dropped** and the receive re-issued |
| offline | fails `NSURLError -1009` | fails `-1009` after a short backoff |

Inbound loss swallows the message and listens again rather than completing
with an error, because those are different events: a client that gets an
error on its receive stops listening, which is a dropped *connection*, not a
dropped message. Apps react to the two very differently, and only one of them
is what `--loss` means.

The offline backoff exists because clients re-arm the receive as soon as one
completes; failing instantly turns an offline socket into a busy loop pinning
a core inside the app under test.

Two things had to be got right for any of this to work, both found by
running it rather than by reading:

- **The handshake must be left alone.** A WebSocket upgrade reaches
  `canInitWithRequest:` as an ordinary `https` GET — the `wss:` scheme is
  gone by then. Claiming it means re-issuing through a data task, the
  Upgrade never completes, and *every* WebSocket in the app fails to connect
  the moment any condition is armed. The protocol now declines anything
  carrying an `Upgrade: websocket` header.
- **The class to hook is registered lazily.** The app holds a private
  `__NSURLSessionWebSocketTask`, which overrides both methods, and it does
  not exist when the dylib loads. Sweeping the class list at load hooks the
  public `NSURLSessionWebSocketTask`, reports success, and never fires. So
  task creation is intercepted instead, and the concrete class is hooked the
  first time one is handed out.

Note the socket itself is not torn down: the TCP connection stays up while
messages are refused. What the app observes is a dead channel with the right
error code, which is what matters for testing; it is not a substitute for
pulling the network out from under a connection.

#### This only reaches Apple's WebSocket API

`URLSessionWebSocketTask` arrived in iOS 13, and plenty of realtime SDKs
predate it or ship their own transport. **Ably's `ably-cocoa` vendors
SocketRocket** (`ARTSRWebSocket`), which is built on `CFStream` rather than
`URLSession` — measured against a driver app using it, the hooks installed
(`websockets=1`) and **not one of them fired**. Starscream is in the same
category.

So check what your realtime layer actually uses before trusting `--offline`
to reach it. The banner tells you the hooks are installed; only the
`conditioning websocket …` lines tell you they are being used:

```bash
xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.baguette.network"'
# [VirtualNetwork] conditioning websocket send (200 ms)
```

Nothing conditions an SDK that opens its own socket, and no amount of work at
this layer would — that would need a hook further down, at `CFStream` or the
BSD socket calls, which conditions the simulator's own daemons along with the
app. That is out of scope on purpose; see
[the boundary](#the-boundary-inject--swizzle-not-a-proxy) for why the boundary sits where it does.

### The load-time check

If neither mechanism installs, the dylib **unregisters itself and conditions
nothing**, saying so in the log. An app is better off with real networking
than with networking this dylib has half taken over, and a conditioning tool
that silently conditions nothing is worse than one that admits it — the whole
point is measuring against a network you believe in.

An unconditioned state is not "intercept and re-issue at full speed" either:
`canInitWithRequest:` declines outright, so a cleared condition costs a
running app nothing.

## Forgetting this is on is the real hazard

A forgotten camera override is obvious — the picture is wrong. A forgotten
throttle is invisible: it reads as "the app is slow" or "the backend is
flaky", possibly days later, and nothing on screen says otherwise. The design
answers that in four places:

- **`baguette network` on its own reports the current condition**, so
  checking is one command.
- **The browser card shows an amber armed badge**, and the toolbar keeps an
  amber dot lit **whether or not the card has ever been opened** — the page
  polls the device's state from load. A throttle armed from the CLI in
  another terminal is exactly the one you forget, and the browser is where
  you'll be looking when things feel slow.
- **`network clear` un-conditions apps that are already running**, not just
  future launches. Disarming alone would leave a running app throttled for as
  long as it lives.
- **The dylib logs every conditioned request** (throttled to one line a
  second), so it's traceable after the fact.

`status` reports what **this simulator** is subject to, not merely what was
published. The condition file is per-simulator
(`/tmp/BaguetteNetwork-<udid>.json`, which the dylib derives from its own
`SIMULATOR_UDID`), but a device can still hold a stale one without the dylib
armed — after a simulator reboot clears `DYLD_INSERT_LIBRARIES`, say. So the
read checks arming as well as content. A badge that cries wolf stops being
read, and this one has to be believed.

## The boundary: inject + swizzle, not a proxy

Most of what follows is one boundary seen from different angles, so it is
worth naming once: **baguette conditions by injecting a dylib and swizzling
the URL Loading System.** Everything that goes through `URLSession` is
reached; everything that opens its own socket is not.

That is a deliberate trade, not a backlog. There are two ways to do this at
all:

| | Reaches | Costs |
| --- | --- | --- |
| **Inject + swizzle** (this) | `URLSession`, including WebSockets | blind to anything that isn't `URLSession` |
| **System proxy + trusted CA** (Charles, Proxyman; `dnctl`/NLC for conditioning) | everything, TLS included | system-wide, needs a certificate installed and trusted |

The second is what Network Link Conditioner does, and being system-wide is
precisely the problem this feature exists to avoid — it degrades your whole
Mac and every other simulator to test one app. So when you need to cross the
boundary below, reach for a proxy deliberately rather than expecting this to
grow into one.

RocketSim's network monitor takes the same inject-and-swizzle approach and
lands on the same boundary, which is some evidence it is the right one for a
per-simulator tool.


Measured boundary facts behind the README's gotchas:

- **`WKWebView` / Safari.** WebKit fetches page resources in its own networking
  process, on a path `URLProtocol` does not sit on. Measured: with a 2 000 ms
  latency armed, launching Safari and opening a page conditioned Safari's *own*
  `URLSession` traffic (`configuration.apple.com`, the SafeBrowsing service) and
  **none** of the page load.
- **`NWConnection`** is rare in app code — Apple's own guidance is to use
  `URLSession` for HTTP and drop to Network.framework only for custom protocols.
- **No bandwidth cap on WebSockets**, because an app cannot observe a partial
  message, so capping one could only mean delaying whole messages by size —
  which is latency wearing another name.
- **Background sessions** run out of process in `nsurlsessiond`, where the
  swizzle does not apply.
- **`httpAdditionalHeaders` survive** the re-issue on a default configuration,
  because they are merged before the request reaches a `URLProtocol`.
