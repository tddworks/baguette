---
description: The normative domain model baguette binds to — the tree from Devices down, the words the CLI and the page use, every law and its one owner, and the bounded contexts; read before adding or changing a Domain type, an @Mockable abstraction or where a rule lives.
---

# baguette — the canonical model

> ONE tree. The CLI, `baguette input`, the `serve` page and its plugins all
> drive it; none of them adds a rule to it. A node is here because a user can
> name it (a verb, a flag, a card on the page), and a rule lives on **the node
> that holds the data it needs** (tell, don't ask).
>
> **Answers:** what is true — the nodes, the words, the laws and their owners.
> **Next:** [ARCHITECTURE.md](ARCHITECTURE.md) for how a tap travels through
> the layers, and each feature's `design.md` for the private-API research.

## 0 · How to read it

| Mark | Means |
|---|---|
| **◆** | a domain object or `@Mockable` role with commands — it can refuse |
| **◇** | a value — it answers, and cannot be told anything |
| **DERIVED** | computed from other nodes, never stored |

**The words are the ones the user types and sees**: the CLI verbs and flags,
the wire `type` names, the page's cards (*Defaults*, *Network*, *Location*),
and Apple's own where we have none (*cover*, *unfolded panel*, *Device Hub*).
Their exact syntax is in [commands.md](commands.md) and [wire.md](wire.md). An abstraction is named for the role it plays — `Touch`,
`Screen`, `Hinge`, `Subprocess` — never for a pattern (`Port`, `Service`,
`Manager`, `Repository`); aggregate persistence takes the plural (`Simulators`,
`Chromes`). See [AGENTS.md](../AGENTS.md#naming-the-abstractions).

| A word | Means here, and only here |
|---|---|
| **device points** | the unit of every coordinate and of the `width` / `height` beside it; never normalized, never pixels |
| **display plane** | one of a device's screens as baguette drives it: `phone` or `carPlay` |
| **panel** | one of a foldable's own screens: the **cover** (`primary`) or the **unfolded** panel (`secondary`) |
| **lit panel** | the panel the hinge lights now; everything that touches or shows the phone plane follows it |
| **binding** | a display plane's framebuffer *and* digitizer, chosen together |
| **target** | a HID digitizer registration — a constant some create-service message registered, never a number computed |
| **injected** | a capability delivered by a dylib in the guest (`motion`, `network`, camera): only apps launched after it is armed see it |
| **heal** | reclaim the input surface Device Hub took: restart backboardd |

## 1 · The tree

```text
Devices  ◆                                  EVERY DEVICE — one list from every source: `list` ·
│                                           find(id) · require(ability, of: id)
└── Device  ◆                               ONE DEVICE — id, name, kind ◇ (platform × reality × model),
    │                                       state ◇ (off · starting · ready · unavailable)
    ├── abilities → Abilities  ◇         WHAT IT CAN DO — require(.location) → the role; names
    └── input() → Abilities  ◇           ITS SCREEN'S INPUT — the roles below, each made once, so a
        │                                   finger lifts where it went down. `ok` = sent, not landed
        ├── Touch  ◆                        tap · swipe · touch1 · touch2 · twoFingerPath, in device points
        ├── Press  ◆                        what it presses — available · button(_:duration:); a
        │                                   DeviceButton ◇ is a Navigation ◇ (home, app switcher,
        │                                   edge pulls, keyboard) or a HardwareButton ◇ (lock,
        │                                   power, volume, action, the watch's crown and sides)
        ├── Key  ◆                          the keyboard — key(_:modifiers:duration:)
        ├── Scroll  ◆                       the wheel — scroll(deltaX:deltaY:)
        └── Gesture  ◇ (GestureRegistry)    an act of ONE of them, named by the wire `type`: Tap · Swipe ·
                                            Touch1 · Touch2 · Pinch · Pan → Touch; ButtonPress → Press;
                                            Keystroke · TypeText → Key; WheelEvent → Scroll.
                                            parse(dict); execute(on:) its role, refused by name without it
        sources (one per device family):    SimulatorDevices (the tree below) · CompanionDevices ·
                                            CoreDevicePhones (screen, touch, accessibility, pasteboard) ·
                                            AndroidDevices (listed through adb; no abilities yet)

Simulators  ◆                               THE SIMULATOR FAMILY — a device set (default or --device-set)
└── Simulator  ◆                            ONE SIMULATOR — udid, name, state, runtime, device type;
    │                                       each role below is one of its abilities
    │                                       boot() · shutdown(); canAcceptInput DERIVED (booted)
    ├── displays → Displays  ◆              ITS SCREENS
    │   ├── phone: Display  ◆              the device's own screen — follows the lit panel
    │   ├── panel(cover | unfolded)  ◆     one panel pinned, the hinge not asked (the 3D book)
    │   └── carPlay: Display  ◆            an attached CarPlay display; never enabled implicitly
    │       Display: resolve() → DisplayBinding ◇ · screen() → Screen ◆ · input() → HID ◆
    │                observedScreen() → AXScreen ◇ · input(expected:) for --expected-screen
    ├── input → HID  ◆                      ONE INDIGO SURFACE playing Touch · Press · Key · Scroll; the
    │   │                                   four abilities share one per screen, so keys ride the
    │   │                                   services gestures warmed
    │   ├── Fill  ◇                         make one named text field hold this text → FillOutcome ◇;
    │   │                                   takes Accessibility, Pasteboard and the screen's input
    │   ├── FoldableInput  ◆                a foldable's keys — hardware and keyboard — through DeviceKeys
    │   └── LitPanelInput  ◆                a socket that outlives a fold: each gesture to the lit panel,
    │                                       a touch on the panel it went down on until it lifts
    ├── hinge → Hinge  ◆                    THE FOLD — angle() · watch(onAngle:) · fold(to:over:)
    │   └── litPanel                        DERIVED — the angle's panel; no reading is folded (cover)
    ├── orientation → Orientation  ◆        portrait · landscape-left · landscape-right · upside-down
    ├── accessibility → Accessibility  ◆    WHAT IS ON SCREEN — describeAll() · describeAt(point:)
    │   ├── AXNode  ◇                       role · label · value · identifier · frame (device points) ·
    │   │                                   children; the root carries AXScreen ◇ (size, orientation, panel)
    │   ├── TextField  ◇                    node.textField: what it shows, secure or not, focused or not;
    │   │                                   reading(of:) → FieldReading ◇ (exact · reformatted · differs)
    │   └── DescribeUI  ◇                   which read was asked for: screen · short · point
    ├── logs → LogStream  ◆                 the unified log, filtered (LogFilter ◇)
    ├── THE CONDITIONS THE APP RUNS UNDER
    │   ├── location → Location  ◆          set(Coordinate ◇) · start(LocationRoute ◇) · clear()
    │   ├── motion → Motion  ◆              injected — publish(MotionIntent ◇) · clear()
    │   ├── network → Network  ◆            injected — apply(NetworkCondition ◇) · clear() · current()
    │   ├── interface → Interface  ◆        appearance · contrast · content size; unknown / unsupported
    │   ├── statusBar → StatusBar  ◆        override(StatusBarOverride ◇) · clear()
    │   └── shake → Shake  ◆
    ├── APPS AND THEIR DATA
    │   ├── apps → Apps  ◆                  install · launch · terminate · open(DeepLink ◇) · installed
    │   ├── notify → Notify  ◆              deliver(RemoteNotification ◇) — its own act, not app management
    │   ├── defaults → Defaults  ◆          read · write · delete — PreferenceEdit ◇ / PreferenceImport ◇
    │   │                                   apply with a Relaunch ◇ (never · always · whenNeeded)
    │   ├── pasteboard → Pasteboard  ◆      Paste ◇ (any unicode) · Copy ◇ (sim → host)
    │   └── photos → PhotoLibrary  ◆        MediaItem ◇
    ├── chrome(in: Chromes) → DeviceChromeAssets  ◇   the bezel, by device TYPE, per panel
    └── deviceModel(in: DeviceModels)  ◇    the 3D model, by device type first, then name

Chromes  ◆            bezels and profiles by device type — panels(forDeviceName:) says if it folds
DeviceModels  ◆       installed 3D models · DeviceRenderer ◆ · DeviceScene ◆ (the page's 3D book)
Stream  ◆             a framebuffer as MJPEG or AVCC — StreamFormat ◇ · StreamDisplayPlan ◇; its frames
                      leave through a FrameSink: stdout, a WebSocket, or a WebRTC viewer
WebRTCViewers  ◆      THE LIVE WEBRTC (WHEP) VIEWERS, by id — admit(offer) → answer · find(id) · hangUp(id)
└── WebRTCViewer  ◆   ONE BROWSER watching one device over WebRTC, with a Stream of its own:
                      new → connecting (STUN) → securing (DTLS) → live → hung up.
                      SessionDescription ◇ (offer in, answer out) · STUNMessage ◇ · RTPPacket ◇ ·
                      H264Packetizer ◇ · SRTPContext ◇ · RTCPFeedback ◇; how much the link takes is
                      its CongestionControl ◆ — TransportWideControl (transport-cc: TransportFeedback ◇ ·
                      SendHistory ◇ · FeedbackClock ◇ · BandwidthEstimate ◇ · Pacer ◇), ReceiverEstimateControl (REMB) or FixedBitrate,
                      picked by CongestionChoice ◇; at the outside world,
                      Datagrams ◆ (its UDP socket) and Handshake ◆ (its DTLS handshake)
CameraSessions  ◆     one virtual camera per server — Cameras ◆ · CameraSource ◇; the device's
                      Camera ◆ (a simulator's: VirtualCamera injected) is what it feeds
Plugins  ◆            installed plugins — PluginManifest ◇ · PluginRoute ◇ · PluginGrants ◆
Bakery  ◇             trusted plugin sources — Checkout ◆ · InstallPlan ◇
CompanionPhones  ◆    the companion-app twin, one source of Devices — not wired: no companion app ships
```

## 2 · The commands, and the node each lands on

| The user does | The node is told | Notes |
|---|---|---|
| `boot` · `shutdown` | `simulator.boot()` · `shutdown()` | `boot` then heals if Device Hub attached |
| `heal` | `InputSurface.heal(on:)` | restarts backboardd; running apps die |
| `tap` · `swipe` · `pinch` · `pan` · `press` · `type` · `key` | `gesture.execute(on: device.require(G.ability))` | one process per gesture; refused by name on a device without the role |
| `fill` | `Fill.execute(accessibility:pasteboard:input:)` | also on `baguette input`; the App only projects the `FillOutcome` |
| `input` (stdin) · the stream WebSocket | `GestureDispatcher` → the plane's input `Abilities` | many gestures; `--expected-screen` → `displays.phone.input(expected:)` |
| the Duo's 3D page | `sim.litPanelInput()` | the socket outlives a fold |
| `paste` · `clipboard …` | `Paste.execute(pasteboard:input:)` · `pasteboard` | the path around `type`'s US-ASCII limit |
| `hinge --pose` · `--angle` | `HingeCommand.parse` → `hinge.fold(to:over:)` | exit 3 when unconfirmed (`PoseDelivery`) |
| `orientation <value>` | `orientation.set(_:) → PoseDelivery` | on a foldable, through the hinge motor |
| `describe-ui [--x --y] [--short]` | `DescribeUI.read(from: accessibility)` | `--short` answers with the short answer, not the tree |
| `screenshot` · `stream` · `record` | `StreamDisplayPlan.bind(to:)` → `Screen` | CarPlay fails closed, never the phone instead |
| the page's WebRTC view (`POST /devices/:udid/whep`) · hang up (`DELETE …/whep/:viewer`) | `viewers.admit(offer, …)` · `viewers.hangUp(id)` | the viewer's touches ride its control WebSocket, through `GestureDispatcher` as any socket's do |
| `location set · start · walk · clear` | `location.set` · `start(route)` · `start(walk.route())` · `clear` | |
| `motion start · set · stop` | `motion.publish` · `clear` | injected |
| `network set · clear · status` | `network.apply` · `clear` · `current` | injected; `clear` reaches running apps |
| `interface appearance · contrast · text-size` | `interface` get / set | no value reads |
| `status-bar override · clear` | `statusBar.override` · `clear` | |
| `install` · `add-media` · `openurl` · `notify` | `apps.install` · `photos.add` · `apps.open(DeepLink)` · `RemoteNotification.deliver(to: notify)` | |
| `defaults write · delete · import` | `PreferenceEdit` / `PreferenceImport` `.apply(on: defaults, apps:)` | `--relaunch-if-needed` is `Relaunch.whenNeeded` |

## 3 · The laws, on the node that owns them

| Law | Owner |
|---|---|
| a device does only what it registered; asking for anything else is a refusal naming the ability and the device, never a fallback | `Abilities` |
| a device takes its gestures one at a time, in the order sent, from every connection; two devices never wait on each other | `GestureQueues` |
| an Indigo mouse message is built on the main thread — that call alone, never a whole gesture | `IndigoHIDInput` (`onMainThread`) |
| an id that no source knows is a refusal naming the id | `Devices.require(_:of:)` |
| one id names one device across every source; asking for an id two sources claim is a refusal, never a pick | `CombinedDevices` |
| an ability that drives the running screen (screen, touch, press, key, scroll, displays, hinge, orientation, shake, accessibility) is refused while the device isn't ready; the key says whether it needs one | `Device.require` (the key: `Ability.needsReady`) |
| what a device family can do is decided once, where its device is built | each family's device (`CoreSimulator`, …) |
| the list a client sees names each device's abilities, and the page shows only those | `Devices.listJSON` |
| every coordinate is in device points, with the plane's `width` / `height` beside it; the adapter divides by size, the domain never normalizes | `Point` · `Size` · `IndigoHIDInput.sendMouse` |
| a display's screen and input come from one binding, so a framebuffer never pairs with another plane's digitizer | `Display` · `DisplayBinding` |
| a HID target is a registration, never computed from a screen id; an unregistered one kills backboardd. The phone plane uses its bound panel's `0x40000000 \| screenId`, else `0x32`; CarPlay its own `1` | `IndigoHIDTouchTarget` · `DisplayTouchTarget.resolve` |
| a read of the frontmost app asks the bridge first and runs the guest helper only when the bridge can't read it, then gives an app that shows only the status bar a moment to appear; no PID outlives its query | `AXFrontmostRead` |
| the sweep always looks where the walk can't see, and sweeps the gaps in full only when a scout finds something the walk didn't know | `AXSweep` |
| a gesture asked to describe the UI compares against the screen before it, and reports the screen only once it has held still and no old page is sliding away | `AXSettle` |
| an affordance is what can be done next on this screen: a verb, the one command that runs it (its envelope on a session), and the names it takes. An enabled text field can be filled, a slider dragged and any other enabled control tapped, wherever it is; a disabled one is listed apart | `AXAffordance` |
| a name that reached nothing answers with what this screen offers, the same way a success does, so a caller can correct itself without another read | `AXTarget.Refusal` |
| a tap by name never guesses between matches and never retries, because the app may have acted without changing its tree | `AXTarget` · `LabelTap` |
| only a text field can be filled; anything else types nothing | `AXNode.textField` |
| a fill types nothing until the field it named has focus | `Fill` |
| a fill that didn't land says Device Hub has the input when it does, and asks only after a miss | `Fill` |
| a fill answers with what can be done next, unless asked not to | `FillDispatch` |
| a fill always clears first, because an empty field reads as its placeholder | `Fill` |
| `ok` from a fill means the field shows the text, not that it was sent | `Fill` · `FillOutcome` |
| a fill retries once with paste, because entering the same text again leaves the same result; a tap never retries | `Fill` |
| a password stays off the shared pasteboard unless it can't be typed | `Fill` |
| a secure field is compared by its number of characters; other punctuation is reformatted, not different | `TextField` |
| a short read is of a screen, not a point; `x` and `y` come together | `DescribeUI` |
| a probe override may name only a known target | `DisplayTouchTarget.parseOverride` |
| a physical phone's touches go to the Universal HID service it registers for its main touchscreen, `0x101` — measured, never computed | `CoreDeviceDigitizer.mainTouchscreen` |
| a WebRTC viewer sees no picture before a keyframe: its sender asks for one when its handshake completes and whenever the browser reports a lost picture (PLI or FIR) | `WebRTCSender` |
| a viewer sends nothing before its DTLS handshake completes, and every packet after it through SRTP | `WebRTCSender` |
| one viewer, one encoder: each viewer owns its stream, and hanging up stops it | `WebRTCViewer` |
| a viewer the browser stops answering — no STUN check for 30 s — hangs up | `WebRTCSender` |
| a STUN check is answered only when it names the viewer's username fragment and is signed with its ICE password | `STUNMessage` |
| an offer with no H.264 the encoder can send — High profile, packetization mode 1 — is refused, never answered with another codec | `SessionDescription` |
| no RTP packet carries more than 1200 bytes of payload, so it fits a 1280-byte tunnel | `H264Packetizer` |
| a viewer is found by its id until it hangs up, and only through the device it watches; an unknown id, or one asked for through another device, is a refusal naming it | `WebRTCViewers` |
| a viewer's encoder targets the lower of the delay-based and loss-based bandwidth estimates, between a floor (300 kbps) and its starting bitrate. A reported cut means that target fell, and carries the signal that limited it | `BandwidthEstimate` |
| an offer carries a congestion-control method only when it numbers its header extension 1–14 (what a one-byte header holds), will receive it (not `inactive` or `sendonly`), and asks for its feedback (`transport-cc`, `goog-remb`) on the H.264 the viewer sends or on every format (`*`) | `SessionDescription` |
| when the browser's offer carries its candidates, a viewer checks each itself (full ICE, the controlled agent) until its session is secured; with none it stays ICE-lite | `WebRTCSender` |
| with a TURN server given, each viewer offers a relayed address on it (lowest), lets the browser's addresses through, keeps it alive until it hangs up and then releases it; what comes through the relay reaches the sender as if from the peer | `RelayedDatagrams` |
| a viewer's session follows the pair the browser nominated last (USE-CANDIDATE); a check that doesn't nominate never moves it, and the browser's feedback counts by its SRTCP signature, whichever of its addresses it comes from | `WebRTCSender` |
| with a STUN server given, each viewer offers the address the server sees its socket at (server-reflexive), below its host addresses and without naming its private base; a silent server leaves the host ones | `STUNServer` |
| a resend leaves on its own stream (RTX), stamped anew for congestion control, when the browser's offer pairs a resend format with our H.264; else as it was sent | `WebRTCSender` |
| a lost packet is resent as it was sent, unless it was first sent over 1 s ago, was resent in the last 100 ms, or resends would take more than half the target bitrate | `PacketHistory` |
| with pacing on, a viewer's packets leave at 2.5 × its target bitrate as the normal rate, faster whenever the queue couldn't otherwise empty within 500 ms of its oldest packet; a small frame leaves at once | `Pacer` |
| a browser's transport-cc reports are read on one unbroken timeline, though their 24-bit reference time wraps | `FeedbackClock` |
| a retune turns one knob of the config as it stands then (`StreamConfig.Change`), so two at once both land | each `Stream` |
| a running device's input is made once and kept for every gesture posted to it, and made afresh once the device has been seen not running | `DeviceInputs` |
| a viewer's congestion control is the one asked for (`?congestion=transport-cc\|remb\|off`) when the offer can carry it, else none; with nothing asked, transport-cc if offered, else REMB if offered, else none | `CongestionChoice` |
| with no congestion control, nothing retunes the encoder: it stays where it started or where `set_bitrate` put it | `FixedBitrate` |
| a viewer retunes its encoder when the target moves by more than 10%. A decrease applies immediately. An increase waits at least a second after the last retune | `EncoderRetune` |
| a phone streams H.264, never HEVC: offered both it picks HEVC, whose pictures mosaic under motion though every packet arrives | `MediaStreamOffer` |
| a phone's frames are its screen: the stream pads the picture (1320 × 2868 in 1328 × 2896) without saying so, and it is cropped once, where it is decoded, to the size the phone reports — never by a page, a bezel or a consumer | `CleanAperture` (applied by `VTStreamDecoder`) |
| a phone keeps streaming only while it hears back: a report each second, an ack per picture, a control packet every 50 ms, a keyframe request every 300 ms while one is wanted | `ReceiverFeedback` |
| a phone's accessibility service serves one session at a time; reads of one phone share the one in flight, never open a second | `SharedRead` |
| a phone's tree takes its screen from the app at its root, which fills it | `AXNode.onItsAppsScreen` |
| the external digitizer is never released | `InputTeardown.forPlane` |
| an unknown edge, modifier, phase or button is an error, never a fallback | `Field` · `Keystroke.parseModifiers` · `ButtonPress.parse` |
| `type` / `key` are US-layout printable ASCII; anything else fails to parse and goes through `paste` | `KeyboardKey.decompose` · `TypeText.parse` |
| a typed key is held 30 ms, because a burst needs it short; a single key press keeps its own hold | `TypeText` |
| `siri` is not a button: every known path crashes backboardd | `HardwareButton` (left out on purpose) |
| a press of a navigation or button the device doesn't list `available` is refused by name before it reaches the device | `ButtonPress` (the list: `Press.available`) |
| no hinge reading means as booted: folded, the cover | `Hinge.litPanel` |
| 90° or more lights the unfolded panel | `HingeAngle.litPanel` |
| everything on the phone plane follows the lit panel; a socket that outlives a fold asks per gesture, and a touch stays on the digitizer it went down on until it lifts | `Displays.phone` · `LitPanelInput` |
| a foldable's keys — volume, power, action, and keyboard keys — go to the guest's buttons service, not Indigo | `FoldableInput` → `DeviceKeys` |
| a pose move that timed out is *unconfirmed*, not rejected: it may have landed | `PoseDelivery` |
| re-observe the screen before a `down` and a `move`, never before an `up` | `InputScreenGuard` |
| the external plane never falls back to a phone-sized surface; CarPlay never streams the phone | `FramebufferSurfacePick` · `StreamDisplayPlan.bind` |
| CarPlay is never enabled implicitly when `--require-existing-display` asks | `StreamDisplayPlan` |
| Device Hub can shadow the input surface; healing restarts backboardd and kills running apps | `InputSurface` · `DeviceHubAttachment` |
| an injected capability reaches only apps launched after arming; `DYLD_INSERT_LIBRARIES` is shared, so arming is read-modify-write by dylib name | `Motion` · `Network` · `InjectedDylibs` |
| injected dylibs install under per-hash paths, so dyld never serves a stale page | `InjectedDylibInstallPlan` |
| network conditioning is per simulator; `clear` reaches running apps | `Network` |
| `unknown` and `unsupported` are answers, not errors | `InterfaceReading` · `ContentSize` |
| a write to a running app's settings may not be seen: `whenNeeded` relaunches only for keys it doesn't watch, and relaunches when it can't say | `Relaunch` · `PreferenceEdit` |
| a preference's type is never coerced; a suite name can't smuggle a path or a flag | `PreferenceValue` · `PreferenceSuite` |
| a push payload is an object with `aps`, at most 4096 bytes; an explicit bundle id beats the payload's | `RemoteNotification` |
| an `http(s)` link opens in Safari, a custom scheme in its app | `DeepLink` |
| a coordinate out of range never constructs; a route needs two points; a bearing wraps onto 0–360 | `Coordinate` · `LocationRoute` · `Bearing` |
| a bezel is found by device type, never by UDID | `Chromes` |
| one virtual camera owner per server; a source is only ever downscaled | `CameraSessions` · `ScaleToFit` |
| a plugin route not in the table is denied; grants are per invocation | `PluginRoute` · `PluginGrants` |
| a bakery installs only its pinned commit | `BakeryUpdate` |

## 4 · What is deliberately NOT in the tree

| Absent | Why |
|---|---|
| `XxxPort` · `XxxService` · `XxxManager` · `XxxRepository` | pattern labels, not roles ([AGENTS.md](../AGENTS.md#naming-the-abstractions)) |
| a subclass or `if name == "iPhone Duo"` per device | what differs is data: the profile's panels, the chrome, the 3D model. A foldable is a device whose `Chromes` lists two panels |
| a `--display inner` / `--panel` on gestures | the hinge picks the lit panel; folding is how you choose it |
| a HID target from `IndigoHIDTargetForScreen` or any arithmetic | a trap: only registrations are safe |
| normalized coordinates in the domain | device points end to end; the adapter normalizes |
| a `siri` button | it crashes backboardd |
| a method per ability on `Device`, or a protocol per ability (`Device & Locatable`) | abilities are data in an `Abilities`; Mockable can't generate inherited requirements, and the page needs them as a list ([devices](features/devices/design.md)) |
| a branch on a device's kind above Infrastructure | a family registers what it can do; nobody else asks what it is |
| a ViewModel, or rules in the page's JS | the page is a dumb sender; `KeyboardKey.from(wireCode:)` resolves keys in Swift |
| a second input hierarchy for tests | `IndigoHIDInput` is the simulator's only adapter; tests mock the role they test (`MockTouch`, `MockKey`, …) |
| a role that answers `false` for what its device can't do | the device doesn't register it; a phone on a cable has `Touch` only |
| one protocol for every input role (an 8-method `Input`) | `Touch`, `Press`, `Key`, `Scroll`; a simulator's `HID` is only their name together |

## 5 · The contexts

Each is a **fence**: inside it every word has one meaning, and its laws have
one owner. Across a fence only a reference passes (an id, a value of the
shared kernel) — never another context's aggregate, its storage or its
adapter. A device's own contexts — what it is, how it looks, what it can do
— are the module `BaguetteDevice` (`Sources/Device/`, an ability's roles and
values under `Abilities/<ability>/`, the Mac's side of each in its `Internal/`). What
only one family does lives in `Sources/Devices/<Family>/` (`Simulator/`, `iPhone/`,
`CompanionPhone/`), its private-API adapters in `Internal/`, sorted by these
context names; plugins in `Sources/Plugins/`; the ways in are `Sources/Commands/`
and `Sources/Server/`. `Tests/BaguetteTests/` mirrors `Sources/`
([devices](features/devices/design.md#6--the-tree--outside-in-split-by-what-it-talks-to)).

| Context | Owns the question | Its root |
|---|---|---|
| **Common** (shared kernel) | *in what units?* | ◇ `Point` `Size` `Rect` `GesturePhase` `HIDUsage` `DeviceEdge` |
| **Device** (core) | *which devices are there, and what can each do?* | ◆ `Devices` → `Device` · ◇ `Abilities` `DeviceKind` `DeviceState` |
| **Simulator** | *what is a simulator made of?* | ◆ `Simulators` → `Simulator` → `Displays` · `InputSurface` · `SimulatorInjection` |
| **Screen** | *which framebuffer is this plane, which panel is it?* | ◆ `Screen` · ◇ `DisplayBinding` `ConnectedScreens` `IntegratedPanel` |
| **Input** (core) | *how does a gesture reach the device?* | ◆ `Touch` · `Press` · `Key` · `Scroll` · `DeviceKeys` · ◇ `Gesture` `DeviceButton` `Navigation` `HardwareButton` |
| **Hinge** | *how far open is the fold?* | ◆ `Hinge` · `HingeMotor` · ◇ `HingeAngle` `HingeCommand` |
| **Orientation** | *which way is it turned?* | ◆ `Orientation` |
| **Accessibility** | *what is on screen?* | ◆ `Accessibility` · ◇ `AXNode` `AXScreen` |
| **Chrome** · **Render** · **Capture** | *what does the device look like, and how is it framed?* | ◆ `Chromes` · `DeviceModels` · ◇ `CaptureSize` |
| **Stream** · **Recording** | *how do frames leave?* | ◆ `Stream` · `Reel` · `WebRTCViewers` → `WebRTCViewer` · ◇ `EncoderRetune` (when the encoder follows a viewer's target) |
| **WebRTCKit** (`Sources/WebRTCKit`, its own module; depends on nothing of baguette's) | *how does a stream reach a browser over WebRTC?* | ◆ `WebRTCSender` (one browser's session: `EncodedFrame` in, `SenderEvents` out — keyframe needed, the bitrate the link can take, hung up) · ◇ `SessionDescription` `ICECredentials` `MediaPorts` (signaling) · `STUNMessage` `Datagrams` `Handshake` `SRTPContext` (transport) · `RTPPacket` `H264Packetizer` `Pacer` `RTCPFeedback` (media; `RTPPacket` shared with CoreDevice) · `CongestionControl` `BandwidthEstimate` `TransportWideControl` (congestion) |
| **Location** · **Motion** · **Network** · **Interface** · **StatusBar** · **Shake** · **Camera** | *what conditions does the app run under?* | one ◆ role each |
| **Apps** · **Defaults** · **Pasteboard** · **Photos** | *which apps, and what data?* | one ◆ role each |
| **Logs** | *what is the device saying?* | ◆ `LogStream` · `Subprocess` |
| **Plugin** · **Bakery** | *what extends the page?* | ◆ `Plugins` · `Checkout` |
| **Companion** | *a physical phone's twin, through the companion app* | ◆ `CompanionPhones` · `CompanionDevices` (its source of `Devices`) |
| **CoreDevice** | *what is a phone on a cable, and how do its services talk?* | ◇ `PhysicalPhone` · `MediaStreamOffer` `ReceiverFeedback` `VideoDepacketizer` (its screen; `RTPPacket` is WebRTCKit's) · `ServiceDirectory` `XPCObject` `HTTP2Frame` `DTXMessage` `AXTreeDump` (its services) · `CoreDevicePhones` (its source of `Devices`, Infrastructure) |

## 6 · Where the code is still behind

The tree and laws above are the design; where the code disagrees, the code
moves, one change at a time.

| Node | The code today | Moves to |
|---|---|---|
| `Devices` | every command asks `Devices` for the ability it needs, and each role is bound to its device when registered; the `/simulators/…` routes still read `Simulators`, and `/devices/:udid/…` has only the device page, its stream and `screenshot` | every command and route through `devices.require(ability, of: id)` ([devices](features/devices/design.md)) |
| `Device.abilities` | `Simulator` declares 21 role factories every device would have to fake | registrations in `CoreSimulator`'s `Abilities` |
| `CompanionPhones` | the twin has its own `Devices` / `Device` (`capabilities: [String]`) and copies of the per-device routes | one source of `Devices`, one route tree |
| "no reading means folded" | written out as `angle()?.litPanel ?? .primary` at four call sites | `Hinge.litPanel` everywhere (#124); `Server.hingeJSON` keeps one read for both the degrees and the panel |
| "is this device a foldable" | answered three ways: `chromes.panels(…).contains(.secondary)`, `IntegratedPanels.several(in:)`, `observed.multiplePanels` | one question, one owner |
| the phone plane's target | picked by `DisplayTouchTarget.resolve` in `SimulatorKitDisplay.input()`, inline in `input(expected:)` | `DisplayTouchTarget.resolve` for both, and one place deciding `FoldableInput` |
| `Display.input()`'s doc | says the target is "derived from `connectedScreenId`, never a hard-coded CarPlay constant" | the registration law above (CarPlay is the constant `1`) |
| `IntegratedPanel` on the wire | `"primary"` / `"secondary"` spelled in `DeviceFrame` and twice in `Server` | one wire name on the value |
| `FoldableInput` | calls `log(…)` from the App layer | Domain logs nothing; the failure is its `Bool` |
| `LabelTap` · `ThenDescribe` | hold a law and assemble JSON in the App | a Domain value answers, and the App only projects it, as `Fill` does |
| `GuestHingeMotor` | plays `HingeMotor` and `DeviceKeys` over one guest helper | a name for the helper's role, not "motor" |

## 7 · Open

- ~~**Who owns "IndigoHID runs on the MainActor"?**~~ `IndigoHIDInput`: it
  builds each mouse message on the main thread (`onMainThread`), that call
  alone; gestures run on their device's `GestureQueues` lane. Settled when
  the server's `MainActor` hop held every simulator's gestures behind one
  drag.
- **argv in the Domain.** `LogFilter.argv`, `Coordinate.argument`,
  `PreferenceSuite.containerArguments` and friends are values that build a
  subprocess's arguments. Pure and tested — but is that business or technique?
- **An offline render's default pose.** `DeviceRenderPlan` takes a missing
  `--hinge-degrees` as 180° (flat). That is a picture's pose, not the device's
  hinge, so the folded rule doesn't apply — the doc should say so.
- **A phone held sideways.** Its accessibility frames come in the app's own
  points and its tree takes a portrait screen, so `tap --label` on a phone in
  landscape would place the touch wrong. The phone reports its orientation
  (`devicectl device info displays`); which node takes it is open.
- **Hinge ↔ Orientation.** `Hinge` uses `DeviceOrientation`; `Orientation`
  answers `PoseDelivery`. One should own the vocabulary.
