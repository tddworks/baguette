---
description: Every HTTP and WebSocket route `baguette serve` answers, one row each, linked to the feature that documents it. Read when calling the server from a script, a plugin or your own page.
---

# `baguette serve`

```bash
baguette serve                  # http://127.0.0.1:8421/simulators
```

Every flag: [commands.md#baguette-serve](commands.md#baguette-serve). `/simulators` lists devices with Boot / Shutdown; `/devices/<UDID>` is the focus-mode page (live stream, bezel, toolbar); `/farm` shows every booted device at once ([device-farm](features/device-farm/README.md)).

One resource tree: no `/api/` prefix, the UDID is always in the path, and the format is the file extension.

## Trusted hosts

The server trusts only loopback `Host` / `Origin` values, so a request through a reverse proxy gets `403 forbidden origin`. Trust the proxy's hostname with `--allowed-hosts sim.example.com` (or `'*.example.com'` for subdomains; repeatable, ports ignored). An allowed host is trusted as both `Host` and `Origin`, and allowed origins get CORS headers and preflight answers. Other cross-site origins are still refused. Plugin calls carry their own per-run grant instead — see [plugins](features/plugins/README.md).

## Routes

`:udid` is a device's ID as `/devices.json` lists it: a simulator's or iPhone's UDID, an emulator's AVD name, a phone's adb serial. Rows without a feature link are documented here only.

**One tree: `/devices/:udid/…`.** A route marked *any device* answers for every device — a simulator, a phone on a cable, an emulator. A device that can't do what's asked answers `422` naming it (`han's iPhone can't do orientation`); one that isn't running, `409`. A plugin's grant covers the route under either spelling. The old `/simulators/:udid/…` spelling still answers, with `Deprecation: true` and a `Link` to its `/devices` successor; it goes in a later release.

| Method | Path | What | Docs |
|---|---|---|---|
| `GET` | `/` | 302 → `/simulators` | |
| `GET` | `/simulators` | device list page | |
| `GET` | `/simulators.json` | `{running, available}`, same as `baguette list --json` | |
| `GET` | `/mac-frames.json?width=&height=` | `{frames}`: the installed Mac frames a display of that size fits | [mac-screen](features/mac-screen/README.md#frames) |
| `GET` | `/devices.json` | `{devices}`: every device of every family, its kind (platform, reality, model, OS), state and abilities; what the list page reads | |
| `GET` | `/devices/:udid` | focus-mode page, for any device (`/simulators/:udid` serves it too) | [baguette-sdk](features/baguette-sdk/README.md) |
| `POST` | `/devices/:udid/boot`, `/shutdown` *any device* | boot / shut down | [boot](features/boot/README.md) |
| `POST` | `/devices/:udid/orientation?value=` *any device* | `portrait`, `landscape-left`, `landscape-right`, `portrait-upside-down`; `504` when an iPhone Duo change is unconfirmed | [hinge](features/hinge/README.md#rotation) |
| `POST` | `/devices/:udid/input` *any device* | one gesture envelope → its ack | [wire.md](wire.md) |
| `GET` | `/devices/:udid/describe-ui.json?x=&y=` *any device* | accessibility tree; `x`+`y` hit-tests a point | [accessibility](features/accessibility/README.md) |
| `GET` | `/devices/:udid/screenshot.jpg`, `.png` *any device* | one frame (`quality`, `scale`, `size`, `fit`, `background`) from a simulator or a phone on a cable | [screenshot](features/screenshot/README.md), [capture-size](features/capture-size/README.md), [real-devices](features/real-devices/README.md) |
| `GET` | `/devices/:udid/screenshot-bezel.png` *any device* | the frame inside its bezel (`buttons=`, `chrome=` a picked one) | [screenshot](features/screenshot/README.md) |
| `GET` | `/devices/:udid/definition.json` *any device* | SDK bootstrap: identity, screen rect, bezel URLs, buttons — the device's own bezel by its model, or `?chrome=<device name>` to borrow one (`404` with `needsChrome` when it has none) | [baguette-sdk](features/baguette-sdk/README.md) |
| `GET` | `/devices/:udid/chrome.json`, `bezel.png`, `screen-mask.png`, `chrome-button/:file` *any device* | DeviceKit bezel layout and images (`panel=` on a foldable) | [chrome-bezel](features/chrome-bezel/README.md) |
| `GET` | `/devices/:udid/3d-model.json` *any device* | the device's 3D model and variants, by its hardware id, model or name; a phone with none matched gets the installed models to pick from | [3d-rendering](features/3d-rendering/README.md) |
| `POST` | `/devices/:udid/render-3d.png` *any device* | screenshot on the 3D model | [3d-rendering](features/3d-rendering/README.md) |
| `GET` `POST` | `/devices/:udid/interface.json`, `/interface` *any device* | appearance, contrast, text size | [interface](features/interface/README.md) |
| `POST` | `/devices/:udid/shake` *any device* | motion shake | [shake](features/shake/README.md) |
| `GET` `POST` `DELETE` | `/devices/:udid/status-bar` *any device* | status-bar override | [status-bar](features/status-bar/README.md) |
| `GET` `POST` `DELETE` | `/devices/:udid/defaults.json`, `/defaults` *any device* | an app's typed UserDefaults, App Group suites | [defaults](features/defaults/README.md) |
| `GET` `POST` | `/devices/:udid/apps.json`, `/defaults-groups.json`, `/relaunch` *any device* | installed apps, an app's App Groups, quit + launch | [defaults](features/defaults/README.md#http) |
| `POST` `DELETE` | `/devices/:udid/location` *any device* | simulated GPS | [location](features/location/README.md) |
| `GET` `POST` `DELETE` | `/devices/:udid/motion` *any device* | injected CoreMotion | [motion](features/motion/README.md) |
| `GET` `POST` `DELETE` | `/devices/:udid/network` *any device* | injected network conditioning | [network](features/network/README.md) |
| `GET` `POST` | `/devices/:udid/hinge` *any device* | iPhone Duo hinge angle / fold (`pose=`, `angle=`, `duration=`); `504` when a fold is unconfirmed | [hinge](features/hinge/README.md) |
| `GET` | `/devices/:udid/companion-screens.json` *any device* | CarPlay display + paired watch | [companion-screens](features/companion-screens/README.md) |
| `POST` | `/devices/:udid/carplay-display` *any device* | attach CarPlay | [companion-screens](features/companion-screens/README.md) |
| `POST` | `/devices/:udid/files`, `/apps`, `/media` *any device* | upload: by extension, app install, Photos | [file-upload](features/file-upload/README.md) |
| `POST` | `/devices/:udid/camera-source?name=` *any device* | stage an image / video for the camera | [camera](features/camera/README.md) |
| `POST` | `/devices/:udid/openurl?url=` *any device* | open a deep link | [deep-links](features/deep-links/README.md) |
| `GET` | `/devices/:udid/schemes.json?q=` *any device* | URL schemes the device's apps registered | [deep-links](features/deep-links/README.md) |
| `POST` | `/devices/:udid/notify?bundleId=` *any device* | deliver a remote notification (body: the payload) | [notifications](features/notifications/README.md) |
| `WS` | `/devices/:udid/stream?format=mjpeg\|avcc` *any device* | live frames + gestures + stream control (`display=carplay`, `panel=`); a phone running the companion app streams its own video instead | [below](#one-websocket-per-stream) |
| `POST` | `/devices/:udid/whep` *any device* | WebRTC (WHEP) viewer of the screen: SDP offer in, `201` + `Location` + answer out | [webrtc](features/webrtc/README.md) |
| `DELETE` | `/devices/:udid/whep/:viewer` *any device* | hang a WebRTC viewer up | [webrtc](features/webrtc/README.md) |
| `WS` | `/devices/:udid/whep/:viewer/control` *any device* | a WebRTC viewer's gestures + stream control, no video | [webrtc](features/webrtc/README.md) |
| `WS` | `/devices/:udid/stream.3d.mjpeg`, `.avcc` *any device* | live 3D stage; a phone running the companion app is posed by its motion | [3d-rendering](features/3d-rendering/README.md) |
| `WS` | `/devices/:udid/logs?level=&style=&predicate=&bundleId=` *any device* | live unified log | [logs](features/logs/README.md) |
| `WS` | `/devices/:udid/camera` *any device* | virtual camera control; a device with no camera baguette can feed, like a phone on a cable, is refused by name | [camera](features/camera/README.md) |
| `GET` | `/plugins.json` | installed plugin manifests | [plugins](features/plugins/README.md) |
| `POST` | `/plugins/:id/commands/:cmd?udid=` | run one plugin contribution | [plugins](features/plugins/README.md) |
| `GET` | `/bakeries.json` | trusted bakeries, pinned commits, install state | [plugins](features/plugins/README.md) |
| `POST` | `/bakeries/preview`, `/bakeries/install` | read a bakery's menu; install from an already-trusted one | [plugins](features/plugins/README.md) |
| `GET` `WS` | `/devices/:udid/…` | physical-device twin (preview) | [device-twin](features/device-twin/README.md) |
| `GET` | `/farm` | device-farm page | [device-farm](features/device-farm/README.md) |
| `GET` | `/<dir>/:file`, `/:file` | static UI assets from `Resources/Web/` | |

## One WebSocket per stream

`WS /devices/:udid/stream` (or `/simulators/:udid/stream`) carries a whole viewing session in both directions:

- **Server → page**: one binary message per encoded frame. MJPEG sends raw JPEG bytes. AVCC sends a 1-byte tag then the payload: `0x01` avcC description (feed to `VideoDecoder.configure`), `0x02` keyframe, `0x03` delta, `0x04` JPEG seed that paints before the first H.264 keyframe lands. Text messages come back for `*_result` replies and a foldable's `hinge` samples.
- **Page → server**: text JSON, one message each — stream control (`set_bitrate`, `set_fps`, `set_scale`, `force_idr`, `snapshot`) and gestures, both in [wire.md](wire.md).

There is no `/event` side route and no UDID-keyed registry: the socket owns the stream and the simulator handle for as long as it is open. Closing it stops the capture.

## Editing the UI without rebuilding

The page is plain HTML and JS under `Sources/Baguette/Resources/Web/`. Point `BAGUETTE_WEB_DIR` at that folder and reload the browser to see edits without rebuilding:

```bash
BAGUETTE_WEB_DIR=Sources/Baguette/Resources/Web baguette serve
```

Why the server is shaped this way — thin handlers, no templating, the plugin grant check — is in [ARCHITECTURE.md](ARCHITECTURE.md#server-route-surface).
