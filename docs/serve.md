---
description: Every HTTP and WebSocket route `baguette serve` answers, one row each, linked to the feature that documents it. Read when calling the server from a script, a plugin or your own page.
---

# `baguette serve`

```bash
baguette serve                  # http://127.0.0.1:8421/simulators
```

Every flag: [commands.md#baguette-serve](commands.md#baguette-serve). `/simulators` lists devices with Boot / Shutdown; `/simulators/<UDID>` is the focus-mode page (live stream, bezel, toolbar); `/farm` shows every booted device at once ([device-farm](features/device-farm/README.md)).

One resource tree: no `/api/` prefix, the UDID is always in the path, and the format is the file extension.

## Trusted hosts

The server trusts only loopback `Host` / `Origin` values, so a request through a reverse proxy gets `403 forbidden origin`. Trust the proxy's hostname with `--allowed-hosts sim.example.com` (or `'*.example.com'` for subdomains; repeatable, ports ignored). An allowed host is trusted as both `Host` and `Origin`, and allowed origins get CORS headers and preflight answers. Other cross-site origins are still refused. Plugin calls carry their own per-run grant instead — see [plugins](features/plugins/README.md).

## Routes

`:udid` is a simulator UDID. Rows without a feature link are documented here only.

| Method | Path | What | Docs |
|---|---|---|---|
| `GET` | `/` | 302 → `/simulators` | |
| `GET` | `/simulators` | device list page | |
| `GET` | `/simulators.json` | `{running, available}`, same as `baguette list --json` | |
| `GET` | `/simulators/:udid` | focus-mode page | [baguette-sdk](features/baguette-sdk/README.md) |
| `POST` | `/simulators/:udid/boot`, `/shutdown` | boot / shut down | [boot](features/boot/README.md) |
| `POST` | `/simulators/:udid/orientation?value=` | `portrait`, `landscape-left`, `landscape-right`, `portrait-upside-down`; `504` when an iPhone Duo change is unconfirmed | [hinge](features/hinge/README.md#rotation) |
| `POST` | `/simulators/:udid/input` | one gesture envelope → its ack | [wire.md](wire.md) |
| `GET` | `/simulators/:udid/describe-ui.json?x=&y=` | accessibility tree; `x`+`y` hit-tests a point | [accessibility](features/accessibility/README.md) |
| `GET` | `/simulators/:udid/screenshot.jpg`, `.png` | one frame (`quality`, `scale`, `size`, `fit`, `background`) | [screenshot](features/screenshot/README.md), [capture-size](features/capture-size/README.md) |
| `GET` | `/devices/:udid/screenshot.jpg`, `.png` | the same frame from any device — a simulator or a phone on a cable | [real-devices](features/real-devices/README.md) |
| `GET` | `/simulators/:udid/screenshot-bezel.png` | the frame inside its bezel (`buttons=`) | [screenshot](features/screenshot/README.md) |
| `GET` | `/simulators/:udid/definition.json` | SDK bootstrap: identity, screen rect, bezel URLs, buttons | [baguette-sdk](features/baguette-sdk/README.md) |
| `GET` | `/simulators/:udid/chrome.json`, `bezel.png`, `screen-mask.png`, `chrome-button/:file` | DeviceKit bezel layout and images (`panel=` on a foldable) | [chrome-bezel](features/chrome-bezel/README.md) |
| `GET` | `/simulators/:udid/3d-model.json` | the device's 3D model and variants | [3d-rendering](features/3d-rendering/README.md) |
| `POST` | `/simulators/:udid/render-3d.png` | screenshot on the 3D model | [3d-rendering](features/3d-rendering/README.md) |
| `GET` `POST` | `/simulators/:udid/interface.json`, `/interface` | appearance, contrast, text size | [interface](features/interface/README.md) |
| `POST` | `/simulators/:udid/shake` | motion shake | [shake](features/shake/README.md) |
| `GET` `POST` `DELETE` | `/simulators/:udid/status-bar` | status-bar override | [status-bar](features/status-bar/README.md) |
| `GET` `POST` `DELETE` | `/simulators/:udid/defaults.json`, `/defaults` | an app's typed UserDefaults, App Group suites | [defaults](features/defaults/README.md) |
| `GET` `POST` | `/simulators/:udid/apps.json`, `/defaults-groups.json`, `/relaunch` | installed apps, an app's App Groups, quit + launch | [defaults](features/defaults/README.md#http) |
| `POST` `DELETE` | `/simulators/:udid/location` | simulated GPS | [location](features/location/README.md) |
| `GET` `POST` `DELETE` | `/simulators/:udid/motion` | injected CoreMotion | [motion](features/motion/README.md) |
| `GET` `POST` `DELETE` | `/simulators/:udid/network` | injected network conditioning | [network](features/network/README.md) |
| `GET` `POST` | `/simulators/:udid/hinge` | iPhone Duo hinge angle / fold (`pose=`, `angle=`, `duration=`); `504` when a fold is unconfirmed | [hinge](features/hinge/README.md) |
| `GET` | `/simulators/:udid/companion-screens.json` | CarPlay display + paired watch | [companion-screens](features/companion-screens/README.md) |
| `POST` | `/simulators/:udid/carplay-display` | attach CarPlay | [companion-screens](features/companion-screens/README.md) |
| `POST` | `/simulators/:udid/files`, `/apps`, `/media` | upload: by extension, app install, Photos | [file-upload](features/file-upload/README.md) |
| `POST` | `/simulators/:udid/camera-source?name=` | stage an image / video for the camera | [camera](features/camera/README.md) |
| `POST` | `/simulators/:udid/openurl?url=` | open a deep link | [deep-links](features/deep-links/README.md) |
| `GET` | `/simulators/:udid/schemes.json?q=` | URL schemes the device's apps registered | [deep-links](features/deep-links/README.md) |
| `POST` | `/simulators/:udid/notify?bundleId=` | deliver a remote notification (body: the payload) | [notifications](features/notifications/README.md) |
| `WS` | `/simulators/:udid/stream?format=mjpeg\|avcc` | live frames + gestures + stream control (`display=carplay`, `panel=`) | [below](#one-websocket-per-stream) |
| `WS` | `/simulators/:udid/stream.3d.mjpeg`, `.avcc` | live 3D stage | [3d-rendering](features/3d-rendering/README.md) |
| `WS` | `/simulators/:udid/logs?level=&style=&predicate=&bundleId=` | live unified log | [logs](features/logs/README.md) |
| `WS` | `/simulators/:udid/camera` | virtual camera control | [camera](features/camera/README.md) |
| `GET` | `/plugins.json` | installed plugin manifests | [plugins](features/plugins/README.md) |
| `POST` | `/plugins/:id/commands/:cmd?udid=` | run one plugin contribution | [plugins](features/plugins/README.md) |
| `GET` | `/bakeries.json` | trusted bakeries, pinned commits, install state | [plugins](features/plugins/README.md) |
| `POST` | `/bakeries/preview`, `/bakeries/install` | read a bakery's menu; install from an already-trusted one | [plugins](features/plugins/README.md) |
| `GET` `WS` | `/devices.json`, `/devices/:udid/…` | physical-device twin (preview) | [device-twin](features/device-twin/README.md) |
| `GET` | `/farm` | device-farm page | [device-farm](features/device-farm/README.md) |
| `GET` | `/<dir>/:file`, `/:file` | static UI assets from `Resources/Web/` | |

## One WebSocket per stream

`WS /simulators/:udid/stream` carries a whole viewing session in both directions:

- **Server → page**: one binary message per encoded frame. MJPEG sends raw JPEG bytes. AVCC sends a 1-byte tag then the payload: `0x01` avcC description (feed to `VideoDecoder.configure`), `0x02` keyframe, `0x03` delta, `0x04` JPEG seed that paints before the first H.264 keyframe lands. Text messages come back for `*_result` replies and a foldable's `hinge` samples.
- **Page → server**: text JSON, one message each — stream control (`set_bitrate`, `set_fps`, `set_scale`, `force_idr`, `snapshot`) and gestures, both in [wire.md](wire.md).

There is no `/event` side route and no UDID-keyed registry: the socket owns the stream and the simulator handle for as long as it is open. Closing it stops the capture.

## Editing the UI without rebuilding

The page is plain HTML and JS under `Sources/Baguette/Resources/Web/`. Point `BAGUETTE_WEB_DIR` at that folder and reload the browser to see edits without rebuilding:

```bash
BAGUETTE_WEB_DIR=Sources/Baguette/Resources/Web baguette serve
```

Why the server is shaped this way — thin handlers, no templating, the plugin grant check — is in [ARCHITECTURE.md](ARCHITECTURE.md#server-route-surface).
