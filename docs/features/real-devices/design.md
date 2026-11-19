# Real devices: CoreDevice research

> Status: **built**, 2026-11-18, on an iPhone 18 Pro Max (iOS 27.0.1, Xcode 27.0). H1, H2 and H3 pass: baguette touches a physical iPhone and shows its live screen through CoreDevice. How to use it: [README.md](README.md).

## Question

**Can an unentitled `baguette` process stream the screen of a CoreDevice-connected iPhone and send it touches, the way Xcode 27's Device Hub does?**

- **Yes:** one adapter gives baguette both physical iPhones and [vphone-cli](https://github.com/Lakr233/vphone-cli) virtual iPhones, because a vphone guest now presents itself to the Mac as a real device.
- **No:** baguette can still reach vphone VMs through their own guest API ([Fallback](#fallback-vphone-only-through-vphoned)), but not physical devices.

Proposed time box: 2 days. Output: the [Decision](#decision) table filled in, plus proof-of-concept code on a scratch branch.

## Background

### How vphone reached Device Hub

[vphone-cli PR #604](https://github.com/Lakr233/vphone-cli/pull/604) (merged 2026-10-07) adds no host-side Device Hub code. The guest passes as a USB-connected iPhone (usbmuxd, lockdownd, remoted, CoreDevice pairing), so Device Hub takes its normal **physical-device** path:

```
DeviceHub.app ──CoreDevice──▶ guest/device: dtremotedisplayd  (from the DDI)
                               service com.apple.coredevice.displayservice
                                 getmediasupportinfo
                                 getmediastreamserverstatus
                                 startmediastream / stopmediastream
                                 startvideooutput / startaudiooutput
               ◀── H.264, encoded on the device (AVConference) ──
```

The PR fixed four places where that path stopped on a VM. All of the fixes are in the guest:

| Stage | Symptom | Fix |
|---|---|---|
| DDI mount (iOS 27) | "connected (no DDI)" forever: `cryptexd` gets `EPERM` from `F_SETPROTECTIONCLASS` | Report the error as `ENOTSUP`, which takes cryptexd's existing path for filesystems without protection classes |
| Feature query | `supportedFeatures: 0`; iPads and customer-restricted devices refused | `MediaStreamSupportedFeatures.current` answers `0x8c` (140, what a Mac reports); `isCustomerRestricted` answers false |
| Capture display (iOS 27) | Stream starts, view black: swaps go to a kernel port the capture display lacks | Patch the swap code so only the main display presents through the kernel |
| Display metadata (27.x iPhone) | Screen drawn over the bezel corners | `dtdeviceinfod` answers the `phone11` framebuffer mask |

Measured by the PR: the live view runs 30–150 ms behind the VM's own window. Under load it stalls for 1–3 s or falls seconds behind, because the HEVC encode is paravirtualized to the Mac and shared by every VM. Touch from Device Hub reaches the guest, checked by hand only. Full write-up: `Research/Guest/devicehub_screen_viewing.md` in vphone-cli.

### Not the Device Hub problem we already know

[device-hub](../device-hub/design.md) (#77) is Device Hub's **simulator** path: `dtuhidd` attaching to a simulator and SimulatorHID dropping our legacy touch service. This spike is about the **physical-device** path through CoreDevice, which baguette does not touch today. The one overlap: the [hinge](../hinge/design.md) research found CoreDevice's UniversalHID not callable from outside, which predicts a problem for input here.

## Hypotheses

Each one is proven or killed by an experiment below.

| # | Hypothesis | Killed if |
|---|---|---|
| H1 | Device Hub's screen view is a CoreDevice action any process can invoke through `CoreDevice.framework` | The call is refused for a missing entitlement (record which one) |
| H2 | The frames reach the client as something we can decode to a `CVPixelBuffer` / `IOSurface` (HEVC sample buffers or similar) | Frames are only rendered inside an AVConference view we cannot host |
| H3 | Device Hub's touches go over a CoreDevice service we can also call | Input needs an entitlement we can't have, or runs through UniversalHID (see hinge) |
| H4 | Whatever works on a physical iPhone works unchanged on a vphone VM | The VM needs host-side cooperation beyond PR #604 |

## Experiments

Run them in order; stop at the first kill of H1 and jump to [Fallback](#fallback-vphone-only-through-vphoned).

1. **Prerequisites.** A physical iPhone, paired with this Mac, Developer Mode on, its DDI mounted. `xcrun devicectl list devices` shows it connected. Xcode 27 is a beta here and isn't selected with `xcode-select`, so prefix commands with `DEVELOPER_DIR=…`.
2. **Watch Device Hub.** Open the device's live view in Device Hub while running `log stream` on the CoreDevice and `com.apple.dt` subsystems. Record: which host process opens the stream (DeviceHub itself or `CoreDeviceService`), the action names, the transport the frames arrive on, and what a touch in the view logs. Also dump `codesign -d --entitlements -` of DeviceHub.app and of CoreDeviceService.
3. **Map the API.** List `MediaStream*` and display-service symbols in `CoreDevice.framework` and the DDI's `CoreDeviceUtilities.framework`. Check whether `devicectl` already exposes any of them (`devicectl device --help` and its subcommands).
4. **Feature query from our own process (H1).** A Swift script on a scratch branch loads CoreDevice and invokes `getmediasupportinfo` on the device. Pass: `supportedFeatures: 140`. Fail: record the error and the entitlement it names.
5. **One frame (H2).** Invoke `startmediastream`, take the first video sample and write it to a PNG. Pass: a PNG of the home screen. Record latency against the device.
6. **One tap (H3).** Send a single touch down/up through whatever service step 2 found. Pass: the tap visibly lands (open an app from the home screen).
7. **Same again on a vphone VM (H4).** Only if a vphone VM is available. Needs `csrutil allow-research-guests enable` on the host, so it may run on another Mac.

## Decision

| Hypothesis | Result |
|---|---|
| H1 — CoreDevice is callable from our process | **Pass.** `DeviceManager`, built with every visibility class, lists physical phones beside simulators; `RemoteDevice.getImplementation(for:)` opens capabilities. No entitlement asked. |
| H2 — frames reach us as something decodable | **Pass, without AVConference's receiver.** `MediaStreamFunctions.startMediaStream(with:)` starts the phone's stream, but `avconferenced` refuses an unentitled receiver (`vcMediaStreamSetSessionConfig failed authorization`; it wants `com.apple.videoconference.allow-conferencing`, which AMFI won't let us self-sign). So baguette receives the stream itself: plain RTP over the tunnel, unencrypted, H.264 (HEVC is offered too by default, but mosaics under motion; see *Codec*). See *How the screen reaches the Mac*. |
| H3 — touches go over a callable service | **Pass.** The `UniversalHIDServiceCapability` opens on the phone, and a UniversalHID `DigitizerReport` sent with `UniversalHIDService.send(report:to:)` to service `0x101` lands: a swipe paged the Home Screen and back, an edge swipe went Home. |
| H4 — a vphone VM works unchanged | Not run (no VM on this Mac). |

Outcome: **Go** for touch and the live screen. Built: `CoreDevicePhones` registers `screen` (the live stream, devicectl screenshots as fallback), `input` (Universal HID) and `pasteboard` (devicectl). Not `orientation`: `devicectl device orientation set` exits 0 on a phone and answers "New Device Orientation: portrait" — a phone turns by its sensors only.

### How the screen reaches the Mac

```
MediaStreamScreen.start
  → MediaStreamOffer(...).bytes                    our own offer: H.264 only, 6 Mbit/s cap (mode 5, video)
  → RemoteDevice.startMediaStream { request }      MediaStreamFunctions: support info (tunnel up), then start
        request: StartRequest as JSON through CoreDevice's own Decodable —
        type video, direction output, clientSupportedFeatures 140, receiverIP/Port = our socket,
        options DisplayByID / VideoStreamForDisplayID 1 / network type 1 / transport type 2
  ← StartResponse.connection.streamConfig          SourceIP/SourcePort, LocalSSRC (phone), RemoteSSRC (ours)
  → UDP [::]:port ← RTP, payload type 123         unencrypted (SRTP suites 0)
  → VideoDepacketizer → AccessUnit                 RFC 6184: STAP-A 24, FU-A 28; SPS/PPS from the 0x92 sample description
  → VTStreamDecoder (H.264 parameter sets) → IOSurface → the usual Stream pipeline
  ↔ ReceiverFeedback: receiver report every 1 s (the phone ends a stream after 20 s without), an ack per
    picture, an RCTL every 50 ms (as Device Hub sends), PLI every 300 ms until a keyframe; BYE on stop
```

- **Why not AVConference's receiver.** CoreDevice's own client (`CoreDeviceMediaStreamSupport`, `VideoStreamConfiguration.receiveMirroredPrimary(layer:)`) negotiates fine and the phone starts streaming, but configuring the receiving `AVCVideoStream` asks `avconferenced`, which checks `com.apple.videoconference.allow-conferencing` — Device Hub has it; a self-signed binary claiming it is killed by AMFI.
- **The receiver address** is the Mac's end of the CoreDevice tunnel: the phone is `…::1` on a `utun` (`devicectl list devices` lists it; resolving `<CoreDevice identifier>.coredevice.local` instead can sit out a five-second mDNS timeout), and the Mac is its own address on the same prefix (`…::2`). It exists once the tunnel is up.
- **The tunnel is brought up first, and stays up.** CoreDevice drops an idle tunnel about 15 s after its last user — `devicectl` included — and its media-stream and Universal HID calls don't bring one back: on a cold phone they fail with `xpcConnectionUnavailable(target: remoteService)`, and a stream that started dies some 15 s in despite its RTP and RTCP (AXe saw the same). `RemoteDevice.connect()` brings it up in about half a second and keeps it until CoreDevice is told to disconnect or the phone goes, past the calling process's own exit. So `Tunnel` owns the phone's tunnel: one per phone, opened before the live screen, the touch service or accessibility, answering both ends (`TunnelEnds`). Baguette never disconnects, which could cut off Xcode's own session with the phone.
- **Codec: H.264, never HEVC.** AVConference's own offer (`AVCMediaStreamNegotiator initWithMode:5`) lists H.264 (payload 123) and HEVC (payload 100), and the phone picks HEVC. That stream doesn't survive motion: in a recorded swipe every packet arrived (no sequence gaps; each picture's packet count, in the `0x9011` header extension, matched; its frame counter never skipped; references only to the previous one or two pictures in a 12-picture buffer), yet VideoToolbox and ffmpeg alike decoded it into the same mosaic, which stayed until the next keyframe. The same swipe offered H.264 only decodes whole in both. So `MediaStreamOffer` writes the offer itself, with AVConference's fields minus the HEVC entry, and the AVConference class is no longer loaded.
- **H.264 parameter sets arrive outside the NAL units:** a payload starting `0x92` (not a NAL type) carries an `avc1` sample description whose `avcC` atom holds the SPS and PPS; the depacketizer hands them to the next IDR.
- **Size.** Coded 1328 × 2896 for a 1320 × 2868 screen, padded right and bottom, with no crop window in the SPS; a smaller resolution in the offer is ignored. The phone's screen size comes from `devicectl device info displays` (the primary display's `nativeSize`), asked while the stream starts, and the decoder crops each picture to it — a clean aperture at the top-left, applied by VideoToolbox as it converts (`kVTScalingMode_CropSourceToCleanAperture`). So every consumer — the page, `screenshot`, `record` — gets the screen and never the padding.
- **Stopping.** An RTCP BYE; the phone's 20 s RTCP timeout ends it anyway. `StopRequest(stopAll:)` is not used — it could end Device Hub's stream too.

### The screen through AVConference, in-process (spike, 2026-11-19)

A second route, measured on the same iPhone 18 Pro Max (iOS 27.0.1, macOS 26, AVConference 2235.63.5.2) from an unentitled process; the approach is [device-hub-ios](https://github.com/JaviSoto/device-hub-ios)'s (`DHAVConferenceReceiver.mm`), reimplemented. It corrects *Why not AVConference's receiver* above: that refusal is `avconferenced`'s, and an in-process stream never asks it.

| Step | Call | Result |
|---|---|---|
| Load | `dlopen` `/System/Library/PrivateFrameworks/AVConference.framework/AVConference`; everything through `objc_msgSend` | ok |
| Offer | `AVCMediaStreamNegotiator initWithMode:5 options:` (`TransportProtocolType` 2, `AccessNetworkType` 1) → `createOffer` → `offer` (≈490 bytes) | ok; sent verbatim as the `StartRequest`'s `negotiatorOffer` |
| Answer | CoreDevice's `StartResponse` carries `negotiatorAnswer` (≈430 bytes) beside `connection` → `setAnswer:withError:` | ok; negotiates **HEVC** (`RxPayloadType` 100) |
| Stream | `generateMediaStreamConfigurationWithError:` · `generateMediaStreamInitOptionsWithError:` + `avcMediaStreamOptionRunInProcess = YES` → `AVCVideoStream initWithNetworkSockets:` (`avcKeySharedSocket`) → `configure:error:` → `start` | ok — `configure` is the call `avconferenced` refused out of process |
| Pictures | `AVCVideoStream._opaqueStream` (a `VCVideoStream`): set `_shouldCacheRemoteVideoFrame`, call `requestLastDecodedFrame`, take the `CVPixelBuffer` in a replaced `sendLastRemoteVideoFrame:` that never calls through (the original JPEG-encodes every picture) | 1328 × 2896, `420f`, IOSurface-backed; 25–50 distinct pictures a second while the screen moves |

- **The socket is a loopback relay.** Handing AVConference the tunnel's IPv6 socket, connected to the phone, decodes but fails its RTCP (`RTPSendControlPacket failed, 80010006`) and stalls; unconnected, nothing is decoded. An IPv4 loopback pair — AVConference's end connected to ours, ours relaying to and from the tunnel socket — runs a 70-second session at 25–47 pictures a second with no stall.
- **One RTCP report still fails**, every `rtcpSendInterval` (5 s): the negotiated `remoteAddress` is empty and `rtcpRemotePort` 0; setting the port doesn't help. Sessions run regardless.
- **Decoded pictures don't come out on their own.** In-process they go to `VCVideoPlayer` / `VCImageQueue` (C, for a `CALayer`); `VCVideoStreamReceiver -showDecodedFrame:atTime:` is never called. Asking for the last decoded picture is the Objective-C way out.
- **A locked phone sends nothing**, through either route; a still screen sends nothing either.

### How the accessibility tree reaches the Mac

```
RemoteAXAccessibility.describeAll
  → Tunnel.open                                 the phone's end of its tunnel, brought up (RemoteDevice.connect())
  → nettop -m tcp -n -x -p remoted -J state     remoted's one connection to the phone = its service directory's port
  → ServiceDirectory (RemoteXPC over HTTP/2)    the handshake's Services: remoteAXService's Port
  → DTX to that port                            _notifyOfPublishedCapabilities:, then clientNeedsAccessibility: YES
  ← processDataFromRemoteDevice: × 2            InitialDump, then AdditionalData — the tree (AXPTranslatorResponse records)
  → AXTreeDump answers AXPTranslator            through AXPTranslatorBridge's token dispatcher, no round trip per question
  → AXPMacPlatformElement → AXNode.walk         the same walk as a simulator's; frames already in device points
```

- **Why not CoreDevice or remoted.** `remoted` (`remote_device_copy_service`) needs Apple-private
  entitlements (`com.apple.private.RemoteServiceDiscovery.device-admin`). CoreDevice's
  `CreateServiceSocketCapability.fileHandle(toServiceNamed:)` opens raw sockets to some services
  (`dtservicehub`, `testmanagerd.remote`) but refuses `remoteAXService` — its directory entry says
  `Entitlement: AppleInternal`. The phone itself takes a plain TCP connection to the port.
- **The directory's port** isn't fixed; `remoted` keeps one connection to it per tunnel, and nettop shows it.
- **The tree is a cache.** The second push holds every answer the phone's service gave: request 4
  (the frontmost app), 5 (all of an element's attributes), 2 (one attribute), 3 (settable).
  Answering the translator from it builds the tree in-process; a request it lacks answers empty.
- **No press yet.** Pressing through accessibility needs a live `processDataFromHost:` request;
  `press` answers `false`, so `tap --label` falls back to a touch at the element.

### How a touch reaches the phone

```
DigitizerTouch (gesture → reports, fractions of the screen; the phone's only input role)
  → CoreDeviceDigitizer.report
      → CoreDeviceFramework.device(<CoreDevice identifier>)        DeviceManager.allDevices()
      → RemoteDevice.open(.universalHID)                           getImplementation(for:) async throws
      → cdabi_send_digitizer_report(capability, 0x101, fingers…)   UniversalHIDService.send(report:to:)
```

- **The service is `0x101`.** The phone's Universal HID stack registers its main touchscreen as `0x100` plus the display id `devicectl device info displays` reports (`displayId: 1`). Baguette keeps it as the measured constant `CoreDeviceDigitizer.mainTouchscreen`, never computes it (the HID-target law).
- **The developer disk image must be mounted.** A phone listed with `ddiServicesAvailable: false` takes the report without error and does nothing. Any developer service mounts it; `devicectl device info ddiServices` is the cheapest.
- **The phone must be awake.** Injected touches don't wake a dark screen; tap-to-wake lives in the touch controller.
- **A Lock Screen swipe from the right opens the Camera.** Check the screen before driving a phone that may have locked.
- **Identity.** CoreDevice's API takes its own identifier (`30546CC9-…`, the `identifier` in `devicectl list devices`), not the UDID. `PhysicalPhone.coreDeviceIdentifier` carries it.
- **The report.** A UniversalHID `DigitizerReport` and `DigitizerContact` each wrap one `Foundation.Data` (two words). UniversalHID's own initializers and setters build them; `CoreDeviceABI` checks the two-word size before sending and refuses otherwise. An edge swipe sets the inward swipe flag and "swipe locked" on every report including the lift.
- **The calling convention.** CoreDevice ships no Swift module, so baguette weak-links it and its nested UniversalHID (both have absolute install names outside Xcode.app; see `Package.swift`) and binds their symbols with `@_silgen_name` on stand-in types: `CoreDeviceFramework` for the manager, devices and capabilities (the async `getImplementation(for:)` included), `DigitizerReport` for the report, whose stand-in holds one `Data` like Apple's types so Swift retains and releases it. One call stays in C (`CoreDeviceABI`): `UniversalHIDService.send(report:to:)` throws a typed error through a slot placed before the type metadata, an argument order no Swift declaration lowers to. A build machine without CoreDevice compiles the touch path out.

## Fallback: vphone only, through vphoned

vphone's guest daemon `vphoned` serves an HTTP / WebSocket API once a VM is launched with `--api-listen 127.0.0.1:<port>` (bearer token printed at launch). Baguette acts as a client; the VM host binary needs Apple-private virtualization entitlements, so it can never ship inside baguette.

| baguette | vphoned method | Fit |
|---|---|---|
| `Input.touch1` / `touch2` | `input.touch {phase,x,y}` / `input.touch2 {x1,y1,x2,y2}` | Direct; coordinates are 0..1, so divide by size as `IndigoHIDInput` does |
| tap, swipe, button, key, type, paste | `input.tap`, `swipe`, `button`, `hid {page,usage}`, `key`, `type`, `paste` | Direct |
| `Accessibility` | `ui.tree`, `ui.element_at` | Map onto `AXNode` |
| `Location`, `Pasteboard`, `Orientation`, apps, logs | `location.*`, `clipboard.*`, `display.rotation`, `apps.*`, `logs.syslog` | Good |
| `Screen` / `Stream` | `screen.screenshot` only, one image per call | **Gap:** live frames exist only inside the `vphone-vm` process |

Shape in baguette, following AGENTS.md: one `@Mockable` collaborator `Guest` for the vphoned conversation (integration-only concrete client); a `VirtualPhone` aggregate conforming to `Simulator` that refuses the verbs a VM lacks (status bar, motion, injection, hinge). The stream gap is closed by a vphone-cli PR adding a host-side frame stream from `vphone-vm`; polling `screen.screenshot` is the stopgap.

## Risks and open questions

- Is CoreDevice's display service gated by an entitlement only Apple-signed clients carry? H1 answers it.
- The stream is the phone's H.264, not the IOSurface frames our `Stream` pipeline takes today. A decode step costs latency on top of the device's encode.
- vphoned deliberately breaks compatibility between versions; any vphoned client pins a version and checks the capability flags `/v1/health` returns.
- vphone runs patched iOS firmware in a security-research VM and needs weakened host security. Baguette stays a client and never installs or launches it.
- No paired iPhone and no vphone VM on the maintainer Mac as of 2026-10-07; experiment 1 needs one.
